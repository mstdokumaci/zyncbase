const std = @import("std");

const query_ast = @import("../query/ast.zig");
const qth = @import("../query/test_helpers.zig");
const schema_system = @import("../schema/system.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const tth = @import("../typed/test_helpers.zig");
const wire_encode = @import("../wire/encode.zig");
const send_queue_type = @import("../connection/send_queue.zig").send_queue;
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const ChangeQueue = @import("change_queue.zig").ChangeQueue;
const RecordChange = @import("engine.zig").RecordChange;
const SubscriptionEngine = @import("engine.zig").SubscriptionEngine;
const SubscriptionWorker = @import("worker_pool.zig").SubscriptionWorker;

const testing = std.testing;

const TestContext = struct {
    allocator: std.mem.Allocator,
    memory_strategy: MemoryStrategy,
    change_queue: ChangeQueue,
    subscription_engine: SubscriptionEngine,
    send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node),
    send_queue: send_queue_type,
    schema: sth.Schema,
    notifier_called: std.atomic.Value(u32),

    fn init(self: *TestContext, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        // SAFETY: Immediately initialized by init() call below.
        self.memory_strategy = undefined;
        try self.memory_strategy.init();
        self.change_queue = try ChangeQueue.init(testing.io, allocator, 1);
        self.subscription_engine = SubscriptionEngine.init(testing.io, allocator);
        try self.send_node_pool.init(self.memory_strategy.generalAllocator(), 4096, null, null);
        self.send_queue = try send_queue_type.init(&self.send_node_pool);
        self.schema = try sth.createSchema(allocator, &.{
            schema_helpers.makeTable("items", &.{
                schema_helpers.makeField("status", .text),
            }),
        });
        self.notifier_called = std.atomic.Value(u32).init(0);
    }

    fn deinit(self: *TestContext) void {
        self.schema.deinit();
        while (self.send_queue.pop()) |entry| {
            entry.deinit();
        }
        self.send_queue.deinit();
        self.send_node_pool.deinit();
        self.subscription_engine.deinit();
        self.change_queue.deinit();
        self.memory_strategy.deinit();
    }

    fn notifierFn(ctx: ?*anyopaque) void {
        const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
        _ = counter.fetchAdd(1, .monotonic);
    }
};

