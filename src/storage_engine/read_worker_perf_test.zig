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
const query_ast = @import("../query/ast.zig");
const qth = @import("../query/test_helpers.zig");
const tth = @import("../typed/test_helpers.zig");
const read_mod = @import("reader.zig");
const wire_encode = @import("../wire/encode.zig");
const query_hasher = @import("../query/hasher.zig");

const items_table = schema_helpers.makeTable("items", &.{
    schema_helpers.makeField("val", .integer),
});

const query_table = schema_helpers.makeTable("items", &.{
    schema_helpers.makeField("name", .text),
    schema_helpers.makeField("priority", .integer),
    schema_helpers.makeField("active", .integer),
    schema_helpers.makeField("tags", .text),
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
    const ww_alloc = ctx.engine.write_worker.allocator;
    var batch = std.ArrayListUnmanaged(WriteOp).empty;
    defer {
        for (batch.items) |op| op.deinit(ww_alloc);
        batch.deinit(allocator);
    }
    try batch.append(allocator, makeUpsertOp(ww_alloc, table_metadata, id, 1, val));
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

/// Construct a multi-column upsert WriteOp for the query_table (name, priority, active, tags).
fn makeQueryUpsertOp(
    allocator: Allocator,
    table: *const sth.Table,
    id: DocId,
    namespace_id: i64,
) WriteOp {
    const name_index = table.fieldIndex("name") orelse unreachable;
    const priority_index = table.fieldIndex("priority") orelse unreachable;
    const active_index = table.fieldIndex("active") orelse unreachable;
    const tags_index = table.fieldIndex("tags") orelse unreachable;

    const columns = allocator.alloc(ColumnValue, 4) catch @panic("oom");

    // name = "item-{id}"
    const name_str = std.fmt.allocPrint(allocator, "item-{d}", .{id}) catch @panic("oom");
    columns[0] = .{ .index = name_index, .value = .{ .scalar = .{ .text = name_str } } };

    // priority = id % 100
    const id_i64: i64 = @intCast(id);
    const priority: i64 = @rem(id_i64, 100);
    columns[1] = .{ .index = priority_index, .value = .{ .scalar = .{ .integer = priority } } };

    // active = id % 2
    const active: i64 = @rem(id_i64, 2);
    columns[2] = .{ .index = active_index, .value = .{ .scalar = .{ .integer = active } } };

    // tags = "tag-data-for-testing" (fixed string, must be owned by allocator)
    const tags_str = allocator.dupe(u8, "tag-data-for-testing") catch @panic("oom");
    columns[3] = .{ .index = tags_index, .value = .{ .scalar = .{ .text = tags_str } } };

    return .{ .upsert = .{
        .table_index = table.index,
        .id = id,
        .namespace_id = namespace_id,
        .owner_doc_id = typed_doc_id.zero,
        .columns = columns,
        .timestamp = std.time.timestamp(),
    } };
}

/// Bulk-insert 200 deterministic rows into the query_table via a single flushBatch call.
fn insertQueryRows(
    allocator: Allocator,
    ctx: *EngineTestContext,
    table_metadata: *const sth.Table,
) !void {
    const ww_alloc = ctx.engine.write_worker.allocator;
    var batch = std.ArrayListUnmanaged(WriteOp).empty;
    defer {
        for (batch.items) |op| op.deinit(ww_alloc);
        batch.deinit(allocator);
    }

    // Append 200 upsert ops into the batch.
    for (0..200) |i| {
        const id: DocId = @intCast(i);
        try batch.append(allocator, makeQueryUpsertOp(ww_alloc, table_metadata, id, 1));
    }

    // Flush the entire batch at once.
    ctx.engine.write_worker.flush_wg.add(batch.items.len);
    var last_batch_time = std.time.milliTimestamp();
    ctx.engine.write_worker.flushBatch(&batch, &last_batch_time);

    // Drain change_queue and send_queue so nothing leaks.
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

const SweepResult = struct {
    avg_a_ms: f64,
    avg_b_ms: f64,
    avg_c_ms: f64,
};

/// Run warmup + timed iterations of the select query pipeline (buildSelectQuery → execQuery → encodeQuery).
/// Returns per-stage average times in milliseconds.
fn runSelectQuerySweep(
    worker: *ReadWorker,
    table_metadata: *const sth.Table,
    filter: *const query_ast.QueryFilter,
    expected_rows: usize,
    iterations: usize,
) !SweepResult {
    const namespace_id: i64 = 1;
    const sort_field_index = filter.order_by.field_index;

    // --- Warmup: 5 iterations asserting correct row count ---
    for (0..5) |_| {
        _ = worker.read_arena.reset(.retain_capacity);

        const query_res = try read_mod.buildSelectQuery(worker.read_arena.allocator(), table_metadata, namespace_id, filter);

        worker.node.mutex.lock();
        var mstmt = try worker.node.stmt_cache.acquire(worker.allocator, &worker.node.conn, filter.structural_hash, query_res.sql);
        const exec_res = try read_mod.execQuery(
            worker.read_arena.allocator(),
            &worker.node.conn,
            mstmt.stmt,
            query_res.values,
            table_metadata,
            filter.limit,
            sort_field_index,
            &worker.json_buf,
        );
        mstmt.release();
        worker.node.mutex.unlock();

        try testing.expectEqual(expected_rows, exec_res.records.len);

        _ = try wire_encode.encodeQuery(worker.read_arena.allocator(), .{
            .msg_id = 1,
            .records = exec_res.records,
            .table = table_metadata,
        });
    }

    // --- Timed iterations ---
    var total_a: u64 = 0;
    var total_b: u64 = 0;
    var total_c: u64 = 0;

    for (0..iterations) |_| {
        _ = worker.read_arena.reset(.retain_capacity);

        var timer = try std.time.Timer.start();

        // Stage A: buildSelectQuery
        const query_res = try read_mod.buildSelectQuery(worker.read_arena.allocator(), table_metadata, namespace_id, filter);
        total_a += timer.lap();

        // Stage B: mutex.lock → stmt_cache.acquire → execQuery → stmt.release → mutex.unlock
        worker.node.mutex.lock();
        var mstmt = try worker.node.stmt_cache.acquire(worker.allocator, &worker.node.conn, filter.structural_hash, query_res.sql);
        const exec_res = try read_mod.execQuery(
            worker.read_arena.allocator(),
            &worker.node.conn,
            mstmt.stmt,
            query_res.values,
            table_metadata,
            filter.limit,
            sort_field_index,
            &worker.json_buf,
        );
        mstmt.release();
        worker.node.mutex.unlock();
        total_b += timer.lap();

        // Stage C: encodeQuery
        _ = try wire_encode.encodeQuery(worker.read_arena.allocator(), .{
            .msg_id = 1,
            .records = exec_res.records,
            .table = table_metadata,
        });
        total_c += timer.lap();
    }

    const iter_f: f64 = @floatFromInt(iterations);
    return SweepResult{
        .avg_a_ms = @as(f64, @floatFromInt(total_a)) / iter_f / 1_000_000.0,
        .avg_b_ms = @as(f64, @floatFromInt(total_b)) / iter_f / 1_000_000.0,
        .avg_c_ms = @as(f64, @floatFromInt(total_c)) / iter_f / 1_000_000.0,
    };
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
    defer ctx.engine.metadata_cache.reclaim(true);

    const table_metadata = try ctx.tableMetadata("items");
    const doc_id: DocId = 42;

    // Insert row into SQLite. The metadata cache is cold for this key, so
    // executeSelectDocument should go to SQLite and populate the cache.
    try insertRow(allocator, &ctx, table_metadata, doc_id, 100);
    ctx.engine.stopReaderPool();

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
    const miss_limit: u64 = if (is_tsan) 350_000 else if (is_debug) 300_000 else 250_000;
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
    defer ctx.engine.metadata_cache.reclaim(true);

    const table_metadata = try ctx.tableMetadata("items");
    const doc_id: DocId = 77;

    // Insert row and let cache populate via a normal read.
    try insertRow(allocator, &ctx, table_metadata, doc_id, 10);
    ctx.engine.stopReaderPool();

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
    defer ctx.engine.metadata_cache.reclaim(true);

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

test "ReadWorker: selectQuery throughput" {
    const allocator = testing.allocator;
    var ctx: EngineTestContext = undefined;
    try ctx.initWithPerformance(allocator, "read_select_query", &.{query_table}, .{}, .{
        .in_memory = true,
        .reader_pool_size = 1,
    });
    defer ctx.deinit();

    const table_metadata = try ctx.tableMetadata("items");

    // Insert 200 deterministic rows.
    try insertQueryRows(allocator, &ctx, table_metadata);

    // Stop reader pool, get worker directly.
    ctx.engine.stopReaderPool();
    const worker = firstWorker(&ctx.engine);

    // Mode-aware iteration counts.
    const is_debug = builtin.mode == .Debug;
    const is_tsan = builtin.sanitize_thread;
    const iterations: usize = if (is_tsan) 50 else if (is_debug) 100 else 500;

    // Sweep config: rows=10, priority < 5
    {
        var filter = try qth.makeFilterWithConditions(allocator, &.{
            .{
                .field_index = 4,
                .op = .lt,
                .value = tth.valInt(5),
                .field_type = .integer,
                .items_type = null,
            },
        });
        defer filter.deinit(allocator);
        filter.limit = 1000;
        filter.structural_hash = query_hasher.computeStructuralHash(&filter);

        const result = try runSelectQuerySweep(worker, table_metadata, &filter, 10, iterations);
        const total = result.avg_a_ms + result.avg_b_ms + result.avg_c_ms;
        std.debug.print("selectQuery (rows=10) [ms]: build(A)={d:.3} exec(B)={d:.3} encode(C)={d:.3} total={d:.3}\n", .{
            result.avg_a_ms,
            result.avg_b_ms,
            result.avg_c_ms,
            total,
        });

        const total_limit: f64 = if (is_tsan) 1.8 else if (is_debug) 0.6 else 0.2;
        try testing.expect(total < total_limit);
    }

    // Sweep config: rows=50, priority < 25
    {
        var filter = try qth.makeFilterWithConditions(allocator, &.{
            .{
                .field_index = 4,
                .op = .lt,
                .value = tth.valInt(25),
                .field_type = .integer,
                .items_type = null,
            },
        });
        defer filter.deinit(allocator);
        filter.limit = 1000;
        filter.structural_hash = query_hasher.computeStructuralHash(&filter);

        const result = try runSelectQuerySweep(worker, table_metadata, &filter, 50, iterations);
        const total = result.avg_a_ms + result.avg_b_ms + result.avg_c_ms;
        std.debug.print("selectQuery (rows=50) [ms]: build(A)={d:.3} exec(B)={d:.3} encode(C)={d:.3} total={d:.3}\n", .{
            result.avg_a_ms,
            result.avg_b_ms,
            result.avg_c_ms,
            total,
        });

        const total_limit: f64 = if (is_tsan) 3.6 else if (is_debug) 1.2 else 0.4;
        try testing.expect(total < total_limit);
    }

    // Sweep config: rows=100, priority < 50
    {
        var filter = try qth.makeFilterWithConditions(allocator, &.{
            .{
                .field_index = 4,
                .op = .lt,
                .value = tth.valInt(50),
                .field_type = .integer,
                .items_type = null,
            },
        });
        defer filter.deinit(allocator);
        filter.limit = 1000;
        filter.structural_hash = query_hasher.computeStructuralHash(&filter);

        const result = try runSelectQuerySweep(worker, table_metadata, &filter, 100, iterations);
        const total = result.avg_a_ms + result.avg_b_ms + result.avg_c_ms;
        std.debug.print("selectQuery (rows=100) [ms]: build(A)={d:.3} exec(B)={d:.3} encode(C)={d:.3} total={d:.3}\n", .{
            result.avg_a_ms,
            result.avg_b_ms,
            result.avg_c_ms,
            total,
        });

        const total_limit: f64 = if (is_tsan) 6.3 else if (is_debug) 2.1 else 0.7;
        try testing.expect(total < total_limit);
    }
}
