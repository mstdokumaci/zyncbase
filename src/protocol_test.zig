const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const schema_helpers = @import("schema_test_helpers.zig");
const storage_types = @import("storage_engine/types.zig");
const tth = @import("typed_test_helpers.zig");

fn makeDeltaTestRow(allocator: std.mem.Allocator, id: []const u8, namespace: []const u8, name: []const u8) !storage_types.TypedRow {
    const values = try allocator.alloc(storage_types.TypedValue, 5);
    errdefer allocator.free(values);

    values[0] = try tth.valTextOwned(allocator, id);
    errdefer values[0].deinit(allocator);
    values[1] = try tth.valTextOwned(allocator, namespace);
    errdefer values[1].deinit(allocator);
    values[2] = try tth.valTextOwned(allocator, name);
    errdefer values[2].deinit(allocator);
    values[3] = tth.valInt(0);
    values[4] = tth.valInt(0);

    return .{ .values = values };
}

test "extractAs: Envelope from valid map" {
    const allocator = testing.allocator;
    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreSet", allocator));
    try map.mapPut("id", Payload.uintToPayload(42));
    const result = try protocol.extractAs(protocol.Envelope, undefined, map);
    try testing.expectEqualStrings("StoreSet", result.type);
    try testing.expectEqual(@as(u64, 42), result.id);
}

test "extractAs: Envelope missing required field" {
    const allocator = testing.allocator;
    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreSet", allocator));
    const result = protocol.extractAs(protocol.Envelope, undefined, map);
    try testing.expectError(error.MissingRequiredFields, result);
}

test "extractAs: StorePathRequest from valid map" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var path_arr = try allocator.alloc(Payload, 3);

    path_arr[0] = Payload.uintToPayload(0); // table index
    path_arr[1] = try Payload.strToPayload("doc1", allocator);
    path_arr[2] = Payload.uintToPayload(2); // field index

    var map = Payload.mapPayload(allocator);
    try map.mapPut("namespace", try Payload.strToPayload("default", allocator));
    try map.mapPut("path", Payload{ .arr = path_arr });
    try map.mapPut("value", Payload{ .bool = true });

    const result = try protocol.extractAs(protocol.StorePathRequest, arena_allocator, map);
    try testing.expectEqualStrings("default", result.namespace);
    try testing.expect(result.path == .arr);
    try testing.expectEqual(@as(usize, 3), result.path.arr.len);
    try testing.expectEqual(@as(u64, 0), result.path.arr[0].uint);
    try testing.expectEqualStrings("doc1", result.path.arr[1].str.value());
    try testing.expectEqual(@as(u64, 2), result.path.arr[2].uint);
    try testing.expect(result.value != null);

    map.free(allocator);
}

test "extractAs: StorePathRequest without value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var path_arr = try allocator.alloc(Payload, 2);
    path_arr[0] = Payload.uintToPayload(0); // table index
    path_arr[1] = try Payload.strToPayload("doc1", allocator);

    var map = Payload.mapPayload(allocator);
    try map.mapPut("namespace", try Payload.strToPayload("default", allocator));
    try map.mapPut("path", Payload{ .arr = path_arr });

    const result = try protocol.extractAs(protocol.StorePathRequest, arena_allocator, map);
    try testing.expect(result.value == null);

    map.free(allocator);
}

test "extractAs: StoreCollectionRequest from valid map" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("namespace", try Payload.strToPayload("default", allocator));
    try map.mapPut("collection", Payload.uintToPayload(0));

    const result = try protocol.extractAs(protocol.StoreCollectionRequest, undefined, map);
    try testing.expectEqualStrings("default", result.namespace);
    try testing.expect(result.collection == .uint);
    try testing.expectEqual(@as(u64, 0), result.collection.uint);
}

test "extractAs: StoreUnsubscribeRequest from valid map" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("subId", Payload.uintToPayload(12345));

    const result = try protocol.extractAs(protocol.StoreUnsubscribeRequest, undefined, map);
    try testing.expectEqual(@as(u64, 12345), result.subId);
}

test "extractAs: StoreLoadMoreRequest from valid map" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("subId", Payload.uintToPayload(99));
    try map.mapPut("nextCursor", try Payload.strToPayload("abc123", allocator));

    const result = try protocol.extractAs(protocol.StoreLoadMoreRequest, undefined, map);
    try testing.expectEqual(@as(u64, 99), result.subId);
    try testing.expectEqualStrings("abc123", result.nextCursor);
}

test "extractAs: non-map payload returns InvalidMessageFormat" {
    const result = protocol.extractAs(protocol.Envelope, undefined, Payload{ .uint = 42 });
    try testing.expectError(error.InvalidMessageFormat, result);
}

test "extractAs: wrong type for field returns InvalidMessageFormat" {
    const allocator = testing.allocator;
    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", Payload.uintToPayload(42));
    try map.mapPut("id", Payload.uintToPayload(1));

    const result = protocol.extractAs(protocol.Envelope, undefined, map);
    try testing.expectError(error.InvalidMessageFormat, result);
}