// Measures the full subscription fanout for one change that matches 5k of 10k subscribers,
// broken down by stage so regressions can be attributed to a specific stage:
//   A: handleRecordChange (filter evaluation + Match gathering)   — matching
//   B: encodeSetDeltaSuffix (delta encoding, once per change)      — suffix
//   C: dispatchDeltasToMatches (arena dupe + send_queue push)      — fan-out dispatch
//   D: drain send_queue (per-match pop + free)                     — consumer side
test "SubscriptionWorkerPool: dispatch fanout performance" {
    const allocator = std.heap.smp_allocator;
    var ctx: TestContext = undefined;
    try ctx.init(allocator);
    defer ctx.deinit();

    const table = ctx.schema.table("items") orelse return error.TestExpectedValue;

    // 10k subscriptions: 500 groups × 20 subscribers.
    // Even groups match (field_3 == 0), odd groups reject (field_3 == 999),
    // so a record with field_3 == 0 yields 5k matches (50% of 10k).
    const group_count = 500;
    const subs_per_group = 20;

    for (0..group_count) |i| {
        const match_val: i64 = if (i % 2 == 0) 0 else 999;
        var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
            .{ .field_index = 3, .op = .eq, .value = tth.valInt(match_val), .field_type = .integer, .items_type = null },
        });
        defer filter.deinit(allocator);

        for (0..subs_per_group) |j| {
            _ = try ctx.subscription_engine.subscribe(
                1,
                table.index,
                filter,
                @as(u64, @intCast(i + 1)),
                @as(u64, @intCast(j + 1)),
            );
        }
    }

    // Worker is constructed but never started — we drive dispatch synchronously
    // (no thread scheduling jitter) to isolate the fanout cost from worker plumbing.
    var worker = SubscriptionWorker.init(
        0,
        &ctx.change_queue,
        &ctx.subscription_engine,
        &ctx.memory_strategy,
        &ctx.schema,
        &ctx.send_queue,
        TestContext.notifierFn,
        &ctx.notifier_called,
    );

    const doc_id: typed_doc_id.DocId = 42;
    var new_record = try tth.recordFromValues(allocator, &.{tth.valInt(0)});
    defer new_record.deinit(allocator);
    new_record.values[0].deinit(allocator);
    new_record.values[0] = .{ .scalar = .{ .doc_id = doc_id } };

    const change = RecordChange{
        .namespace_id = 1,
        .table_index = table.index,
        .operation = .insert,
        .new_record = new_record,
        .old_record = null,
    };

    const builtin = @import("builtin");
    const is_debug = builtin.mode == .Debug;
    const is_tsan = builtin.sanitize_thread;

    const iterations: usize = 500;
    const warmup: usize = 5;

    // Warm up (also confirms matching + dispatch + drain paths run end-to-end).
    // The expectEqual below guards the structural assumption: 500 groups × 20 subs × 50%
    // match rate = 5,000 matches. Without this, a broken filter or subscription setup
    // would silently measure a 0-match fast-path and pass all timing thresholds trivially.
    for (0..warmup) |_| {
        const handle = try ctx.memory_strategy.acquireArenaDeferred();
        errdefer handle.release();
        const alloc = handle.allocator();
        const matches = try ctx.subscription_engine.handleRecordChange(change, alloc);
        try testing.expectEqual(@as(usize, 5000), matches.len);
        const id_val = new_record.values[schema_system.id_field_index];
        const set_suffix = try wire_encode.encodeSetDeltaSuffix(alloc, table.index, id_val, new_record, table);
        worker.dispatchDeltasToMatches(matches, set_suffix, null, handle);
        // dispatchDeltasToMatches owns the arena; the final pop in this drain releases it.
        while (ctx.send_queue.pop()) |entry| {
            entry.deinit();
        }
    }

    var total_a: u64 = 0;
    var total_b: u64 = 0;
    var total_c: u64 = 0;
    var total_d: u64 = 0;

    for (0..iterations) |_| {
        const handle = try ctx.memory_strategy.acquireArenaDeferred();
        errdefer handle.release();
        const alloc = handle.allocator();

        // Single timer with lap() so inter-stage bookkeeping is included in the
        // total rather than silently lost to repeated Timer.start() syscalls.
        var last_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        const matches = try ctx.subscription_engine.handleRecordChange(change, alloc);
        var now_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        total_a += @intCast(now_ns - last_ns);
        last_ns = now_ns;

        const id_val = new_record.values[schema_system.id_field_index];
        const set_suffix = try wire_encode.encodeSetDeltaSuffix(alloc, table.index, id_val, new_record, table);
        now_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        total_b += @intCast(now_ns - last_ns);
        last_ns = now_ns;

        // Note: notifier callback is a counter increment, not a futex/semaphore
        // wake — C understates the real OS-level notification cost in production.
        worker.dispatchDeltasToMatches(matches, set_suffix, null, handle);
        now_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        total_c += @intCast(now_ns - last_ns);
        last_ns = now_ns;

        // Same-thread cache-warm drain. Real consumer is on a separate thread with
        // cache-cold access — D understates production consumer latency.
        // The final pop releases the arena back to the pool.
        while (ctx.send_queue.pop()) |entry| {
            entry.deinit();
        }
        now_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        total_d += @intCast(now_ns - last_ns);
    }

    const inv_iters: f64 = 1.0 / @as(f64, @floatFromInt(iterations));
    const avg_a = @as(f64, @floatFromInt(total_a)) / 1e6 * inv_iters;
    const avg_b = @as(f64, @floatFromInt(total_b)) / 1e6 * inv_iters;
    const avg_c = @as(f64, @floatFromInt(total_c)) / 1e6 * inv_iters;
    const avg_d = @as(f64, @floatFromInt(total_d)) / 1e6 * inv_iters;
    const avg_total = avg_a + avg_b + avg_c + avg_d;

    std.debug.print(
        "Fanout (10k subs / 5k matches) per stage [ms]: matching(A)={d:.3} suffix(B)={d:.3} dispatch(C)={d:.3} drain(D)={d:.3} total={d:.3}\n",
        .{ avg_a, avg_b, avg_c, avg_d, avg_total },
    );

    const target_a: f64 = if (is_tsan) 0.7 else if (is_debug) 0.7 else 0.15;
    const target_b: f64 = if (is_tsan) 0.01 else if (is_debug) 0.02 else 0.01;
    const target_c: f64 = if (is_tsan) 5.5 else if (is_debug) 6.0 else 1.0;
    const target_d: f64 = if (is_tsan) 1.0 else if (is_debug) 1.2 else 0.2;
    const target_total: f64 = if (is_tsan) 7.0 else if (is_debug) 8.0 else 1.3;

    try testing.expect(avg_a < target_a);
    try testing.expect(avg_b < target_b);
    try testing.expect(avg_c < target_c);
    try testing.expect(avg_d < target_d);
    try testing.expect(avg_total < target_total);
}
