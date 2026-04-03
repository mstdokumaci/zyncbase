const std = @import("std");
const testing = std.testing;
const storage_mod = @import("storage_engine.zig");
const StorageEngine = storage_mod.StorageEngine;
const ColumnValue = storage_mod.ColumnValue;
const msgpack = @import("msgpack_test_helpers.zig");
const ddl_generator = @import("ddl_generator.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;

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

    var context = try schema_helpers.TestContext.init(allocator, "storage-crud");
    defer context.deinit();
    const tmp_path = context.test_dir;

    // Setup schema
    var fields = try allocator.alloc(schema_manager.Field, 2);
    defer allocator.free(fields);
    fields[0] = .{ .name = "name", .sql_type = .text, .required = true, .indexed = false, .references = null, .on_delete = null };
    fields[1] = .{ .name = "age", .sql_type = .integer, .required = true, .indexed = false, .references = null, .on_delete = null };

    var tables = try allocator.alloc(schema_manager.Table, 1);
    defer allocator.free(tables);
    tables[0] = .{ .name = "users", .fields = fields };

    const schema = schema_manager.Schema{ .version = "1.0.0", .tables = tables };
    const sm = try SchemaManager.initWithSchema(allocator, try schema.clone(allocator));
    defer sm.deinit();

    // Initialize memory strategy
    var memory_strategy: @import("memory_strategy.zig").MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();

    var storage = try StorageEngine.init(allocator, &memory_strategy, tmp_path, sm, .{}, .{ .in_memory = true });
    defer storage.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    const table_metadata = sm.getTable("users") orelse return error.TableNotFound;
    const table = table_metadata.table;
    const ddl = try gen.generateDDL(table.*);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try storage.writer_conn.execMulti(ddl_z, .{});
    // 1. Create (Insert)
    {
        const cols = try createUserCols(allocator, "Alice", 30);
        defer freeUserCols(allocator, cols);
        try storage.insertOrReplace("users", "1", "test_ns", cols);
    }
    try storage.flushPendingWrites();
    // 2. Read (Select)
    {
        var managed = try storage.selectDocument(allocator, "users", "1", "test_ns");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
        if (doc) |d| {
            const val = msgpack.getMapValue(d, "name") orelse return error.TestExpectedError;
            try testing.expectEqualStrings("Alice", val.str.value());
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
        var managed = try storage.selectDocument(allocator, "users", "1", "test_ns");
        defer managed.deinit();
        const doc = managed.value;
        if (doc) |d| {
            const val = msgpack.getMapValue(d, "age") orelse return error.TestExpectedError;
            const actual_age: i64 = switch (val) {
                .int => |v| v,
                .uint => |v| @intCast(v),
                else => unreachable,
            };
            try testing.expectEqual(@as(i64, 31), actual_age);
        }
    }
    // 4. Delete
    try storage.deleteDocument("users", "1", "test_ns");
    try storage.flushPendingWrites();
    // Verify deletion
    {
        var managed = try storage.selectDocument(allocator, "users", "1", "test_ns");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc == null);
    }
}
