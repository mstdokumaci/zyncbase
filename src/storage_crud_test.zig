const std = @import("std");
const testing = std.testing;
const storage_mod = @import("storage_engine.zig");
const StorageEngine = storage_mod.StorageEngine;
const ColumnValue = storage_mod.ColumnValue;
const msgpack = @import("msgpack_utils.zig");
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");

// Helper to create a ColumnValue array for a simple user object
fn createUserCols(allocator: std.mem.Allocator, name: []const u8, age: i64) ![]ColumnValue {
    const cols = try allocator.alloc(ColumnValue, 2);
    cols[0] = .{ .name = "name", .value = try msgpack.Payload.strToPayload(name, allocator) };
    cols[1] = .{ .name = "age", .value = .{ .int = age } };
    return cols;
}

fn freeUserCols(allocator: std.mem.Allocator, cols: []ColumnValue) void {
    for (cols) |col| col.value.free(allocator);
    allocator.free(cols);
}

test "Storage: CRUD operations" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/storage_crud";
    std.fs.cwd().makePath(tmp_path) catch {}; // zwanzig-disable-line: empty-catch-engine
    defer std.fs.cwd().deleteTree(tmp_path) catch {}; // zwanzig-disable-line: empty-catch-engine

    // Setup schema
    var fields = try allocator.alloc(schema_parser.Field, 2);
    fields[0] = .{ .name = "name", .sql_type = .text, .required = true, .indexed = false, .references = null, .on_delete = null };
    fields[1] = .{ .name = "age", .sql_type = .integer, .required = true, .indexed = false, .references = null, .on_delete = null };
    const table = schema_parser.Table{ .name = "users", .fields = fields };

    const schema_ptr = try allocator.create(schema_parser.Schema);
    const tables = try allocator.alloc(schema_parser.Table, 1);
    tables[0] = try table.clone(allocator);
    schema_ptr.* = .{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };

    // Initialize memory strategy
    var memory_strategy: @import("memory_strategy.zig").MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();

    var storage = try StorageEngine.init(allocator, &memory_strategy, tmp_path, schema_ptr);
    defer {
        storage.deinit();
        schema_parser.freeSchema(allocator, schema_ptr.*);
        allocator.destroy(schema_ptr);
    }
    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try storage.writer_conn.execMulti(ddl_z, .{});
    allocator.free(fields);
    // 1. Create (Insert)
    {
        const cols = try createUserCols(allocator, "Alice", 30);
        defer freeUserCols(allocator, cols);
        try storage.insertOrReplace("users", "1", "test_ns", cols);
    }
    try storage.flushPendingWrites();
    // 2. Read (Select)
    {
        const doc = try storage.selectDocument("users", "1", "test_ns");
        defer if (doc) |d| d.free(allocator);
        try testing.expect(doc != null);
        if (doc) |d| {
            var found_name = false;
            var it = d.map.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.str.value(), "name")) {
                    try testing.expectEqualStrings("Alice", entry.value_ptr.str.value());
                    found_name = true;
                }
            }
            try testing.expect(found_name);
        }
    }
    // 3. Update (InsertOrReplace with new data)
    {
        const cols = try createUserCols(allocator, "Alice Updated", 31);
        defer freeUserCols(allocator, cols);
        try storage.insertOrReplace("users", "1", "test_ns", cols);
    }
    try storage.flushPendingWrites();
    // Verify update
    {
        const doc = try storage.selectDocument("users", "1", "test_ns");
        defer if (doc) |d| d.free(allocator);
        if (doc) |d| {
            var it = d.map.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.str.value(), "age")) {
                    const actual_age: i64 = switch (entry.value_ptr.*) {
                        .int => |v| v,
                        .uint => |v| @intCast(v),
                        else => unreachable,
                    };
                    try testing.expectEqual(@as(i64, 31), actual_age);
                }
            }
        }
    }
    // 4. Delete
    try storage.deleteDocument("users", "1", "test_ns");
    try storage.flushPendingWrites();
    // Verify deletion
    {
        const doc = try storage.selectDocument("users", "1", "test_ns");
        defer if (doc) |d| d.free(allocator);
        try testing.expect(doc == null);
    }
}
