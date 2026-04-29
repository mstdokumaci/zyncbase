const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

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
test "StorageEngine: transaction support" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("_dummy", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-tx", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Initially no transaction should be active
    try testing.expect(!engine.isTransactionActive());
    // Begin transaction
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());
    // Cannot begin another transaction while one is active
    try testing.expectError(error.TransactionAlreadyActive, engine.beginTransaction());
    // Commit transaction
    try engine.commitTransaction();
    try testing.expect(!engine.isTransactionActive());
    // Cannot commit when no transaction is active
    try testing.expectError(error.NoActiveTransaction, engine.commitTransaction());
    // Begin and rollback transaction
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());
    try engine.rollbackTransaction();
    try testing.expect(!engine.isTransactionActive());
    // Cannot rollback when no transaction is active
    try testing.expectError(error.NoActiveTransaction, engine.rollbackTransaction());
}
test "StorageEngine: automatic rollback in batch operations" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-auto-rollback", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Queue some operations
    try ctx.insertText("items", 1, 5, "val", "value1");
    try ctx.insertText("items", 2, 5, "val", "value1");
    // Wait for operations to be processed
    try engine.flushPendingWrites();
    // Verify no transaction is active after batch completes
    try testing.expect(!engine.isTransactionActive());
    // Verify data was written
    var managed1 = try (try ctx.table("items")).selectDocument(allocator, 1, 5);
    defer managed1.deinit();
    try testing.expect(managed1.rows.len > 0);

    var managed2 = try (try ctx.table("items")).selectDocument(allocator, 2, 5);
    defer managed2.deinit();
    try testing.expect(managed2.rows.len > 0);
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
    const Thread = struct {
        fn readKey(eng: *sth.StorageEngine, alloc: std.mem.Allocator, id: u128) !void {
            var managed = try eng.selectDocument(alloc, 0, id, 2);
            defer managed.deinit();
            try testing.expect(managed.rows.len > 0);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const id: u128 = if (i % 2 == 0) 1 else 2;
        thread.* = try std.Thread.spawn(.{}, Thread.readKey, .{ engine, allocator, id });
    }
    for (threads) |thread| {
        thread.join();
    }
}
test "StorageEngine: all pending writes are flushed before deinit returns" {
    // Regression test for brittle shutdown synchronization.
    // Previously deinit() used a fixed 50ms sleep before joining the write
    // thread, which could race and lose in-flight writes. Now it signals
    // write_cond and joins cleanly, guaranteeing the write thread has flushed
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
test "StorageEngine: manual transaction MUST increment write_seq on commit" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-tx-race", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // 1. Initial write_seq
    // sth.setupEngine executes DDL, so write_seq starts at 1
    const seq0 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 1), seq0);
    // 2. Begin transaction
    try engine.beginTransaction();
    // 3. Write something
    try ctx.insertText("items", 1, 1, "val", "updated");
    // 4. Flush batch. This should increment write_seq to 2.
    try engine.flushPendingWrites();
    const seq1 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 2), seq1);
    // 5. Commit transaction. This SHOULD increment write_seq to 3.
    try engine.commitTransaction();
    // 6. VERIFY: write_seq should have advanced to 3
    const seq2 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 3), seq2);
}
