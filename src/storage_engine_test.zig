const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const storage_mod = @import("storage_engine.zig");
const DDLGenerator = @import("ddl_generator.zig").DDLGenerator;
const SessionResolutionResult = @import("session_resolution.zig").SessionResolutionResult;

const BatchOpForTest = struct {
    entries: []storage_mod.BatchEntry,
    completion_signal: ?*storage_mod.WriteOp.CompletionSignal,
};

const DirectWriterContext = struct {
    allocator: std.mem.Allocator,
    engine: storage_mod.StorageEngine,
    sm: sth.Schema,
    memory_strategy: sth.MemoryStrategy,
    test_context: sth.TestContext,

    fn init(self: *DirectWriterContext, allocator: std.mem.Allocator, table: sth.Table) !void {
        self.allocator = allocator;
        self.test_context = try sth.TestContext.initInMemory(allocator);
        errdefer self.test_context.deinit();

        try self.memory_strategy.init(allocator);
        errdefer self.memory_strategy.deinit();

        const users_fields = [_]sth.Field{};
        const users_table = sth.makeTable("users", &users_fields);
        self.sm = try sth.createSchema(allocator, &[_]sth.Table{ users_table, table });
        errdefer self.sm.deinit();

        try self.engine.init(
            allocator,
            &self.memory_strategy,
            self.test_context.test_dir,
            &self.sm,
            .{},
            .{ .in_memory = true, .reader_pool_size = 1 },
            null,
            null,
        );
        errdefer self.engine.deinit();

        var gen = DDLGenerator.init(allocator);
        for (self.sm.tables) |schema_table| {
            const ddl = try gen.generateDDL(schema_table);
            defer allocator.free(ddl);
            const ddl_z = try allocator.dupeZ(u8, ddl);
            defer allocator.free(ddl_z);
            try self.engine.execSetupSQL(ddl_z);
        }
    }

    fn deinit(self: *DirectWriterContext) void {
        self.engine.deinit();
        self.sm.deinit();
        self.memory_strategy.deinit();
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

fn executeBatchForTest(ctx: *DirectWriterContext, entries: []storage_mod.BatchEntry, signal: *storage_mod.WriteOp.CompletionSignal) void {
    var last_batch_time: i64 = 0;
    const op = BatchOpForTest{
        .entries = entries,
        .completion_signal = signal,
    };
    ctx.engine.writer.executeBatchOp(op, &last_batch_time);
}

test "StorageEngine: shutdown drain completes immediate writer ops" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
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
            .result_buffer = ctx.engine.sessionResolutionBuffer(),
        },
    };
    errdefer if (!session_queued) session_op.deinit(allocator);

    var checkpoint_signal = storage_mod.WriteOp.CompletionSignal{};
    const checkpoint_op = storage_mod.WriteOp{
        .checkpoint = .{
            .mode = storage_mod.CheckpointMode.passive,
            .completion_signal = &checkpoint_signal,
        },
    };

    try ctx.engine.writer.enqueueOp(session_op);
    session_queued = true;
    try ctx.engine.writer.enqueueOp(checkpoint_op);

    ctx.engine.writer.shutdown_requested.store(true, .release);
    try ctx.engine.writer.spawnThread();
    ctx.engine.writer.waitUntilReady();
    ctx.engine.writer.stopThread();

    try checkpoint_signal.wait();
    const checkpoint_stats = checkpoint_signal.result orelse return error.TestExpectedValue;

    var results = std.ArrayListUnmanaged(SessionResolutionResult).empty;
    defer results.deinit(allocator);
    try ctx.engine.sessionResolutionBuffer().drainInto(&results, allocator);

    try testing.expectEqual(@as(usize, 1), results.items.len);
    if (results.items[0].err) |err| return err;
    try testing.expect(results.items[0].namespace_id > 0);
    try testing.expect(results.items[0].user_doc_id != 0);
    try testing.expectEqual(storage_mod.CheckpointMode.passive, checkpoint_stats.mode);
    try testing.expectEqual(@as(usize, 0), ctx.engine.writer.pendingOpCount());
}

