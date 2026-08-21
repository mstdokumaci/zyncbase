const std = @import("std");

const app_test_helpers = @import("app_test_helpers.zig");
const send_queue_mod = @import("connection/send_queue.zig");
const fail_alloc = @import("failing_allocator_test_helper.zig");
const query_ast = @import("query/ast.zig");
const qth = @import("query/test_helpers.zig");
const schema_parse = @import("schema/parse.zig");
const schema_helpers = @import("schema/test_helpers.zig");
const storage_mod = @import("storage_engine.zig");
const cache_mod = @import("storage_engine/cache.zig");
const sth = @import("storage_engine_test_helpers.zig");
const typed_doc_id = @import("typed/doc_id.zig");
const tth = @import("typed/test_helpers.zig");
const typed = @import("typed/types.zig");
const DDLGenerator = @import("sql/ddl.zig").DDLGenerator;
const MessageType = @import("wire/message_type.zig").MessageType;

const testing = std.testing;
const SendQueueEntry = send_queue_mod.Entry;
const StorageEngine = sth.StorageEngine;

// Wire marker for the "type" key + numeric message ID, e.g. type:"WriteError"
fn typeMarker(comptime t: MessageType) [6]u8 {
    return .{ 0xa4, 't', 'y', 'p', 'e', @intFromEnum(t) };
}

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

        var gen = DDLGenerator.init(allocator);
        for (self.schema.tables) |schema_table| {
            const ddl = try gen.generateDDL(schema_table);
            defer allocator.free(ddl);
            const ddl_z = try allocator.dupeZ(u8, ddl);
            defer allocator.free(ddl_z);
            try self.engine.execSetupSQL(ddl_z);
        }
    }

    fn deinit(self: *DirectWriterContext) void {
        self.engine.deinit();
        self.schema.deinit();
        self.memory_strategy.deinit();
        self.test_context.deinit();
    }
};

fn makeDeleteBatchOps(allocator: std.mem.Allocator, table_index: usize) ![]storage_mod.WriteOp {
    _ = allocator;
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

test "StorageEngine: shutdown drain completes immediate writer ops" {
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

test "StorageEngine: init and deinit" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("_dummy", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "engine-init", table, .{ .in_memory = false });
    defer ctx.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ ctx.test_context.test_dir, "zyncbase.db" });
    defer allocator.free(db_path);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, db_path, .{});
    file.close(std.testing.io);
}
test "StorageEngine: insert and select basic" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("name", .text),
        schema_helpers.makeField("age", .integer),
    };
    const table = schema_helpers.makeTable("people", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "crud-basic", table);
    defer ctx.deinit();
    const people = try ctx.table("people");

    // Insert
    try people.insertNamed(1, 1, .{
        sth.named("name", tth.valText("Alice")),
        sth.named("age", tth.valInt(30)),
    });
    try people.flush();

    // Select
    var doc = try people.getOne(allocator, 1, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("name", "Alice");
    _ = try doc.expectFieldInt("age", 30);
}
test "StorageEngine: update document" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("test", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "crud-update", table);
    defer ctx.deinit();
    const docs = try ctx.table("test");

    try docs.insertText(1, 1, "val", "v1");
    try docs.flush();

    try docs.insertText(1, 1, "val", "v2");
    try docs.flush();

    var doc = try docs.getOne(allocator, 1, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("val", "v2");
}
test "StorageEngine: delete document" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("test", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "crud-delete", table);
    defer ctx.deinit();
    const docs = try ctx.table("test");

    try docs.insertText(1, 1, "val", "foo");
    try docs.flush();

    try docs.deleteDocument(1, 1);
    try docs.flush();

    const record = try docs.readDoc(allocator, 1, 1);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record == null);
}
test "StorageEngine: upsertDocument and selectDocument" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-crud", table);
    defer ctx.deinit();
    const items = try ctx.table("items");

    // Set a value
    try items.insertText(1, 2, "val", "test");
    // Flush writes
    try items.flush();
    // Get the value
    var doc = try items.getOne(allocator, 1, 2);
    defer doc.deinit();
    _ = try doc.expectFieldString("val", "test");
}
test "StorageEngine: selectDocument non-existent key" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-nonexistent", table);
    defer ctx.deinit();
    const items = try ctx.table("items");

    const record = try items.readDoc(allocator, 999, 2);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record == null);
}
test "StorageEngine: update existing document" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-update", table);
    defer ctx.deinit();
    const items = try ctx.table("items");

    // Set initial value
    try items.insertText(1, 2, "val", "initial");
    try items.flush();
    // Update value
    try items.insertText(1, 2, "val", "updated");
    try items.flush();
    // Get the value
    var doc = try items.getOne(allocator, 1, 2);
    defer doc.deinit();
    _ = try doc.expectFieldString("val", "updated");
}
test "StorageEngine: query collection" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("name", .text)};
    const table = schema_helpers.makeTable("people", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-query", table);
    defer ctx.deinit();
    const people = try ctx.table("people");

    // Set multiple documents
    try people.insertText(1, 2, "name", "Alice");
    try people.insertText(2, 2, "name", "Bob");
    try people.flush();
    // Query for collection using empty filter
    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    const qres = try people.queryDocs(allocator, 2, &filter);
    defer qres.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), qres.records.len);
}
test "StorageEngine: duplicate ids across namespaces are rejected" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-namespaces", table);
    defer ctx.deinit();
    const items = try ctx.table("items");

    // Insert the initial document.
    try items.insertText(1, 3, "val", "ns1");
    try items.flush();

    // Reusing the same id from another namespace must fail instead of mutating
    // the existing hidden row.
    try items.insertText(1, 4, "val", "ns2");
    try items.flush();

    var doc1 = try items.getOne(allocator, 1, 3);
    defer doc1.deinit();
    _ = try doc1.expectFieldString("val", "ns1");

    const record = try items.readDoc(allocator, 1, 4);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record == null);
}

