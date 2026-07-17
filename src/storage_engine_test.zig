const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const schema_helpers = @import("schema/test_helpers.zig");
const qth = @import("query/test_helpers.zig");
const tth = @import("typed/test_helpers.zig");
const storage_mod = @import("storage_engine.zig");
const DDLGenerator = @import("sql/ddl.zig").DDLGenerator;
const query_ast = @import("query/ast.zig");
const typed = @import("typed/types.zig");
const typed_doc_id = @import("typed/doc_id.zig");
const send_queue_mod = @import("connection/send_queue.zig");
const SendQueueEntry = send_queue_mod.Entry;

const BatchOpForTest = struct {
    entries: []storage_mod.BatchEntry,
    latch: ?*storage_mod.AckLatch,
};

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

        try self.memory_strategy.init(allocator);
        errdefer _ = self.memory_strategy.deinit();

        const users_fields = [_]sth.Field{};
        const users_table = schema_helpers.makeTable("users", &users_fields);
        self.schema = try sth.createSchema(allocator, &[_]sth.Table{ users_table, table });
        errdefer self.schema.deinit();

        try self.engine.init(
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
        std.debug.assert(self.memory_strategy.deinit() == .ok);
        self.test_context.deinit();
    }
};

fn makeDeleteBatchEntries(allocator: std.mem.Allocator, table_index: usize) ![]storage_mod.BatchEntry {
    const entries = try allocator.alloc(storage_mod.BatchEntry, 1);
    errdefer allocator.free(entries);
    entries[0] = .{
        .kind = .delete,
        .table_index = table_index,
        .id = 1,
        .namespace_id = 1,
        .owner_doc_id = 0,
        .sql = try allocator.dupe(u8, "not used"),
        .values = null,
        .timestamp = 0,
    };
    return entries;
}

fn executeBatchForTest(ctx: *DirectWriterContext, entries: []storage_mod.BatchEntry, latch: *storage_mod.AckLatch) void {
    var last_batch_time: i64 = 0;
    const op = BatchOpForTest{
        .entries = entries,
        .latch = latch,
    };
    ctx.engine.write_worker.executeBatchOp(op, &last_batch_time);
}

test "StorageEngine: shutdown drain completes immediate writer ops" {
    const allocator = testing.allocator;
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

    var checkpoint_latch = storage_mod.CheckpointLatch{};
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
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("_dummy", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "engine-init", table, .{ .in_memory = false });
    defer ctx.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ ctx.test_context.test_dir, "zyncbase.db" });
    defer allocator.free(db_path);
    const file = try std.fs.cwd().openFile(db_path, .{});
    file.close();
}
test "StorageEngine: insert and select basic" {
    const allocator = testing.allocator;

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
    const allocator = testing.allocator;

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
    const allocator = testing.allocator;

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
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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

    var timer = std.time.Timer.start() catch unreachable;
    try ctx.insertText("items", 1, 5, "val", "value1");
    try ctx.engine.flushPendingWrites();
    const elapsed = timer.read();
    try testing.expect(elapsed < std.time.ns_per_s);

    const record = try (try ctx.table("items")).readDoc(allocator, 1, 5);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
}

test "StorageEngine: low-level batch writer cleans up when begin fails" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchEntries(allocator, 999);
    var latch = storage_mod.AckLatch{};
    ctx.engine.write_worker.beginOp();
    try ctx.engine.write_worker.conn.exec("BEGIN TRANSACTION", .{}, .{});
    defer ctx.engine.write_worker.conn.exec("ROLLBACK", .{}, .{}) catch |err| {
        std.log.warn("failed to roll back test transaction: {}", .{err});
    };

    executeBatchForTest(&ctx, entries, &latch);

    try testing.expectError(storage_mod.StorageError.SQLiteError, latch.wait());
    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
}

test "StorageEngine: low-level batch writer rejects unknown tables and rolls back" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchEntries(allocator, 999);
    var latch = storage_mod.AckLatch{};
    const version_before = ctx.engine.write_worker.version.load(.acquire);;
    ctx.engine.write_worker.beginOp();
    executeBatchForTest(&ctx, entries, &latch);

    try testing.expectError(storage_mod.StorageError.UnknownTable, latch.wait());
    try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
    try testing.expectEqual(version_before, ctx.engine.write_worker.version.load(.acquire););

    try ctx.engine.write_worker.conn.exec("BEGIN TRANSACTION", .{}, .{});
    try ctx.engine.write_worker.conn.exec("ROLLBACK", .{}, .{});
}

test "StorageEngine: batchWrite rejects unknown tables before enqueue" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-batch-validate-table", table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchEntries(allocator, 999);

    ctx.engine.batchWrite(entries, null, null) catch |err| {
        try testing.expectEqual(storage_mod.StorageError.UnknownTable, err);
        try testing.expectEqual(@as(usize, 0), ctx.engine.write_worker.pendingOpCount());
        return;
    };

    return error.TestUnexpectedResult;
}