test "StorageEngine: init and deinit" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("_dummy", &fields_arr);
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
        sth.makeField("name", .text, false),
        sth.makeField("age", .integer, false),
    };
    const table = sth.makeTable("people", &fields_arr);

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
        sth.makeField("val", .text, false),
    };
    const table = sth.makeTable("test", &fields_arr);

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
        sth.makeField("val", .text, false),
    };
    const table = sth.makeTable("test", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "crud-delete", table);
    defer ctx.deinit();
    const docs = try ctx.table("test");

    try docs.insertText(1, 1, "val", "foo");
    try docs.flush();

    try docs.deleteDocument(1, 1);
    try docs.flush();

    var managed = try docs.selectDocument(allocator, 1, 1);
    defer managed.deinit();
    try testing.expect(managed.rows.len == 0);
}
test "StorageEngine: insertOrReplace and selectDocument" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
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
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-nonexistent", table);
    defer ctx.deinit();
    const items = try ctx.table("items");

    var managed = try items.selectDocument(allocator, 999, 2);
    defer managed.deinit();
    try testing.expect(managed.rows.len == 0);
}
test "StorageEngine: update existing document" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
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
    var fields_arr = [_]sth.Field{sth.makeField("name", .text, false)};
    const table = sth.makeTable("people", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-query", table);
    defer ctx.deinit();
    const people = try ctx.table("people");

    // Set multiple documents
    try people.insertText(1, 2, "name", "Alice");
    try people.insertText(2, 2, "name", "Bob");
    try people.flush();
    // Query for collection using empty filter
    const filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    var managed = try people.selectQuery(allocator, 2, filter);
    defer managed.deinit();
    try testing.expectEqual(@as(usize, 2), managed.rows.len);
}
test "StorageEngine: duplicate ids across namespaces are rejected" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
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

    var managed = try items.selectDocument(allocator, 1, 4);
    defer managed.deinit();
    try testing.expectEqual(@as(usize, 0), managed.rows.len);
}

test "StorageEngine: batchWrites false flushes single write without timeout delay" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithPerformance(
        &ctx,
        allocator,
        "engine-batch-writes-disabled",
        table,
        .{ .batch_writes = false, .batch_timeout = 5_000 },
        .{ .in_memory = true },
    );
    defer ctx.deinit();

    const start = std.time.nanoTimestamp();
    try ctx.insertText("items", 1, 5, "val", "value1");
    try ctx.engine.flushPendingWrites();
    const elapsed = std.time.nanoTimestamp() - start;
    try testing.expect(elapsed < std.time.ns_per_s);

    var managed = try (try ctx.table("items")).selectDocument(allocator, 1, 5);
    defer managed.deinit();
    try testing.expect(managed.rows.len > 0);
}

test "StorageEngine: low-level batch writer cleans up when begin fails" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchEntries(allocator, 999);
    var signal = storage_mod.WriteOp.CompletionSignal{};
    ctx.engine.writer.beginOp();
    try ctx.engine.writer.conn.exec("BEGIN TRANSACTION", .{}, .{});
    defer ctx.engine.writer.conn.exec("ROLLBACK", .{}, .{}) catch |err| {
        std.log.warn("failed to roll back test transaction: {}", .{err});
    };

    executeBatchForTest(&ctx, entries, &signal);

    try testing.expectError(storage_mod.StorageError.SQLiteError, signal.wait());
    try testing.expectEqual(@as(usize, 0), ctx.engine.writer.pendingOpCount());
}

test "StorageEngine: low-level batch writer rejects unknown tables and rolls back" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: DirectWriterContext = undefined;
    try ctx.init(allocator, table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchEntries(allocator, 999);
    var signal = storage_mod.WriteOp.CompletionSignal{};
    const version_before = ctx.engine.writer.snapshotVersion();
    ctx.engine.writer.beginOp();
    executeBatchForTest(&ctx, entries, &signal);

    try testing.expectError(storage_mod.StorageError.UnknownTable, signal.wait());
    try testing.expectEqual(@as(usize, 0), ctx.engine.writer.pendingOpCount());
    try testing.expectEqual(version_before, ctx.engine.writer.snapshotVersion());

    try ctx.engine.writer.conn.exec("BEGIN TRANSACTION", .{}, .{});
    try ctx.engine.writer.conn.exec("ROLLBACK", .{}, .{});
}

test "StorageEngine: batchWrite rejects unknown tables before enqueue" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-batch-validate-table", table);
    defer ctx.deinit();

    const entries = try makeDeleteBatchEntries(allocator, 999);

    ctx.engine.batchWrite(entries) catch |err| {
        try testing.expectEqual(storage_mod.StorageError.UnknownTable, err);
        try testing.expectEqual(@as(usize, 0), ctx.engine.writer.pendingOpCount());
        return;
    };

    return error.TestUnexpectedResult;
}

test "StorageEngine: concurrent reads" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.makeTable("items", &fields_arr);
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
            var managed = try eng.selectDocument(alloc, table_index, id, 2);
            defer managed.deinit();
            try testing.expect(managed.rows.len > 0);
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

    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.makeTable("items", &fields_arr);
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
        var managed = try (try verify_ctx.table("items")).selectDocument(allocator, id, 1);
        defer managed.deinit();
        try testing.expect(managed.rows.len > 0);
    }
}
test "StorageEngine: client writes blocked during migration" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-migration-block", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Simulate migration in progress
    engine.migration_active.store(true, .release);
    defer engine.migration_active.store(false, .release);
    // insertOrReplace should be blocked
    const err1 = ctx.insertField("items", 1, 1, "val", tth.valInt(1));
    try testing.expectError(sth.StorageError.MigrationInProgress, err1);
    // deleteDocument should be blocked
    const err3 = (try ctx.table("items")).deleteDocument(1, 1);
    try testing.expectError(sth.StorageError.MigrationInProgress, err3);
}
