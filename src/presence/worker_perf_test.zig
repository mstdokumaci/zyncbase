const builtin = @import("builtin");
const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const wire_encode = @import("../wire/encode.zig");
const th = @import("test_helpers.zig");
const send_queue_type = @import("../connection/send_queue.zig").send_queue;
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const PresenceManager = @import("manager.zig").PresenceManager;

const testing = std.testing;
const freeTestFields = th.freeTestFields;
const makePresencePatch = th.makePresencePatch;
const makeTestSharedSingleField = th.makeTestSharedSingleField;
const makeTestUserFields = th.makeTestUserFields;

const namespace_id: i64 = 1;
const subscriber_count: usize = 1_000;
const update_count: usize = 10;

const IterationResult = struct {
    update_ns: u64,
    batch_ns: u64,
    dispatch_ns: u64,
    drain_ns: u64,
    batch_count: usize,
    batch_namespace_id: i64,
    shared_batch_count: usize,
    update_count: usize,
    subscriber_count: usize,
    message_count: usize,
};

fn deinitBatches(comptime Batch: type, batches: *std.ArrayListUnmanaged(Batch), allocator: std.mem.Allocator) void {
    for (batches.items) |*batch| {
        for (batch.updates.items) |*update| update.patch.free(allocator);
        batch.updates.deinit(allocator);
        batch.subscribers.deinit(allocator);
    }
    batches.deinit(allocator);
}

fn discardPending(manager: *PresenceManager) !void {
    var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
    defer deinitBatches(PresenceManager.UserUpdateBatch, &user_batches, manager.allocator);
    var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
    defer deinitBatches(PresenceManager.SharedUpdateBatch, &shared_batches, manager.allocator);
    try manager.drainPendingBatches(&user_batches, &shared_batches);
}

fn runIteration(
    allocator: std.mem.Allocator,
    memory_strategy: *MemoryStrategy,
    manager: *PresenceManager,
    send_queue: *send_queue_type,
    patch: msgpack.Payload,
) !IterationResult {
    var last_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    for (0..update_count) |i| {
        const user_id: typed_doc_id.DocId = @intCast(i + 1);
        try manager.setUser(namespace_id, user_id, patch);
    }
    var now_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    const update_ns: u64 = @intCast(now_ns - last_ns);
    last_ns = now_ns;

    var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
    var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
    var batches_owned = true;
    defer if (batches_owned) {
        deinitBatches(PresenceManager.UserUpdateBatch, &user_batches, allocator);
        deinitBatches(PresenceManager.SharedUpdateBatch, &shared_batches, allocator);
    };
    try manager.drainPendingBatches(&user_batches, &shared_batches);
    now_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    const batch_ns: u64 = @intCast(now_ns - last_ns);
    last_ns = now_ns;

    const batch_count = user_batches.items.len;
    const batch_namespace_id = if (batch_count == 1) user_batches.items[0].namespace_id else 0;
    const shared_batch_count = shared_batches.items.len;
    const drained_update_count = if (batch_count == 1) user_batches.items[0].updates.items.len else 0;
    const drained_subscriber_count = if (batch_count == 1) user_batches.items[0].subscribers.items.len else 0;

    const handle = try memory_strategy.acquireArenaDeferred();
    var handle_owned = true;
    defer if (handle_owned) handle.release();

    for (user_batches.items) |batch| {
        for (batch.subscribers.items) |subscriber| {
            const msg = try wire_encode.encodePresenceBroadcast(handle.allocator(), subscriber.sub_id, batch.updates.items);
            handle.retain();
            send_queue.push(.{ .conn_id = subscriber.conn_id, .data = msg, .arena = handle }) catch |err| {
                handle.release();
                return err;
            };
        }
    }
    handle.release();
    handle_owned = false;
    deinitBatches(PresenceManager.UserUpdateBatch, &user_batches, allocator);
    deinitBatches(PresenceManager.SharedUpdateBatch, &shared_batches, allocator);
    batches_owned = false;
    now_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    const dispatch_ns: u64 = @intCast(now_ns - last_ns);
    last_ns = now_ns;

    var message_count: usize = 0;
    while (send_queue.pop()) |entry| {
        entry.deinit();
        message_count += 1;
    }
    now_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();

    return .{
        .update_ns = update_ns,
        .batch_ns = batch_ns,
        .dispatch_ns = dispatch_ns,
        .drain_ns = @intCast(now_ns - last_ns),
        .batch_count = batch_count,
        .batch_namespace_id = batch_namespace_id,
        .shared_batch_count = shared_batch_count,
        .update_count = drained_update_count,
        .subscriber_count = drained_subscriber_count,
        .message_count = message_count,
    };
}

