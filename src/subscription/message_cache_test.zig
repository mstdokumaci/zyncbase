const std = @import("std");

const message_cache = @import("message_cache.zig");
const MessageCache = message_cache.MessageCache;

test "MessageCache: empty, put, and last-key hit" {
    var cache: MessageCache = .{};
    try std.testing.expect(cache.get(1, .set_op) == null);
    cache.put(1, .set_op, "a");
    try std.testing.expectEqualStrings("a", cache.get(1, .set_op).?);
    try std.testing.expectEqualStrings("a", cache.get(1, .set_op).?);
    try std.testing.expect(cache.get(1, .remove) == null);
}

test "MessageCache: op and sub id distinguish entries" {
    var cache: MessageCache = .{};
    cache.put(1, .set_op, "set-1");
    cache.put(1, .remove, "remove-1");
    cache.put(2, .set_op, "set-2");
    try std.testing.expectEqualStrings("set-1", cache.get(1, .set_op).?);
    try std.testing.expectEqualStrings("remove-1", cache.get(1, .remove).?);
    try std.testing.expectEqualStrings("set-2", cache.get(2, .set_op).?);
    try std.testing.expect(cache.get(3, .set_op) == null);
}

test "MessageCache: collision overwrites without wrong results" {
    var cache: MessageCache = .{};
    // 65 maps to the same slot as 1 with 128 slots and one op bit.
    cache.put(1, .set_op, "one");
    cache.put(65, .set_op, "sixty-five");
    try std.testing.expect(cache.get(1, .set_op) == null);
    try std.testing.expectEqualStrings("sixty-five", cache.get(65, .set_op).?);
    cache.put(1, .set_op, "one-again");
    try std.testing.expectEqualStrings("one-again", cache.get(1, .set_op).?);
}

test "MessageCache: more keys than slots stays correct" {
    var cache: MessageCache = .{};
    var messages: [160][4]u8 = undefined;
    for (0..160) |i| {
        const msg = try std.fmt.bufPrint(&messages[i], "{d}", .{i});
        cache.put(i + 1, .set_op, msg);
        try std.testing.expectEqualStrings(msg, cache.get(i + 1, .set_op).?);
    }
}
