const builtin = @import("builtin");
const std = @import("std");

const config_state = @import("../config/state.zig");
const memory_strategy = @import("../memory/strategy.zig");
const schema_system = @import("../schema/system.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const ColumnValue = @import("sql.zig").ColumnValue;
const WriteOp = @import("write_queue.zig").WriteOp;

const Allocator = std.mem.Allocator;
const testing = std.testing;
const MemoryStrategy = memory_strategy.MemoryStrategy;
const EngineTestContext = sth.EngineTestContext;
const DocId = typed_doc_id.DocId;

const items_table = schema_helpers.makeTable("items", &.{
    schema_helpers.makeField("val", .integer),
});

fn makeUpsertOp(
    allocator: Allocator,
    table: *const sth.Table,
    id: DocId,
    namespace_id: i64,
    val: i64,
) WriteOp {
    const val_index = table.fieldIndex("val") orelse unreachable;
    const columns = allocator.alloc(ColumnValue, 1) catch @panic("oom");
    columns[0] = .{ .index = val_index, .value = .{ .scalar = .{ .integer = val } } };
    return .{ .upsert = .{
        .table_index = table.index,
        .id = id,
        .namespace_id = namespace_id,
        .owner_doc_id = typed_doc_id.zero,
        .columns = columns,
        .timestamp = std.Io.Clock.real.now(std.testing.io).toMicroseconds(),
    } };
}

fn runBatchSweep(
    allocator: Allocator,
    batch_len: usize,
    distinct_doc_count: usize,
    cache_population: usize,
    iterations: usize,
    ctx: *EngineTestContext,
) !struct { avg_flush: f64, avg_drain: f64, change_jobs: usize } {
    std.debug.assert(distinct_doc_count > 0 and distinct_doc_count <= batch_len);
    const table_metadata = try ctx.tableMetadata("items");
    const table_index = table_metadata.index;
    const ns_id: i64 = 1;

    var total_flush: u64 = 0;
    var total_drain: u64 = 0;
    const ww_alloc = ctx.engine.write_worker.allocator;

    // Warmup: insert initial rows so later iterations hit the update path (prefetchOldRecord).
    for (0..5) |warmup_idx| {
        var batch = std.ArrayListUnmanaged(WriteOp).empty;
        defer {
            for (batch.items) |op| op.deinit(ww_alloc);
            batch.deinit(allocator);
        }

        const warmup_len = if (warmup_idx == 0) @max(batch_len, cache_population) else batch_len;
        for (0..warmup_len) |i| {
            const id: DocId = @intCast(if (warmup_idx == 0) i else i % distinct_doc_count);
            try batch.append(allocator, makeUpsertOp(ww_alloc, table_metadata, id, ns_id, @intCast(i)));
        }

        // flush_wg.add(batch_len) is called manually to balance flushBatch's
        // internal endOp(batch_len). This mirrors what enqueueOp does in
        // production without involving the SPSC queue or worker thread.
        ctx.engine.write_worker.flush_wg.add(batch.items.len);
        var last_batch_time = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
        ctx.engine.write_worker.flushBatch(&batch, &last_batch_time);

        while (ctx.test_context.change_queue.?.shards[0].popTimed(0)) |job| {
            var j = job;
            j.deinit(allocator);
        }
        while (ctx.test_context.send_queue.?.pop()) |entry| entry.deinit();
    }

    // Warmup assertion: confirm last doc-id is present in SQLite.
    const last_id: DocId = @intCast((batch_len - 1) % distinct_doc_count);
    const warmup_record = try sth.readDoc(allocator, &ctx.engine, table_index, last_id, ns_id);
    try testing.expect(warmup_record != null);
    if (warmup_record) |r| r.deinit(allocator);

    // Timed iterations.
    for (0..iterations) |_| {
        var batch = std.ArrayListUnmanaged(WriteOp).empty;
        defer {
            for (batch.items) |op| op.deinit(ww_alloc);
            batch.deinit(allocator);
        }

        for (0..batch_len) |i| {
            const id: DocId = @intCast(i % distinct_doc_count);
            try batch.append(allocator, makeUpsertOp(ww_alloc, table_metadata, id, ns_id, @intCast(i)));
        }

        ctx.engine.write_worker.flush_wg.add(batch.items.len);

        var last_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();

        // Stage BC: full flushBatch (calls endOp internally, balancing the WaitGroup).
        // Includes BEGIN, N sqlite3_step() calls, COMMIT (WAL fsync to in-memory VFS),
        // cache write-through, ChangeQueue.push, and SendQueue.push.
        // In production on NVMe, COMMIT alone is ~3-5x slower than measured here due
        // to WAL file sync.
        var last_batch_time = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
        ctx.engine.write_worker.flushBatch(&batch, &last_batch_time);
        var now_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        total_flush += @intCast(now_ns - last_ns);
        last_ns = now_ns;

        // Stage D: drains shard 0 of the ChangeQueue (num_shards=1 in tests).
        // In production, changes are sharded across N shards by (namespace_id,
        // table_index, doc_id) hash. D measures the single-shard happy path.
        var change_jobs: usize = 0;
        while (ctx.test_context.change_queue.?.shards[0].popTimed(0)) |job| {
            var j = job;
            j.deinit(allocator);
            change_jobs += 1;
        }
        try testing.expectEqual(distinct_doc_count, change_jobs);
        now_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
        total_drain += @intCast(now_ns - last_ns);

        // Drain SendQueue (outcomes) to prevent arena leak.
        while (ctx.test_context.send_queue.?.pop()) |entry| entry.deinit();
    }

    const inv_iters: f64 = 1.0 / @as(f64, @floatFromInt(iterations));
    return .{
        .avg_flush = @as(f64, @floatFromInt(total_flush)) / 1e6 * inv_iters,
        .avg_drain = @as(f64, @floatFromInt(total_drain)) / 1e6 * inv_iters,
        .change_jobs = distinct_doc_count,
    };
}

test "WriteWorker: flushBatch throughput" {
    // Prod-shaped allocator: server.zig passes memory_strategy.generalAllocator()
    // into the engine. std.heap.smp_allocator's 10-frame stack capture dominates wall
    // time in Debug and distorts the throughput numbers.
    var prod_ms: MemoryStrategy = undefined;
    try prod_ms.init();
    defer prod_ms.deinit();
    const allocator = prod_ms.generalAllocator();

    // Disable auto-batching: test owns batch construction and flushBatch timing.
    const perf_cfg = config_state.Config.PerformanceConfig{
        .batch_writes = false,
        .batch_size = 1,
        .batch_timeout = 0,
        .statement_cache_size = 100,
        .message_buffer_size = 1000,
    };
    var ctx: EngineTestContext = undefined;
    try ctx.initWithPerformance(allocator, "write_worker_perf", &.{items_table}, perf_cfg, .{
        .in_memory = true,
        .reader_pool_size = 1,
    });
    defer ctx.deinit();

    const is_debug = builtin.mode == .Debug;
    const is_release_safe = builtin.mode == .ReleaseSafe;
    const is_tsan = builtin.sanitize_thread;

    // batch_len=10
    const r10 = try runBatchSweep(allocator, 10, 10, 10, if (is_tsan) 100 else if (is_debug) 100 else 500, &ctx);
    std.debug.print("flushBatch (batch_len=10) [ms]: flush={d:.3} drain={d:.3}\n", .{ r10.avg_flush, r10.avg_drain });

    // batch_len=100
    const r100 = try runBatchSweep(allocator, 100, 100, 100, if (is_tsan) 50 else if (is_debug) 50 else 200, &ctx);
    std.debug.print("flushBatch (batch_len=100) [ms]: flush={d:.3} drain={d:.3}\n", .{ r100.avg_flush, r100.avg_drain });

    // Production-sized batch against a small cache that still exposes per-write map cloning.
    const r200 = try runBatchSweep(allocator, 200, 200, 512, if (is_debug) 5 else if (is_release_safe) 10 else 20, &ctx);
    std.debug.print("flushBatch (batch_len=200, cache_entries=512) [ms]: flush={d:.3} drain={d:.3}\n", .{ r200.avg_flush, r200.avg_drain });

    const r200_hot = try runBatchSweep(allocator, 200, 10, 512, if (is_debug) 5 else if (is_release_safe) 10 else 20, &ctx);
    std.debug.print("flushBatch (batch_len=200, distinct_docs=10) [ms]: flush={d:.3} drain={d:.3} jobs={d}\n", .{ r200_hot.avg_flush, r200_hot.avg_drain, r200_hot.change_jobs });

    const target_flush_10: f64 = if (is_tsan) 3.0 else if (is_debug) 2.5 else 0.3;
    const target_drain_10: f64 = if (is_tsan) 0.02 else if (is_debug) 0.03 else 0.01;
    const target_flush_100: f64 = if (is_tsan) 45.0 else if (is_debug) 35.0 else 5.0;
    const target_drain_100: f64 = if (is_tsan) 0.25 else if (is_debug) 0.25 else 0.1;

    try testing.expect(r10.avg_flush < target_flush_10);
    try testing.expect(r10.avg_drain < target_drain_10);
    try testing.expect(r100.avg_flush < target_flush_100);
    try testing.expect(r100.avg_drain < target_drain_100);
    try testing.expect(r200.avg_flush < r100.avg_flush * 4.0);
}

test "WriteWorker: session resolutions commit in batches" {
    const resolution_count = 2000;
    var prod_ms: MemoryStrategy = undefined;
    try prod_ms.init();
    defer prod_ms.deinit();
    const allocator = prod_ms.generalAllocator();

    const perf_cfg = config_state.Config.PerformanceConfig{
        .batch_writes = true,
        .batch_size = 500,
        .batch_timeout = 8,
        .statement_cache_size = 100,
        .message_buffer_size = 1000,
    };
    const users_fields = [_]sth.Field{};
    const tables = [_]sth.Table{
        schema_helpers.makeTable("users", &users_fields),
        items_table,
    };
    // File-backed and synchronous=full: one commit per resolution would fsync
    // twice per client, which is exactly the storm this batch path removes.
    var ctx: EngineTestContext = undefined;
    try ctx.initWithPerformance(allocator, "resolve_batch_perf", &tables, perf_cfg, .{
        .in_memory = false,
        .reader_pool_size = 1,
        .synchronous = .full,
    });
    defer ctx.deinit();

    // The engine is started without a SessionResolver in tests, so drop the
    // per-resolution "resolver not set" warnings.
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    for (0..resolution_count) |i| {
        var user_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "resolve-user-{d}", .{i});
        try ctx.engine.enqueueSessionResolution(@intCast(i + 1), @intCast(i + 1), 0, "resolve-perf", user, false);
    }
    try ctx.engine.flushPendingWrites();
    const elapsed_ms = @as(f64, @floatFromInt(started.untilNow(std.testing.io, .awake).toNanoseconds())) / std.time.ns_per_ms;

    std.debug.print("flushResolutions ({d} sessions) [ms]: {d:.1}\n", .{ resolution_count, elapsed_ms });
    try testing.expect(ctx.engine.cachedNamespaceId("resolve-perf") != null);
    try testing.expect(ctx.engine.cachedUserId(schema_system.global_namespace_id, "resolve-user-0") != null);
    try testing.expect(ctx.engine.cachedUserId(schema_system.global_namespace_id, "resolve-user-1999") != null);

    // Unbatched this is one namespace + one user commit per client (~4k fsyncs).
    const target_ms: f64 = if (builtin.sanitize_thread) 10_000 else 1_000;
    try testing.expect(elapsed_ms < target_ms);
}
