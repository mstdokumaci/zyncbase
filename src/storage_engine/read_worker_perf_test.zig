const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const StorageEngine = @import("../storage_engine.zig").StorageEngine;
const WriteOp = @import("write_queue.zig").WriteOp;
const ColumnValue = @import("sql.zig").ColumnValue;
const typed_doc_id = @import("../typed/doc_id.zig");
const DocId = typed_doc_id.DocId;
const sth = @import("../storage_engine_test_helpers.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const EngineTestContext = sth.EngineTestContext;
const ReadWorker = @import("read_worker_pool.zig").ReadWorker;
const storage_cache = @import("cache.zig");
const builtin = @import("builtin");

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
        .timestamp = std.time.timestamp(),
    } };
}

/// Insert one row via flushBatch so it hits SQLite + metadata cache.
fn insertRow(
    allocator: Allocator,
    ctx: *EngineTestContext,
    table_metadata: *const sth.Table,
    id: DocId,
    val: i64,
) !void {
    var batch = std.ArrayListUnmanaged(WriteOp).empty;
    defer {
        for (batch.items) |op| op.deinit(allocator);
        batch.deinit(allocator);
    }
    try batch.append(allocator, makeUpsertOp(allocator, table_metadata, id, 1, val));
    ctx.engine.write_worker.flush_wg.add(batch.items.len);
    var last_batch_time = std.time.milliTimestamp();
    ctx.engine.write_worker.flushBatch(&batch, &last_batch_time);
    // Drain change queue so nothing leaks.
    while (ctx.test_context.change_queue.?.shards[0].popTimed(0)) |job| {
        var j = job;
        j.deinit(allocator);
    }
    while (ctx.test_context.send_queue.?.pop()) |entry| entry.deinit();
}

/// Return a ReadWorker from the pool's first worker (pool must be running).
fn firstWorker(engine: *StorageEngine) *ReadWorker {
    const pool = engine.read_worker_pool.?; // zwanzig-disable-line: optional-unwrap
    return &pool.pool.workers[0];
}

const ConcurrentThreadCtx = struct {
    worker: *ReadWorker,
    table_metadata: *const sth.Table,
    ns_id: i64,
    num_rows: usize,
    reads_per_thread: usize,
    barrier: *std.atomic.Value(u32),
    pool_size: usize,
    err: ?anyerror,
};

fn concurrentThreadFn(tctx: *ConcurrentThreadCtx) void {
    _ = tctx.barrier.fetchAdd(1, .acq_rel);
    while (tctx.barrier.load(.acquire) < tctx.pool_size) {
        std.Thread.sleep(100);
    }

    tctx.err = null;
    for (0..tctx.reads_per_thread) |i| {
        const id: DocId = @intCast(i % tctx.num_rows);
        const record = tctx.worker.executeSelectDocument(tctx.table_metadata, id, tctx.ns_id) catch |e| {
            tctx.err = e;
            return;
        };
        if (record) |r| {
            const val = sth.getFieldInt(r, tctx.table_metadata, "val") catch {
                r.deinit(tctx.worker.read_arena.allocator());
                tctx.err = error.InvalidValue;
                return;
            };
            const expected_base: i64 = @intCast((i % tctx.num_rows) * 10);
            if (val != expected_base) {
                r.deinit(tctx.worker.read_arena.allocator());
                tctx.err = error.ValueMismatch;
                return;
            }
            r.deinit(tctx.worker.read_arena.allocator());
        } else {
            tctx.err = error.RowNotFound;
            return;
        }
    }
}

test "ReadWorker: cache miss → cache hit" {
    const allocator = testing.allocator;
    var ctx: EngineTestContext = undefined;
    try ctx.initWithPerformance(allocator, "read_cache_miss_hit", &.{items_table}, .{}, .{
        .in_memory = true,
        .reader_pool_size = 1,
    });
    defer ctx.deinit();

    const table_metadata = try ctx.tableMetadata("items");
    const doc_id: DocId = 42;

    // Insert row into SQLite. The metadata cache is cold for this key, so
    // executeSelectDocument should go to SQLite and populate the cache.
    try insertRow(allocator, &ctx, table_metadata, doc_id, 100);

    const worker = firstWorker(&ctx.engine);

    // Collect repeated miss/hit measurements and take the median.
    const rounds: usize = 20;
    var miss_samples: [rounds]u64 = undefined;
    var hit_samples: [rounds]u64 = undefined;

    for (0..rounds) |i| {
        // Miss: first read for this doc_id in a fresh arena reset cycle.
        // We evict the cache entry between rounds to force a miss.
        _ = ctx.engine.metadata_cache.evict(storage_cache.getCacheKey(table_metadata, 1, doc_id));

        var t = try std.time.Timer.start();
        const record_a = try worker.executeSelectDocument(table_metadata, doc_id, 1);
        miss_samples[i] = t.lap();
        try testing.expect(record_a != null);
        if (record_a) |r| r.deinit(worker.read_arena.allocator());

        // Hit: same doc_id — metadata cache now has the entry.
        var t2 = try std.time.Timer.start();
        const record_b = try worker.executeSelectDocument(table_metadata, doc_id, 1);
        hit_samples[i] = t2.lap();
        try testing.expect(record_b != null);
        if (record_b) |r| r.deinit(worker.read_arena.allocator());
    }

    // Verify the last read returned the correct value.
    const record_check = try worker.executeSelectDocument(table_metadata, doc_id, 1);
    try testing.expect(record_check != null);
    defer if (record_check) |r| r.deinit(worker.read_arena.allocator());
    const val = try sth.getFieldInt(record_check.?, table_metadata, "val");
    try testing.expectEqual(@as(i64, 100), val);

    // Sort samples and take the median (middle element).
    std.mem.sort(u64, &miss_samples, {}, comptime std.sort.asc(u64));
    std.mem.sort(u64, &hit_samples, {}, comptime std.sort.asc(u64));
    const median_miss = miss_samples[rounds / 2];
    const median_hit = hit_samples[rounds / 2];

    std.debug.print("ReadWorker cache: miss={d:.0} ns, hit={d:.0} ns, speedup={d:.2}x (median of {d})\n", .{
        @as(f64, @floatFromInt(median_miss)),
        @as(f64, @floatFromInt(median_hit)),
        if (median_hit > 0) @as(f64, @floatFromInt(median_miss)) / @as(f64, @floatFromInt(median_hit)) else 0,
        rounds,
    });

    // Cache hit must be at least as fast as cache miss.
    try testing.expect(median_hit <= median_miss);

    // Absolute thresholds: generous limits to catch regressions while
    // tolerating machine/allocator variance.
    const is_debug = builtin.mode == .Debug;
    const is_tsan = builtin.sanitize_thread;
    const miss_limit: u64 = if (is_tsan) 600_000 else if (is_debug) 300_000 else 150_000;
    const hit_limit: u64 = if (is_tsan) 4_000 else if (is_debug) 2_000 else 1_000;
    try testing.expect(median_miss < miss_limit);
    try testing.expect(median_hit < hit_limit);
}