test "StorageEngine: batchWrites false flushes single write without timeout delay" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithPerformance(
        &ctx,
        allocator,
        "engine-batch-writes-disabled",
        table,
        .{ .batch_writes = false, .batch_timeout = 5_000 },
        .{ .in_memory = true, .reader_pool_size = 1 },
    );
    defer ctx.deinit();

    const start_ns = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
    try ctx.insertText("items", 1, 5, "val", "value1");
    try ctx.engine.flushPendingWrites();
    const elapsed = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() - start_ns;
    try testing.expect(elapsed < std.time.ns_per_s);

    const record = try (try ctx.table("items")).readDoc(allocator, 1, 5);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
}

test "StorageEngine: low-level batch writer cleans up when begin fails" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchOps(allocator, 999);
    ctx.engine.write_worker.beginOp();
    try ctx.engine.write_worker.conn.exec("BEGIN TRANSACTION", .{}, .{});
    defer ctx.engine.write_worker.conn.exec("ROLLBACK", .{}, .{}) catch |err| {
        std.log.warn("failed to roll back test transaction: {}", .{err});
    };

    executeBatchForTest(&ctx, entries);

    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
}

test "StorageEngine: low-level batch writer rejects unknown tables and rolls back" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchOps(allocator, 999);
    const version_before = ctx.engine.write_worker.version.load(.acquire);
    ctx.engine.write_worker.beginOp();
    executeBatchForTest(&ctx, entries);

    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
    try testing.expectEqual(version_before, ctx.engine.write_worker.version.load(.acquire));

    try ctx.engine.write_worker.conn.exec("BEGIN TRANSACTION", .{}, .{});
    try ctx.engine.write_worker.conn.exec("ROLLBACK", .{}, .{});
}

test "StorageEngine: low-level batch writer rejects unsupported ops and rolls back" {
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

test "StorageEngine: concurrent reads" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .integer)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-concurrent", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Set some values
    try ctx.insertInt("items", 1, 2, "val", 1);
    try ctx.insertInt("items", 2, 2, "val", 1);
    try engine.flushPendingWrites();
    // Perform multiple concurrent reads
    const items_table_index = ctx.tableIndex("items");
    const Thread = struct {
        fn readKey(eng: *sth.StorageEngine, alloc: std.mem.Allocator, table_index: usize, id: u128) !void {
            const record = try sth.readDoc(alloc, eng, table_index, id, 2);
            defer if (record) |r| r.deinit(alloc);
            try testing.expect(record != null);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const id: u128 = if (i % 2 == 0) 1 else 2;
        thread.* = try std.Thread.spawn(.{}, Thread.readKey, .{ engine, allocator, items_table_index, id });
    }
    for (threads) |thread| {
        thread.join();
    }
}
test "StorageEngine: all pending writes are flushed before deinit returns" {
    // Regression test for brittle shutdown synchronization.
    // Previously deinit() used a fixed 50ms sleep before joining the write
    // thread, which could race and lose in-flight writes. Now it signals
    // work_cond and joins cleanly, guaranteeing the write thread has flushed
    // its remaining batch before deinit returns.
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .integer)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    const num_keys = 50;
    var test_dir: []const u8 = undefined;

    {
        // Enqueue a burst of writes without waiting — deinit must flush them.
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngineWithOptions(&ctx, allocator, "engine-deinit-flush", table, .{ .in_memory = false });
        errdefer ctx.deinit();
        // We dupe the test_dir because deinitNoCleanup will free the copy in ctx,
        // but we need it for the second part of the test.
        test_dir = try allocator.dupe(u8, ctx.test_context.test_dir);
        for (0..num_keys) |i| {
            const id: u128 = i + 1;
            try ctx.insertInt("items", id, 1, "val", @intCast(i));
        }
        // deinitNoCleanup will stop the engine but NOT delete the files.
        ctx.deinitNoCleanup();
    }
    defer allocator.free(test_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

    // Reopen the same database and verify every key is present.
    // We use setupEngineWithDir which reuses the existing data.
    var verify_ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithDir(&verify_ctx, allocator, test_dir, table, .{
        .in_memory = false,
    });
    defer verify_ctx.deinit();

    for (0..num_keys) |i| {
        const id: u128 = i + 1;
        const record = try (try verify_ctx.table("items")).readDoc(allocator, id, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
}
test "StorageEngine: client writes blocked during migration" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .integer)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-migration-block", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Simulate migration in progress
    engine.migration_active.store(true, .release);
    defer engine.migration_active.store(false, .release);
    // enqueueWriteOp should be blocked
    const err1 = ctx.insertField("items", 1, 1, "val", tth.valInt(1));
    try testing.expectError(sth.StorageError.MigrationInProgress, err1);
    // delete should be blocked
    const err3 = (try ctx.table("items")).deleteDocument(1, 1);
    try testing.expectError(sth.StorageError.MigrationInProgress, err3);
}
test "StorageEngine: engine healthy after start" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-healthy-start", table);
    defer ctx.deinit();

    try testing.expect(ctx.engine.isHealthy());
    try testing.expect(ctx.engine.write_worker.isHealthy());
}
test "StorageEngine: writes rejected when engine unhealthy" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-unhealthy-reject", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    engine.write_worker.is_healthy.store(false, .release);
    defer engine.write_worker.is_healthy.store(true, .release);

    try testing.expect(!engine.isHealthy());

    const err1 = ctx.insertField("items", 1, 1, "val", tth.valInt(1));
    try testing.expectError(sth.StorageError.EngineUnhealthy, err1);

    const err2 = (try ctx.table("items")).deleteDocument(1, 1);
    try testing.expectError(sth.StorageError.EngineUnhealthy, err2);
}
test "StorageEngine: ensureHealthy returns error when unhealthy" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-ensure-healthy", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try engine.ensureHealthy();

    engine.write_worker.is_healthy.store(false, .release);
    defer engine.write_worker.is_healthy.store(true, .release);

    try testing.expectError(sth.StorageError.EngineUnhealthy, engine.ensureHealthy());
}

fn drainOutcomes(sq: *send_queue_mod.send_queue) ![]SendQueueEntry {
    var entries = std.ArrayListUnmanaged(SendQueueEntry).empty;
    errdefer {
        for (entries.items) |entry| entry.deinit();
        entries.deinit(std.heap.smp_allocator);
    }
    while (sq.pop()) |entry| {
        errdefer entry.deinit();
        try entries.append(std.heap.smp_allocator, entry);
    }
    return try entries.toOwnedSlice(std.heap.smp_allocator);
}

