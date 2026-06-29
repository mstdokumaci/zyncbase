const std = @import("std");
const skip = @import("msgpack_skip.zig");

/// Encode a fixstr into `buf` starting at `w`, returning new write offset.
fn putFixStr(buf: []u8, w: usize, s: []const u8) usize {
    buf[w] = @as(u8, 0xa0) | @as(u8, @intCast(s.len));
    @memcpy(buf[w + 1 ..][0..s.len], s);
    return w + 1 + s.len;
}

test "skip nil" {
    const bytes = [_]u8{ 0xc0, 0xff };
    var pos: usize = 0;
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "skip bool true and false" {
    const bytes = [_]u8{ 0xc2, 0xc3 };
    var pos: usize = 0;
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 1), pos);
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 2), pos);
}

test "skip positive fixint and negative fixint" {
    const bytes = [_]u8{ 0x7f, 0xff };
    var pos: usize = 0;
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 1), pos);
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 2), pos);
}

test "skip uint family" {
    const cases = [_]struct { bytes: []const u8, expect: usize }{
        .{ .bytes = &[_]u8{ 0xcc, 0x01 }, .expect = 2 },
        .{ .bytes = &[_]u8{ 0xcd, 0x01, 0x02 }, .expect = 3 },
        .{ .bytes = &[_]u8{ 0xce, 0x00, 0x00, 0x00, 0x03 }, .expect = 5 },
        .{ .bytes = &[_]u8{ 0xcf, 0, 0, 0, 0, 0, 0, 0, 4 }, .expect = 9 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        try skip.skipValue(c.bytes, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skip int family" {
    const cases = [_]struct { bytes: []const u8, expect: usize }{
        .{ .bytes = &[_]u8{ 0xd0, 0xff }, .expect = 2 },
        .{ .bytes = &[_]u8{ 0xd1, 0xff, 0xff }, .expect = 3 },
        .{ .bytes = &[_]u8{ 0xd2, 0xff, 0xff, 0xff, 0xff }, .expect = 5 },
        .{ .bytes = &[_]u8{ 0xd3, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .expect = 9 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        try skip.skipValue(c.bytes, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skip float32 and float64" {
    const cases = [_]struct { bytes: []const u8, expect: usize }{
        .{ .bytes = &[_]u8{ 0xca, 0, 0, 0, 0 }, .expect = 5 },
        .{ .bytes = &[_]u8{ 0xcb, 0, 0, 0, 0, 0, 0, 0, 0 }, .expect = 9 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        try skip.skipValue(c.bytes, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skip fixstr" {
    var bytes: [16]u8 = undefined;
    const w = putFixStr(&bytes, 0, "hi");
    var pos: usize = 0;
    try skip.skipValue(bytes[0..w], &pos);
    try std.testing.expectEqual(w, pos);
}

test "skip str8/16/32" {
    var buf: [64]u8 = undefined;
    // str8 with len 3
    buf[0] = 0xd9;
    buf[1] = 3;
    @memcpy(buf[2..5], "abc");
    var pos: usize = 0;
    try skip.skipValue(buf[0..5], &pos);
    try std.testing.expectEqual(@as(usize, 5), pos);

    // str16 with len 2
    buf[0] = 0xda;
    buf[1] = 0;
    buf[2] = 2;
    @memcpy(buf[3..5], "xy");
    pos = 0;
    try skip.skipValue(buf[0..5], &pos);
    try std.testing.expectEqual(@as(usize, 5), pos);
}

test "skip bin8/16/32" {
    var buf: [64]u8 = undefined;
    buf[0] = 0xc4;
    buf[1] = 2;
    buf[2] = 0xaa;
    buf[3] = 0xbb;
    var pos: usize = 0;
    try skip.skipValue(buf[0..4], &pos);
    try std.testing.expectEqual(@as(usize, 4), pos);

    // bin16 with len 1
    buf[0] = 0xc5;
    buf[1] = 0;
    buf[2] = 1;
    buf[3] = 0xcc;
    pos = 0;
    try skip.skipValue(buf[0..4], &pos);
    try std.testing.expectEqual(@as(usize, 4), pos);
}

test "skip fixarray of two ints" {
    const bytes = [_]u8{ 0x92, 0x01, 0x02 };
    var pos: usize = 0;
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "skip array16" {
    const bytes = [_]u8{ 0xdc, 0x00, 0x02, 0x01, 0x02 };
    var pos: usize = 0;
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 5), pos);
}

test "skip fixmap of one pair (two values)" {
    const bytes = [_]u8{ 0x81, 0xa1, 0x61, 0x01 };
    var pos: usize = 0;
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 4), pos);
}

test "skip map16" {
    const bytes = [_]u8{ 0xde, 0x00, 0x01, 0xa1, 0x6b, 0x05 };
    var pos: usize = 0;
    try skip.skipValue(&bytes, &pos);
    try std.testing.expectEqual(@as(usize, 6), pos);
}

test "skip fixext family" {
    const cases = [_]struct { bytes: []const u8, expect: usize }{
        .{ .bytes = &[_]u8{ 0xd4, 0x01, 0xaa }, .expect = 3 },
        .{ .bytes = &[_]u8{ 0xd5, 0x01, 0xaa, 0xbb }, .expect = 4 },
        .{ .bytes = &[_]u8{ 0xd6, 0x01, 0xaa, 0xbb, 0xcc, 0xdd }, .expect = 6 },
        .{ .bytes = &[_]u8{ 0xd7, 0x01, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11 }, .expect = 10 },
        .{ .bytes = &[_]u8{ 0xd8, 0x01, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99 }, .expect = 18 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        try skip.skipValue(c.bytes, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skip ext8/16/32 (len + type byte + payload)" {
    var buf: [32]u8 = undefined;
    // ext8 len=2 → 1 byte len + 1 byte type + 2 bytes payload = 5 total incl marker
    buf[0] = 0xc7;
    buf[1] = 2;
    buf[2] = 0x01;
    buf[3] = 0xaa;
    buf[4] = 0xbb;
    var pos: usize = 0;
    try skip.skipValue(buf[0..5], &pos);
    try std.testing.expectEqual(@as(usize, 5), pos);
}

test "skip nested array of strings" {
    // [ "a", "bb" ] as fixarray(2) + fixstr(1) "a" + fixstr(2) "bb"
    var bytes: [16]u8 = undefined;
    var w: usize = 0;
    bytes[w] = 0x92;
    w += 1;
    w = putFixStr(&bytes, w, "a");
    w = putFixStr(&bytes, w, "bb");
    var pos: usize = 0;
    try skip.skipValue(bytes[0..w], &pos);
    try std.testing.expectEqual(w, pos);
}

test "truncated input returns InvalidMessageFormat" {
    // uint16 needing 2 bytes, only 1 available
    const bytes = [_]u8{0xcd};
    var pos: usize = 0;
    try std.testing.expectError(error.InvalidMessageFormat, skip.skipValue(&bytes, &pos));
}

test "unknown marker returns InvalidMessageFormat" {
    // 0xc1 is reserved/unused in the MsgPack spec — not a valid marker.
    const bytes = [_]u8{0xc1};
    var pos: usize = 0;
    try std.testing.expectError(error.InvalidMessageFormat, skip.skipValue(&bytes, &pos));
}
