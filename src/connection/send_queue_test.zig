const std = @import("std");

const memory_strategy = @import("../memory/strategy.zig");
const send_queue_mod = @import("send_queue.zig");

const testing = std.testing;
const ArenaHandle = memory_strategy.ArenaHandle;
const MemoryStrategy = memory_strategy.MemoryStrategy;
const Delivery = send_queue_mod.Delivery;
const SendQueue = send_queue_mod.SendQueue;

fn dupeDelivery(handle: ArenaHandle, conn_id: u64, loop_id: u8, bytes: []const u8) !Delivery {
    return .{
        .conn_id = conn_id,
        .data = try handle.allocator().dupe(u8, bytes),
        .loop_id = loop_id,
    };
}

test "SendQueue: single entries land in the queue for their loop" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var queue = try SendQueue.init(ms.generalAllocator());
    defer queue.deinit();

    const handle = try ms.acquireArenaDeferred();
    const zero = try handle.allocator().dupe(u8, "zero");
    handle.retain();
    try queue.push(0, .{ .conn_id = 1, .data = zero, .arena = handle });
    const one = try handle.allocator().dupe(u8, "one");
    handle.retain();
    try queue.push(1, .{ .conn_id = 2, .data = one, .arena = handle });
    handle.release(); // producer hold; the entries hold the rest

    const zero_entry = queue.popFrom(0) orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("zero", zero_entry.data);
    zero_entry.deinit();
    try testing.expect(queue.popFrom(0) == null);

    const one_entry = queue.popFrom(1) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 2), one_entry.conn_id);
    try testing.expectEqualStrings("one", one_entry.data);
    one_entry.deinit();
    try testing.expect(queue.popFrom(1) == null);

    try testing.expect(!queue.hasItems());
}

test "SendQueue: a fanout batch is split once per owning loop" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var queue = try SendQueue.init(ms.generalAllocator());
    defer queue.deinit();

    const handle = try ms.acquireArenaDeferred();
    const deliveries = try handle.allocator().alloc(Delivery, 3);
    deliveries[0] = try dupeDelivery(handle, 11, 0, "a");
    deliveries[1] = try dupeDelivery(handle, 22, 1, "b");
    deliveries[2] = try dupeDelivery(handle, 33, 0, "c");

    handle.retain();
    queue.push(0, .{ .conn_id = 0, .data = &.{}, .arena = handle, .items = deliveries }) catch |err| {
        handle.release();
        return err;
    };
    handle.release(); // producer hold; one ref per split entry remains

    const loop0 = queue.popFrom(0) orelse return error.TestExpectedValue;
    const loop1 = queue.popFrom(1) orelse return error.TestExpectedValue;
    try testing.expect(loop0.items != null and loop1.items != null);
    try testing.expectEqual(@as(usize, 2), loop0.items.?.len);
    try testing.expectEqual(@as(usize, 1), loop1.items.?.len);
    // Each split entry takes its conn id from the first delivery in its slice.
    try testing.expectEqual(@as(u64, 11), loop0.conn_id);
    try testing.expectEqual(@as(u64, 22), loop1.conn_id);
    try testing.expectEqualStrings("b", loop1.items.?[0].data);
    loop0.deinit();
    loop1.deinit();

    try testing.expect(!queue.hasItems());
}

test "SendQueue: a single-loop batch stays one entry" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var queue = try SendQueue.init(ms.generalAllocator());
    defer queue.deinit();

    const handle = try ms.acquireArenaDeferred();
    const deliveries = try handle.allocator().alloc(Delivery, 2);
    deliveries[0] = try dupeDelivery(handle, 11, 0, "a");
    deliveries[1] = try dupeDelivery(handle, 22, 0, "b");

    handle.retain();
    queue.push(0, .{ .conn_id = 0, .data = &.{}, .arena = handle, .items = deliveries }) catch |err| {
        handle.release();
        return err;
    };
    handle.release();

    const entry = queue.popFrom(0) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 2), entry.items.?.len);
    try testing.expect(queue.popFrom(1) == null);
    entry.deinit();

    try testing.expect(!queue.hasItems());
}