test "ReadWorker: version-gated cache update" {
    const allocator = testing.allocator;
    var ctx: EngineTestContext = undefined;
    try ctx.initWithPerformance(allocator, "read_version_gate", &.{items_table}, .{}, .{
        .in_memory = true,
        .reader_pool_size = 1,
    });
    defer ctx.deinit();

    const table_metadata = try ctx.tableMetadata("items");
    const doc_id: DocId = 77;

    // Insert row and let cache populate via a normal read.
    try insertRow(allocator, &ctx, table_metadata, doc_id, 10);

    const worker = firstWorker(&ctx.engine);

    // First read populates cache.
    const r1 = try worker.executeSelectDocument(table_metadata, doc_id, 1);
    try testing.expect(r1 != null);
    defer if (r1) |r| r.deinit(worker.read_arena.allocator());

    // Bump writer_version — simulates a concurrent write between reads.
    // executeSelectDocument snapshots seq_before; cache.update is gated on
    // writer_version still equaling seq_before. With the bumped version the
    // gate fails and the (now stale) cache entry is NOT overwritten.
    const old_version = ctx.engine.write_worker.version.load(.monotonic);
    ctx.engine.write_worker.version.store(old_version + 1, .release);

    // Re-read: goes to SQLite, gets the *same* DB row (we didn't actually
    // update it), but version gate blocks cache refresh — this is correct
    // behaviour: a concurrent write *might* have changed the row, so we
    // must not blindly overwrite cache with a potentially stale snapshot.
    const r2 = try worker.executeSelectDocument(table_metadata, doc_id, 1);
    try testing.expect(r2 != null);
    defer if (r2) |r| r.deinit(worker.read_arena.allocator());

    // Verify the returned value is still correct.
    const val = try sth.getFieldInt(r2.?, table_metadata, "val");
    try testing.expectEqual(@as(i64, 10), val);
}

test "ReadWorker: concurrent readers — no data race" {
    const allocator = testing.allocator;
    const reader_pool_size: usize = 4;

    var ctx: EngineTestContext = undefined;
    try ctx.initWithPerformance(allocator, "read_concurrent", &.{items_table}, .{}, .{
        .in_memory = true,
        .reader_pool_size = reader_pool_size,
    });
    defer ctx.deinit();

    const table_metadata = try ctx.tableMetadata("items");
    const ns_id: i64 = 1;

    // Insert rows so every thread has something to read.
    const num_rows: usize = 64;
    for (0..num_rows) |i| {
        const id: DocId = @intCast(i);
        try insertRow(allocator, &ctx, table_metadata, id, @intCast(i * 10));
    }

    // Stop the pool — we want exclusive access to workers to drive them
    // from our own threads (avoids the pool's SPMC queue + notifier).
    ctx.engine.stopReaderPool();
    const pool = ctx.engine.read_worker_pool.?; // zwanzig-disable-line: optional-unwrap

    // Barrier so all reader threads start at the same instant.
    var barrier: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    const reads_per_thread: usize = 200;

    var threads: [reader_pool_size]std.Thread = undefined;
    var tctxs: [reader_pool_size]ConcurrentThreadCtx = undefined;

    for (0..reader_pool_size) |i| {
        const worker = &pool.pool.workers[i];
        tctxs[i] = .{
            .worker = worker,
            .table_metadata = table_metadata,
            .ns_id = ns_id,
            .num_rows = num_rows,
            .reads_per_thread = reads_per_thread,
            .barrier = &barrier,
            .pool_size = reader_pool_size,
            .err = null,
        };
        threads[i] = std.Thread.spawn(.{}, concurrentThreadFn, .{&tctxs[i]}) catch @panic("spawn");
    }

    for (threads) |t| t.join();

    for (tctxs, 0..) |tc, i| {
        if (tc.err) |err| {
            std.debug.print("\nthread {d} error: {}\n", .{ i, err });
            return error.TestUnexpectedResult;
        }
    }
}
