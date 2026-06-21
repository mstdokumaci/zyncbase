const std = @import("std");
const testing = std.testing;
const wire = @import("wire.zig");
const msgpack = @import("msgpack_utils.zig");
const msgpack_helpers = @import("msgpack_test_helpers.zig");
const Payload = msgpack.Payload;
const schema_helpers = @import("schema_test_helpers.zig");
const storage_types = @import("storage_engine.zig");
const typed = @import("typed.zig");
const query_parser = @import("query_parser.zig");
const tth = @import("typed_test_helpers.zig");
const PendingUserUpdate = @import("presence/manager.zig").PresenceManager.PendingUserUpdate;

fn makeDeltaTestRecord(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !typed.Record {
    const values = try allocator.alloc(typed.Value, 6);
    errdefer allocator.free(values);

    values[0] = try tth.valTextOwned(allocator, id);
    errdefer values[0].deinit(allocator);
    values[1] = tth.valInt(1);
    values[2] = try tth.valTextOwned(allocator, "test-owner");
    errdefer values[2].deinit(allocator);
    values[3] = try tth.valTextOwned(allocator, name);
    errdefer values[3].deinit(allocator);
    values[4] = tth.valInt(0);
    values[5] = tth.valInt(0);

    return .{ .values = values };
}

fn encodePayload(allocator: std.mem.Allocator, payload: Payload) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(allocator);
    try msgpack.encode(payload, list.writer(allocator));
    return list.toOwnedSlice(allocator);
}

fn writeFixStr(writer: anytype, s: []const u8) !void {
    // Write a fixstr header + payload bytes
    try writer.writeByte(@as(u8, @intCast(0xa0 | s.len)));
    try writer.writeAll(s);
}

fn writeFixMapHeader(writer: anytype, n: usize) !void {
    try writer.writeByte(@as(u8, @intCast(0x80 | n)));
}

// === Fast Decoder Tests ===

test "extractEnvelopeFast: valid envelope" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreSet", allocator));
    try map.mapPut("id", Payload.uintToPayload(42));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try wire.extractEnvelopeFast(bytes);
    try testing.expectEqualStrings("StoreSet", result.type);
    try testing.expectEqual(@as(u64, 42), result.id);
}

test "extractEnvelopeFast: missing type" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("id", Payload.uintToPayload(1));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, wire.extractEnvelopeFast(bytes));
}

test "extractEnvelopeFast: missing id" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreSet", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, wire.extractEnvelopeFast(bytes));
}

test "extractEnvelopeFast: non-map payload" {
    const bytes = &[_]u8{0x01}; // positive fixint, not a map
    try testing.expectError(error.InvalidMessageFormat, wire.extractEnvelopeFast(bytes));
}

test "extractEnvelopeFast: wrong type for field" {
    const allocator = testing.allocator;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try writeFixMapHeader(writer, 2);
    try writeFixStr(writer, "type");
    try writer.writeByte(0xcf);
    try writer.writeInt(u64, 999, .big); // type as uint64 instead of string
    try writeFixStr(writer, "id");
    try writer.writeByte(0x01); // positive fixint 1

    try testing.expectError(error.InvalidMessageFormat, wire.extractEnvelopeFast(buf.items));
}

test "extractEnvelopeFast: extra fields (lenient)" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreSet", allocator));
    try map.mapPut("id", Payload.uintToPayload(99));
    try map.mapPut("extra", Payload.uintToPayload(123)); // unknown field
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try wire.extractEnvelopeFast(bytes);
    try testing.expectEqualStrings("StoreSet", result.type);
    try testing.expectEqual(@as(u64, 99), result.id);
}

test "extractStoreSetNamespaceFast: valid" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreSetNamespace", allocator));
    try map.mapPut("id", Payload.uintToPayload(1));
    try map.mapPut("namespace", try Payload.strToPayload("my-ns", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try wire.extractStoreSetNamespaceFast(bytes);
    try testing.expectEqualStrings("my-ns", result.namespace);
}

test "extractStoreSetNamespaceFast: missing namespace" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreSetNamespace", allocator));
    try map.mapPut("id", Payload.uintToPayload(1));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, wire.extractStoreSetNamespaceFast(bytes));
}