test "StorageEngine: concurrent reads" {
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;

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
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

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
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .integer)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-migration-block", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Simulate migration in progress
    engine.migration_active.store(true, .release);
    defer engine.migration_active.store(false, .release);
    // upsertDocument should be blocked
    const err1 = ctx.insertField("items", 1, 1, "val", tth.valInt(1));
    try testing.expectError(sth.StorageError.MigrationInProgress, err1);
    // deleteDocument should be blocked
    const err3 = (try ctx.table("items")).deleteDocument(1, 1);
    try testing.expectError(sth.StorageError.MigrationInProgress, err3);
}
test "StorageEngine: engine healthy after start" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-healthy-start", table);
    defer ctx.deinit();

    try testing.expect(ctx.engine.isHealthy());
    try testing.expect(ctx.engine.write_worker.isHealthy());
}
test "StorageEngine: writes rejected when engine unhealthy" {
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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

fn drainOutcomes(sq: *send_queue_mod.send_queue) []SendQueueEntry {
    var entries = std.ArrayListUnmanaged(SendQueueEntry).empty;
    while (sq.pop()) |entry| {
        entries.append(std.testing.allocator, entry) catch break;
    }
    return entries.toOwnedSlice(std.testing.allocator) catch &[_]SendQueueEntry{};
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
    const allocator = testing.allocator;
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
    try ctx.engine.upsertDocument(table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = &[_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    const conn_id: u64 = 999;
    const write_id: [16]u8 = .{1} ** 16;
    try ctx.engine.upsertDocument(table_meta.index, doc_id, namespace_id, author_a, update_columns, &guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "WriteError") != null);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "PERMISSION_DENIED") != null);
}

test "StorageEngine: mixed flush batch commits passing op and rejects guarded op independently" {
    const allocator = testing.allocator;
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
    try ctx.engine.upsertDocument(table_meta.index, doc_ok, namespace_id, author_a, &seed_ok, null, null, null);
    const seed_reject = [_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "original" } } },
    };
    try ctx.engine.upsertDocument(table_meta.index, doc_reject, namespace_id, author_a, &seed_reject, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    // Enqueue two confirmed writes, then flush once so they share a batch:
    // op #1 has no guard (must commit), op #2 has a rejecting guard (must fail).
    const conn_ok: u64 = 1001;
    const write_ok: [16]u8 = .{1} ** 16;
    const ok_columns = &[_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    try ctx.engine.upsertDocument(table_meta.index, doc_ok, namespace_id, author_a, ok_columns, null, conn_ok, write_ok);

    const conn_reject: u64 = 1002;
    const write_reject: [16]u8 = .{2} ** 16;
    const reject_columns = &[_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    try ctx.engine.upsertDocument(table_meta.index, doc_reject, namespace_id, author_a, reject_columns, &guard, conn_reject, write_reject);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |e| {
        if (e.conn_id == conn_reject) {
            try testing.expect(std.mem.indexOf(u8, e.data, "WriteError") != null);
            try testing.expect(std.mem.indexOf(u8, e.data, "PERMISSION_DENIED") != null);
        } else {
            try testing.expectEqual(conn_ok, e.conn_id);
            try testing.expect(std.mem.indexOf(u8, e.data, "WriteError") == null);
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
    const allocator = testing.allocator;
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
    try ctx.engine.upsertDocument(table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = &[_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    try ctx.engine.upsertDocument(table_meta.index, doc_id, namespace_id, author_a, update_columns, &guard, null, null);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
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
    const allocator = testing.allocator;
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
    try ctx.engine.upsertDocument(table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const conn_id: u64 = 888;
    const write_id: [16]u8 = .{2} ** 16;
    try ctx.engine.deleteDocument(table_meta.index, doc_id, namespace_id, &guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "WriteError") != null);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "PERMISSION_DENIED") != null);

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
}

test "StorageEngine: confirmed delete of non-existent row succeeds" {
    const allocator = testing.allocator;
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
    try ctx.engine.deleteDocument(table_meta.index, doc_id, namespace_id, &guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "WriteCommitted") != null);
}

test "StorageEngine: confirmed update with guard on non-existent row succeeds" {
    const allocator = testing.allocator;
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

    const update_columns = &[_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    const conn_id: u64 = 555;
    const write_id: [16]u8 = .{4} ** 16;
    try ctx.engine.updateDocument(table_meta.index, doc_id, namespace_id, update_columns, &guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "WriteCommitted") != null);
}

test "StorageEngine: confirmed upsert with guard on non-existent row succeeds" {
    const allocator = testing.allocator;
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

    const columns = &[_]sth.ColumnValue{
        .{ .index = author_field_idx, .value = .{ .scalar = .{ .doc_id = author_a } } },
        .{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "new" } } },
    };
    const conn_id: u64 = 666;
    const write_id: [16]u8 = .{5} ** 16;
    try ctx.engine.upsertDocument(table_meta.index, doc_id, namespace_id, author_a, columns, &guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "WriteCommitted") != null);

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    const val = record.?.values[val_field_idx];
    try testing.expectEqualStrings("new", val.scalar.text);
}

test "StorageEngine: confirmed update with rejecting guard on existing row returns PermissionDenied" {
    const allocator = testing.allocator;
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
    try ctx.engine.upsertDocument(table_meta.index, doc_id, namespace_id, author_a, &columns, null, null, null);
    try ctx.engine.flushPendingWrites();

    var guard = try makeGuardPredicate(allocator, author_field_idx, .doc_id, .{ .scalar = .{ .doc_id = author_b } });
    defer guard.deinit(allocator);

    const update_columns = &[_]sth.ColumnValue{.{ .index = val_field_idx, .value = .{ .scalar = .{ .text = "updated" } } }};
    const conn_id: u64 = 444;
    const write_id: [16]u8 = .{6} ** 16;
    try ctx.engine.updateDocument(table_meta.index, doc_id, namespace_id, update_columns, &guard, conn_id, write_id);
    try ctx.engine.flushPendingWrites();

    const entries = drainOutcomes(&ctx.test_context.send_queue.?);
    defer {
        for (entries) |e| e.deinit();
        allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(conn_id, entries[0].conn_id);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "WriteError") != null);
    try testing.expect(std.mem.indexOf(u8, entries[0].data, "PERMISSION_DENIED") != null);

    const record = try sth.readDoc(allocator, &ctx.engine, table_meta.index, doc_id, namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    const val = record.?.values[val_field_idx];
    try testing.expectEqualStrings("original", val.scalar.text);
}
