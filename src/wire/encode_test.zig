const std = @import("std");

const msgpack_helpers = @import("../msgpack_test_helpers.zig");
const msgpack = @import("../msgpack_utils.zig");
const query_ast = @import("../query/ast.zig");
const query_parser = @import("../query/parser.zig");
const schema_parse = @import("../schema/parse.zig");
const schema_system = @import("../schema/system.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const tth = @import("../typed/test_helpers.zig");
const typed = @import("../typed/types.zig");
const wire_encode = @import("encode.zig");
const wire_errors = @import("errors.zig");
const msgpack_skip = @import("msgpack_skip.zig");
const helpers = @import("test_helpers.zig");
const PendingSharedUpdate = @import("../presence/manager.zig").PresenceManager.PendingSharedUpdate;
const PendingUserUpdate = @import("../presence/manager.zig").PresenceManager.PendingUserUpdate;
const MessageType = @import("message_type.zig").MessageType;

const Allocator = std.mem.Allocator;
const testing = std.testing;
const makeDeltaTestRecord = helpers.makeDeltaTestRecord;

fn expectType(bytes: []const u8, parsed: msgpack.Payload, expected: MessageType) !void {
    // Walk the top-level map structurally so only the "type" key at the top
    // level is located; nested payloads or truncated matches elsewhere in the
    // buffer cannot be mistaken for it. The value must be a one-byte positive
    // fixint (0x00-0x7f), never a uint8/16/32/64 marker (0xcc-0xcf).
    if (bytes.len == 0) return error.Truncated;
    if (bytes[0] < 0x80 or bytes[0] > 0x8f) return error.NotFixMap;
    const map_size = bytes[0] & 0x0f;
    var idx: usize = 1;
    for (0..map_size) |_| {
        if (idx >= bytes.len) return error.Truncated;
        const key_marker = bytes[idx];
        if (key_marker < 0xa0 or key_marker > 0xbf) return error.MalformedKey;
        const key_len: usize = key_marker & 0x1f;
        idx += 1;
        if (idx + key_len > bytes.len) return error.Truncated;
        const key = bytes[idx .. idx + key_len];
        idx += key_len;
        if (std.mem.eql(u8, key, "type")) {
            if (idx >= bytes.len) return error.Truncated;
            const type_byte = bytes[idx];
            try testing.expect(type_byte < 0x80);

            const type_val = (try parsed.mapGet("type")) orelse return error.MissingType;
            try testing.expect(type_val == .uint);
            try testing.expectEqual(expected, std.enums.fromInt(MessageType, type_val.uint) orelse return error.TestExpectedError);
            return;
        }
        try msgpack_skip.skipValue(bytes, &idx);
    }
    return error.MissingType;
}

test "encodeSuccess: produces valid MsgPack" {
    const allocator = std.heap.smp_allocator;
    const response = try wire_encode.encodeSuccess(allocator, 12345);
    defer allocator.free(response);

    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    try testing.expect(parsed == .map);
    try expectType(response, parsed, .ok);
    const id_val = (try parsed.mapGet("id")) orelse return error.MissingId;
    try testing.expectEqual(@as(u64, 12345), id_val.uint);
}

test "encodeError: produces valid MsgPack" {
    const allocator = std.heap.smp_allocator;
    const wire_err = wire_errors.getWireError(error.UnknownTable);
    const response = try wire_encode.encodeError(allocator, 999, wire_err);
    defer allocator.free(response);

    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    try testing.expect(parsed == .map);
    try expectType(response, parsed, .@"error");
    const id_val = (try parsed.mapGet("id")) orelse return error.MissingId;
    try testing.expectEqual(@as(u64, 999), id_val.uint);
    const code_val = (try parsed.mapGet("code")) orelse return error.MissingCode;
    try testing.expectEqualStrings("COLLECTION_NOT_FOUND", code_val.str.value());
    const msg_val = (try parsed.mapGet("message")) orelse return error.MissingMessage;
    try testing.expectEqualStrings("Collection missing in schema", msg_val.str.value());
}

test "encodeQuery: includes subscription pagination fields" {
    const allocator = std.heap.smp_allocator;

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

    const descriptors = [_]query_ast.SortDescriptor{
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
    const cursor_values = [_]typed.Value{tth.valInt(10)};
    const next_cursor_str = try query_parser.encodeCursorToken(allocator, table_metadata.index, &descriptors, &cursor_values);
    defer allocator.free(next_cursor_str);

    const response = try wire_encode.encodeQuery(allocator, .{
        .msg_id = 44,
        .sub_id = 7,
        .records = records,
        .table = table_metadata,
        .next_cursor = next_cursor_str,
    });
    defer allocator.free(response);

    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    try expectType(response, parsed, .ok);
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
    const allocator = std.heap.smp_allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &.{"name"},
    }});
    defer schema.deinit();

    const table_metadata = schema.table("users") orelse return error.UnknownTable;
    const record = try makeDeltaTestRecord(allocator, "user-123", "Ada");
    defer record.deinit(allocator);

    const suffix = try wire_encode.encodeSetDeltaSuffix(allocator, table_metadata.index, tth.valText("user-123"), record, table_metadata);
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
    try testing.expect(value.? == .arr);
    try testing.expectEqual(@as(usize, 6), value.?.arr.len);
}