test "extractStoreUnsubscribeFast: valid" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreUnsubscribe", allocator));
    try map.mapPut("id", Payload.uintToPayload(1));
    try map.mapPut("subId", Payload.uintToPayload(12345));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try wire.extractStoreUnsubscribeFast(bytes);
    try testing.expectEqual(@as(u64, 12345), result.subId);
}

test "extractStoreUnsubscribeFast: missing subId" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreUnsubscribe", allocator));
    try map.mapPut("id", Payload.uintToPayload(1));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, wire.extractStoreUnsubscribeFast(bytes));
}

test "extractStoreLoadMoreFast: valid" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreLoadMore", allocator));
    try map.mapPut("id", Payload.uintToPayload(1));
    try map.mapPut("subId", Payload.uintToPayload(99));
    try map.mapPut("nextCursor", try Payload.strToPayload("abc123", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try wire.extractStoreLoadMoreFast(bytes);
    try testing.expectEqual(@as(u64, 99), result.subId);
    try testing.expectEqualStrings("abc123", result.nextCursor);
}

test "extractStoreLoadMoreFast: missing subId" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreLoadMore", allocator));
    try map.mapPut("id", Payload.uintToPayload(1));
    try map.mapPut("nextCursor", try Payload.strToPayload("abc123", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, wire.extractStoreLoadMoreFast(bytes));
}

test "extractStoreLoadMoreFast: missing nextCursor" {
    const allocator = testing.allocator;

    var map = Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try Payload.strToPayload("StoreLoadMore", allocator));
    try map.mapPut("id", Payload.uintToPayload(1));
    try map.mapPut("subId", Payload.uintToPayload(99));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, wire.extractStoreLoadMoreFast(bytes));
}

// === Encode Tests (unchanged) ===

test "encodeSuccess: produces valid MsgPack" {
    const allocator = testing.allocator;
    const response = try wire.encodeSuccess(allocator, 12345);
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

test "encodeError: produces valid MsgPack" {
    const allocator = testing.allocator;
    const wire_err = wire.getWireError(error.UnknownTable);
    const response = try wire.encodeError(allocator, 999, wire_err);
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

test "encodeQuery: includes subscription pagination fields" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &.{"name"},
    }});
    defer schema.deinit();

    const table_metadata = schema.table("users") orelse return error.UnknownTable;
    const records = try allocator.alloc(typed.Record, 1);
    records[0] = try makeDeltaTestRecord(allocator, "user-123", "Ada");
    defer {
        records[0].deinit(allocator);
        allocator.free(records);
    }

    var result = storage_types.ManagedResult{
        .records = records,
    };

    const cursor = typed.Cursor{
        .sort_value = tth.valInt(10),
        .id = 1,
    };
    const next_cursor_str = try query_parser.encodeCursorToken(allocator, cursor);
    defer allocator.free(next_cursor_str);

    const response = try wire.encodeQuery(allocator, .{
        .msg_id = 44,
        .sub_id = 7,
        .results = &result,
        .table = table_metadata,
        .next_cursor = next_cursor_str,
    });
    defer allocator.free(response);

    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack.decodeTrusted(allocator, &reader);
    defer parsed.free(allocator);

    const type_val = (try parsed.mapGet("type")) orelse return error.MissingType;
    try testing.expectEqualStrings("ok", type_val.str.value());
    const id_val = (try parsed.mapGet("id")) orelse return error.MissingId;
    try testing.expectEqual(@as(u64, 44), id_val.uint);
    const sub_id_val = (try parsed.mapGet("subId")) orelse return error.MissingSubId;
    try testing.expectEqual(@as(u64, 7), sub_id_val.uint);

    const rows_payload = (try parsed.mapGet("value")) orelse return error.MissingValue;
    try testing.expect(rows_payload == .arr);
    try testing.expectEqual(@as(usize, 1), rows_payload.arr.len);
    const name = (try msgpack_helpers.getMapValueByName(rows_payload.arr[0], table_metadata, "name")) orelse return error.MissingName;
    try testing.expectEqualStrings("Ada", name.str.value());

    const has_more = (try parsed.mapGet("hasMore")) orelse return error.MissingHasMore;
    try testing.expectEqual(true, has_more.bool);
    const next_cursor = (try parsed.mapGet("nextCursor")) orelse return error.MissingNextCursor;
    try testing.expect(next_cursor == .str);
    try testing.expect(next_cursor.str.value().len > 0);
}

