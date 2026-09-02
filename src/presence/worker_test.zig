const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const typed = @import("../typed/doc_id.zig");
const th = @import("test_helpers.zig");
const send_queue_type = @import("../connection/send_queue.zig").send_queue;
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const MessageType = @import("../wire/message_type.zig").MessageType;
const PresenceManager = @import("manager.zig").PresenceManager;
const PresenceOp = @import("worker.zig").PresenceOp;
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
        try testing.expect(decoded == .arr);
        try testing.expectEqual(@as(usize, 3), decoded.arr.len);
        try testing.expectEqual(@as(u64, @intFromEnum(MessageType.presence_broadcast)), decoded.arr[0].uint);
        try testing.expectEqual(expected_sub, decoded.arr[1].uint);

        const users_val = decoded.arr[2];
        try testing.expect(users_val == .arr);
        try testing.expectEqual(@as(usize, 1), users_val.arr.len);
        const user = users_val.arr[0];
        try testing.expect(user == .arr);
        try testing.expectEqual(@as(usize, 4), user.arr.len);
        try testing.expectEqual(@as(u64, 0), user.arr[1].uint);
        const data_val = user.arr[2];
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

    // Build first so enqueueing into the running worker stays well inside the
    // fixed 2 ms window.
    var ops: [5]PresenceOp = undefined;
    var built: usize = 0;
    var enqueued: usize = 0;
    defer for (ops[enqueued..built]) |*op| op.deinit();

    for (0..5) |i| {
        const patch = try makePresencePatch(allocator, &.{
            .{ .idx = 0, .value = .{ .float = @floatFromInt(i) } },
        });
        defer patch.free(allocator);
        ops[built] = .{
            .op = .{ .set_user = .{
                .namespace_id = namespace_id,
                .user_id = user_id,
                .patch = try patch.deepClone(allocator),
            } },
            .allocator = allocator,
        };
        built += 1;
    }

    for (ops[0..built]) |op| {
        try worker.enqueue(op);
        enqueued += 1;
    }
    try worker.spawn();
    try notifier.completion.waitTimeout(testing.io, completion_timeout);

    var broadcast_count: usize = 0;
    while (send_queue.pop()) |entry| {
        defer entry.deinit();
        var reader: std.Io.Reader = .fixed(entry.data);
        const decoded = try msgpack.decode(allocator, &reader);
        defer decoded.free(allocator);
        try testing.expectEqual(@as(f64, 4.0), decoded.arr[2].arr[0].arr[2].arr[0].arr[1].float);
        broadcast_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), broadcast_count);
    try testing.expectEqual(@as(u32, 1), notifier.called.load(.monotonic));

    // Shutdown must bypass the window and publish the final pending mutation.
    const final_patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 5.0 } },
    });
    defer final_patch.free(allocator);
    try worker.enqueue(.{
        .op = .{ .set_user = .{
            .namespace_id = namespace_id,
            .user_id = user_id,
            .patch = try final_patch.deepClone(allocator),
        } },
        .allocator = allocator,
    });
    worker.stop();

    const final_entry = send_queue.pop() orelse return error.MissingFinalBroadcast;
    defer final_entry.deinit();
    var final_reader: std.Io.Reader = .fixed(final_entry.data);
    const final_decoded = try msgpack.decode(allocator, &final_reader);
    defer final_decoded.free(allocator);
    try testing.expectEqual(@as(f64, 5.0), final_decoded.arr[2].arr[0].arr[2].arr[0].arr[1].float);
    try testing.expect(send_queue.pop() == null);
}

test "PresenceWorker: dispatchBatches shares message buffer for same sub_id" {
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init();
    defer memory_strategy.deinit();
    const allocator = memory_strategy.generalAllocator();

    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedSingleField(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(testing.io, allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try send_node_pool.init(allocator, 64, null, null);
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

    const namespace_id: i64 = 1;

    // 3 subscribers: two share sub_id=1, one has sub_id=2
    var s1 = try presence_manager.onSubscribeUser(namespace_id, 10, 1);
    defer s1.deinit(allocator);
    var s2 = try presence_manager.onSubscribeUser(namespace_id, 20, 1);
    defer s2.deinit(allocator);
    var s3 = try presence_manager.onSubscribeUser(namespace_id, 30, 2);
    defer s3.deinit(allocator);

    const patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 42.0 } },
    });
    defer patch.free(allocator);

    try worker.enqueue(.{
        .op = .{ .set_user = .{
            .namespace_id = namespace_id,
            .user_id = 99,
            .patch = try patch.deepClone(allocator),
        } },
        .allocator = allocator,
    });

    try notifier.completion.waitTimeout(testing.io, completion_timeout);

    const SendQueueEntry = @import("../connection/send_queue.zig").Entry;
    var entry_1: ?SendQueueEntry = null;
    var entry_2: ?SendQueueEntry = null;
    var entry_3: ?SendQueueEntry = null;

    while (send_queue.pop()) |entry| {
        switch (entry.conn_id) {
            10 => entry_1 = entry,
            20 => entry_2 = entry,
            30 => entry_3 = entry,
            else => {
                entry.deinit();
                return error.UnexpectedConnId;
            },
        }
    }

    defer if (entry_1) |e| e.deinit();
    defer if (entry_2) |e| e.deinit();
    defer if (entry_3) |e| e.deinit();

    try testing.expect(entry_1 != null);
    try testing.expect(entry_2 != null);
    try testing.expect(entry_3 != null);

    const e1 = entry_1.?;
    const e2 = entry_2.?;
    const e3 = entry_3.?;

    // Conn 10 and 20 share sub_id=1, so their data slices must point to the EXACT same memory!
    try testing.expectEqual(@intFromPtr(e1.data.ptr), @intFromPtr(e2.data.ptr));
    try testing.expectEqual(e1.data.len, e2.data.len);

    // Conn 30 has sub_id=2, so its data slice must be a different allocation.
    try testing.expect(@intFromPtr(e1.data.ptr) != @intFromPtr(e3.data.ptr));

    // Verify wire payloads
    var r1: std.Io.Reader = .fixed(e1.data);
    const d1 = try msgpack.decode(allocator, &r1);
    defer d1.free(allocator);
    try testing.expectEqual(@as(u64, 1), d1.arr[1].uint);

    var r3: std.Io.Reader = .fixed(e3.data);
    const d3 = try msgpack.decode(allocator, &r3);
    defer d3.free(allocator);
    try testing.expectEqual(@as(u64, 2), d3.arr[1].uint);
}