test "encodeDeleteDeltaSuffix: delete operation" {
    const allocator = std.heap.smp_allocator;

    const id_val = tth.valInt(999);
    const suffix = try wire_encode.encodeDeleteDeltaSuffix(allocator, 0, id_val);
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

test "encodeWriteCommitted: produces valid MsgPack with type and writeId" {
    const allocator = std.heap.smp_allocator;
    const write_id = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const msg = try wire_encode.encodeWriteCommitted(allocator, write_id);
    defer allocator.free(msg);

    var reader: std.Io.Reader = .fixed(msg);
    const p = try msgpack.decode(allocator, &reader);
    defer p.free(allocator);

    try expectType(msg, p, .write_committed);
    const wid_val = (try p.mapGet("writeId")) orelse return error.MissingWriteId;
    try testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", wid_val.str.value());
}

test "encodeWriteError: 5-field map with phase=write, no batchIndex" {
    const allocator = std.heap.smp_allocator;
    const write_id = [_]u8{0} ** 16;
    const wire_err = wire_errors.getWireError(error.PermissionDenied);
    const msg = try wire_encode.encodeWriteError(allocator, write_id, wire_err, null);
    defer allocator.free(msg);

    var reader: std.Io.Reader = .fixed(msg);
    const p = try msgpack.decode(allocator, &reader);
    defer p.free(allocator);

    try expectType(msg, p, .write_error);
    const phase_val = (try p.mapGet("phase")) orelse return error.MissingPhase;
    try testing.expectEqualStrings("write", phase_val.str.value());
    try testing.expect((try p.mapGet("batchIndex")) == null);
}

test "encodeWriteError: 6-field map includes batchIndex when set" {
    const allocator = std.heap.smp_allocator;
    const write_id = [_]u8{0} ** 16;
    const wire_err = wire_errors.getWireError(error.PermissionDenied);
    const msg = try wire_encode.encodeWriteError(allocator, write_id, wire_err, 2);
    defer allocator.free(msg);

    var reader: std.Io.Reader = .fixed(msg);
    const p = try msgpack.decode(allocator, &reader);
    defer p.free(allocator);

    const batch_idx = (try p.mapGet("batchIndex")) orelse return error.MissingBatchIndex;
    try testing.expectEqual(@as(u64, 2), batch_idx.uint);
    const phase_val = (try p.mapGet("phase")) orelse return error.MissingPhase;
    try testing.expectEqualStrings("write", phase_val.str.value());
}

test "store_delta_header: decodes to StoreDelta type" {
    const allocator = std.heap.smp_allocator;

    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    try writer.writeAll(&wire_encode.store_delta_header);
    try writer.writeByte(0xcf);
    try writer.writeInt(u64, 42, .big);
    try msgpack.writeMsgPackStr(writer, "ops");
    try writer.writeByte(0x90);

    var reader: std.Io.Reader = .fixed(buf.written());
    const p = try msgpack.decodeTrusted(allocator, &reader);
    defer p.free(allocator);

    try testing.expect(p == .map);
    try expectType(buf.written(), p, .store_delta);
    const sub_id_val = (try p.mapGet("subId")) orelse return error.MissingSubId;
    try testing.expectEqual(@as(u64, 42), sub_id_val.uint);
}

test "encodeDeleteDeltaSuffix: with string id" {
    const allocator = std.heap.smp_allocator;

    const id_val = tth.valText("doc-abc-123");
    const suffix = try wire_encode.encodeDeleteDeltaSuffix(allocator, 1, id_val);
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

/// Test-only assembly of a full broadcast message from the production
/// comptime header, a per-recipient subId, and a production suffix.
fn assembleBroadcast(
    allocator: Allocator,
    comptime header: []const u8,
    sub_id: u64,
    suffix: []const u8,
) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    try writer.writeAll(header);
    try msgpack.encode(msgpack.Payload.uintToPayload(sub_id), writer);
    try writer.writeAll(suffix);
    return buf.toOwnedSlice();
}

fn expectTopLevelFieldCount(parsed: msgpack.Payload, expected: usize) !void {
    var key_count: usize = 0;
    var it = parsed.map.iterator();
    while (it.next()) |_| key_count += 1;
    try testing.expectEqual(expected, key_count);
}

test "encodePresenceBroadcast - update event round-trips with correct map size" {
    const allocator = std.heap.smp_allocator;

    var patch = msgpack.Payload{ .arr = try allocator.alloc(msgpack.Payload, 1) };
    defer patch.free(allocator);
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = msgpack.Payload{ .float = 100.5 };
    patch.arr[0] = .{ .arr = pair };

    const update = PendingUserUpdate{
        .namespace_id = 1,
        .user_id = typed_doc_id.zero,
        .patch = patch,
        .is_new_user = false,
        .joined_at = 0,
        .is_leave = false,
    };

    const suffix = try wire_encode.encodePresenceBroadcastSuffix(allocator, &.{update});
    defer allocator.free(suffix);
    const bytes = try assembleBroadcast(allocator, &wire_encode.presence_broadcast_header, 42, suffix);
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const decoded = try msgpack.decode(allocator, &reader);
    defer decoded.free(allocator);

    try testing.expect(decoded == .map);
    try expectType(bytes, decoded, .presence_broadcast);
    try expectTopLevelFieldCount(decoded, 3);
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
    const data_val = (try user_entry.mapGet("data")) orelse return error.MissingData;
    try testing.expect(data_val == .arr);
    try testing.expectEqual(@as(usize, 1), data_val.arr.len);
}

test "encodePresenceBroadcast - leave event round-trips with correct map size" {
    const allocator = std.heap.smp_allocator;

    const update = PendingUserUpdate{
        .namespace_id = 1,
        .user_id = typed_doc_id.zero,
        .patch = .nil,
        .is_new_user = false,
        .joined_at = 0,
        .is_leave = true,
    };

    const suffix = try wire_encode.encodePresenceBroadcastSuffix(allocator, &.{update});
    defer allocator.free(suffix);
    const bytes = try assembleBroadcast(allocator, &wire_encode.presence_broadcast_header, 7, suffix);
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const decoded = try msgpack.decode(allocator, &reader);
    defer decoded.free(allocator);

    try testing.expect(decoded == .map);
    try expectType(bytes, decoded, .presence_broadcast);
    try expectTopLevelFieldCount(decoded, 3);
    const sub_id_val = (try decoded.mapGet("subId")) orelse return error.MissingSubId;
    try testing.expectEqual(@as(u64, 7), sub_id_val.uint);
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

test "encodeSharedStateBroadcast - patches round-trip with correct map size" {
    const allocator = std.heap.smp_allocator;

    var patch = msgpack.Payload{ .arr = try allocator.alloc(msgpack.Payload, 1) };
    defer patch.free(allocator);
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = msgpack.Payload{ .float = 7.25 };
    patch.arr[0] = .{ .arr = pair };

    const update = PendingSharedUpdate{
        .namespace_id = 1,
        .patch = patch,
        .source_conn = 999,
    };

    const suffix = try wire_encode.encodeSharedStateBroadcastSuffix(allocator, &.{update});
    defer allocator.free(suffix);
    const bytes = try assembleBroadcast(allocator, &wire_encode.shared_state_broadcast_header, 13, suffix);
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const decoded = try msgpack.decode(allocator, &reader);
    defer decoded.free(allocator);

    try testing.expect(decoded == .map);
    try expectType(bytes, decoded, .shared_state_broadcast);
    try expectTopLevelFieldCount(decoded, 3);
    const sub_id_val = (try decoded.mapGet("subId")) orelse return error.MissingSubId;
    try testing.expectEqual(@as(u64, 13), sub_id_val.uint);
    const data_val = (try decoded.mapGet("data")) orelse return error.MissingData;
    try testing.expect(data_val == .arr);
    try testing.expectEqual(@as(usize, 1), data_val.arr.len);
    const entry_patch = data_val.arr[0];
    try testing.expect(entry_patch == .arr);
    try testing.expectEqual(@as(usize, 1), entry_patch.arr.len);
    const decoded_pair = entry_patch.arr[0];
    try testing.expect(decoded_pair == .arr);
    try testing.expectEqual(@as(u64, 0), decoded_pair.arr[0].uint);
    try testing.expectEqual(@as(f64, 7.25), decoded_pair.arr[1].float);
}

test "encodeSchemaSync: fieldFlags match bit encoding rules" {
    const allocator = std.heap.smp_allocator;

    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": { "namespaced": false, "fields": { "email": { "type": "string" } } },
        \\    "tasks": { "fields": { "title": { "type": "string" }, "status": { "type": "string" } } }
        \\  }
        \\}
    ;

    var schema = try schema_parse.initFromJson(allocator, schema_json);
    defer schema.deinit();

    const encoded = try wire_encode.encodeSchemaSync(allocator, &schema);
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