test "encodeSetDeltaSuffix: set operation" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &.{"name"},
    }});
    defer schema.deinit();

    const table_metadata = schema.table("users") orelse return error.UnknownTable;
    const record = try makeDeltaTestRecord(allocator, "user-123", "Ada");
    defer record.deinit(allocator);

    const suffix = try wire.encodeSetDeltaSuffix(allocator, table_metadata.index, tth.valText("user-123"), record, table_metadata);
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

    const value = try op_obj.mapGet("value");
    try testing.expect(value != null);
    try testing.expect(value.? == .map);
    var val_it = value.?.map.iterator();
    var found_entries: usize = 0;
    while (val_it.next()) |_| found_entries += 1;
    try testing.expectEqual(@as(usize, 6), found_entries);
}

test "encodeDeleteDeltaSuffix: delete operation" {
    const allocator = testing.allocator;

    const id_val = tth.valInt(999);
    const suffix = try wire.encodeDeleteDeltaSuffix(allocator, 0, id_val);
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
    try testing.expectEqual(@as(u64, 0), path.arr[0].uint);
    try testing.expectEqual(@as(u64, 999), path.arr[1].uint);

    try testing.expect((try op_obj.mapGet("value")) == null);
}

test "getWireError: returns non-empty comptime-encoded keys" {
    const err1 = wire.getWireError(error.UnknownTable);
    try testing.expect(err1.code.len > 0);
    const err2 = wire.getWireError(error.UnknownField);
    try testing.expect(err2.code.len > 0);
    try testing.expect(err1.code.len != err2.code.len or !std.mem.eql(u8, err1.code, err2.code));
}

test "getWireError: returns non-empty comptime-encoded messages" {
    const err1 = wire.getWireError(error.UnknownTable);
    try testing.expect(err1.message.len > 0);
    const err2 = wire.getWireError(error.UnknownField);
    try testing.expect(err2.message.len > 0);
}

test "encodeWriteCommitted: produces valid MsgPack with type and writeId" {
    const allocator = testing.allocator;
    const write_id = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const msg = try wire.encodeWriteCommitted(allocator, write_id);
    defer allocator.free(msg);

    var reader: std.Io.Reader = .fixed(msg);
    const p = try msgpack.decode(allocator, &reader);
    defer p.free(allocator);

    const type_val = (try p.mapGet("type")) orelse return error.MissingType;
    try testing.expectEqualStrings("WriteCommitted", type_val.str.value());
    const wid_val = (try p.mapGet("writeId")) orelse return error.MissingWriteId;
    try testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", wid_val.str.value());
}

test "encodeWriteError: 5-field map with phase=write, no batchIndex" {
    const allocator = testing.allocator;
    const write_id = [_]u8{0} ** 16;
    const wire_err = wire.getWireError(error.PermissionDenied);
    const msg = try wire.encodeWriteError(allocator, write_id, wire_err, null);
    defer allocator.free(msg);

    var reader: std.Io.Reader = .fixed(msg);
    const p = try msgpack.decode(allocator, &reader);
    defer p.free(allocator);

    const type_val = (try p.mapGet("type")) orelse return error.MissingType;
    try testing.expectEqualStrings("WriteError", type_val.str.value());
    const phase_val = (try p.mapGet("phase")) orelse return error.MissingPhase;
    try testing.expectEqualStrings("write", phase_val.str.value());
    try testing.expect((try p.mapGet("batchIndex")) == null);
}

