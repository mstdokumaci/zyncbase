// Unit tests for typed SQL methods on StorageEngine.
const std = @import("std");
const testing = std.testing;
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const StorageError = storage_engine.StorageError;
const msgpack = @import("msgpack_utils.zig");

fn makeField(name: []const u8, sql_type: schema_parser.FieldType, required: bool) schema_parser.Field {
    return .{
        .name = name,
        .sql_type = sql_type,
        .required = required,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

fn setupEngine(allocator: std.mem.Allocator, test_dir: []const u8, table: schema_parser.Table) !*StorageEngine {
    var dummy_fields = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var dummy_tables = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &dummy_fields }};
    const dummy_schema = schema_parser.Schema{ .version = "1.0.0", .tables = &dummy_tables };
    const engine = try StorageEngine.init(allocator, test_dir, &dummy_schema);
    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.writer_conn.execMulti(ddl_z, .{});
    return engine;
}

// Unit test 8.7: client writes blocked during migration
// Simulate an active migration transaction and assert that insertOrReplace / updateField
// return an error.
test "storage_engine_typed: unit 8.7 - client writes blocked during migration" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/typed_unit/8_7_migration_block";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const engine = try setupEngine(allocator, test_dir, table);
    defer engine.deinit();

    // Simulate migration in progress by setting migration_active = true
    engine.migration_active.store(true, .release);
    defer engine.migration_active.store(false, .release);

    // insertOrReplace should be blocked
    const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(1) }};
    const err1 = engine.insertOrReplace("items", "id1", "ns", &cols);
    try testing.expectError(StorageError.MigrationInProgress, err1);

    // updateField should be blocked
    const err2 = engine.updateField("items", "id1", "ns", "val", msgpack.Payload.intToPayload(2));
    try testing.expectError(StorageError.MigrationInProgress, err2);

    // deleteDocument should be blocked
    const err3 = engine.deleteDocument("items", "id1", "ns");
    try testing.expectError(StorageError.MigrationInProgress, err3);
}
