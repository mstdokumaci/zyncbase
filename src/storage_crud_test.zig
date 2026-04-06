const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const ColumnValue = storage_engine.ColumnValue;
const schema_manager = @import("schema_manager.zig");
const sth = @import("storage_engine_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");

test "StorageEngine: insert and select basic" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("name", .text, false),
        sth.makeField("age", .integer, false),
    };
    const table = schema_manager.Table{ .name = "users", .fields = &fields_arr };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "crud-basic", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Insert
    const name_p = try msgpack.Payload.strToPayload("Alice", allocator);
    defer name_p.free(allocator);
    const cols = [_]ColumnValue{
        .{ .name = "name", .value = name_p },
        .{ .name = "age", .value = msgpack.Payload.intToPayload(30) },
    };
    try engine.insertOrReplace("users", "id1", "ns", &cols);
    try engine.flushPendingWrites();

    // Select
    var managed = try engine.selectDocument(allocator, "users", "id1", "ns");
    defer managed.deinit();
    const doc = managed.value orelse return error.NotFound;

    try testing.expectEqualStrings("Alice", (try doc.mapGet("name")).?.str.value());
    try testing.expectEqual(@as(i64, 30), (try doc.mapGet("age")).?.int);
}

test "StorageEngine: update document" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("val", .text, false),
    };
    const table = schema_manager.Table{ .name = "test", .fields = &fields_arr };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "crud-update", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    const val1 = try sth.makePayloadStr("v1", allocator);
    defer val1.free(allocator);
    const cols1 = [_]ColumnValue{.{ .name = "val", .value = val1 }};
    try engine.insertOrReplace("test", "id1", "ns", &cols1);
    try engine.flushPendingWrites();

    const val2 = try sth.makePayloadStr("v2", allocator);
    defer val2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "val", .value = val2 }};
    try engine.insertOrReplace("test", "id1", "ns", &cols2);
    try engine.flushPendingWrites();

    var managed = try engine.selectDocument(allocator, "test", "id1", "ns");
    defer managed.deinit();
    const doc = managed.value orelse return error.TestValueMissing;
    try testing.expectEqualStrings("v2", (try doc.mapGet("val")).?.str.value());
}

test "StorageEngine: delete document" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("val", .text, false),
    };
    const table = schema_manager.Table{ .name = "test", .fields = &fields_arr };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "crud-delete", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    const p = try sth.makePayloadStr("foo", allocator);
    defer p.free(allocator);
    try engine.insertOrReplace("test", "id1", "ns", &[_]ColumnValue{.{ .name = "val", .value = p }});
    try engine.flushPendingWrites();

    try engine.deleteDocument("test", "id1", "ns");
    try engine.flushPendingWrites();

    var managed = try engine.selectDocument(allocator, "test", "id1", "ns");
    defer managed.deinit();
    try testing.expect(managed.value == null);
}