test "encodeWriteError: 6-field map includes batchIndex when set" {
    const allocator = testing.allocator;
    const write_id = [_]u8{0} ** 16;
    const wire_err = wire.getWireError(error.PermissionDenied);
    const msg = try wire.encodeWriteError(allocator, write_id, wire_err, 2);
    defer allocator.free(msg);

    var reader: std.Io.Reader = .fixed(msg);
    const p = try msgpack.decode(allocator, &reader);
    defer p.free(allocator);

    const batch_idx = (try p.mapGet("batchIndex")) orelse return error.MissingBatchIndex;
    try testing.expectEqual(@as(u64, 2), batch_idx.uint);
    const phase_val = (try p.mapGet("phase")) orelse return error.MissingPhase;
    try testing.expectEqualStrings("write", phase_val.str.value());
}

test "getWireError: query parser errors keep distinct human messages" {
    const allocator = testing.allocator;
    const check = struct {
        fn run(comptime err: anyerror, comptime expected: []const u8) !void {
            const wire_err = wire.getWireError(err);
            var reader: std.Io.Reader = .fixed(wire_err.message);
            const decoded = try msgpack.decode(allocator, &reader);
            defer decoded.free(allocator);
            try testing.expectEqualStrings(expected, decoded.str.value());
        }
    }.run;

    try check(error.MissingOperand, "Query operator is missing an operand");
    try check(error.UnexpectedOperand, "Query operator does not accept an operand");
    try check(error.InvalidInOperand, "IN and NOT IN require an array operand");
    try check(error.NullOperandUnsupported, "Null is not allowed as a query operand");
    try check(error.UnsupportedOperatorForFieldType, "Query operator is not supported for this field type");
    try check(error.InvalidCursorSortValue, "Cursor sort value does not match the active sort field");
}

test "store_delta_header: decodes to StoreDelta type" {
    const allocator = testing.allocator;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &wire.store_delta_header);
    try buf.append(allocator, 0xcf);
    try buf.writer(allocator).writeInt(u64, 42, .big);
    try msgpack.writeMsgPackStr(buf.writer(allocator), "ops");
    try buf.append(allocator, 0x90);

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
    const suffix = try wire.encodeDeleteDeltaSuffix(allocator, 1, id_val);
    defer allocator.free(suffix);

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
    try testing.expectEqual(@as(u64, 1), path.arr[0].uint);
    try testing.expectEqualStrings("doc-abc-123", path.arr[1].str.value());
}

test "encodePresenceBroadcast - update event round-trips with correct map size" {
    const allocator = testing.allocator;

    var patch = Payload.mapPayload(allocator);
    defer patch.free(allocator);
    try patch.mapPut("cursor__x", Payload{ .float = 100.5 });

    const update = PendingUserUpdate{
        .namespace_id = 1,
        .user_id = typed.zeroDocId,
        .patch = patch,
        .is_new_user = false,
        .joined_at = 0,
        .is_leave = false,
    };

    const bytes = try wire.encodePresenceBroadcast(allocator, 42, &.{update});
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const decoded = try msgpack.decode(allocator, &reader);
    defer decoded.free(allocator);

    try testing.expect(decoded == .map);
    const type_val = (try decoded.mapGet("type")) orelse return error.MissingType;
    try testing.expectEqualStrings("PresenceBroadcast", type_val.str.value());
    const sub_id_val = (try decoded.mapGet("subId")) orelse return error.MissingSubId;
    try testing.expectEqual(@as(u64, 42), sub_id_val.uint);
    const users_val = (try decoded.mapGet("users")) orelse return error.MissingUsers;
    try testing.expect(users_val == .arr);
    try testing.expectEqual(@as(usize, 1), users_val.arr.len);

    const user_entry = users_val.arr[0];
    try testing.expect(user_entry == .map);
    var key_count: usize = 0;
    var it = user_entry.map.iterator();
    while (it.next()) |_| key_count += 1;
    try testing.expectEqual(@as(usize, 3), key_count);

    const event_val = (try user_entry.mapGet("event")) orelse return error.MissingEvent;
    try testing.expectEqualStrings("update", event_val.str.value());
    try testing.expect((try user_entry.mapGet("data")) != null);
}

