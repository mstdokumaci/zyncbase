const std = @import("std");
const testing = std.testing;
const msgpack_utils = @import("msgpack_utils.zig");
const Payload = msgpack_utils.Payload;

// ============================================================
// encodeBase64 / decodeBase64 tests
// ============================================================

test "encodeBase64 / decodeBase64: round-trip for complex payload" {
    const allocator = testing.allocator;

    var map = msgpack_utils.Payload.mapPayload(allocator);
    defer map.free(allocator);
    try map.mapPut("name", try Payload.strToPayload("test", allocator));
    try map.mapPut("age", .{ .int = 42 });

    const encoded = try msgpack_utils.encodeBase64(allocator, map);
    defer allocator.free(encoded);

    const decoded = try msgpack_utils.decodeBase64(allocator, encoded);
    defer decoded.free(allocator);

    try testing.expect(decoded == .map);
    const name = (try decoded.mapGet("name")) orelse return error.KeyNotFound;
    try testing.expectEqualStrings("test", name.str.value());
    const age = (try decoded.mapGet("age")) orelse return error.KeyNotFound;
    const age_val = switch (age) {
        .int => |v| v,
        .uint => |v| @as(i64, @intCast(v)),
        else => return error.TestFailed,
    };
    try testing.expectEqual(@as(i64, 42), age_val);
}

// ============================================================
// writeMsgPackStr tests
// ============================================================

test "msgpack_utils: writeMsgPackStr fixstr (≤31 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), "type");
    // fixstr(4) = 0xa4 | "type" = 5 bytes
    try testing.expectEqual(@as(usize, 5), buf.items.len);
    try testing.expectEqual(@as(u8, 0xa4), buf.items[0]);
    try testing.expectEqualSlices(u8, "type", buf.items[1..]);
}

test "msgpack_utils: writeMsgPackStr str8 (≤255 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    const long_str = "a" ** 100;

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), long_str[0..]);
    // str8(100) = 0xd9 | 0x64 | "a"*100 = 102 bytes
    try testing.expectEqual(@as(usize, 102), buf.items.len);
    try testing.expectEqual(@as(u8, 0xd9), buf.items[0]);
    try testing.expectEqual(@as(u8, 100), buf.items[1]);
}

test "msgpack_utils: writeMsgPackStr empty string" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), "");
    // fixstr(0) = 0xa0 = 1 byte
    try testing.expectEqual(@as(usize, 1), buf.items.len);
    try testing.expectEqual(@as(u8, 0xa0), buf.items[0]);
}

test "msgpack_utils: writeMsgPackStr str16 (>255 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    const long_str = "b" ** 300;

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), long_str[0..]);
    // str16(300) = 0xda | 0x012c | "b"*300 = 303 bytes
    try testing.expectEqual(@as(usize, 303), buf.items.len);
    try testing.expectEqual(@as(u8, 0xda), buf.items[0]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, buf.items[1..3], .big));
}

test "msgpack_utils: writeMsgPackStr str32 (>65535 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    const len = 70000;
    const long_str = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(long_str);
    @memset(long_str, 'c');

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), long_str);
    // str32(70000) = 0xdb | 0x00011170 | "c"*70000 = 70005 bytes
    try testing.expectEqual(@as(usize, 70005), buf.items.len);
    try testing.expectEqual(@as(u8, 0xdb), buf.items[0]);
    try testing.expectEqual(@as(u32, len), std.mem.readInt(u32, buf.items[1..5], .big));
}
