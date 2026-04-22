const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema_manager = @import("../schema_manager.zig");
const sql_identifier = @import("../sql_identifier.zig");
const types = @import("types.zig");

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
    table_metadata: *const schema_manager.TableMetadata,
) !void {
    for (table_metadata.fields, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        if (f.sql_type == .array) {
            try buf.appendSlice(allocator, "json(");
            try sql_identifier.appendQuoted(allocator, buf, f.name);
            try buf.appendSlice(allocator, ") AS ");
            try sql_identifier.appendQuoted(allocator, buf, f.name);
        } else {
            try sql_identifier.appendQuoted(allocator, buf, f.name);
        }
    }
}

/// Safe bind helpers to avoid alignment errors with TSAN on ARM.
pub fn bindTextTransient(stmt: ?*sqlite.c.sqlite3_stmt, index: c_int, value: []const u8) c_int {
    return sqlite.c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), sqlite.c.sqliteTransientAsDestructor());
}

pub fn bindBlobTransient(stmt: ?*sqlite.c.sqlite3_stmt, index: c_int, value: []const u8) c_int {
    return sqlite.c.sqlite3_bind_blob(stmt, index, value.ptr, @intCast(value.len), sqlite.c.sqliteTransientAsDestructor());
}

pub fn buildInsertOrReplaceSql(
    allocator: Allocator,
    table_metadata: *const schema_manager.TableMetadata,
    columns: []const types.ColumnValue,
) ![]const u8 {
    const table = table_metadata.table.name;

    // Build SQL: INSERT INTO <table> (id, namespace_id, col1, .., created_at, updated_at)
    // VALUES (?, ?, .., ?, ?)
    // ON CONFLICT(id) DO UPDATE SET col1 = excluded.col1, .., updated_at = excluded.updated_at
    // WHERE <table>.namespace_id = excluded.namespace_id
    // Array columns use jsonb(?) instead of ? as the placeholder.
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "INSERT INTO ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, table);
    try sql_buf.appendSlice(allocator, " (");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "id");
    try sql_buf.appendSlice(allocator, ", ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "namespace_id");
    for (columns) |col| {
        const field = try getColumnField(table_metadata, col);
        try sql_buf.appendSlice(allocator, ", ");
        try sql_identifier.appendQuoted(allocator, &sql_buf, field.name);
    }
    try sql_buf.appendSlice(allocator, ", ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "created_at");
    try sql_buf.appendSlice(allocator, ", ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "updated_at");
    try sql_buf.appendSlice(allocator, ") VALUES (?, ?");
    for (columns) |col| {
        const field = try getColumnField(table_metadata, col);
        if (field.sql_type == .array) {
            try sql_buf.appendSlice(allocator, ", jsonb(?)");
        } else {
            try sql_buf.appendSlice(allocator, ", ?");
        }
    }
    // created_at and updated_at placeholders
    try sql_buf.appendSlice(allocator, ", ?, ?) ON CONFLICT(");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "id");
    try sql_buf.appendSlice(allocator, ") DO UPDATE SET ");

    // Update each column provided
    for (columns, 0..) |col, i| {
        const field = try getColumnField(table_metadata, col);
        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
        try sql_identifier.appendQuoted(allocator, &sql_buf, field.name);
        try sql_buf.appendSlice(allocator, " = excluded.");
        try sql_identifier.appendQuoted(allocator, &sql_buf, field.name);
    }
    // Always update updated_at
    if (columns.len > 0) try sql_buf.appendSlice(allocator, ", ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "updated_at");
    try sql_buf.appendSlice(allocator, " = excluded.");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "updated_at");
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql_identifier.appendQualified(allocator, &sql_buf, table, "namespace_id");
    try sql_buf.appendSlice(allocator, " = excluded.");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "namespace_id");
    try sql_buf.appendSlice(allocator, " RETURNING ");
    try appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);

    return sql_buf.toOwnedSlice(allocator);
}

fn getColumnField(
    table_metadata: *const schema_manager.TableMetadata,
    col: types.ColumnValue,
) !schema_manager.Field {
    if (col.index >= table_metadata.fields.len) return types.StorageError.UnknownField;
    return table_metadata.fields[col.index];
}

pub fn buildDeleteDocumentSql(
    allocator: Allocator,
    table_metadata: *const schema_manager.TableMetadata,
) ![]const u8 {
    const table = table_metadata.table.name;
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    try sql_buf.appendSlice(allocator, "DELETE FROM ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, table);
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "id");
    try sql_buf.appendSlice(allocator, "=? AND ");
    try sql_identifier.appendQuoted(allocator, &sql_buf, "namespace_id");
    try sql_buf.appendSlice(allocator, "=? RETURNING ");
    try appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    return sql_buf.toOwnedSlice(allocator);
}

test "storage SQL builders quote identifiers" {
    const allocator = std.testing.allocator;

    const fields = [_]schema_manager.Field{
        .{
            .name = "from",
            .sql_type = .text,
            .items_type = null,
            .required = false,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
    };
    const table = schema_manager.Table{
        .name = "select",
        .fields = @constCast(&fields),
    };
    var table_metadata = try schema_manager.TableMetadata.init(allocator, &table, 0);
    defer table_metadata.deinit(allocator);

    const columns = [_]types.ColumnValue{
        .{ .index = 2, .value = undefined },
    };

    const insert_sql = try buildInsertOrReplaceSql(allocator, &table_metadata, &columns);
    defer allocator.free(insert_sql);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "INSERT INTO \"select\" (\"id\", \"namespace_id\", \"from\", \"created_at\", \"updated_at\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"from\" = excluded.\"from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"select\".\"namespace_id\" = excluded.\"namespace_id\"") != null);

    const delete_sql = try buildDeleteDocumentSql(allocator, &table_metadata);
    defer allocator.free(delete_sql);
    try std.testing.expect(std.mem.indexOf(u8, delete_sql, "DELETE FROM \"select\" WHERE \"id\"=? AND \"namespace_id\"=? RETURNING ") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_sql, "\"id\", \"namespace_id\", \"from\", \"created_at\", \"updated_at\"") != null);
}
