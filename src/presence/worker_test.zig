const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const typed = @import("../typed/doc_id.zig");
const th = @import("test_helpers.zig");
const send_queue_type = @import("../connection/send_queue.zig").send_queue;
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const PresenceManager = @import("manager.zig").PresenceManager;
const PresenceWorker = @import("worker.zig").PresenceWorker;

const testing = std.testing;
const freeTestFields = th.freeTestFields;
const makePresencePatch = th.makePresencePatch;
const makeTestSharedSingleField = th.makeTestSharedSingleField;
const makeTestUserFields = th.makeTestUserFields;

const completion_timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } };

const TestNotifier = struct {
    called: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    completion: std.Io.Event = .unset,

    fn notify(ctx: ?*anyopaque) void {
        const self: *TestNotifier = @ptrCast(@alignCast(ctx));
        _ = self.called.fetchAdd(1, .monotonic);
        self.completion.set(testing.io);
    }
};

fn setupWorker(
    allocator: std.mem.Allocator,
    memory_strategy: *MemoryStrategy,
    presence_manager: *PresenceManager,
    send_queue: *send_queue_type,
    notifier: *TestNotifier,
) !*PresenceWorker {
    const worker = try allocator.create(PresenceWorker);
    try worker.init(allocator, memory_strategy, presence_manager, send_queue, TestNotifier.notify, notifier);
    try worker.spawn();
    return worker;
}

test "PresenceWorker: set_user op produces broadcast to send_queue" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(testing.io, allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init();
    defer memory_strategy.deinit();

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier: TestNotifier = .{};

    // Two subscribers on different connections whose subIds have different
    // MessagePack widths (fixint vs uint16) to catch scratch-buffer aliasing.
    const conn_a: u64 = 100;
    const sub_a: u64 = 1;
    const conn_b: u64 = 200;
    const sub_b: u64 = 256;
    const namespace_id: i64 = 1;

    // Subscribe synchronously so the worker has subscribers to broadcast to
    var snapshot_a = try presence_manager.onSubscribeUser(namespace_id, conn_a, sub_a);
    defer snapshot_a.deinit(allocator);
    var snapshot_b = try presence_manager.onSubscribeUser(namespace_id, conn_b, sub_b);
    defer snapshot_b.deinit(allocator);

    const worker = try setupWorker(allocator, &memory_strategy, &presence_manager, &send_queue, &notifier);
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

    try notifier.completion.waitTimeout(testing.io, completion_timeout);

    // Verify notifier was called
    try testing.expect(notifier.called.load(.monotonic) > 0);

    // Drain both entries only after dispatch completed; decode each while its
    // arena retain is live.
    var routed: usize = 0;
    while (send_queue.pop()) |entry| {
        defer entry.deinit();

        var reader: std.Io.Reader = .fixed(entry.data);
        const decoded = try msgpack.decode(allocator, &reader);
        defer decoded.free(allocator);

        const expected_sub: u64 = switch (entry.conn_id) {
            conn_a => sub_a,
            conn_b => sub_b,
            else => return error.UnexpectedConnId,
        };
        const sub_id_val = (try decoded.mapGet("subId")) orelse return error.MissingSubId;
        try testing.expectEqual(expected_sub, sub_id_val.uint);

        const users_val = (try decoded.mapGet("users")) orelse return error.MissingUsers;
        try testing.expect(users_val == .arr);
        try testing.expectEqual(@as(usize, 1), users_val.arr.len);
        const data_val = (try users_val.arr[0].mapGet("data")) orelse return error.MissingData;
        try testing.expect(data_val == .arr);
        try testing.expectEqual(@as(f64, 100.0), data_val.arr[0].arr[1].float);

        routed += 1;
    }
    try testing.expectEqual(@as(usize, 2), routed);
}

test "PresenceWorker: no ops enqueued does not push to send_queue" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(testing.io, allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init();
    defer memory_strategy.deinit();

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier: TestNotifier = .{};

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;

    // Add a subscriber but enqueue no ops
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const worker = try setupWorker(allocator, &memory_strategy, &presence_manager, &send_queue, &notifier);
    defer {
        worker.stop();
        worker.deinit();
        allocator.destroy(worker);
    }

    // Wait briefly — no work enqueued, nothing should happen
    try std.testing.io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake);

    // Verify send_queue is empty
    try testing.expect(!send_queue.hasItems());

    // Verify notifier was NOT called
    try testing.expectEqual(@as(u32, 0), notifier.called.load(.monotonic));
}

test "PresenceWorker: subscribe_user op sends snapshot via send_queue" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(testing.io, allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init();
    defer memory_strategy.deinit();

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier: TestNotifier = .{};

    const worker = try setupWorker(allocator, &memory_strategy, &presence_manager, &send_queue, &notifier);
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

    try notifier.completion.waitTimeout(testing.io, completion_timeout);

    // Verify send_queue received the snapshot response
    try testing.expect(send_queue.hasItems());
    try testing.expect(notifier.called.load(.monotonic) > 0);

    // Drain and release
    if (send_queue.pop()) |entry| {
        entry.deinit();
    }
}

test "PresenceWorker: multiple ops batched into single flush" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(testing.io, allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init();
    defer memory_strategy.deinit();

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 256, null, null);
    defer send_node_pool.deinit();

    var send_queue = try send_queue_type.init(&send_node_pool);
    defer {
        while (send_queue.pop()) |entry| entry.deinit();
        send_queue.deinit();
    }

    var notifier: TestNotifier = .{};

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;
    const user_id: typed.DocId = 42;

    // Subscribe synchronously
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const worker = try allocator.create(PresenceWorker);
    try worker.init(allocator, &memory_strategy, &presence_manager, &send_queue, TestNotifier.notify, &notifier);
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

    // Start only after the final op is queued, so this notification acknowledges
    // the single flush that drained the complete batch.
    try worker.spawn();
    try notifier.completion.waitTimeout(testing.io, completion_timeout);

    var broadcast_count: usize = 0;
    while (send_queue.pop()) |entry| {
        entry.deinit();
        broadcast_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), broadcast_count);
}
