const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema_manager = @import("../schema_manager.zig");

/// Specialized cache for sqlite3_stmt objects to avoid parsing overhead.
/// Implements a fixed-size LRU eviction policy using intrusive DoublyLinkedList (Zig 0.15+).
const Entry = struct {
    sql: []const u8,
    stmt: *sqlite.c.sqlite3_stmt,
    node: std.DoublyLinkedList.Node = .{},
};

pub const StatementCache = struct {
    const LruList = std.DoublyLinkedList;

    map: std.StringHashMap(*LruList.Node),
    list: LruList,
    count: usize,
    cache_limit: usize,

    pub fn init(allocator: Allocator, cache_limit: usize) StatementCache {
        return .{
            .map = std.StringHashMap(*LruList.Node).init(allocator),
            .list = LruList{},
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

    /// Adds a new statement to the cache. Returns true if it took ownership,
    /// false if it already exists (caller must finalize stmt).
    /// Evicts LRU if capacity exceeded.
    fn put(self: *StatementCache, allocator: Allocator, sql: []const u8, stmt: *sqlite.c.sqlite3_stmt) !bool {
        // Double check existence
        if (self.map.contains(sql)) return false;

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

        self.list.prepend(&entry.node);
        try self.map.put(sql_owned, &entry.node);
        self.count += 1;
        return true;
    }

    /// High-level helper to get a statement or prepare one if missing.
    /// Returns a ManagedStmt which ensures the statement is reset upon release.
    pub fn acquire(self: *StatementCache, allocator: Allocator, db: *sqlite.Db, sql: []const u8) !ManagedStmt {
        if (self.get(sql)) |stmt| {
            return ManagedStmt{ .stmt = stmt };
        }

        var stmt = try db.prepareDynamic(sql);
        errdefer stmt.deinit();

        if (!try self.put(allocator, sql, stmt.stmt)) {
            // Lost the race or redundancy - clean up and use winner
            stmt.deinit();
            return ManagedStmt{ .stmt = self.get(sql).? };
        }
        return ManagedStmt{ .stmt = stmt.stmt };
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
    table_metadata: schema_manager.TableMetadata,
) !void {
    try buf.appendSlice(allocator, "id, namespace_id");
    for (table_metadata.table.fields) |f| {
        try buf.appendSlice(allocator, ", ");
        if (f.sql_type == .array) {
            try buf.appendSlice(allocator, "json(");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, ") AS ");
            try buf.appendSlice(allocator, f.name);
        } else {
            try buf.appendSlice(allocator, f.name);
        }
    }
    try buf.appendSlice(allocator, ", created_at, updated_at");
}

/// Safe bind helpers to avoid alignment errors with TSAN on ARM.
pub fn bindTextTransient(stmt: ?*sqlite.c.sqlite3_stmt, index: c_int, value: []const u8) c_int {
    return sqlite.c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), sqlite.c.sqliteTransientAsDestructor());
}

pub fn bindBlobTransient(stmt: ?*sqlite.c.sqlite3_stmt, index: c_int, value: []const u8) c_int {
    return sqlite.c.sqlite3_bind_blob(stmt, index, value.ptr, @intCast(value.len), sqlite.c.sqliteTransientAsDestructor());
}
