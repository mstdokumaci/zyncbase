const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RecordChange = @import("subscription_engine.zig").RecordChange;
const query_ast = @import("query_ast.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const send_queue_type = @import("send_queue.zig").send_queue;
const ChangeQueue = @import("change_queue.zig").ChangeQueue;
const NotificationWorker = @import("notification_worker_pool.zig").NotificationWorker;
const wire_encode = @import("wire/encode.zig");
const sth = @import("storage_engine_test_helpers.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const typed = @import("typed.zig");
const schema_mod = @import("schema.zig");

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
        try self.memory_strategy.init(allocator);
        self.change_queue = try ChangeQueue.init(allocator, 1);
        self.subscription_engine = SubscriptionEngine.init(allocator);
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
        std.debug.assert(self.memory_strategy.deinit() == .ok);
    }

    fn notifierFn(ctx: ?*anyopaque) void {
        const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
        _ = counter.fetchAdd(1, .monotonic);
    }
};

// Measures the full notification fanout for one change that matches 5k of 10k subscribers,
// broken down by stage so regressions can be attributed to a specific stage:
//   A: handleRecordChange (filter evaluation + Match gathering)   — matching
//   B: encodeSetDeltaSuffix (delta encoding, once per change)      — suffix
//   C: dispatchDeltasToMatches (arena dupe + send_queue push)      — fan-out dispatch
//   D: drain send_queue (per-match pop + free)                     — consumer side
test "NotificationWorkerPool: dispatch fanout performance" {
    const allocator = testing.allocator;
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
    var worker = NotificationWorker.init(
        0,
        &ctx.change_queue,
        &ctx.subscription_engine,
        &ctx.memory_strategy,
        &ctx.schema,
        &ctx.send_queue,
        TestContext.notifierFn,
        &ctx.notifier_called,
    );

    const doc_id: typed.DocId = 42;
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
    for (0..warmup) |_| {
        const handle = try ctx.memory_strategy.acquireArenaDeferred();
        const alloc = handle.allocator();
        const matches = try ctx.subscription_engine.handleRecordChange(change, alloc);
        const id_val = new_record.values[schema_mod.id_field_index];
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
        const alloc = handle.allocator();

        var t = try std.time.Timer.start();
        const matches = try ctx.subscription_engine.handleRecordChange(change, alloc);
        total_a += t.read();

        const id_val = new_record.values[schema_mod.id_field_index];
        t = try std.time.Timer.start();
        const set_suffix = try wire_encode.encodeSetDeltaSuffix(alloc, table.index, id_val, new_record, table);
        total_b += t.read();

        t = try std.time.Timer.start();
        worker.dispatchDeltasToMatches(matches, set_suffix, null, handle);
        total_c += t.read();

        t = try std.time.Timer.start();
        // final pop releases the arena back to the pool.
        while (ctx.send_queue.pop()) |entry| {
            entry.deinit();
        }
        total_d += t.read();
    }

    const inv_iters: f64 = 1.0 / @as(f64, @floatFromInt(iterations));
    const avg_a = @as(f64, @floatFromInt(total_a)) / 1e6 * inv_iters;
    const avg_b = @as(f64, @floatFromInt(total_b)) / 1e6 * inv_iters;
    const avg_c = @as(f64, @floatFromInt(total_c)) / 1e6 * inv_iters;
    const avg_d = @as(f64, @floatFromInt(total_d)) / 1e6 * inv_iters;
    const avg_total = avg_a + avg_b + avg_c + avg_d;

    std.debug.print(
        "\nFanout (10k subs / 5k matches) per stage [ms]: matching(A)={d:.3} suffix(B)={d:.3} dispatch(C)={d:.3} drain(D)={d:.3} total={d:.3}\n",
        .{ avg_a, avg_b, avg_c, avg_d, avg_total },
    );

    // Baseline (10k subs / 5k matches), per-iteration avg [ms]:
    //   ReleaseFast: A~0.04  C~0.36  D~0.11  total~0.52  (pool-parameterized MPSC queue)
    //   Debug:       A~0.21  C~16.9  D~14    total~31.1  (pool-parameterized MPSC queue, 500 iters)
    //   TSan:        A~1.6   C~37.2  D~21.6  total~60.4  (pool-parameterized MPSC queue, 500 iters)
    // Thresholds carry ~2x headroom over the Debug/TSan baseline to absorb machine/allocator
    // variance while still catching regressions, especially in the pool-backed dispatch stage C.
    const target_a: f64 = if (is_tsan) 3.5 else if (is_debug) 0.5 else 0.15;
    const target_c: f64 = if (is_tsan) 60.0 else if (is_debug) 35.0 else 0.9;
    const target_total: f64 = if (is_tsan) 120.0 else if (is_debug) 65.0 else 1.0;

    try testing.expect(avg_a < target_a);
    try testing.expect(avg_c < target_c);
    try testing.expect(avg_total < target_total);
}
