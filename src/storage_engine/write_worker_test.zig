const std = @import("std");

const schema_system = @import("../schema/system.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const storage_mod = @import("../storage_engine.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const write_worker = @import("write_worker.zig");

const testing = std.testing;

const DirectWriterContext = struct {
    allocator: std.mem.Allocator,
    engine: storage_mod.StorageEngine,
    schema: sth.Schema,
    memory_strategy: sth.MemoryStrategy,
    test_context: sth.TestContext,

    fn init(self: *DirectWriterContext, allocator: std.mem.Allocator, table: sth.Table) !void {
        self.allocator = allocator;
        self.test_context = try sth.TestContext.initInMemory(allocator);
        errdefer self.test_context.deinit();

        try self.memory_strategy.init();
        errdefer self.memory_strategy.deinit();

        const users_fields = [_]sth.Field{};
        const users_table = schema_helpers.makeTable("users", &users_fields);
        self.schema = try sth.createSchema(allocator, &[_]sth.Table{ users_table, table });
        errdefer self.schema.deinit();

        try self.engine.init(
            std.testing.io,
            allocator,
            &self.memory_strategy,
            self.test_context.test_dir,
            &self.schema,
            .{},
            .{ .in_memory = true, .reader_pool_size = 1 },
            null,
            null,
        );
        errdefer self.engine.deinit();

        for (self.schema.tables) |schema_table| {
            const ddl = try schema_helpers.fullDDL(allocator, schema_table);
            defer allocator.free(ddl);
            // zwanzig-disable-next-line: sentinel-alloc
            const ddl_z = try allocator.dupeZ(u8, ddl);
            defer allocator.free(ddl_z);
            try sth.execSetupSQL(&self.engine, ddl_z);
        }
    }

    fn deinit(self: *DirectWriterContext) void {
        self.engine.deinit();
        self.schema.deinit();
        self.memory_strategy.deinit();
        self.test_context.deinit();
    }
};

fn makeDeleteBatchOps(table_index: usize) ![]storage_mod.WriteOp {
    const entries = try std.heap.smp_allocator.alloc(storage_mod.WriteOp, 1);
    errdefer std.heap.smp_allocator.free(entries);
    entries[0] = .{ .delete = .{
        .table_index = table_index,
        .id = 1,
        .namespace_id = 1,
    } };
    return entries;
}

fn executeBatchForTest(ctx: *DirectWriterContext, entries: []storage_mod.WriteOp) void {
    var last_batch_time: i64 = 0;
    ctx.engine.write_worker.executeBatchOp(.{ .entries = entries }, &last_batch_time);
}

test "WriteWorker: created_at claim follows wall time then advances monotonically" {
    var last: i64 = 0;
    try std.testing.expectEqual(@as(i64, 100), try write_worker.claimNextCreatedAt(&last, 100));
    try std.testing.expectEqual(@as(i64, 101), try write_worker.claimNextCreatedAt(&last, 100));
    try std.testing.expectEqual(@as(i64, 102), try write_worker.claimNextCreatedAt(&last, 50));

    var other_table: i64 = 0;
    try std.testing.expectEqual(@as(i64, 100), try write_worker.claimNextCreatedAt(&other_table, 100));
    try std.testing.expectEqual(@as(i64, 102), last);

    last = schema_system.max_safe_timestamp_us;
    try std.testing.expectError(error.InvalidOperation, write_worker.claimNextCreatedAt(&last, 0));
}

test "WriteWorker: shutdown drain completes immediate ops" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const namespace_name = try allocator.dupe(u8, "shutdown-drain");
    const external_user_id = try allocator.dupe(u8, "shutdown-user");
    var session_queued = false;
    const session_op = storage_mod.WriteOp{
        .resolve_session = .{
            .conn_id = 0,
            .loop_id = 0,
            .msg_id = 1,
            .scope_seq = 0,
            .namespace = namespace_name,
            .external_user_id = external_user_id,
            .timestamp = 0,
        },
    };
    errdefer if (!session_queued) session_op.deinit(allocator);

    var checkpoint_latch = storage_mod.CheckpointLatch.init(std.testing.io);
    const checkpoint_op = storage_mod.WriteOp{
        .checkpoint = .{
            .mode = storage_mod.CheckpointMode.passive,
            .latch = &checkpoint_latch,
        },
    };

    try ctx.engine.write_worker.enqueueOp(session_op);
    session_queued = true;
    try ctx.engine.write_worker.enqueueOp(checkpoint_op);

    try ctx.engine.write_worker.spawn();
    ctx.engine.write_worker.stop();

    const checkpoint_stats = try checkpoint_latch.wait();

    try testing.expectEqual(storage_mod.CheckpointMode.passive, checkpoint_stats.mode);
    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
}