fn makeGuardPredicate(allocator: std.mem.Allocator, field_index: usize, field_type: sth.FieldType, value: typed.Value) !query_ast.FilterPredicate {
    const conditions = try allocator.alloc(query_ast.Condition, 1);
    conditions[0] = .{
        .field_index = field_index,
        .op = .eq,
        .value = value,
        .field_type = field_type,
        .items_type = null,
    };
    return .{ .conditions = conditions };
}

test "StorageEngine: confirmed upsert with rejecting guard returns PermissionDenied" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-upsert-reject", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const val_field_idx = table_meta.fieldIndex("val").?;
    const doc_id: typed_doc_id.DocId = 42;
    const namespace_id: i64 = 1;
    const author_a: typed_doc_id.DocId = 100;
    const author_b: typed_doc_id.DocId = 200;

    const columns = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "original" } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    const conn_id: u64 = 999;
    const write_id: [16]u8 = .{1} ** 16;
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &update_columns, guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, &typeMarker(.write_error)) != null);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "PERMISSION_DENIED") != null);
}

test "StorageEngine: mixed flush batch commits passing op and rejects guarded op independently" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-mixed-batch", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const val_field_idx = table_meta.fieldIndex("val").?;
    const namespace_id: i64 = 1;
    const doc_ok: typed_doc_id.DocId = 1;
    const doc_reject: typed_doc_id.DocId = 2;
    const author_a: typed_doc_id.DocId = 100;
    const author_b: typed_doc_id.DocId = 200;

    // Pre-create both documents owned by author_a.
    const seed_ok = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "original" } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_ok, namespace_id, author_a, &seed_ok, null, null, null);
    const seed_reject = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "original" } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_reject, namespace_id, author_a, &seed_reject, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    // Enqueue two confirmed writes, then flush once so they share a batch:
    // op #1 has no guard (must commit), op #2 has a rejecting guard (must fail).
    const conn_ok: u64 = 1001;
    const write_ok: [16]u8 = .{1} ** 16;
    const ok_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_ok, namespace_id, author_a, &ok_columns, null, conn_ok, write_ok);

    const conn_reject: u64 = 1002;
    const write_reject: [16]u8 = .{2} ** 16;
    const reject_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_reject, namespace_id, author_a, &reject_columns, guard, conn_reject, write_reject);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |e| {
        if (e.conn_id == conn_reject) {
            try testing.expect(std.mem.indexOf(u8, e.data, &typeMarker(.write_error)) != null);
            try testing.expect(std.mem.indexOf(u8, e.data, "PERMISSION_DENIED") != null);
        } else {
            try testing.expectEqual(conn_ok, e.conn_id);
            try testing.expect(std.mem.indexOf(u8, e.data, &typeMarker(.write_error)) == null);
        }
    }

    // The passing op committed; the rejected op left its row untouched.
    const rec_ok = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_ok, namespace_id);
    defer if (rec_ok) |r| r.deinit(allocator);
    try testing.expect(rec_ok != null);
    try testing.expectEqualStrings("updated", rec_ok.?.values[val_field_idx].scalar.text);

    const rec_reject = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_reject, namespace_id);
    defer if (rec_reject) |r| r.deinit(allocator);
    try testing.expect(rec_reject != null);
    try testing.expectEqualStrings("original", rec_reject.?.values[val_field_idx].scalar.text);
}

test "StorageEngine: accepted upsert with rejecting guard is silent no-op" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-upsert-accepted", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const val_field_idx = table_meta.fieldIndex("val").?;
    const doc_id: typed_doc_id.DocId = 42;
    const namespace_id: i64 = 1;
    const author_a: typed_doc_id.DocId = 100;
    const author_b: typed_doc_id.DocId = 200;

    const columns = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "original" } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &update_columns, guard, null, null);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 0), entries.len);

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    const val = record.?.values[val_field_idx];
    try testing.expectEqualStrings("original", val.scalar.text);
}

test "StorageEngine: confirmed delete with rejecting guard returns PermissionDenied" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-delete-reject", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const val_field_idx = table_meta.fieldIndex("val").?;
    const doc_id: typed_doc_id.DocId = 42;
    const namespace_id: i64 = 1;
    const author_a: typed_doc_id.DocId = 100;
    const author_b: typed_doc_id.DocId = 200;

    const columns = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "hello" } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const conn_id: u64 = 888;
    const write_id: [16]u8 = .{2} ** 16;
    try sth.enqueueDelete(&ctx.engine, table_meta.index, doc_id, namespace_id, guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, &typeMarker(.write_error)) != null);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "PERMISSION_DENIED") != null);

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
}

test "StorageEngine: confirmed delete of non-existent row succeeds" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-delete-missing", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const doc_id: typed_doc_id.DocId = 999;
    const namespace_id: i64 = 1;
    const author_b: typed_doc_id.DocId = 200;

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const conn_id: u64 = 777;
    const write_id: [16]u8 = .{3} ** 16;
    try sth.enqueueDelete(&ctx.engine, table_meta.index, doc_id, namespace_id, guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, &typeMarker(.write_committed)) != null);
}

test "StorageEngine: confirmed update with guard on non-existent row succeeds" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-update-missing", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const val_field_idx = table_meta.fieldIndex("val").?;
    const doc_id: typed_doc_id.DocId = 42;
    const namespace_id: i64 = 1;
    const author_b: typed_doc_id.DocId = 200;

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    const conn_id: u64 = 555;
    const write_id: [16]u8 = .{4} ** 16;
    try sth.enqueueUpdate(&ctx.engine, table_meta.index, doc_id, namespace_id, &update_columns, guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, &typeMarker(.write_committed)) != null);
}

