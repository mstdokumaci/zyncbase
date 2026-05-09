const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema = @import("../schema.zig");
const errors = @import("errors.zig");
const typed = @import("../typed.zig");

/// A schema field index + typed value pair for storage inserts/updates.
pub const ColumnValue = struct {
    index: usize,
    value: typed.TypedValue,
};

/// Specialized cache for sqlite3_stmt objects to avoid parsing overhead.
/// Implements a fixed-size LRU eviction policy using intrusive DoublyLinkedList (Zig 0.15+).
const Entry = struct {
    sql: []const u8,
    stmt: *sqlite.c.sqlite3_stmt,
    node: std.DoublyLinkedList.Node = .{},
};

/// Not thread-safe. Each thread must have its own instance.
pub const StatementCache = struct {
    const LruList = std.DoublyLinkedList;

    map: std.StringHashMap(*LruList.Node),
    list: LruList,
    count: usize,
    cache_limit: usize,

    pub fn init(self: *StatementCache, allocator: Allocator, cache_limit: usize) void {
        const map = std.StringHashMap(*LruList.Node).init(allocator);
        const list = LruList{};
        self.* = .{
            .map = map,
            .list = list,
            .count = 0,
            .cache_limit = cache_limit,
        };
    }

    pub fn deinit(self: *StatementCache, allocator: Allocator) void {
        self.clear(allocator);
        self.map.deinit();
    }

    /// Finalizes all cached statements and clears the cache.
    fn clear(self: *StatementCache, allocator: Allocator) void {
        var it = self.list.first;
        while (it) |node| {
            const next = node.next;
            const entry: *Entry = @fieldParentPtr("node", node);
            _ = sqlite.c.sqlite3_finalize(entry.stmt);
            allocator.free(entry.sql);
            allocator.destroy(entry);
            it = next;
        }
        self.map.clearRetainingCapacity();
        self.list = LruList{};
        self.count = 0;
    }

    /// Retrieves a prepared statement matched by SQL string.
    /// Returns null if not in cache. Updates LRU on hit.
    fn get(self: *StatementCache, sql: []const u8) ?*sqlite.c.sqlite3_stmt {
        const node = self.map.get(sql) orelse return null;
        const entry: *Entry = @fieldParentPtr("node", node);

        // Move to front (Most Recently Used)
        self.list.remove(node);
        self.list.prepend(node);

        // Reset and clear bindings for fresh use
        _ = sqlite.c.sqlite3_reset(entry.stmt);
        _ = sqlite.c.sqlite3_clear_bindings(entry.stmt);

        return entry.stmt;
    }

    /// Adds a new statement to the cache. Evicts LRU if capacity exceeded.
    fn put(self: *StatementCache, allocator: Allocator, sql: []const u8, stmt: *sqlite.c.sqlite3_stmt) !void {
        // Evict if at capacity
        if (self.count >= self.cache_limit) {
            if (self.list.last) |old_node| {
                const old_entry: *Entry = @fieldParentPtr("node", old_node);
                self.list.remove(old_node);
                _ = self.map.remove(old_entry.sql);
                _ = sqlite.c.sqlite3_finalize(old_entry.stmt);
                allocator.free(old_entry.sql);
                allocator.destroy(old_entry);
                self.count -= 1;
            }
        }

        const sql_owned = try allocator.dupe(u8, sql);
        errdefer allocator.free(sql_owned);

        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);

        entry.* = .{
            .sql = sql_owned,
            .stmt = stmt,
            .node = .{},
        };

        try self.map.put(sql_owned, &entry.node);
        self.list.prepend(&entry.node);
        self.count += 1;
    }

    /// High-level helper to get a statement or prepare one if missing.
    /// Returns a ManagedStmt which ensures the statement is reset upon release.
    pub fn acquire(self: *StatementCache, allocator: Allocator, db: *sqlite.Db, sql: []const u8) !ManagedStmt {
        if (self.get(sql)) |stmt| {
            return ManagedStmt{ .stmt = stmt };
        }

        const stmt = blk: {
            const dynamic = try db.prepareDynamic(sql);
            break :blk dynamic.stmt;
        };
        errdefer _ = sqlite.c.sqlite3_finalize(stmt);

        try self.put(allocator, sql, stmt);
        return ManagedStmt{ .stmt = stmt };
    }
};