test "encodePresenceBroadcast - leave event round-trips with correct map size" {
    const allocator = testing.allocator;

    const update = PendingUserUpdate{
        .namespace_id = 1,
        .user_id = typed.zeroDocId,
        .patch = null,
        .is_new_user = false,
        .joined_at = 0,
        .is_leave = true,
    };

    const bytes = try wire.encodePresenceBroadcast(allocator, 7, &.{update});
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const decoded = try msgpack.decode(allocator, &reader);
    defer decoded.free(allocator);

    try testing.expect(decoded == .map);
    const users_val = (try decoded.mapGet("users")) orelse return error.MissingUsers;
    const user_entry = users_val.arr[0];

    var key_count: usize = 0;
    var it = user_entry.map.iterator();
    while (it.next()) |_| key_count += 1;
    try testing.expectEqual(@as(usize, 2), key_count);

    const event_val = (try user_entry.mapGet("event")) orelse return error.MissingEvent;
    try testing.expectEqualStrings("leave", event_val.str.value());
    try testing.expect((try user_entry.mapGet("data")) == null);
}

test "encodeSchemaSync: fieldFlags match bit encoding rules" {
    const allocator = testing.allocator;
    const schema_mod = @import("schema.zig");

    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": { "namespaced": false, "fields": { "email": { "type": "string" } } },
        \\    "tasks": { "fields": { "title": { "type": "string" }, "status": { "type": "string" } } }
        \\  }
        \\}
    ;

    var schema = try schema_mod.initSchema(allocator, schema_json);
    defer schema.deinit();

    const encoded = try wire.encodeSchemaSync(allocator, &schema);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    const field_flags_val = (try parsed.mapGet("fieldFlags")) orelse {
        return error.MissingFieldFlags;
    };

    try testing.expect(field_flags_val == .arr);
    try testing.expectEqual(@as(usize, 2), field_flags_val.arr.len);

    // Users fieldFlags: [id, namespace_id, owner_id, email, created_at, updated_at]
    const users_flags = field_flags_val.arr[0];
    try testing.expectEqual(@as(usize, 6), users_flags.arr.len);
    // id=7 (0b111 = system|doc_id|required)
    try testing.expectEqual(@as(u64, 7), users_flags.arr[0].uint);
    // namespace_id=5 (0b101 = system|required)
    try testing.expectEqual(@as(u64, 5), users_flags.arr[1].uint);
    // owner_id=7 (0b111 = system|doc_id|required)
    try testing.expectEqual(@as(u64, 7), users_flags.arr[2].uint);
    // email=0 (user field, not required)
    try testing.expectEqual(@as(u64, 0), users_flags.arr[3].uint);
    // created_at=5 (0b101 = system|required)
    try testing.expectEqual(@as(u64, 5), users_flags.arr[4].uint);
    // updated_at=5 (0b101 = system|required)
    try testing.expectEqual(@as(u64, 5), users_flags.arr[5].uint);

    // Tasks fieldFlags: [id, namespace_id, owner_id, title, status, created_at, updated_at]
    const tasks_flags = field_flags_val.arr[1];
    try testing.expectEqual(@as(usize, 7), tasks_flags.arr.len);
    // id=7
    try testing.expectEqual(@as(u64, 7), tasks_flags.arr[0].uint);
    // namespace_id=5
    try testing.expectEqual(@as(u64, 5), tasks_flags.arr[1].uint);
    // owner_id=7
    try testing.expectEqual(@as(u64, 7), tasks_flags.arr[2].uint);
    // title=0 (user field, not required)
    try testing.expectEqual(@as(u64, 0), tasks_flags.arr[3].uint);
    // status=0 (user field, not required)
    try testing.expectEqual(@as(u64, 0), tasks_flags.arr[4].uint);
    // created_at=5
    try testing.expectEqual(@as(u64, 5), tasks_flags.arr[5].uint);
    // updated_at=5
    try testing.expectEqual(@as(u64, 5), tasks_flags.arr[6].uint);
}
