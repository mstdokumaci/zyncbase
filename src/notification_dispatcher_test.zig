const std = @import("std");
const testing = std.testing;
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const NotificationDispatcher = @import("notification_dispatcher.zig").NotificationDispatcher;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;

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
    // We don't fully init cm because it won't be used since buffer is empty

    // Poll without anything in buffer should do nothing
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

    // Push an item into ChangeBuffer
    try cb.push(.{
        .namespace = try alloc.dupe(u8, "ns"),
        .collection = try alloc.dupe(u8, "coll"),
        .operation = .insert,
        .old_row = null,
        .new_row = null,
    });

    var cm: ConnectionManager = undefined;
    // No subscriptions in sub_engine, so nd.poll won't actually call cm methods

    // Polling processes the item and clears it from our internal queue
    nd.poll(&cm);

    // The items inside drain_buf should be cleared
    try testing.expectEqual(@as(usize, 0), nd.drain_buf.items.len);
}