test "StorageEngine: confirmed upsert with guard on non-existent row succeeds" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-upsert-missing", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const val_field_idx = table_meta.fieldIndex("val").?;
    const doc_id: typed_doc_id.DocId = 42;
    const namespace_id: i64 = 1;
    const author_a: typed_doc_id.DocId = 100;

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_a } });
    defer guard.deinit(allocator);

    const columns = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "new" } } },
    };
    const conn_id: u64 = 666;
    const write_id: [16]u8 = .{5} ** 16;
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &columns, guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, &typeMarker(.write_committed)) != null);

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    const val = record.?.values[val_field_idx];
    try testing.expectEqualStrings("new", val.scalar.text);
}

test "StorageEngine: confirmed update with rejecting guard on existing row returns PermissionDenied" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("author_id", .doc_id),
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-update-reject", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const author_field_idx = table_meta.fieldIndex("author_id").?;
    const val_field_idx = table_meta.fieldIndex("val").?;
    const doc_id: typed_doc_id.DocId = 42;
    const namespace_id: i64 = 1;
    const author_a: typed_doc_id.DocId = 100;
    const author_b: typed_doc_id.DocId = 200;

    const columns = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "original" } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    const conn_id: u64 = 444;
    const write_id: [16]u8 = .{6} ** 16;
    try sth.enqueueUpdate(&ctx.engine, table_meta.index, doc_id, namespace_id, &update_columns, guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = try drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, &typeMarker(.write_error)) != null);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "PERMISSION_DENIED") != null);

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    const val = record.?.values[val_field_idx];
    try testing.expectEqualStrings("original", val.scalar.text);
}

test "StorageEngine: write-through cache populates cache post-commit and handles guard rejection without invalidation" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("val", .text),
        schema_helpers.makeField("author_id", .doc_id),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "write-through-cache-test", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const namespace_id: i64 = 100;
    const doc_id: typed_doc_id.DocId = 1;

    const val_field_idx = table_meta.fieldIndex("val").?;
    const author_field_idx = table_meta.fieldIndex("author_id").?;

    const author_a: typed_doc_id.DocId = 50;
    const author_b: typed_doc_id.DocId = 51;

    const cache_key = cache_mod.getCacheKey(table_meta, namespace_id, doc_id);

    // 1. Initial upsert: Should write-through to document_cache
    const columns = [_]sth.ColumnValue{
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "initial_val" } } },
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    // Verify cache hit immediately after write without reading DB
    switch (cache_mod.getCachedRecord(&ctx.engine.document_cache, cache_key)) {
        .miss => return error.TestUnexpectedResult,
        .hit => |hit| {
            defer hit.handle.release();
            try testing.expectEqualStrings("initial_val", hit.record.values[val_field_idx].scalar.text);
        },
    }

    // 2. Rejecting guard: Cache should RETAIN existing entry (no eviction)
    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "rejected_val" } } }};
    const conn_id: u64 = 555;
    const write_id: [16]u8 = .{7} ** 16;
    try sth.enqueueUpdate(&ctx.engine, table_meta.index, doc_id, namespace_id, &update_columns, guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    // Verify cache still holds "initial_val" and was NOT evicted
    switch (cache_mod.getCachedRecord(&ctx.engine.document_cache, cache_key)) {
        .miss => return error.TestUnexpectedResult,
        .hit => |hit| {
            defer hit.handle.release();
            try testing.expectEqualStrings("initial_val", hit.record.values[val_field_idx].scalar.text);
        },
    }

    // 3. Delete: Should evict entry post-commit
    try sth.enqueueDelete(&ctx.engine, table_meta.index, doc_id, namespace_id, null, null, null);
    try ctx.engine.flushPendingWrites();

    // Verify cache is now a miss
    switch (cache_mod.getCachedRecord(&ctx.engine.document_cache, cache_key)) {
        .miss => {},
        .hit => |hit| {
            defer hit.handle.release();
            return error.TestUnexpectedResult;
        },
    }
}

test "StorageEngine: failed document cache update evicts stale entry post-commit" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "cache-update-failure-test", table);
    defer ctx.deinit();

    const table_meta = try ctx.tableMetadata("items");
    const namespace_id: i64 = 100;
    const doc_id: typed_doc_id.DocId = 1;

    const val_field_idx = table_meta.fieldIndex("val").?;
    const cache_key = cache_mod.getCacheKey(table_meta, namespace_id, doc_id);

    // Re-point the engine's document cache at an allocator that fails exactly
    // `remaining` allocations (unlike std.testing.FailingAllocator, which
    // fails permanently). The write worker holds a pointer to
    // &engine.document_cache, which is unchanged by deinit+reinit in place.
    var failing = fail_alloc.FailNextAllocator{ .backing = allocator, .remaining = 0 };
    ctx.engine.document_cache.deinit();
    try ctx.engine.document_cache.init(testing.io, failing.allocator(), .{});

    // 1. Initial upsert: Should write-through to document_cache
    const columns = [_]sth.ColumnValue{
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "initial_val" } } },
    };
    try sth.enqueueUpsert(&ctx.engine, table_meta.index, doc_id, namespace_id, 1, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    switch (cache_mod.getCachedRecord(&ctx.engine.document_cache, cache_key)) {
        .miss => return error.TestUnexpectedResult,
        .hit => |hit| {
            defer hit.handle.release();
            try testing.expectEqualStrings("initial_val", hit.record.values[val_field_idx].scalar.text);
        },
    }

    // 2. Fail the next cache allocation: the post-commit cache write for the
    //    update below will fail, and the stale "initial_val" entry must be
    //    evicted so subsequent reads produce a miss instead of stale data.
    failing.remaining = 1;

    const update_columns = [_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "new_val" } } }};
    try sth.enqueueUpdate(&ctx.engine, table_meta.index, doc_id, namespace_id, &update_columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    // 3. Cache entry must be gone; the DB holds the committed value
    switch (cache_mod.getCachedRecord(&ctx.engine.document_cache, cache_key)) {
        .miss => {},
        .hit => |hit| {
            defer hit.handle.release();
            return error.TestUnexpectedResult;
        },
    }

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    try testing.expectEqualStrings("new_val", record.?.values[val_field_idx].scalar.text);
}