test "buildSuccessResponse: produces valid MsgPack" {
    const allocator = testing.allocator;
    const response = try protocol.buildSuccessResponse(allocator, 12345);
    defer allocator.free(response);

    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    try testing.expect(parsed == .map);
    const type_val = (try parsed.mapGet("type")) orelse return error.MissingType;
    try testing.expectEqualStrings("ok", type_val.str.value());
    const id_val = (try parsed.mapGet("id")) orelse return error.MissingId;
    try testing.expectEqual(@as(u64, 12345), id_val.uint);
}

test "buildErrorResponse: produces valid MsgPack" {
    const allocator = testing.allocator;
    const response = try protocol.buildErrorResponse(allocator, 999, protocol.err_code_collection_not_found, protocol.err_msg_collection_not_found);
    defer allocator.free(response);

    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    try testing.expect(parsed == .map);
    const type_val = (try parsed.mapGet("type")) orelse return error.MissingType;
    try testing.expectEqualStrings("error", type_val.str.value());
    const id_val = (try parsed.mapGet("id")) orelse return error.MissingId;
    try testing.expectEqual(@as(u64, 999), id_val.uint);
    const code_val = (try parsed.mapGet("code")) orelse return error.MissingCode;
    try testing.expectEqualStrings("COLLECTION_NOT_FOUND", code_val.str.value());
    const msg_val = (try parsed.mapGet("message")) orelse return error.MissingMessage;
    try testing.expectEqualStrings("Collection missing in schema", msg_val.str.value());
}

test "encodeSetDeltaSuffix: set operation" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &.{"name"},
    }});
    defer sm.deinit();

    const table_metadata = sm.getTable("users") orelse return error.UnknownTable;
    const row = try makeDeltaTestRow(allocator, "user-123", "default", "Ada");
    defer row.deinit(allocator);

    const suffix = try protocol.encodeSetDeltaSuffix(allocator, table_metadata.index, tth.valText("user-123"), row, table_metadata);
    defer allocator.free(suffix);

    const full_msg = try std.mem.concat(allocator, u8, &.{ &[_]u8{0x81}, suffix });
    defer allocator.free(full_msg);
    var reader: std.Io.Reader = .fixed(full_msg);
    const p = try msgpack.decodeTrusted(allocator, &reader);
    defer p.free(allocator);

    const ops_opt = try p.mapGet("ops");
    try testing.expect(ops_opt != null);
    const ops = ops_opt.?;
    try testing.expect(ops == .arr);
    try testing.expectEqual(@as(usize, 1), ops.arr.len);

    const op_obj = ops.arr[0];
    try testing.expect(op_obj == .map);

    const op = (try op_obj.mapGet("op")) orelse return error.MissingOp;
    try testing.expectEqualStrings("set", op.str.value());

    const path = (try op_obj.mapGet("path")) orelse return error.MissingPath;
    try testing.expect(path == .arr);
    try testing.expectEqual(@as(usize, 2), path.arr.len);
    try testing.expectEqual(@as(u64, 0), path.arr[0].uint);
    try testing.expectEqualStrings("user-123", path.arr[1].str.value());

    // Value map now uses integer keys
    const value = try op_obj.mapGet("value");
    try testing.expect(value != null);
    try testing.expect(value.? == .map);
    // Integer key 0 = id field, key 1 = namespace_id, key 2 = name
    // Verify the map has entries with integer keys
    var val_it = value.?.map.iterator();
    var found_entries: usize = 0;
    while (val_it.next()) |_| found_entries += 1;
    try testing.expectEqual(@as(usize, 5), found_entries);
}

test "encodeDeleteDeltaSuffix: delete operation" {
    const allocator = testing.allocator;

    const id_val = tth.valInt(999);
    const suffix = try protocol.encodeDeleteDeltaSuffix(allocator, 0, id_val);
    defer allocator.free(suffix);

    const full_msg = try std.mem.concat(allocator, u8, &.{ &[_]u8{0x81}, suffix });
    defer allocator.free(full_msg);
    var reader: std.Io.Reader = .fixed(full_msg);
    const p = try msgpack.decodeTrusted(allocator, &reader);
    defer p.free(allocator);

    const ops_opt = try p.mapGet("ops");
    try testing.expect(ops_opt != null);
    const op_obj = ops_opt.?.arr[0];

    const op = (try op_obj.mapGet("op")) orelse return error.MissingOp;
    try testing.expectEqualStrings("remove", op.str.value());

    const path = (try op_obj.mapGet("path")) orelse return error.MissingPath;
    try testing.expectEqual(@as(u64, 0), path.arr[0].uint); // table index
    try testing.expectEqual(@as(u64, 999), path.arr[1].uint);

    try testing.expect((try op_obj.mapGet("value")) == null);
}

test "mapErrorToCode: returns non-empty comptime-encoded keys" {
    const code1 = protocol.mapErrorToCode(error.UnknownTable);
    try testing.expect(code1.len > 0);
    const code2 = protocol.mapErrorToCode(error.UnknownField);
    try testing.expect(code2.len > 0);
    try testing.expect(code1.len != code2.len or !std.mem.eql(u8, code1, code2));
}

