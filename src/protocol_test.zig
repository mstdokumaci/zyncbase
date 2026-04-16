const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const tth = @import("typed_test_helpers.zig");

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

    path_arr[0] = try Payload.strToPayload("items", allocator);
    path_arr[1] = try Payload.strToPayload("doc1", allocator);
    path_arr[2] = try Payload.strToPayload("tags", allocator);

    var map = Payload.mapPayload(allocator);
    try map.mapPut("namespace", try Payload.strToPayload("default", allocator));
    try map.mapPut("path", Payload{ .arr = path_arr });
    try map.mapPut("value", Payload{ .bool = true });

    const result = try protocol.extractAs(protocol.StorePathRequest, arena_allocator, map);
    try testing.expectEqualStrings("default", result.namespace);
    try testing.expectEqual(@as(usize, 3), result.path.len);
    try testing.expectEqualStrings("items", result.path[0]);
    try testing.expectEqualStrings("doc1", result.path[1]);
    try testing.expectEqualStrings("tags", result.path[2]);
    try testing.expect(result.value != null);

    map.free(allocator);
}

test "extractAs: StorePathRequest without value" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var path_arr = try allocator.alloc(Payload, 2);
    path_arr[0] = try Payload.strToPayload("items", allocator);
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
    try map.mapPut("collection", try Payload.strToPayload("users", allocator));

    const result = try protocol.extractAs(protocol.StoreCollectionRequest, undefined, map);
    try testing.expectEqualStrings("default", result.namespace);
    try testing.expectEqualStrings("users", result.collection);
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

test "encodeDeltaSuffix: set operation" {
    const allocator = testing.allocator;

    const id_val = tth.valInt(12345);
    const suffix = try protocol.encodeDeltaSuffix(allocator, "users", id_val, false, null);
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
    try testing.expectEqualStrings("users", path.arr[0].str.value());
    try testing.expectEqual(@as(u64, 12345), path.arr[1].uint);

    const value = try op_obj.mapGet("value");
    try testing.expect(value != null);
    try testing.expect(value.? == .nil);
}

test "encodeDeltaSuffix: delete operation" {
    const allocator = testing.allocator;

    const id_val = tth.valInt(999);
    const suffix = try protocol.encodeDeltaSuffix(allocator, "items", id_val, true, null);
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
    try testing.expectEqualStrings("items", path.arr[0].str.value());
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

test "encodeDeltaSuffix: with string id" {
    const allocator = testing.allocator;

    const id_val = tth.valText("doc-abc-123");
    const suffix = try protocol.encodeDeltaSuffix(allocator, "posts", id_val, false, null);
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
    try testing.expectEqualStrings("posts", path.arr[0].str.value());
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