test "storage: engine init rejects empty data dir" {
    const allocator = std.heap.smp_allocator;
    var ms: sth.MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    const invalid_dir = "";
    var sm = try sth.createDummySchema(allocator);
    defer sm.deinit();
    var engine: StorageEngine = undefined;
    const result = engine.init(std.testing.io, allocator, &ms, invalid_dir, &sm, .{}, .{ .in_memory = false }, null, null);
    try testing.expectError(error.InvalidDataDir, result);
}

test "storage: engine init rejects file path as data dir" {
    const allocator = std.heap.smp_allocator;
    var ms: sth.MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var context = try sth.TestContext.init(allocator, "storage-not-dir");
    defer context.deinit();
    const test_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test_file_not_dir.txt" });
    defer allocator.free(test_file);

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, test_file, .{});
    file.close(std.testing.io);

    var sm = try sth.createDummySchema(allocator);
    defer sm.deinit();
    var engine: StorageEngine = undefined;
    const result = engine.init(std.testing.io, allocator, &ms, test_file, &sm, .{}, .{ .in_memory = false }, null, null);
    try testing.expectError(error.NotDir, result);
}

// Storage engine thread safety properties
test "storage: thread-safe engine access" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-thread-safe", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Concurrent writes and reads
    const num_threads = 10;
    const ops_per_thread = 50;
    const ThreadContext = struct {
        ctx: *sth.EngineTestContext,
        result: *?anyerror,
    };
    const WriteThread = struct {
        fn run(t_ctx: ThreadContext, thread_id: usize) void {
            runErr(t_ctx, thread_id) catch |err| {
                t_ctx.result.* = err;
            };
        }
        fn runErr(t_ctx: ThreadContext, thread_id: usize) !void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const key: u128 = thread_id * 1_000 + i + 1;
                const value = try std.fmt.allocPrint(
                    std.heap.smp_allocator,
                    "{{\"thread\":{d},\"op\":{d}}}",
                    .{ thread_id, i },
                );
                defer std.heap.smp_allocator.free(value);
                try t_ctx.ctx.insertField("test", key, 1, "val", tth.valText(value));
            }
        }
    };
    const ReadThread = struct {
        fn run(eng: *StorageEngine, table_index: usize, thread_id: usize, result: *?anyerror) void {
            runErr(eng, table_index, thread_id) catch |err| {
                result.* = err;
            };
        }
        fn runErr(eng: *StorageEngine, table_index: usize, thread_id: usize) !void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const key: u128 = (thread_id % (num_threads / 2)) * 1_000 + i + 1;
                const record = try sth.readDoc(std.heap.smp_allocator, eng, table_index, key, 1);
                defer if (record) |r| r.deinit(std.heap.smp_allocator);
            }
        }
    };

    var write_results = [_]?anyerror{null} ** (num_threads / 2);
    var read_results = [_]?anyerror{null} ** (num_threads / 2);

    // Spawn write threads
    var write_threads: [num_threads / 2]std.Thread = undefined;
    var write_spawned: usize = 0;
    errdefer for (write_threads[0..write_spawned]) |thread| thread.join();
    for (&write_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, WriteThread.run, .{ ThreadContext{ .ctx = &ctx, .result = &write_results[i] }, i });
        write_spawned += 1;
    }
    // Spawn read threads
    var read_threads: [num_threads / 2]std.Thread = undefined;
    const test_table = try ctx.table("test");
    var read_spawned: usize = 0;
    errdefer for (read_threads[0..read_spawned]) |thread| thread.join();
    for (&read_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, ReadThread.run, .{ engine, test_table.metadata.index, i, &read_results[i] });
        read_spawned += 1;
    }
    // Wait for all threads
    for (write_threads) |thread| {
        thread.join();
    }
    for (read_threads) |thread| {
        thread.join();
    }
    // All workers must have completed without error
    for (write_results) |r| try testing.expect(r == null);
    for (read_results) |r| try testing.expect(r == null);
    // Flush writes and verify data
    try engine.flushPendingWrites();
    // Verify some data was written
    const record = try test_table.readDoc(allocator, 1, 1);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    _ = try sth.expectFieldString(record.?, test_table.metadata, "val", "{\"thread\":0,\"op\":0}");
}

test "storage: connection pool reuse and release" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-conn-pool", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Set some initial data
    {
        try ctx.insertText("test", 1, 1, "val", "test1");
        try ctx.insertText("test", 2, 1, "val", "test2");
    }
    try engine.flushPendingWrites();
    // Perform many read operations to ensure connections are being reused
    // If connections weren't released, we'd run out of connections
    const num_operations = 1000;
    var i: usize = 0;
    const test_table = try ctx.table("test");
    while (i < num_operations) : (i += 1) {
        const key: u128 = if (i % 2 == 0) 1 else 2;
        const record = try test_table.readDoc(allocator, key, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
    // If we got here, connections were properly released and reused
}

test "storage: persistence round-trip (various types)" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-persistence", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Test various data types and values
    const test_cases = [_]struct {
        namespace_id: i64,
        id: u128,
        value: []const u8,
    }{
        .{ .namespace_id = 1, .id = 1, .value = "{\"data\":\"simple\"}" },
        .{ .namespace_id = 1, .id = 2, .value = "{\"user\":{\"name\":\"Alice\",\"age\":30}}" },
        .{ .namespace_id = 2, .id = 3, .value = "[1,2,3,4,5]" },
        .{ .namespace_id = 2, .id = 4, .value = "{}" },
        .{ .namespace_id = 3, .id = 5, .value = "{\"text\":\"Hello 世界 🌍\"}" },
        .{ .namespace_id = 3, .id = 6, .value = "{\"chars\":\"\\\"\\n\\t\\r\"}" },
    };
    // Insert all test cases
    for (test_cases) |tc| {
        try ctx.insertText("test", tc.id, tc.namespace_id, "val", tc.value);
    }
    // Flush writes
    try engine.flushPendingWrites();
    const test_table = try ctx.table("test");
    // Retrieve and verify all test cases
    for (test_cases) |tc| {
        const record = try test_table.readDoc(allocator, tc.id, tc.namespace_id);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
        _ = try sth.expectFieldString(record.?, test_table.metadata, "val", tc.value);
    }
}