test "mapErrorToMessage: returns non-empty comptime-encoded messages" {
    const msg1 = protocol.mapErrorToMessage(error.UnknownTable);
    try testing.expect(msg1.len > 0);
    const msg2 = protocol.mapErrorToMessage(error.UnknownField);
    try testing.expect(msg2.len > 0);
}

test "mapErrorToMessage: query parser errors keep distinct human messages" {
    try testing.expectEqualSlices(u8, protocol.err_msg_missing_query_operand, protocol.mapErrorToMessage(error.MissingOperand));
    try testing.expectEqualSlices(u8, protocol.err_msg_unexpected_query_operand, protocol.mapErrorToMessage(error.UnexpectedOperand));
    try testing.expectEqualSlices(u8, protocol.err_msg_invalid_in_operand, protocol.mapErrorToMessage(error.InvalidInOperand));
    try testing.expectEqualSlices(u8, protocol.err_msg_null_query_operand, protocol.mapErrorToMessage(error.NullOperandUnsupported));
    try testing.expectEqualSlices(u8, protocol.err_msg_unsupported_query_operator, protocol.mapErrorToMessage(error.UnsupportedOperatorForFieldType));
    try testing.expectEqualSlices(u8, protocol.err_msg_invalid_cursor_sort_value, protocol.mapErrorToMessage(error.InvalidCursorSortValue));
}

test "store_delta_header: decodes to StoreDelta type" {
    const allocator = testing.allocator;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &protocol.store_delta_header);
    try buf.append(allocator, 0xcf);
    try buf.writer(allocator).writeInt(u64, 42, .big);
    // Append a minimal ops array to complete the map
    // ops key + fixarray(0)
    try msgpack.writeMsgPackStr(buf.writer(allocator), "ops");
    try buf.append(allocator, 0x90); // fixarray(0)

    var reader: std.Io.Reader = .fixed(buf.items);
    const p = try msgpack.decodeTrusted(allocator, &reader);
    defer p.free(allocator);

    try testing.expect(p == .map);
    const type_val = (try p.mapGet("type")) orelse return error.MissingType;
    try testing.expectEqualStrings("StoreDelta", type_val.str.value());
    const sub_id_val = (try p.mapGet("subId")) orelse return error.MissingSubId;
    try testing.expectEqual(@as(u64, 42), sub_id_val.uint);
}

test "encodeDeleteDeltaSuffix: with string id" {
    const allocator = testing.allocator;

    const id_val = tth.valText("doc-abc-123");
    const suffix = try protocol.encodeDeleteDeltaSuffix(allocator, 1, id_val);
    defer allocator.free(suffix);

    // Decode and verify
    const full_msg = try std.mem.concat(allocator, u8, &.{ &[_]u8{0x81}, suffix });
    defer allocator.free(full_msg);
    var reader: std.Io.Reader = .fixed(full_msg);
    const p = try msgpack.decodeTrusted(allocator, &reader);
    defer p.free(allocator);

    const ops_opt = try p.mapGet("ops");
    try testing.expect(ops_opt != null);
    const ops = ops_opt.?;
    const op_obj = ops.arr[0];

    const path_opt = try op_obj.mapGet("path");
    try testing.expect(path_opt != null);
    const path = path_opt.?;
    try testing.expectEqual(@as(u64, 1), path.arr[0].uint); // table index
    try testing.expectEqualStrings("doc-abc-123", path.arr[1].str.value());
}

test "extractAs: respects default values" {
    const allocator = testing.allocator;

    const TestStruct = struct {
        required: u64,
        with_default: u64 = 42,
        optional_with_default: ?u64 = 100,
        optional_no_default: ?u64,
    };

    // Case 1: Only required field provided
    {
        var map = Payload.mapPayload(allocator);
        defer map.free(allocator);
        try map.mapPut("required", Payload.uintToPayload(10));

        const result = try protocol.extractAs(TestStruct, undefined, map);

        try testing.expectEqual(@as(u64, 10), result.required);
        try testing.expectEqual(@as(u64, 42), result.with_default);
        try testing.expectEqual(@as(?u64, 100), result.optional_with_default);
        try testing.expectEqual(@as(?u64, null), result.optional_no_default);
    }

    // Case 2: Overriding defaults
    {
        var map = Payload.mapPayload(allocator);
        defer map.free(allocator);
        try map.mapPut("required", Payload.uintToPayload(10));
        try map.mapPut("with_default", Payload.uintToPayload(50));
        try map.mapPut("optional_with_default", Payload.uintToPayload(200));
        try map.mapPut("optional_no_default", Payload.uintToPayload(300));

        const result = try protocol.extractAs(TestStruct, undefined, map);

        try testing.expectEqual(@as(u64, 10), result.required);
        try testing.expectEqual(@as(u64, 50), result.with_default);
        try testing.expectEqual(@as(?u64, 200), result.optional_with_default);
        try testing.expectEqual(@as(?u64, 300), result.optional_no_default);
    }
}