fn expectWorkload(result: IterationResult) !void {
    try testing.expectEqual(@as(usize, 1), result.batch_count);
    try testing.expectEqual(namespace_id, result.batch_namespace_id);
    try testing.expectEqual(@as(usize, 0), result.shared_batch_count);
    try testing.expectEqual(update_count, result.update_count);
    try testing.expectEqual(subscriber_count, result.subscriber_count);
    try testing.expectEqual(subscriber_count, result.message_count);
}

test "PresenceWorker: batched user update fanout throughput" {
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init();
    defer memory_strategy.deinit();
    const allocator = memory_strategy.generalAllocator();

    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 2_048, null, null);
    defer send_node_pool.deinit();
    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    for (0..subscriber_count) |i| {
        var snapshot = try manager.onSubscribeUser(namespace_id, @intCast(i + 1), @intCast(i + 1));
        snapshot.deinit(allocator);
    }

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
        .{ .idx = 1, .value = .{ .float = 200.0 } },
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("active", allocator) },
    });
    defer patch.free(allocator);

    // Seed users, then discard their join batch so timed iterations exercise updates.
    for (0..update_count) |i| {
        try manager.setUser(namespace_id, @intCast(i + 1), patch);
    }
    try discardPending(&manager);

    for (0..5) |_| {
        const result = try runIteration(allocator, &memory_strategy, &manager, &send_queue, patch);
        try expectWorkload(result);
    }

    const iterations: usize = if (builtin.sanitize_thread) 50 else if (builtin.mode == .Debug) 100 else 500;
    var total_update: u64 = 0;
    var total_batch: u64 = 0;
    var total_dispatch: u64 = 0;
    var total_drain: u64 = 0;

    for (0..iterations) |_| {
        const result = try runIteration(allocator, &memory_strategy, &manager, &send_queue, patch);
        try expectWorkload(result);
        total_update += result.update_ns;
        total_batch += result.batch_ns;
        total_dispatch += result.dispatch_ns;
        total_drain += result.drain_ns;
    }

    const inv_iterations = 1.0 / @as(f64, @floatFromInt(iterations));
    const avg_update = @as(f64, @floatFromInt(total_update)) / 1e6 * inv_iterations;
    const avg_batch = @as(f64, @floatFromInt(total_batch)) / 1e6 * inv_iterations;
    const avg_dispatch = @as(f64, @floatFromInt(total_dispatch)) / 1e6 * inv_iterations;
    const avg_drain = @as(f64, @floatFromInt(total_drain)) / 1e6 * inv_iterations;
    const avg_total = avg_update + avg_batch + avg_dispatch + avg_drain;

    std.debug.print(
        "Presence fanout (1k subscribers / 10 updates) per stage [ms]: update(A)={d:.3} batch(B)={d:.3} dispatch(C)={d:.3} drain(D)={d:.3} total={d:.3}\n",
        .{ avg_update, avg_batch, avg_dispatch, avg_drain, avg_total },
    );

    const is_debug = builtin.mode == .Debug;
    const is_tsan = builtin.sanitize_thread;
    const target_update: f64 = if (is_tsan) 0.1 else if (is_debug) 0.5 else 0.03;
    const target_batch: f64 = if (is_tsan) 0.05 else if (is_debug) 1.0 else 0.2;
    const target_dispatch: f64 = if (is_tsan) 35.0 else if (is_debug) 125.0 else 7.0;
    const target_drain: f64 = if (is_tsan) 0.2 else if (is_debug) 1.0 else 0.05;
    const target_total: f64 = if (is_tsan) 35.0 else if (is_debug) 130.0 else 7.0;

    try testing.expect(avg_update < target_update);
    try testing.expect(avg_batch < target_batch);
    try testing.expect(avg_dispatch < target_dispatch);
    try testing.expect(avg_drain < target_drain);
    try testing.expect(avg_total < target_total);
}