test "WriteWorker: batch cleanup when begin fails" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchOps(999);
    ctx.engine.write_worker.beginOp();
    try ctx.engine.write_worker.conn.exec("BEGIN TRANSACTION", .{}, .{});
    defer ctx.engine.write_worker.conn.exec("ROLLBACK", .{}, .{}) catch |err| {
        std.log.warn("failed to roll back test transaction: {}", .{err});
    };

    executeBatchForTest(&ctx, entries);

    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
}

test "WriteWorker: unknown tables roll back batches" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchOps(999);
    const version_before = ctx.engine.write_worker.version.load(.acquire);
    ctx.engine.write_worker.beginOp();
    executeBatchForTest(&ctx, entries);

    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
    try testing.expectEqual(version_before, ctx.engine.write_worker.version.load(.acquire));

    try ctx.engine.write_worker.conn.exec("BEGIN TRANSACTION", .{}, .{});
    try ctx.engine.write_worker.conn.exec("ROLLBACK", .{}, .{});
}

test "WriteWorker: unsupported ops roll back batches" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    var latch_ckpt = storage_mod.CheckpointLatch.init(std.testing.io);
    const entries = try allocator.alloc(storage_mod.WriteOp, 1);
    entries[0] = .{ .checkpoint = .{ .mode = .passive, .latch = &latch_ckpt } };
    const version_before = ctx.engine.write_worker.version.load(.acquire);
    ctx.engine.write_worker.beginOp();
    executeBatchForTest(&ctx, entries);

    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
    try testing.expectEqual(version_before, ctx.engine.write_worker.version.load(.acquire));

    try ctx.engine.write_worker.conn.exec("BEGIN TRANSACTION", .{}, .{});
    try ctx.engine.write_worker.conn.exec("ROLLBACK", .{}, .{});
}

test "WriteWorker: resolution queued after a write waits for that write" {
    const allocator = std.heap.smp_allocator;
    const users_fields = [_]sth.Field{};
    const users = schema_helpers.makeTable("users", &users_fields);
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try ctx.initWithPerformance(
        allocator,
        "resolution-after-write",
        &[_]sth.Table{ users, table },
        .{ .batch_timeout = 1000 },
        .{ .in_memory = true, .reader_pool_size = 1 },
    );
    defer ctx.deinit();

    // The user write and the session resolution share one identity. If the
    // resolution runs first, the write fails the unique external id index.
    const users_index = ctx.tableIndex("users");
    const user_id: typed_doc_id.DocId = 42;
    try sth.enqueueUpsert(&ctx.engine, users_index, user_id, 1, typed_doc_id.zero, &.{}, null, null);

    var id_buf: [32]u8 = undefined;
    const external_user_id = typed_doc_id.hexSlice(user_id, &id_buf);
    try ctx.engine.enqueueSessionResolution(0, 1, 0, 0, "resolution-order", external_user_id, false);
    try ctx.engine.flushPendingWrites();

    try testing.expect(ctx.engine.documentExists(users_index, user_id));
    try testing.expectEqual(user_id, ctx.engine.cachedUserId(schema_system.global_namespace_id, external_user_id).?);
}
