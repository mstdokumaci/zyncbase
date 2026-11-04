const std = @import("std");

const log = @import("log.zig");

const testing = std.testing;

test "json log line escapes special characters" {
    const allocator = testing.allocator;

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);

    try log.appendJsonLine(allocator, &line, .warn, .default, "a\"b\\c\nd\x01", .{});
    try testing.expectEqualStrings(
        "{\"level\":\"warn\",\"msg\":\"a\\\"b\\\\c\\nd\\u0001\"}\n",
        line.items,
    );
}

test "json log line includes scope" {
    const allocator = testing.allocator;

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);

    try log.appendJsonLine(allocator, &line, .info, .http, "ok", .{});
    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"scope\":\"http\",\"msg\":\"ok\"}\n",
        line.items,
    );
}

test "json log line has no fixed message limit" {
    var msg: [4096]u8 = undefined;
    @memset(&msg, 'a');

    const allocator = testing.allocator;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);

    try log.appendJsonLine(allocator, &line, .info, .default, "{s}", .{msg[0..]});
    try testing.expect(std.mem.indexOf(u8, line.items, msg[0..]) != null);
    try testing.expect(std.mem.endsWith(u8, line.items, "\"}\n"));
}
