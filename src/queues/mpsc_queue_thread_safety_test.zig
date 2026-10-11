const std = @import("std");

const memory_strategy = @import("../memory/strategy.zig");
const mpscQueue = @import("mpsc_queue.zig").mpscQueue;

const testing = std.testing;
const ArenaHandle = memory_strategy.ArenaHandle;
const MemoryStrategy = memory_strategy.MemoryStrategy;

const TestEntry = struct {
    id: u64,
    msg: []const u8,
    arena: ArenaHandle,

    pub fn owner(self: TestEntry) ArenaHandle {
        return self.arena;
    }
};

const queue_type = mpscQueue(TestEntry, ArenaHandle);

const ProducerContext = struct {
    queue: *queue_type,
    ms: *MemoryStrategy,
    thread_id: u64,
    count: usize,
};

/// Mirrors the production producer shape: one deferred arena per batch,
/// a queue reference per pushed entry, producer reference dropped at the end.
fn produce(ctx: *ProducerContext) !void {
    const handle = try ctx.ms.acquireArenaDeferred();
    defer handle.release();
    const alloc = handle.allocator();

    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        const id = ctx.thread_id * 10000 + i;
        const msg = try std.fmt.allocPrint(alloc, "msg-{d}-{d}", .{ ctx.thread_id, i });
        handle.retain();
        ctx.queue.push(.{ .id = id, .msg = msg, .arena = handle }) catch |err| {
            handle.release();
            return err;
        };
    }
}

test "MpscQueue: many producers, one consumer, every entry arrives once" {
    const alloc = std.heap.smp_allocator;

    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(alloc);

    const thread_count = 4;
    const items_per_thread = 1000;

    var contexts = try alloc.alloc(ProducerContext, thread_count);
    defer alloc.free(contexts);
    var threads = try alloc.alloc(std.Thread, thread_count);
    defer alloc.free(threads);

    for (0..thread_count) |i| {
        contexts[i] = .{
            .queue = &q,
            .ms = &ms,
            .thread_id = @intCast(i),
            .count = items_per_thread,
        };
        threads[i] = try std.Thread.spawn(.{}, produce, .{&contexts[i]});
    }
    for (threads) |t| t.join();

    // Per-producer FIFO is guaranteed; global interleaving is not. Record
    // what each producer contributed and check it arrives as an unbroken run.
    var next_expected = [_]u64{0} ** thread_count;
    var received: usize = 0;
    while (q.pop()) |entry| {
        const producer = entry.id / 10000;
        try testing.expect(producer < thread_count);
        try testing.expectEqual(next_expected[producer], entry.id % 10000);
        next_expected[producer] += 1;
        received += 1;
        entry.arena.release();
    }

    try testing.expectEqual(@as(usize, thread_count * items_per_thread), received);
    q.deinit();
    // No entry reference and no head reference may survive the run.
    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}

test "MpscQueue: concurrent producers racing a live consumer" {
    const alloc = std.heap.smp_allocator;

    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(alloc);

    const producer_count = 3;
    const items_per_producer = 500;
    const total_expected = producer_count * items_per_producer;

    var contexts = try alloc.alloc(ProducerContext, producer_count);
    defer alloc.free(contexts);
    var threads = try alloc.alloc(std.Thread, producer_count + 1);
    defer alloc.free(threads);

    for (0..producer_count) |i| {
        contexts[i] = .{
            .queue = &q,
            .ms = &ms,
            .thread_id = @intCast(i),
            .count = items_per_producer,
        };
        threads[i] = try std.Thread.spawn(.{}, produce, .{&contexts[i]});
    }

    var consumed = std.atomic.Value(usize).init(0);
    threads[producer_count] = try std.Thread.spawn(.{}, struct {
        fn run(queue: *queue_type, counter: *std.atomic.Value(usize), expected: usize) void {
            while (counter.load(.acquire) < expected) {
                if (queue.pop()) |entry| {
                    entry.arena.release();
                    _ = counter.fetchAdd(1, .acq_rel);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run, .{ &q, &consumed, total_expected });

    for (threads) |t| t.join();

    try testing.expectEqual(total_expected, consumed.load(.acquire));
    try testing.expect(q.pop() == null);
    q.deinit();
    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}

test "MpscQueue: push during drain" {
    const alloc = std.testing.allocator;

    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(alloc);

    const first = try ms.acquireArenaDeferred();
    first.retain();
    try q.push(.{ .id = 1, .msg = try first.allocator().dupe(u8, "initial1"), .arena = first });

    first.retain();
    try q.push(.{ .id = 2, .msg = try first.allocator().dupe(u8, "initial2"), .arena = first });

    const drained_first = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 1), drained_first.id);
    drained_first.arena.release();

    first.retain();
    try q.push(.{ .id = 3, .msg = try first.allocator().dupe(u8, "during_drain"), .arena = first });
    first.retain();
    try q.push(.{ .id = 4, .msg = try first.allocator().dupe(u8, "after_push"), .arena = first });

    var count: usize = 0;
    while (q.pop()) |entry| {
        entry.arena.release();
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
    first.release(); // drop the producer reference
    q.deinit();
    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}
