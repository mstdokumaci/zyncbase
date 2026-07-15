const std = @import("std");
const testing = std.testing;
const decode = @import("decode.zig");
const msgpack = @import("../msgpack_utils.zig");
const helpers = @import("test_helpers.zig");

const encodePayload = helpers.encodePayload;
const writeFixStr = helpers.writeFixStr;
const writeFixMapHeader = helpers.writeFixMapHeader;

// === Fast Decoder Tests (extracted from src/wire_test.zig) ===

test "extractEnvelopeFast: valid envelope" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreSet", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(42));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try decode.extractEnvelopeFast(bytes);
    try testing.expectEqualStrings("StoreSet", result.type);
    try testing.expectEqual(@as(u64, 42), result.id);
}

test "extractEnvelopeFast: missing type" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, decode.extractEnvelopeFast(bytes));
}

test "extractEnvelopeFast: missing id" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreSet", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, decode.extractEnvelopeFast(bytes));
}

test "extractEnvelopeFast: non-map payload" {
    const bytes = &[_]u8{0x01}; // positive fixint, not a map
    try testing.expectError(error.InvalidMessageFormat, decode.extractEnvelopeFast(bytes));
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

    try testing.expectError(error.InvalidMessageFormat, decode.extractEnvelopeFast(buf.items));
}

test "extractEnvelopeFast: extra fields (lenient)" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreSet", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(99));
    try map.mapPut("extra", msgpack.Payload.uintToPayload(123)); // unknown field
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try decode.extractEnvelopeFast(bytes);
    try testing.expectEqualStrings("StoreSet", result.type);
    try testing.expectEqual(@as(u64, 99), result.id);
}

test "extractStoreSetNamespaceFast: valid" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreSetNamespace", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    try map.mapPut("namespace", try msgpack.Payload.strToPayload("my-ns", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try decode.extractStoreSetNamespaceFast(bytes);
    try testing.expectEqualStrings("my-ns", result.namespace);
}

test "extractStoreSetNamespaceFast: missing namespace" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreSetNamespace", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, decode.extractStoreSetNamespaceFast(bytes));
}

test "extractStoreUnsubscribeFast: valid" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreUnsubscribe", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    try map.mapPut("subId", msgpack.Payload.uintToPayload(12345));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try decode.extractStoreUnsubscribeFast(bytes);
    try testing.expectEqual(@as(u64, 12345), result.subId);
}

test "extractStoreUnsubscribeFast: missing subId" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreUnsubscribe", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, decode.extractStoreUnsubscribeFast(bytes));
}

test "extractStoreLoadMoreFast: valid" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreLoadMore", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    try map.mapPut("subId", msgpack.Payload.uintToPayload(99));
    try map.mapPut("nextCursor", try msgpack.Payload.strToPayload("abc123", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    const result = try decode.extractStoreLoadMoreFast(bytes);
    try testing.expectEqual(@as(u64, 99), result.subId);
    try testing.expectEqualStrings("abc123", result.nextCursor);
}

test "extractStoreLoadMoreFast: missing subId" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreLoadMore", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    try map.mapPut("nextCursor", try msgpack.Payload.strToPayload("abc123", allocator));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, decode.extractStoreLoadMoreFast(bytes));
}

test "extractStoreLoadMoreFast: missing nextCursor" {
    const allocator = testing.allocator;

    var map = msgpack.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("type", try msgpack.Payload.strToPayload("StoreLoadMore", allocator));
    try map.mapPut("id", msgpack.Payload.uintToPayload(1));
    try map.mapPut("subId", msgpack.Payload.uintToPayload(99));
    const bytes = try encodePayload(allocator, map);
    defer allocator.free(bytes);

    try testing.expectError(error.MissingRequiredFields, decode.extractStoreLoadMoreFast(bytes));
}