/// RAII-like wrapper for cached statements to ensure they are clean when returned to the cache.
pub const ManagedStmt = struct {
    stmt: *sqlite.c.sqlite3_stmt,

    pub fn release(self: *ManagedStmt) void {
        _ = sqlite.c.sqlite3_reset(self.stmt);
        _ = sqlite.c.sqlite3_clear_bindings(self.stmt);
    }
};

/// Appends the standard ZyncBase column projection list (id, namespace_id, all fields, timestamps)
/// to the provided buffer. Array/object fields are wrapped in json() to ensure they return
/// text even if stored as JSONB.
pub fn appendProjectedColumnsSql(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    table_metadata: *const schema.Table,
) !void {
    for (table_metadata.fields, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        if (f.storage_type == .array) {
            try buf.appendSlice(allocator, "json(");
            try buf.appendSlice(allocator, f.name_quoted);
            try buf.appendSlice(allocator, ") AS ");
            try buf.appendSlice(allocator, f.name_quoted);
        } else {
            try buf.appendSlice(allocator, f.name_quoted);
        }
    }
}

pub fn appendSelectFromTableSql(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    table_metadata: *const schema.Table,
) !void {
    try buf.appendSlice(allocator, "SELECT ");
    try appendProjectedColumnsSql(allocator, buf, table_metadata);
    try buf.appendSlice(allocator, " FROM ");
    try buf.appendSlice(allocator, table_metadata.name_quoted);
}

pub fn appendNamespaceFilterSql(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
) !void {
    try buf.appendSlice(allocator, schema.quoted_namespace_id);
    try buf.appendSlice(allocator, " = ?");
}

pub fn appendCursorPredicateSql(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    sort_field_name_quoted: []const u8,
    sort_field_is_id: bool,
    desc: bool,
) !void {
    const op = if (desc) "<" else ">";

    if (sort_field_is_id) {
        try buf.appendSlice(allocator, schema.quoted_id);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, op);
        try buf.appendSlice(allocator, " ?");
        return;
    }

    try buf.append(allocator, '(');
    try buf.appendSlice(allocator, sort_field_name_quoted);
    try buf.appendSlice(allocator, ", ");
    try buf.appendSlice(allocator, schema.quoted_id);
    try buf.appendSlice(allocator, ") ");
    try buf.appendSlice(allocator, op);
    try buf.appendSlice(allocator, " (?, ?)");
}

pub fn appendOrderBySql(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    sort_field_name_quoted: []const u8,
    desc: bool,
) !void {
    try buf.appendSlice(allocator, " ORDER BY ");
    try buf.appendSlice(allocator, sort_field_name_quoted);
    try buf.appendSlice(allocator, if (desc) " DESC" else " ASC");
    try buf.appendSlice(allocator, ", ");
    try buf.appendSlice(allocator, schema.quoted_id);
    try buf.appendSlice(allocator, if (desc) " DESC" else " ASC");
}

pub fn buildSelectDocumentSql(
    allocator: Allocator,
    table_metadata: *const schema.Table,
    guard_sql: ?[]const u8,
) ![]const u8 {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try appendSelectFromTableSql(allocator, &sql_buf, table_metadata);
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql_buf.appendSlice(allocator, schema.quoted_id);
    try sql_buf.appendSlice(allocator, "=? AND ");
    try sql_buf.appendSlice(allocator, schema.quoted_namespace_id);
    try sql_buf.appendSlice(allocator, "=?");
    if (guard_sql) |fragment| {
        try sql_buf.appendSlice(allocator, fragment);
    }
    return sql_buf.toOwnedSlice(allocator);
}

/// Safe bind helpers to avoid alignment errors with TSAN on ARM.
pub fn bindTextTransient(stmt: ?*sqlite.c.sqlite3_stmt, index: c_int, value: []const u8) c_int {
    return sqlite.c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), sqlite.c.sqliteTransientAsDestructor());
}