test "storage: insert/delete inverse consistency" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-inverse", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    const test_cases = [_]struct {
        namespace_id: i64,
        id: u128,
        value: []const u8,
    }{
        .{ .namespace_id = 1, .id = 1, .value = "{\"data\":\"value1\"}" },
        .{ .namespace_id = 1, .id = 2, .value = "{\"data\":\"value2\"}" },
        .{ .namespace_id = 2, .id = 3, .value = "{\"data\":\"value3\"}" },
    };
    const test_table = try ctx.table("test");
    for (test_cases) |tc| {
        // Insert
        try ctx.insertText("test", tc.id, tc.namespace_id, "val", tc.value);
        try engine.flushPendingWrites();
        // Verify it exists
        const record1 = try test_table.readDoc(allocator, tc.id, tc.namespace_id);
        defer if (record1) |r| r.deinit(allocator);
        try testing.expect(record1 != null);

        // Delete
        try engine.enqueueWriteOp(.{ .delete = .{ .table_index = test_table.metadata.index, .id = tc.id, .namespace_id = tc.namespace_id } });
        try engine.flushPendingWrites();
        // Verify it's gone
        const record2 = try test_table.readDoc(allocator, tc.id, tc.namespace_id);
        defer if (record2) |r| r.deinit(allocator);
        try testing.expect(record2 == null);
    }
}

test "storage: batched writes commit consistently" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-txn-isolation", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // The write thread uses transactions internally to ensure atomicity
    // Set up initial state
    {
        try ctx.insertText("test", 1, 1, "val", "initial1");
        try ctx.insertText("test", 2, 1, "val", "initial2");
    }
    try engine.flushPendingWrites();
    const test_table = try ctx.table("test");
    // Verify initial state
    const record1 = try test_table.readDoc(allocator, 1, 1);
    defer if (record1) |r| r.deinit(allocator);
    try testing.expect(record1 != null);
    const record2 = try test_table.readDoc(allocator, 2, 1);
    defer if (record2) |r| r.deinit(allocator);
    try testing.expect(record2 != null);
    // Queue multiple operations that should execute atomically in a batch
    {
        try ctx.insertText("test", 1, 1, "val", "updated1");
        try ctx.insertText("test", 2, 1, "val", "updated2");
        try ctx.insertText("test", 3, 1, "val", "new3");
    }
    // Flush to ensure operations are processed
    try engine.flushPendingWrites();

    const record_up1 = try test_table.readDoc(allocator, 1, 1);
    defer if (record_up1) |r| r.deinit(allocator);

    const record_up2 = try test_table.readDoc(allocator, 2, 1);
    defer if (record_up2) |r| r.deinit(allocator);

    const record_n3 = try test_table.readDoc(allocator, 3, 1);
    defer if (record_n3) |r| r.deinit(allocator);

    try testing.expect(record_up1 != null);
    try testing.expect(record_up2 != null);
    try testing.expect(record_n3 != null);
    _ = try sth.expectFieldString(record_up1.?, test_table.metadata, "val", "updated1");
    _ = try sth.expectFieldString(record_up2.?, test_table.metadata, "val", "updated2");
    _ = try sth.expectFieldString(record_n3.?, test_table.metadata, "val", "new3");
}

test "storage: multi-batch writes all persist" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-concurrent-batches", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Property: Multiple batches can be queued and will be processed sequentially and atomically
    const num_batches = 5;
    const ops_per_batch = 20;
    var j: usize = 0;
    while (j < num_batches) : (j += 1) {
        var i: usize = 0;
        while (i < ops_per_batch) : (i += 1) {
            const key: u128 = j * 100 + i + 1;
            const value = try std.fmt.allocPrint(allocator, "{{\"batch\":{d},\"op\":{d}}}", .{ j, i });
            defer allocator.free(value);
            try ctx.insertText("test", key, 1, "val", value);
        }
    }
    // Flush and verify all operations succeeded atomically
    try engine.flushPendingWrites();
    const test_table = try ctx.table("test");
    var total_found: usize = 0;
    var k: usize = 0;
    while (k < num_batches) : (k += 1) {
        var i: usize = 0;
        while (i < ops_per_batch) : (i += 1) {
            const key: u128 = k * 100 + i + 1;
            const record = try test_table.readDoc(allocator, key, 1);
            defer if (record) |r| r.deinit(allocator);
            if (record != null) total_found += 1;
        }
    }
    try testing.expectEqual(@as(usize, num_batches * ops_per_batch), total_found);
}

// Property: Database remains consistent after repeated flush operations
test "storage: repeated flush consistency" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-repeated-flush", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try ctx.insertText("test", i + 1, 1, "val", "value");
        if (i % 5 == 0) {
            try engine.flushPendingWrites();
        }
    }
    try engine.flushPendingWrites();
    const test_table = try ctx.table("test");
    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    const qres = try test_table.queryDocs(allocator, 1, &filter);
    defer qres.deinit(allocator);
    try testing.expectEqual(@as(usize, 50), qres.records.len);
}

