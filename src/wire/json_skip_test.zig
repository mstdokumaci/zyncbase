const std = @import("std");
const js = @import("json_skip.zig");

test "skipString simple" {
    const s = "\"hello\" rest";
    var pos: usize = 0;
    _ = js.skipString(s, &pos);
    try std.testing.expectEqual(@as(usize, 7), pos);
}

test "skipString with escapes" {
    const s = "\"a\\\"b\" rest";
    var pos: usize = 0;
    _ = js.skipString(s, &pos);
    try std.testing.expectEqual(@as(usize, 6), pos);
}

test "skipString unterminated returns null" {
    const s = "\"unterminated";
    var pos: usize = 0;
    try std.testing.expect(js.skipString(s, &pos) == null);
}

test "skipBalanced object" {
    const s = "{\"a\":1,\"b\":{\"c\":2}} rest";
    var pos: usize = 0;
    _ = js.skipBalanced(s, &pos, '{', '}');
    try std.testing.expectEqual(@as(usize, 19), pos);
}

test "skipBalanced array" {
    const s = "[1,2,[3,4]] rest";
    var pos: usize = 0;
    _ = js.skipBalanced(s, &pos, '[', ']');
    try std.testing.expectEqual(@as(usize, 11), pos);
}

test "skipBalanced ignores brackets in strings" {
    const s = "{\"key\":\"val{ue\"} rest";
    var pos: usize = 0;
    _ = js.skipBalanced(s, &pos, '{', '}');
    try std.testing.expectEqual(@as(usize, 16), pos);
}

test "skipBalanced unterminated returns null" {
    const s = "{ \"a\": 1 ";
    var pos: usize = 0;
    try std.testing.expect(js.skipBalanced(s, &pos, '{', '}') == null);
}

test "skipLiteral true false null" {
    const cases = [_]struct { src: []const u8, lit: []const u8, expect: usize }{
        .{ .src = "true rest", .lit = "true", .expect = 4 },
        .{ .src = "false rest", .lit = "false", .expect = 5 },
        .{ .src = "null rest", .lit = "null", .expect = 4 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        _ = js.skipLiteral(c.src, &pos, c.lit);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skipLiteral mismatch returns null" {
    const s = "true";
    var pos: usize = 0;
    try std.testing.expect(js.skipLiteral(s, &pos, "null") == null);
    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "skipNumber integer and float" {
    const cases = [_]struct { src: []const u8, expect: usize }{
        .{ .src = "123 rest", .expect = 3 },
        .{ .src = "-456 rest", .expect = 4 },
        .{ .src = "3.14 rest", .expect = 4 },
        .{ .src = "1e10 rest", .expect = 4 },
        .{ .src = "-2.5e-3 rest", .expect = 7 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        _ = js.skipNumber(c.src, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skipNumber non-number returns null" {
    const cases = [_][]const u8{
        "abc",
        "-",
        "-e",
        "-e+",
    };
    for (cases) |c| {
        var pos: usize = 0;
        try std.testing.expect(js.skipNumber(c, &pos) == null);
        try std.testing.expectEqual(@as(usize, 0), pos);
    }
}

test "skipValue dispatches by first byte" {
    const cases = [_]struct { src: []const u8, expect: usize }{
        .{ .src = "\"str\" rest", .expect = 5 },
        .{ .src = "{\"a\":1} rest", .expect = 7 },
        .{ .src = "[1,2] rest", .expect = 5 },
        .{ .src = "true rest", .expect = 4 },
        .{ .src = "false rest", .expect = 5 },
        .{ .src = "null rest", .expect = 4 },
        .{ .src = "123 rest", .expect = 3 },
        .{ .src = "-1.5 rest", .expect = 4 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        _ = js.skipValue(c.src, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skipValue unknown byte returns null" {
    const s = "x";
    var pos: usize = 0;
    try std.testing.expect(js.skipValue(s, &pos) == null);
}

test "skipValue nested object with array and string" {
    const s = "{\"a\":[1,\"b]\"],\"c\":true} rest";
    var pos: usize = 0;
    _ = js.skipValue(s, &pos);
    try std.testing.expectEqual(@as(usize, 23), pos);
}