pub fn bindBlobTransient(stmt: ?*sqlite.c.sqlite3_stmt, index: c_int, value: []const u8) c_int {
    return sqlite.c.sqlite3_bind_blob(stmt, index, value.ptr, @intCast(value.len), sqlite.c.sqliteTransientAsDestructor());
}

pub fn bindTypedValue(typed_value: typed.TypedValue, db: *sqlite.Db, stmt: *sqlite.c.sqlite3_stmt, index: c_int, allocator: Allocator) !void {
    const rc = switch (typed_value) {
        .scalar => |s| switch (s) {
            .doc_id => |id| blk: {
                const bytes = typed.docIdToBytes(id);
                break :blk bindBlobTransient(stmt, index, &bytes);
            },
            .integer => |v| sqlite.c.sqlite3_bind_int64(stmt, index, v),
            .real => |v| sqlite.c.sqlite3_bind_double(stmt, index, v),
            .text => |s_val| bindTextTransient(stmt, index, s_val),
            .boolean => |b| sqlite.c.sqlite3_bind_int(stmt, index, if (b) 1 else 0),
        },
        .nil => sqlite.c.sqlite3_bind_null(stmt, index),
        .array => |items| blk: {
            const json = try typed.jsonAlloc(allocator, .{ .array = items });
            defer allocator.free(json);
            break :blk bindTextTransient(stmt, index, json);
        },
    };
    if (rc != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
}

pub fn typedValueFromColumn(allocator: Allocator, stmt: *sqlite.c.sqlite3_stmt, i: c_int, field: schema.Field) !typed.TypedValue {
    const col_type = sqlite.c.sqlite3_column_type(stmt, i);
    if (field.storage_type == .array and col_type == sqlite.c.SQLITE_TEXT) {
        const ptr = sqlite.c.sqlite3_column_text(stmt, i);
        const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt, i));
        const s = if (ptr != null) ptr[0..len] else "[]";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, s, .{});
        defer parsed.deinit();
        return typed.valueFromJson(allocator, field.storage_type, field.items_type, parsed.value);
    }

    return switch (col_type) {
        sqlite.c.SQLITE_BLOB => blk: {
            if (field.storage_type != .doc_id) break :blk .nil;
            const ptr = sqlite.c.sqlite3_column_blob(stmt, i);
            const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt, i));
            const bytes = if (ptr != null) @as([*]const u8, @ptrCast(ptr))[0..len] else &[_]u8{};
            break :blk typed.TypedValue{ .scalar = .{ .doc_id = try typed.docIdFromBytes(bytes) } };
        },
        sqlite.c.SQLITE_INTEGER => {
            const val = sqlite.c.sqlite3_column_int64(stmt, i);
            if (field.storage_type == .boolean) {
                return typed.TypedValue{ .scalar = .{ .boolean = val != 0 } };
            }
            return typed.TypedValue{ .scalar = .{ .integer = val } };
        },
        sqlite.c.SQLITE_FLOAT => typed.TypedValue{ .scalar = .{ .real = sqlite.c.sqlite3_column_double(stmt, i) } },
        sqlite.c.SQLITE_TEXT => blk: {
            const ptr = sqlite.c.sqlite3_column_text(stmt, i);
            const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt, i));
            const s = if (ptr != null) ptr[0..len] else "";
            break :blk typed.TypedValue{ .scalar = .{ .text = try allocator.dupe(u8, s) } };
        },
        else => .nil,
    };
}

pub fn ensureNamespaceTable(db: *sqlite.Db) !void {
    db.exec(
        "CREATE TABLE IF NOT EXISTS _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)",
        .{},
        .{},
    ) catch |err| return errors.classifyError(err);
    db.exec(
        "INSERT OR IGNORE INTO _zync_namespaces (id, name) VALUES (0, '$global')",
        .{},
        .{},
    ) catch |err| return errors.classifyError(err);
}