// Additional property: Data integrity across engine restarts
test "storage: data persistence across restarts" {
    const allocator = std.heap.smp_allocator;
    var context = try sth.TestContext.init(allocator, "storage-restart-persistence");
    defer context.deinit();
    const test_dir = context.test_dir;

    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);

    // Initial run: Insert data
    {
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngineWithDir(&ctx, allocator, test_dir, table, .{ .in_memory = false });
        // Use deinitNoCleanup to preserve the test directory for the second run
        defer ctx.deinitNoCleanup();

        try ctx.insertText("test", 1, 1, "val", "persistent-value");
        try ctx.engine.flushPendingWrites();
    }

    // Second run: Verify data is still there
    {
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngineWithDir(&ctx, allocator, test_dir, table, .{ .in_memory = false });
        defer ctx.deinitNoCleanup();

        const test_table = try ctx.table("test");
        const record = try test_table.readDoc(allocator, 1, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
}

// Property: Schema updates are reflected in persistence logic
test "storage: schema update integrity" {
    const allocator = std.heap.smp_allocator;
    var context = try sth.TestContext.init(allocator, "storage-schema-update");
    defer context.deinit();
    const test_dir = context.test_dir;

    var fields_v1 = [_]sth.Field{schema_helpers.makeField("val1", .text)};
    const table_v1 = schema_helpers.makeTable("test", &fields_v1);

    // Run 1: Version 1 schema - insert data
    {
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngineWithDir(&ctx, allocator, test_dir, table_v1, .{ .in_memory = false });
        defer ctx.deinitNoCleanup();

        try ctx.insertText("test", 1, 1, "val1", "value1");
        try ctx.engine.flushPendingWrites();
    }

    // Run 2: Version 2 schema (added field) - verify existing data is still readable
    {
        var fields_v2 = [_]sth.Field{
            schema_helpers.makeField("val1", .text),
            schema_helpers.makeField("val2", .integer),
        };
        const table_v2 = schema_helpers.makeTable("test", &fields_v2);

        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngineWithDir(&ctx, allocator, test_dir, table_v2, .{ .in_memory = false });
        defer ctx.deinitNoCleanup();

        const test_table = try ctx.table("test");

        // Existing data should be accessible
        const record1 = try test_table.readDoc(allocator, 1, 1);
        defer if (record1) |r| r.deinit(allocator);
        try testing.expect(record1 != null);
        _ = try sth.expectFieldString(record1.?, test_table.metadata, "val1", "value1");

        // New data with new field
        try ctx.insertInt("test", 2, 1, "val2", 42);
        try ctx.engine.flushPendingWrites();

        const record2 = try test_table.readDoc(allocator, 2, 1);
        defer if (record2) |r| r.deinit(allocator);
        try testing.expect(record2 != null);
        _ = try sth.expectFieldInt(record2.?, test_table.metadata, "val2", 42);
    }
}

// Fuzzy testing of random operations to ensure no crashes
test "storage: random operations fuzzing" {
    const allocator = std.heap.smp_allocator;
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("title", .text),
        schema_helpers.makeField("score", .integer),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-fuzz", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    const items_index = ctx.tableIndex("items");
    const test_table = try ctx.table("items");
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const op = rand.intRangeAtMost(u8, 0, 3);
        const id: u128 = rand.intRangeAtMost(u128, 1, 50);
        const ns: i64 = @intCast(rand.intRangeAtMost(i32, 1, 5));

        switch (op) {
            0 => {
                // Insert/Update
                try ctx.insertText("items", id, ns, "title", "fuzzy");
                try ctx.insertInt("items", id, ns, "score", @intCast(i));
            },
            1 => {
                // Delete
                try engine.enqueueWriteOp(.{ .delete = .{ .table_index = items_index, .id = id, .namespace_id = ns } });
            },
            2 => {
                // Query
                const record = try test_table.readDoc(allocator, id, ns);
                if (record) |r| r.deinit(allocator);
            },
            3 => {
                // Flush
                try engine.flushPendingWrites();
            },
            else => unreachable,
        }
    }
    try engine.flushPendingWrites();
}

fn fkDocId(id: u128) typed.Value {
    return .{ .scalar = .{ .doc_id = id } };
}

fn drainForeignKeyChanges(app: *app_test_helpers.AppTestContext) void {
    const queue = &app.test_context.change_queue.?;
    while (queue.shards[0].popTimed(0)) |job| {
        var owned = job;
        owned.deinit(app.storage_engine.allocator);
    }
}

fn expectForeignKeyCacheMiss(app: *app_test_helpers.AppTestContext, table_name: []const u8, namespace_id: i64, id: u128) !void {
    const table = try app.tableMetadata(table_name);
    const key = cache_mod.getCacheKey(table, namespace_id, id);
    switch (cache_mod.getCachedRecord(&app.storage_engine.document_cache, key)) {
        .miss => {},
        .hit => |hit| {
            defer hit.handle.release();
            return error.TestUnexpectedResult;
        },
    }
}

fn expectForeignKeyCacheNull(app: *app_test_helpers.AppTestContext, table_name: []const u8, field_name: []const u8, namespace_id: i64, id: u128) !void {
    const table = try app.tableMetadata(table_name);
    const field_index = table.fieldIndex(field_name) orelse return error.TestExpectedValue;
    const key = cache_mod.getCacheKey(table, namespace_id, id);
    switch (cache_mod.getCachedRecord(&app.storage_engine.document_cache, key)) {
        .miss => return error.TestUnexpectedResult,
        .hit => |hit| {
            defer hit.handle.release();
            try testing.expect(hit.record.values[field_index] == .nil);
        },
    }
}