test "extractStoreUnsubscribeFast: wrong type for subId" {
    const allocator = testing.allocator;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try writeFixMapHeader(writer, 1);
    try writeFixStr(writer, "subId");
    try writeFixStr(writer, "not-a-number"); // subId as string instead of u64

    try testing.expectError(error.InvalidMessageFormat, decode.extractStoreUnsubscribeFast(buf.items));
}

test "extractEnvelopeFast: duplicate key, last wins" {
    const allocator = testing.allocator;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try writeFixMapHeader(writer, 3);
    try writeFixStr(writer, "type");
    try writeFixStr(writer, "first");
    try writeFixStr(writer, "id");
    try writer.writeByte(0x01); // positive fixint 1
    try writeFixStr(writer, "type");
    try writeFixStr(writer, "second"); // duplicate — last write should win

    const result = try decode.extractEnvelopeFast(buf.items);
    try testing.expectEqualStrings("second", result.type);
}

test "extractPresenceSetFast: duplicate data key, last wins" {
    const allocator = testing.allocator;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try writeFixMapHeader(writer, 2);
    try writeFixStr(writer, "data");
    try writer.writeByte(0xc0); // nil — first value
    try writeFixStr(writer, "data");
    try writeFixStr(writer, "hello"); // string — second value (last wins)

    const result = try decode.extractPresenceSetFast(buf.items, allocator);
    defer result.data.free(allocator);
    try testing.expect(result.data == .str);
    try testing.expectEqualStrings("hello", result.data.str.value());
}

// === readSubtree single-pass correctness (the decode.zig optimization) ===

test "readSubtree consumes exactly one value and advances pos to its boundary" {
    const allocator = testing.allocator;

    // A map {"a":"x","b":"y"} followed by a trailing nil byte.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &[_]u8{
        0x82, // fixmap with 2 entries
        0xa1, 'a', // fixstr "a"
        0xa1, 'x', // fixstr "x"
        0xa1, 'b', // fixstr "b"
        0xa1, 'y', // fixstr "y"
        0xc0, // trailing nil, must NOT be consumed
    });

    var pos: usize = 0;
    const payload = try decode.readSubtree(buf.items, &pos, allocator);
    defer payload.free(allocator);

    // 1 (fixmap header) + 2 entries * (2-byte fixstr + 2-byte fixstr) = 9 bytes.
    try testing.expectEqual(@as(usize, 9), pos);
    try testing.expectEqual(buf.items.len - 1, pos);
    try testing.expect(payload == .map);
}

test "readSubtree on nested array payload advances pos past the whole value" {
    const allocator = testing.allocator;

    // A fixarray of 3 fixints, followed by a trailing nil byte.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &[_]u8{
        0x93, // fixarray of 3
        0x01,
        0x02,
        0x03,
        0xc0, // trailing nil, must NOT be consumed
    });

    var pos: usize = 0;
    const payload = try decode.readSubtree(buf.items, &pos, allocator);
    defer payload.free(allocator);

    try testing.expectEqual(@as(usize, 4), pos);
    try testing.expectEqual(buf.items.len - 1, pos);
    try testing.expect(payload == .arr);
}

test "readSubtree decodes a large batch-style array payload in a single pass" {
    const allocator = testing.allocator;

    // A fixarray of 300 fixints — exercises the iterative parser on a payload
    // large enough that the old skipValue + decode double-walk would be visible.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, 0xdc); // array16
    try buf.append(allocator, 0x01); // length high byte
    try buf.append(allocator, 0x2c); // length low byte (300)
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try buf.append(allocator, 0x00);
    }
    try buf.append(allocator, 0xc0); // trailing nil, must NOT be consumed

    var pos: usize = 0;
    const payload = try decode.readSubtree(buf.items, &pos, allocator);
    defer payload.free(allocator);

    try testing.expectEqual(buf.items.len - 1, pos);
    try testing.expect(payload == .arr);
    try testing.expectEqual(@as(usize, 300), payload.arr.len);
}
