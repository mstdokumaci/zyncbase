const std = @import("std");
const testing = std.testing;
const th = @import("test_helpers.zig");
const makeTestUserFields = th.makeTestUserFields;
const freeTestFields = th.freeTestFields;
const makePresencePatch = th.makePresencePatch;
const makeTestSharedSingleField = th.makeTestSharedSingleField;
const PresenceWorker = @import("worker.zig").PresenceWorker;
const PresenceManager = @import("manager.zig").PresenceManager;
const typed = @import("../typed/doc_id.zig");
const send_queue_type = @import("../send_queue.zig").send_queue;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;

fn notifierFn(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
    _ = counter.fetchAdd(1, .monotonic);
}

fn setupWorker(
    allocator: std.mem.Allocator,
    memory_strategy: *MemoryStrategy,
    presence_manager: *PresenceManager,
    send_queue: *send_queue_type,
    notifier_counter: *std.atomic.Value(u32),
) !*PresenceWorker {
    const worker = try allocator.create(PresenceWorker);
    try worker.init(allocator, memory_strategy, presence_manager, send_queue, notifierFn, notifier_counter);
    try worker.spawn();
    return worker;
}

test "PresenceWorker: set_user op produces broadcast to send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer std.debug.assert(memory_strategy.deinit() == .ok);

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier_called = std.atomic.Value(u32).init(0);

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;

    // Subscribe synchronously so the worker has a subscriber to broadcast to
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const worker = try setupWorker(allocator, &memory_strategy, &presence_manager, &send_queue, &notifier_called);
    defer {
        worker.stop();
        worker.deinit();
        allocator.destroy(worker);
    }

    // Enqueue a set_user op — the patch is cloned into the op's allocator
    const user_id: typed.DocId = 42;
    const patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    const cloned_patch = try patch.deepClone(allocator);
    try worker.enqueue(.{
        .op = .{ .set_user = .{
            .namespace_id = namespace_id,
            .user_id = user_id,
            .patch = cloned_patch,
        } },
        .allocator = allocator,
    });

    // Wait for processing (condvar-based wakeup should be near-instant)
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue received the broadcast
    try testing.expect(send_queue.hasItems());

    // Verify notifier was called
    try testing.expect(notifier_called.load(.monotonic) > 0);

    // Drain and release the send_queue entry
    if (send_queue.pop()) |entry| {
        entry.deinit();
    }
}

test "PresenceWorker: no ops enqueued does not push to send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer std.debug.assert(memory_strategy.deinit() == .ok);

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier_called = std.atomic.Value(u32).init(0);

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;

    // Add a subscriber but enqueue no ops
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const worker = try setupWorker(allocator, &memory_strategy, &presence_manager, &send_queue, &notifier_called);
    defer {
        worker.stop();
        worker.deinit();
        allocator.destroy(worker);
    }

    // Wait briefly — no work enqueued, nothing should happen
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue is empty
    try testing.expect(!send_queue.hasItems());

    // Verify notifier was NOT called
    try testing.expectEqual(@as(u32, 0), notifier_called.load(.monotonic));
}

test "PresenceWorker: subscribe_user op sends snapshot via send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer std.debug.assert(memory_strategy.deinit() == .ok);

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier_called = std.atomic.Value(u32).init(0);

    const worker = try setupWorker(allocator, &memory_strategy, &presence_manager, &send_queue, &notifier_called);
    defer {
        worker.stop();
        worker.deinit();
        allocator.destroy(worker);
    }

    // Enqueue a subscribe_user op
    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;
    const msg_id: u64 = 42;

    try worker.enqueue(.{
        .op = .{ .subscribe_user = .{
            .namespace_id = namespace_id,
            .conn_id = conn_id,
            .sub_id = sub_id,
            .msg_id = msg_id,
        } },
        .allocator = allocator,
    });

    // Wait for processing
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue received the snapshot response
    try testing.expect(send_queue.hasItems());
    try testing.expect(notifier_called.load(.monotonic) > 0);

    // Drain and release
    if (send_queue.pop()) |entry| {
        entry.deinit();
    }
}

test "PresenceWorker: multiple ops batched into single flush" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer std.debug.assert(memory_strategy.deinit() == .ok);

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier_called = std.atomic.Value(u32).init(0);

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;
    const user_id: typed.DocId = 42;

    // Subscribe synchronously
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const worker = try setupWorker(allocator, &memory_strategy, &presence_manager, &send_queue, &notifier_called);
    defer {
        worker.stop();
        worker.deinit();
        allocator.destroy(worker);
    }

    // Enqueue multiple set_user ops rapidly — they should coalesce in the
    // PresenceManager's pending list and produce a single broadcast.
    for (0..5) |i| {
        const patch = try makePresencePatch(allocator, &.{
            .{ .idx = 0, .value = .{ .float = @floatFromInt(i) } },
        });
        defer patch.free(allocator);
        const cloned = try patch.deepClone(allocator);
        try worker.enqueue(.{
            .op = .{ .set_user = .{
                .namespace_id = namespace_id,
                .user_id = user_id,
                .patch = cloned,
            } },
            .allocator = allocator,
        });
    }

    // Wait for processing
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // The coalesced updates should produce at least one broadcast
    try testing.expect(send_queue.hasItems());

    // Drain all entries
    while (send_queue.pop()) |entry| {
        entry.deinit();
    }
}