test "foreign key writes enforce restrict cascade set null and reconcile runtime state" {
    const allocator = testing.allocator;
    const schema_json =
        \\{"version":"1.0.0","store":{
        \\  "parents":{"fields":{}},
        \\  "restrict_children":{"fields":{"parent_id":{"type":"string","references":"parents"}}},
        \\  "cascade_children":{"fields":{"parent_id":{"type":"string","references":"parents","onDelete":"cascade"}}},
        \\  "grandchildren":{"fields":{"child_id":{"type":"string","references":"cascade_children","onDelete":"cascade"}}},
        \\  "nullable_children":{"fields":{"parent_id":{"type":"string","references":"parents","onDelete":"set_null"}}}
        \\}}
    ;

    var app: app_test_helpers.AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "foreign-key-actions", schema_json);
    defer app.deinit();

    const parents = try app.table("parents");
    const restricted = try app.table("restrict_children");
    const cascaded = try app.table("cascade_children");
    const grandchildren = try app.table("grandchildren");
    const nullable = try app.table("nullable_children");

    try restricted.insertNamed(99, 1, .{sth.named("parent_id", fkDocId(999))});
    try restricted.flush();
    try testing.expect((try restricted.readDoc(allocator, 99, 1)) == null);
    try testing.expect(app.storage_engine.isHealthy());

    try parents.insertNamed(1, 1, .{});
    try restricted.insertNamed(11, 1, .{sth.named("parent_id", fkDocId(1))});
    try restricted.flush();
    drainForeignKeyChanges(&app);
    try parents.deleteDocument(1, 1);
    try parents.flush();
    var retained_parent = try parents.getOne(allocator, 1, 1);
    retained_parent.deinit();
    var retained_child = try restricted.getOne(allocator, 11, 1);
    retained_child.deinit();
    drainForeignKeyChanges(&app);

    try parents.insertNamed(2, 1, .{});
    try cascaded.insertNamed(22, 2, .{sth.named("parent_id", fkDocId(2))});
    try grandchildren.insertNamed(33, 3, .{sth.named("child_id", fkDocId(22))});
    try nullable.insertNamed(44, 4, .{sth.named("parent_id", fkDocId(2))});
    try nullable.flush();
    drainForeignKeyChanges(&app);

    var nullable_before = try nullable.getOne(allocator, 44, 4);
    const updated_at_before = try nullable_before.getFieldInt("updated_at");
    nullable_before.deinit();

    try parents.deleteDocument(2, 1);
    try parents.flush();

    try testing.expect((try parents.readDoc(allocator, 2, 1)) == null);
    try testing.expect((try cascaded.readDoc(allocator, 22, 2)) == null);
    try testing.expect((try grandchildren.readDoc(allocator, 33, 3)) == null);
    var nullable_after = try nullable.getOne(allocator, 44, 4);
    defer nullable_after.deinit();
    try testing.expect(nullable_after.getFieldDocIdOrNull("parent_id") == null);
    try testing.expectEqual(updated_at_before, try nullable_after.getFieldInt("updated_at"));

    try testing.expect(!app.storage_engine.documentExists(cascaded.metadata.index, 22));
    try testing.expect(!app.storage_engine.documentExists(grandchildren.metadata.index, 33));
    try testing.expect(app.storage_engine.documentExists(nullable.metadata.index, 44));
    try expectForeignKeyCacheMiss(&app, "cascade_children", 2, 22);
    try expectForeignKeyCacheMiss(&app, "grandchildren", 3, 33);
    try expectForeignKeyCacheNull(&app, "nullable_children", "parent_id", 4, 44);

    var delete_count: usize = 0;
    var update_count: usize = 0;
    const queue = &app.test_context.change_queue.?;
    while (queue.shards[0].popTimed(0)) |job| {
        var owned = job;
        defer owned.deinit(app.storage_engine.allocator);
        switch (owned.change.operation) {
            .delete => delete_count += 1,
            .update => {
                update_count += 1;
                try testing.expectEqual(nullable.metadata.index, owned.change.table_index);
                const parent_field_index = nullable.metadata.fieldIndex("parent_id") orelse return error.TestExpectedValue;
                try testing.expectEqual(@as(u128, 2), owned.change.old_record.?.values[parent_field_index].scalar.doc_id);
                try testing.expect(owned.change.new_record.?.values[parent_field_index] == .nil);
            },
            .insert => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(usize, 3), delete_count);
    try testing.expectEqual(@as(usize, 1), update_count);

    try parents.insertNamed(3, 1, .{});
    try cascaded.insertNamed(55, 2, .{sth.named("parent_id", fkDocId(3))});
    try nullable.insertNamed(66, 4, .{sth.named("parent_id", fkDocId(3))});
    try parents.deleteDocument(3, 1);
    try parents.flush();

    try testing.expect((try cascaded.readDoc(allocator, 55, 2)) == null);
    var batch_nullable = try nullable.getOne(allocator, 66, 4);
    defer batch_nullable.deinit();
    try testing.expect(batch_nullable.getFieldDocIdOrNull("parent_id") == null);

    var cascade_delete_published = false;
    var set_null_update_published = false;
    while (queue.shards[0].popTimed(0)) |job| {
        var owned = job;
        defer owned.deinit(app.storage_engine.allocator);
        switch (owned.change.operation) {
            .delete => {
                if (owned.change.table_index == cascaded.metadata.index and owned.change.doc_id == 55) {
                    cascade_delete_published = true;
                }
            },
            .update => {
                if (owned.change.table_index == nullable.metadata.index and owned.change.doc_id == 66) {
                    const parent_field_index = nullable.metadata.fieldIndex("parent_id") orelse return error.TestExpectedValue;
                    try testing.expectEqual(@as(u128, 3), owned.change.old_record.?.values[parent_field_index].scalar.doc_id);
                    try testing.expect(owned.change.new_record.?.values[parent_field_index] == .nil);
                    set_null_update_published = true;
                }
            },
            .insert => {},
        }
    }
    try testing.expect(cascade_delete_published);
    try testing.expect(set_null_update_published);
}

test "foreign key startup rejects legacy orphaned rows" {
    const allocator = testing.allocator;
    var test_context = try sth.TestContext.initInMemory(allocator);
    defer test_context.deinit();
    var memory_strategy: sth.MemoryStrategy = undefined;
    try memory_strategy.init();
    defer memory_strategy.deinit();
    var schema = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"parents":{"fields":{}},"children":{"fields":{"parent_id":{"type":"string","references":"parents"}}}}}
    );
    defer schema.deinit();

    var engine: storage_mod.StorageEngine = undefined;
    try engine.init(
        testing.io,
        allocator,
        &memory_strategy,
        test_context.test_dir,
        &schema,
        .{},
        .{ .in_memory = true, .reader_pool_size = 1 },
        null,
        null,
    );
    defer engine.deinit();

    var gen = DDLGenerator.init(allocator);
    for (schema.tables) |table| {
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try engine.execSetupSQL(ddl_z);
    }

    const setup_conn = try engine.getSetupConn();
    _ = try setup_conn.pragma(void, .{}, "foreign_keys", "off");
    try setup_conn.exec(
        "INSERT INTO children (id, namespace_id, owner_id, parent_id, created_at, updated_at) VALUES (randomblob(16), 1, zeroblob(16), zeroblob(16), 0, 0)",
        .{},
        .{},
    );
    _ = try setup_conn.pragma(void, .{}, "foreign_keys", "on");

    var send_node_pool: sth.MemoryStrategy.IndexPool(send_queue_mod.send_queue.Node) = undefined;
    try send_node_pool.init(allocator, 1, null, null);
    test_context.send_node_pool = send_node_pool;
    test_context.send_queue = try send_queue_mod.send_queue.init(&test_context.send_node_pool.?);
    try testing.expectError(error.ForeignKeyViolation, engine.start(&test_context.send_queue.?, null, null));
}
