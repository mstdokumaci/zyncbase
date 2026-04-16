const std = @import("std");
const testing = std.testing;
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const NotificationDispatcher = @import("notification_dispatcher.zig").NotificationDispatcher;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const tth = @import("typed_test_helpers.zig");
// ============================================================
// Full dispatch integration tests
// ============================================================

test "NotificationDispatcher: empty poll" {
    const alloc = testing.allocator;

    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    var sub_engine = SubscriptionEngine.init(alloc);
    defer sub_engine.deinit();

    var memory: MemoryStrategy = undefined;
    try memory.init(alloc);
    defer memory.deinit();

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory);
    defer nd.deinit();

    var cm: ConnectionManager = undefined;
    nd.poll(&cm);
}

test "NotificationDispatcher: poll processes items" {
    const alloc = testing.allocator;

    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    var sub_engine = SubscriptionEngine.init(alloc);
    defer sub_engine.deinit();

    var memory: MemoryStrategy = undefined;
    try memory.init(alloc);
    defer memory.deinit();

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory);
    defer nd.deinit();

    // Create a row with an "id" field so dispatchChange doesn't skip it
    const new_row = try tth.row(alloc, .{
        .id = tth.valText("1"),
    });

    try cb.push(.{
        .namespace = try alloc.dupe(u8, "ns"),
        .collection = try alloc.dupe(u8, "coll"),
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    });

    var cm: ConnectionManager = undefined;
    nd.poll(&cm);

    try testing.expectEqual(@as(usize, 0), nd.drain_buf.items.len);
}