pub fn resolveNamespaceId(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt_cache: *StatementCache,
    namespace: []const u8,
) !i64 {
    const sql_text =
        \\INSERT INTO _zync_namespaces (name)
        \\VALUES (?)
        \\ON CONFLICT(name) DO UPDATE SET name = excluded.name
        \\RETURNING id
    ;
    var mstmt = try stmt_cache.acquire(allocator, db, sql_text);
    defer mstmt.release();

    if (bindTextTransient(mstmt.stmt, 1, namespace) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    const rc = sqlite.c.sqlite3_step(mstmt.stmt);
    if (rc == sqlite.c.SQLITE_ROW) return sqlite.c.sqlite3_column_int64(mstmt.stmt, 0);
    if (rc != sqlite.c.SQLITE_DONE) return errors.classifyStepError(db);
    return errors.StorageError.InvalidOperation;
}

pub fn lookupNamespaceId(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt_cache: *StatementCache,
    namespace: []const u8,
) !?i64 {
    const sql_text = "SELECT id FROM _zync_namespaces WHERE name = ?";
    var mstmt = try stmt_cache.acquire(allocator, db, sql_text);
    defer mstmt.release();

    if (bindTextTransient(mstmt.stmt, 1, namespace) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    const rc = sqlite.c.sqlite3_step(mstmt.stmt);
    if (rc == sqlite.c.SQLITE_ROW) return sqlite.c.sqlite3_column_int64(mstmt.stmt, 0);
    if (rc == sqlite.c.SQLITE_DONE) return null;
    return errors.classifyStepError(db);
}

pub fn resolveUserId(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt_cache: *StatementCache,
    namespace_id: i64,
    external_id: []const u8,
    timestamp: i64,
) !typed.DocId {
    const new_user_id = typed.generateUuidV7();
    const id_bytes = typed.docIdToBytes(new_user_id);
    const sql_text =
        \\INSERT INTO "users" ("id", "namespace_id", "owner_id", "external_id", "created_at", "updated_at")
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT("namespace_id", "external_id") DO UPDATE SET "external_id" = excluded."external_id"
        \\RETURNING "id"
    ;
    var mstmt = try stmt_cache.acquire(allocator, db, sql_text);
    defer mstmt.release();

    if (bindBlobTransient(mstmt.stmt, 1, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    if (sqlite.c.sqlite3_bind_int64(mstmt.stmt, 2, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    if (bindBlobTransient(mstmt.stmt, 3, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    if (bindTextTransient(mstmt.stmt, 4, external_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    if (sqlite.c.sqlite3_bind_int64(mstmt.stmt, 5, timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    if (sqlite.c.sqlite3_bind_int64(mstmt.stmt, 6, timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);

    const rc = sqlite.c.sqlite3_step(mstmt.stmt);
    if (rc == sqlite.c.SQLITE_ROW) {
        const ptr = sqlite.c.sqlite3_column_blob(mstmt.stmt, 0);
        const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(mstmt.stmt, 0));
        const bytes = if (ptr != null) @as([*]const u8, @ptrCast(ptr))[0..len] else &[_]u8{};
        return typed.docIdFromBytes(bytes) catch return errors.StorageError.TypeMismatch;
    }
    if (rc != sqlite.c.SQLITE_DONE) return errors.classifyStepError(db);
    return errors.StorageError.InvalidOperation;
}

pub fn buildInsertOrReplaceSql(
    allocator: Allocator,
    table_metadata: *const schema.Table,
    columns: []const ColumnValue,
    guard_sql: ?[]const u8,
) ![]const u8 {
    const table_quoted = table_metadata.name_quoted;

    // Build SQL: INSERT INTO <table> (id, namespace_id, owner_id, col1, .., created_at, updated_at)
    // VALUES (?, ?, ?, .., ?, ?)
    // ON CONFLICT(id) DO UPDATE SET col1 = excluded.col1, .., updated_at = excluded.updated_at
    // WHERE <table>.namespace_id = excluded.namespace_id
    // Array columns use jsonb(?) instead of ? as the placeholder.
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "INSERT INTO ");
    try sql_buf.appendSlice(allocator, table_quoted);
    try sql_buf.appendSlice(allocator, " (");
    try sql_buf.appendSlice(allocator, schema.quoted_id);
    try sql_buf.appendSlice(allocator, ", ");
    try sql_buf.appendSlice(allocator, schema.quoted_namespace_id);
    try sql_buf.appendSlice(allocator, ", ");
    try sql_buf.appendSlice(allocator, schema.quoted_owner_id);
    if (table_metadata.is_users_table) {
        try sql_buf.appendSlice(allocator, ", ");
        try sql_buf.appendSlice(allocator, schema.quoted_external_id);
    }
    for (columns) |col| {
        const field = try getColumnField(table_metadata, col);
        try sql_buf.appendSlice(allocator, ", ");
        try sql_buf.appendSlice(allocator, field.name_quoted);
    }
    try sql_buf.appendSlice(allocator, ", ");
    try sql_buf.appendSlice(allocator, schema.quoted_created_at);
    try sql_buf.appendSlice(allocator, ", ");
    try sql_buf.appendSlice(allocator, schema.quoted_updated_at);
    try sql_buf.appendSlice(allocator, ") VALUES (?, ?, ?");
    if (table_metadata.is_users_table) {
        try sql_buf.appendSlice(allocator, ", ?");
    }
    for (columns) |col| {
        const field = try getColumnField(table_metadata, col);
        if (field.storage_type == .array) {
            try sql_buf.appendSlice(allocator, ", jsonb(?)");
        } else {
            try sql_buf.appendSlice(allocator, ", ?");
        }
    }
    // created_at and updated_at placeholders
    try sql_buf.appendSlice(allocator, ", ?, ?) ON CONFLICT(");
    try sql_buf.appendSlice(allocator, schema.quoted_id);
    try sql_buf.appendSlice(allocator, ") DO UPDATE SET ");

    // Update each column provided
    for (columns, 0..) |col, i| {
        const field = try getColumnField(table_metadata, col);
        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
        try sql_buf.appendSlice(allocator, field.name_quoted);
        try sql_buf.appendSlice(allocator, " = excluded.");
        try sql_buf.appendSlice(allocator, field.name_quoted);
    }
    // Always update updated_at
    if (columns.len > 0) try sql_buf.appendSlice(allocator, ", ");
    try sql_buf.appendSlice(allocator, schema.quoted_updated_at);
    try sql_buf.appendSlice(allocator, " = excluded.");
    try sql_buf.appendSlice(allocator, schema.quoted_updated_at);
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql_buf.appendSlice(allocator, table_quoted);
    try sql_buf.appendSlice(allocator, ".");
    try sql_buf.appendSlice(allocator, schema.quoted_namespace_id);
    try sql_buf.appendSlice(allocator, " = excluded.");
    try sql_buf.appendSlice(allocator, schema.quoted_namespace_id);
    if (guard_sql) |fragment| {
        try sql_buf.appendSlice(allocator, fragment);
    }
    try sql_buf.appendSlice(allocator, " RETURNING ");
    try appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);

    return sql_buf.toOwnedSlice(allocator);
}

fn getColumnField(
    table_metadata: *const schema.Table,
    col: ColumnValue,
) !schema.Field {
    if (col.index >= table_metadata.fields.len) return errors.StorageError.UnknownField;
    return table_metadata.fields[col.index];
}

pub fn buildDeleteDocumentSql(
    allocator: Allocator,
    table_metadata: *const schema.Table,
    guard_sql: ?[]const u8,
) ![]const u8 {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    try sql_buf.appendSlice(allocator, "DELETE FROM ");
    try sql_buf.appendSlice(allocator, table_metadata.name_quoted);
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql_buf.appendSlice(allocator, schema.quoted_id);
    try sql_buf.appendSlice(allocator, "=? AND ");
    try sql_buf.appendSlice(allocator, schema.quoted_namespace_id);
    try sql_buf.appendSlice(allocator, "=?");
    if (guard_sql) |fragment| {
        try sql_buf.appendSlice(allocator, fragment);
    }
    try sql_buf.appendSlice(allocator, " RETURNING ");
    try appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    return sql_buf.toOwnedSlice(allocator);
}
