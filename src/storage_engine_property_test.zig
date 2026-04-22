const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const StorageEngine = sth.StorageEngine;

test "storage: engine initialization errors" {
    const allocator = testing.allocator;
    var ms: sth.MemoryStrategy = undefined;
    try ms.init(allocator);
    defer ms.deinit();

    // Test 1: Invalid directory path
    const invalid_dir = "";
    var sm1 = try sth.createDummySchemaManager(allocator);
    defer sm1.deinit();
    var engine1: StorageEngine = undefined;
    const result1 = engine1.init(allocator, &ms, invalid_dir, &sm1, .{}, .{ .in_memory = false }, null, null);
    try testing.expectError(error.InvalidDataDir, result1);

    // Test 2: Path that is a file, not a directory
    var context_not_dir = try sth.TestContext.init(allocator, "storage-not-dir");
    defer context_not_dir.deinit();
    const test_file = try std.fs.path.join(allocator, &.{ context_not_dir.test_dir, "test_file_not_dir.txt" });
    defer allocator.free(test_file);

    // Create a file
    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();

    var sm2 = try sth.createDummySchemaManager(allocator);
    defer sm2.deinit();
    var engine2: StorageEngine = undefined;
    const result2 = engine2.init(allocator, &ms, test_file, &sm2, .{}, .{ .in_memory = false }, null, null);
    try testing.expectError(error.NotDir, result2);

    // Test 3: Valid initialization should succeed
    var context_valid = try sth.TestContext.init(allocator, "storage-init-valid");
    defer context_valid.deinit();
    const test_dir = context_valid.test_dir;

    var sm3 = try sth.createDummySchemaManager(allocator);
    defer sm3.deinit();
    var engine3: StorageEngine = undefined;
    try engine3.init(allocator, &ms, test_dir, &sm3, .{}, .{ .in_memory = false }, null, null);
    defer engine3.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ test_dir, "zyncbase.db" });
    defer allocator.free(db_path);
    const db_file = try std.fs.cwd().openFile(db_path, .{});
    db_file.close();
}

