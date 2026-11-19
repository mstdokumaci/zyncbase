const std = @import("std");

const Version = @import("version.zig").Version;

test "version: parses strict X.Y.Z" {
    const v = try Version.parse("12.0.345");
    try std.testing.expectEqual(@as(u32, 12), v.major);
    try std.testing.expectEqual(@as(u32, 0), v.minor);
    try std.testing.expectEqual(@as(u32, 345), v.patch);
    _ = try Version.parse("0.0.0");
}

test "version: rejects anything that is not strict X.Y.Z" {
    const invalid = [_][]const u8{
        "",        "1",      "1.0",    "1.0.0.0", "v1.0.0",         "1.0.0-beta",
        "1.0.0+b", "+1.0.0", "-1.0.0", "01.0.0",  "1.00.0",         "1.0.01",
        "1..0",    " 1.0.0", "1.0.0 ", "1.a.0",   "4294967296.0.0",
    };
    for (invalid) |text| {
        try std.testing.expectError(error.InvalidVersion, Version.parse(text));
    }
}

test "version: orders by major, minor, then patch" {
    const cases = [_]struct { a: []const u8, b: []const u8, expected: std.math.Order }{
        .{ .a = "1.0.0", .b = "1.0.0", .expected = .eq },
        .{ .a = "1.0.0", .b = "2.0.0", .expected = .lt },
        .{ .a = "1.10.0", .b = "1.9.9", .expected = .gt },
        .{ .a = "1.0.9", .b = "1.0.10", .expected = .lt },
        .{ .a = "0.9.0", .b = "1.0.0", .expected = .lt },
    };
    for (cases) |case| {
        const a = try Version.parse(case.a);
        const b = try Version.parse(case.b);
        try std.testing.expectEqual(case.expected, a.order(b));
    }
}