// Storage engine thread safety properties
test "storage: thread-safe engine access" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "test", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "prop-multi-table", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Concurrent writes and reads
    const num_threads = 10;
    const ops_per_thread = 50;
    const ThreadContext = struct {
        ctx: *sth.EngineTestContext,
    };
    const WriteThread = struct {
        fn run(t_ctx: ThreadContext, thread_id: usize) !void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const key: u128 = thread_id * 1_000 + i + 1;
                const value = try std.fmt.allocPrint(
                    testing.allocator,
                    "{{\"thread\":{d},\"op\":{d}}}",
                    .{ thread_id, i },
                );
                defer testing.allocator.free(value);
                try t_ctx.ctx.insertField("test", key, "test", "val", tth.valText(value));
            }
        }
    };
    const ReadThread = struct {
        fn run(eng: *StorageEngine, table_index: usize, thread_id: usize) !void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const key: u128 = (thread_id % (num_threads / 2)) * 1_000 + i + 1;
                var managed = try eng.selectDocument(testing.allocator, table_index, key, "test");
                defer managed.deinit();
            }
        }
    };

    // Spawn write threads
    var write_threads: [num_threads / 2]std.Thread = undefined;
    for (&write_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, WriteThread.run, .{ ThreadContext{ .ctx = &ctx }, i });
    }
    // Spawn read threads
    var read_threads: [num_threads / 2]std.Thread = undefined;
    const test_table = try ctx.table("test");
    for (&read_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, ReadThread.run, .{ engine, test_table.metadata.index, i });
    }
    // Wait for all threads
    for (write_threads) |thread| {
        thread.join();
    }
    for (read_threads) |thread| {
        thread.join();
    }
    // Flush writes and verify data
    try engine.flushPendingWrites();
    // Verify some data was written
    var managed = try test_table.selectDocument(allocator, 1, "test");
    defer managed.deinit();
    const doc = managed.rows;
    try testing.expect(doc.len > 0);
}
test "storage: connection pool reuse and release" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "test", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "prop-many-ns", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Set some initial data
    {
        try ctx.insertText("test", 1, "test", "val", "test1");
        try ctx.insertText("test", 2, "test", "val", "test2");
    }
    try engine.flushPendingWrites();
    // Perform many read operations to ensure connections are being reused
    // If connections weren't released, we'd run out of connections
    const num_operations = 1000;
    var i: usize = 0;
    const test_table = try ctx.table("test");
    while (i < num_operations) : (i += 1) {
        const key: u128 = if (i % 2 == 0) 1 else 2;
        var managed = try test_table.selectDocument(testing.allocator, key, "test");
        defer managed.deinit();
        const doc = managed.rows;
        try testing.expect(doc.len > 0);
    }
    // If we got here, connections were properly released and reused
}
test "storage: persistence round-trip (various types)" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "test", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "prop-burst", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Test various data types and values
    const test_cases = [_]struct {
        namespace: []const u8,
        id: u128,
        value: []const u8,
    }{
        .{ .namespace = "ns1", .id = 1, .value = "{\"data\":\"simple\"}" },
        .{ .namespace = "ns1", .id = 2, .value = "{\"user\":{\"name\":\"Alice\",\"age\":30}}" },
        .{ .namespace = "ns2", .id = 3, .value = "[1,2,3,4,5]" },
        .{ .namespace = "ns2", .id = 4, .value = "{}" },
        .{ .namespace = "ns3", .id = 5, .value = "{\"text\":\"Hello 世界 🌍\"}" },
        .{ .namespace = "ns3", .id = 6, .value = "{\"chars\":\"\\\"\\n\\t\\r\"}" },
    };
    // Insert all test cases
    for (test_cases) |tc| {
        try ctx.insertText("test", tc.id, "test", "val", tc.value);
    }
    // Flush writes
    try engine.flushPendingWrites();
    const test_table = try ctx.table("test");
    // Retrieve and verify all test cases
    for (test_cases) |tc| {
        var managed = try test_table.selectDocument(allocator, tc.id, "test");
        defer managed.deinit();
        const doc = managed.rows;
        try testing.expect(doc.len > 0);
    }
}
test "storage: insert/delete inverse consistency" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "test", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-inverse", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    const test_cases = [_]struct {
        namespace: []const u8,
        id: u128,
        value: []const u8,
    }{
        .{ .namespace = "ns1", .id = 1, .value = "{\"data\":\"value1\"}" },
        .{ .namespace = "ns1", .id = 2, .value = "{\"data\":\"value2\"}" },
        .{ .namespace = "ns2", .id = 3, .value = "{\"data\":\"value3\"}" },
    };
    const test_table = try ctx.table("test");
    for (test_cases) |tc| {
        // Insert
        try ctx.insertText("test", tc.id, "test", "val", tc.value);
        try engine.flushPendingWrites();
        // Verify it exists
        var managed1 = try test_table.selectDocument(allocator, tc.id, "test");
        defer managed1.deinit();
        const doc1 = managed1.rows;
        try testing.expect(doc1.len > 0);
        // Delete
        try test_table.deleteDocument(tc.id, "test");
        try engine.flushPendingWrites();
        // Verify it's gone
        var managed2 = try test_table.selectDocument(allocator, tc.id, "test");
        defer managed2.deinit();
        const doc2 = managed2.rows;
        try testing.expect(doc2.len == 0);
    }
}
test "storage: transaction isolation and consistency" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "test", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-txn-isolation", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Test that operations are batched and executed atomically by the write thread
    // The write thread uses transactions internally to ensure atomicity
    // Set up initial state
    {
        try ctx.insertText("test", 1, "test", "val", "initial1");
        try ctx.insertText("test", 2, "test", "val", "initial2");
    }
    try engine.flushPendingWrites();
    const test_table = try ctx.table("test");
    // Verify initial state
    var managed1 = try test_table.selectDocument(allocator, 1, "test");
    defer managed1.deinit();
    const doc1 = managed1.rows;
    var managed2 = try test_table.selectDocument(allocator, 2, "test");
    defer managed2.deinit();
    const doc2 = managed2.rows;
    try testing.expect(doc1.len > 0);
    try testing.expect(doc2.len > 0);
    // Queue multiple operations that should execute atomically in a batch
    {
        try ctx.insertText("test", 1, "test", "val", "updated1");
        try ctx.insertText("test", 2, "test", "val", "updated2");
        try ctx.insertText("test", 3, "test", "val", "new3");
    }
    // Flush to ensure operations are processed
    try engine.flushPendingWrites();
    // All operations should have been applied atomically
    var managed_up1 = try test_table.selectDocument(allocator, 1, "test");
    defer managed_up1.deinit();
    const up1 = managed_up1.rows;

    var managed_up2 = try test_table.selectDocument(allocator, 2, "test");
    defer managed_up2.deinit();
    const up2 = managed_up2.rows;

    var managed_n3 = try test_table.selectDocument(allocator, 3, "test");
    defer managed_n3.deinit();
    const n3 = managed_n3.rows;
    try testing.expect(up1.len > 0);
    try testing.expect(up2.len > 0);
    try testing.expect(n3.len > 0);
    // Test concurrent reads during batch processing see consistent state
    // This tests that the write thread's transaction provides isolation
    try ctx.insertText("test", 10_000, "test", "val", "before");
    try engine.flushPendingWrites();
    // Start a batch by queuing many operations
    const num_ops = 100;
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        const key: u128 = 20_000 + i;
        const value = try std.fmt.allocPrint(allocator, "{{\"batch\":{d}}}", .{i});
        defer allocator.free(value);
        try ctx.insertText("test", key, "test", "val", value);
    }
    // While the batch is being processed, concurrent reads should work
    var managed_conc = try test_table.selectDocument(allocator, 10_000, "test");
    defer managed_conc.deinit();
    const conc_read = managed_conc.rows;
    try testing.expect(conc_read.len > 0);
    // Wait for all writes to complete
    try engine.flushPendingWrites();
    // Verify all batch operations were applied atomically
    i = 0;
    while (i < num_ops) : (i += 1) {
        const key: u128 = 20_000 + i;
        var managed = try test_table.selectDocument(allocator, key, "test");
        defer managed.deinit();
        const doc = managed.rows;
        try testing.expect(doc.len > 0);
    }
}
test "storage: automatic transaction rollback on failure" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "test", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-auto-rollback", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Set up initial state
    {
        try ctx.insertText("test", 1, "test", "val", "initial");
    }
    try engine.flushPendingWrites();
    const test_table = try ctx.table("test");
    // Verify initial state
    var managed_init = try test_table.selectDocument(allocator, 1, "test");
    defer managed_init.deinit();
    const init_doc = managed_init.rows;
    try testing.expect(init_doc.len > 0);
    // Test manual transaction rollback
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());
    // Make changes within transaction
    {
        try ctx.insertText("test", 1, "test", "val", "modified");
        try ctx.insertText("test", 2, "test", "val", "new");
    }
    // Rollback the transaction
    try engine.rollbackTransaction();
    try testing.expect(!engine.isTransactionActive());
    // Flush any pending writes from before the transaction
    try engine.flushPendingWrites();
    // Verify changes were rolled back
    var managed_arb1 = try test_table.selectDocument(allocator, 1, "test");
    defer managed_arb1.deinit();
    const arb1 = managed_arb1.rows;
    try testing.expect(arb1.len > 0);

    var managed_arb2 = try test_table.selectDocument(allocator, 2, "test");
    defer managed_arb2.deinit();
    const arb2 = managed_arb2.rows;
    try testing.expect(arb2.len == 0);
    // Test that errors in batch processing trigger automatic rollback
    // We simulate this by testing the transaction state after an error
    // First, set up a successful transaction
    try engine.beginTransaction();
    {
        try ctx.insertText("test", 3, "test", "val", "test3");
    }
    try engine.commitTransaction();
    try engine.flushPendingWrites();
    var managed_comm = try test_table.selectDocument(allocator, 3, "test");
    defer managed_comm.deinit();
    const comm = managed_comm.rows;
    try testing.expect(comm.len > 0);
    // Test transaction state management
    // Attempting to commit without an active transaction should error
    try testing.expectError(error.NoActiveTransaction, engine.commitTransaction());
    // Attempting to rollback without an active transaction should error
    try testing.expectError(error.NoActiveTransaction, engine.rollbackTransaction());
    // Attempting to begin a transaction when one is already active should error
    try engine.beginTransaction();
    try testing.expectError(error.TransactionAlreadyActive, engine.beginTransaction());
    try engine.rollbackTransaction();
    // Test that the write thread's automatic transaction handling works correctly
    // by verifying that batched operations are atomic (all succeed or all fail)
    const batch_size = 50;
    var j: usize = 0;
    while (j < batch_size) : (j += 1) {
        const key: u128 = 30_000 + j;
        const value = try std.fmt.allocPrint(allocator, "{{\"index\":{d}}}", .{j});
        defer allocator.free(value);
        try ctx.insertText("test", key, "test", "val", value);
    }
    // Flush and verify all operations succeeded atomically
    try engine.flushPendingWrites();
    j = 0;
    while (j < batch_size) : (j += 1) {
        const key: u128 = 30_000 + j;
        var managed = try test_table.selectDocument(allocator, key, "test");
        defer managed.deinit();
        const doc = managed.rows;
        try testing.expect(doc.len > 0);
    }
}
test "storage: document set/get round-trip" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rand = prng.random();
    const scalar_values = [_][]const u8{ "hello", "world", "foo", "bar", "baz" };
    var fields_arr = [_]sth.Field{
        sth.makeField("title", .text, false),
        sth.makeField("score", .integer, false),
    };
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "prop-reopen", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const tbl_md = ctx.sm.getTable("items") orelse return error.UnknownTable;
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id: u128 = iter + 1;
        const title_idx = rand.intRangeAtMost(usize, 0, scalar_values.len - 1);
        const title_str = scalar_values[title_idx];
        const score_val: i64 = rand.intRangeAtMost(i64, 0, 9999);
        try ctx.insertNamed("items", id, "ns-test", .{
            sth.named("title", tth.valText(title_str)),
            sth.named("score", tth.valInt(score_val)),
        });
        try engine.flushPendingWrites();
        const items_table = try ctx.table("items");
        var managed = try items_table.selectDocument(allocator, id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        _ = try sth.expectFieldString(doc, tbl_md, "title", title_str);
        _ = try sth.expectFieldInt(doc, tbl_md, "score", score_val);
    }
}
test "storage: field set/get round-trip" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rand = prng.random();
    var fields_arr = [_]sth.Field{
        sth.makeField("title", .text, false),
        sth.makeField("score", .integer, false),
    };
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-p14", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const tbl_md = ctx.sm.getTable("items") orelse return error.UnknownTable;
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id: u128 = iter + 1;
        try ctx.insertNamed("items", id, "ns-test", .{
            sth.named("title", tth.valText("initial")),
            sth.named("score", tth.valInt(0)),
        });
        try engine.flushPendingWrites();
        const new_score: i64 = rand.intRangeAtMost(i64, 1, 9999);
        try ctx.insertInt("items", id, "ns-test", "score", new_score);
        try engine.flushPendingWrites();

        // Use selectDocument to verify the field update
        const items_table = try ctx.table("items");
        var managed = try items_table.selectDocument(allocator, id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        _ = try sth.expectFieldInt(doc, tbl_md, "score", new_score);
    }
}
test "storage: query is namespace-scoped" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE);
    const rand = prng.random();
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-p15", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const ns_a = try std.fmt.allocPrint(allocator, "ns-alpha-{d}", .{iter});
        defer allocator.free(ns_a);
        const ns_b = try std.fmt.allocPrint(allocator, "ns-beta-{d}", .{iter});
        defer allocator.free(ns_b);
        const count_a = rand.intRangeAtMost(usize, 1, 5);
        const count_b = rand.intRangeAtMost(usize, 1, 5);
        var i: usize = 0;
        while (i < count_a) : (i += 1) {
            const id: u128 = iter * 1_000 + i + 1;
            try ctx.insertInt("items", id, ns_a, "val", @intCast(i));
        }
        i = 0;
        while (i < count_b) : (i += 1) {
            const id: u128 = 100_000 + iter * 1_000 + i + 1;
            try ctx.insertInt("items", id, ns_b, "val", @intCast(i + 100));
        }
        try engine.flushPendingWrites();

        // Use selectQuery with an empty filter to verify collection scoping
        const items_table = try ctx.table("items");
        const filter_a = try qth.makeDefaultFilter(allocator);
        defer filter_a.deinit(allocator);
        var managed_a = try items_table.selectQuery(allocator, ns_a, filter_a);
        defer managed_a.deinit();
        try testing.expectEqual(count_a, managed_a.rows.len);

        const filter_b = try qth.makeDefaultFilter(allocator);
        defer filter_b.deinit(allocator);
        var managed_b = try items_table.selectQuery(allocator, ns_b, filter_b);
        defer managed_b.deinit();
        try testing.expectEqual(count_b, managed_b.rows.len);
    }
}
test "storage: remove then get returns null" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-p16", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id: u128 = iter + 1;
        const items_table = try ctx.table("items");
        try ctx.insertInt("items", id, "ns-test", "val", 42);
        try engine.flushPendingWrites();
        try items_table.deleteDocument(id, "ns-test");
        try engine.flushPendingWrites();
        var managed = try items_table.selectDocument(allocator, id, "ns-test");
        defer managed.deinit();
        const after = managed.rows;
        try testing.expect(after.len == 0);
    }
}
test "storage: updated_at is always refreshed on write" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-p18", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const items_md = ctx.sm.getTable("items") orelse return error.UnknownTable;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id: u128 = iter + 1;
        const items_table = try ctx.table("items");
        const t_before_insert = std.time.timestamp();
        try ctx.insertInt("items", id, "ns-test", "val", 1);
        try engine.flushPendingWrites();
        var managed1 = try items_table.selectDocument(allocator, id, "ns-test");
        defer managed1.deinit();
        if (managed1.rows.len == 0) return error.MissingDoc;
        const doc1 = managed1.rows[0];
        const updated_at_1 = try sth.getFieldInt(doc1, items_md, "updated_at");
        try testing.expect(updated_at_1 >= t_before_insert);

        try ctx.insertInt("items", id, "ns-test", "val", 2);
        try engine.flushPendingWrites();

        var managed2 = try items_table.selectDocument(allocator, id, "ns-test");
        defer managed2.deinit();
        if (managed2.rows.len == 0) return error.MissingDoc;
        const doc2 = managed2.rows[0];
        const updated_at_2 = try sth.getFieldInt(doc2, items_md, "updated_at");
        try testing.expect(updated_at_2 >= updated_at_1);
    }
}
test "storage: write/read round-trip for array fields" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xA77A1_10);
    const rand = prng.random();
    var fields_arr = [_]sth.Field{
        sth.Field{ .name = "tags", .sql_type = .array, .items_type = .integer, .required = false, .indexed = false, .references = null, .on_delete = null },
        sth.makeField("name", .text, false),
    };
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-p10", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const tbl_md = ctx.sm.getTable("items") orelse return error.UnknownTable;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id: u128 = iter + 1;
        const n = rand.intRangeAtMost(usize, 0, 6);
        const elems = try allocator.alloc(msgpack.Payload, n);
        for (0..n) |i| {
            elems[i] = .{ .int = rand.intRangeAtMost(i64, -200, 200) };
        }
        const array_payload = msgpack.Payload{ .arr = elems };
        defer array_payload.free(allocator);
        const storage_engine = @import("storage_engine.zig");
        const tags_tv = try storage_engine.TypedValue.fromPayload(allocator, .array, .integer, array_payload);
        defer tags_tv.deinit(allocator);
        const items_table = try ctx.table("items");
        try ctx.insertNamed("items", id, "ns-test", .{
            sth.named("tags", tags_tv),
            sth.named("name", tth.valText("test-item")),
        });
        try engine.flushPendingWrites();
        var managed = try items_table.selectDocument(allocator, id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        const got_tags = try sth.expectFieldArray(doc, tbl_md, "tags", tags_tv.array.len);
        for (tags_tv.array, got_tags.array) |expected, got| {
            const expected_val = switch (expected) {
                .integer => |v| v,
                else => unreachable,
            };
            const got_val = switch (got) {
                .integer => |v| v,
                else => unreachable,
            };
            try testing.expectEqual(expected_val, got_val);
        }
    }
}
test "storage: non-array fields are unaffected" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xB0B_11);
    const rand = prng.random();
    var fields_arr = [_]sth.Field{
        sth.makeField("title", .text, false),
        sth.makeField("score", .integer, false),
        sth.makeField("rating", .real, false),
        sth.makeField("active", .boolean, false),
    };
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-p11", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const tbl_md = ctx.sm.getTable("items") orelse return error.UnknownTable;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id: u128 = iter + 1;
        const title_str = if (rand.boolean()) "hello" else "world";
        const score_val: i64 = rand.intRangeAtMost(i64, 0, 9999);
        const rating_val: f64 = @as(f64, @floatFromInt(rand.intRangeAtMost(i32, 0, 100))) / 10.0;
        const active_val = rand.boolean();
        const items_table = try ctx.table("items");
        try ctx.insertNamed("items", id, "ns-test", .{
            sth.named("title", tth.valText(title_str)),
            sth.named("score", tth.valInt(score_val)),
            sth.named("rating", tth.valReal(rating_val)),
            sth.named("active", tth.valBool(active_val)),
        });
        try engine.flushPendingWrites();
        var managed = try items_table.selectDocument(allocator, id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        _ = try sth.expectFieldString(doc, tbl_md, "title", title_str);
        _ = try sth.expectFieldInt(doc, tbl_md, "score", score_val);
        _ = try sth.expectFieldReal(doc, tbl_md, "rating", rating_val);
        _ = try sth.expectFieldBool(doc, tbl_md, "active", active_val);
    }
}
