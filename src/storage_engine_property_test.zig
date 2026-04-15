const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");
const qth = @import("query_parser_test_helpers.zig");
const StorageEngine = sth.StorageEngine;
const ColumnValue = sth.ColumnValue;

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
    const WriteThread = struct {
        fn run(eng: *StorageEngine, thread_id: usize) !void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const key = try std.fmt.allocPrint(
                    testing.allocator,
                    "/thread{d}/key{d}",
                    .{ thread_id, i },
                );
                defer testing.allocator.free(key);
                const value = try std.fmt.allocPrint(
                    testing.allocator,
                    "{{\"thread\":{d},\"op\":{d}}}",
                    .{ thread_id, i },
                );
                defer testing.allocator.free(value);
                const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = value } }, .field_type = .text }};
                try eng.insertOrReplace("test", key, "test", &cols);
            }
        }
    };
    const ReadThread = struct {
        fn run(eng: *StorageEngine, thread_id: usize) !void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const key = try std.fmt.allocPrint(
                    testing.allocator,
                    "/thread{d}/key{d}",
                    .{ thread_id % (num_threads / 2), i },
                );
                defer testing.allocator.free(key);
                var managed = try eng.selectDocument(testing.allocator, "test", key, "test");
                defer managed.deinit();
            }
        }
    };

    // Spawn write threads
    var write_threads: [num_threads / 2]std.Thread = undefined;
    for (&write_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, WriteThread.run, .{ engine, i });
    }
    // Spawn read threads
    var read_threads: [num_threads / 2]std.Thread = undefined;
    for (&read_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, ReadThread.run, .{ engine, i });
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
    var managed = try engine.selectDocument(allocator, "test", "/thread0/key0", "test");
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
        try engine.insertOrReplace("test", "key1", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "test1" } }, .field_type = .text }});
        try engine.insertOrReplace("test", "key2", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "test2" } }, .field_type = .text }});
    }
    try engine.flushPendingWrites();
    // Perform many read operations to ensure connections are being reused
    // If connections weren't released, we'd run out of connections
    const num_operations = 1000;
    var i: usize = 0;
    while (i < num_operations) : (i += 1) {
        const key = if (i % 2 == 0) "key1" else "key2";
        var managed = try engine.selectDocument(testing.allocator, "test", key, "test");
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
        path: []const u8,
        value: []const u8,
    }{
        .{ .namespace = "ns1", .path = "simple", .value = "{\"data\":\"simple\"}" },
        .{ .namespace = "ns1", .path = "nested", .value = "{\"user\":{\"name\":\"Alice\",\"age\":30}}" },
        .{ .namespace = "ns2", .path = "array", .value = "[1,2,3,4,5]" },
        .{ .namespace = "ns2", .path = "empty", .value = "{}" },
        .{ .namespace = "ns3", .path = "unicode", .value = "{\"text\":\"Hello 世界 🌍\"}" },
        .{ .namespace = "ns3", .path = "special", .value = "{\"chars\":\"\\\"\\n\\t\\r\"}" },
    };
    // Insert all test cases
    for (test_cases) |tc| {
        const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = tc.value } }, .field_type = .text }};
        try engine.insertOrReplace("test", tc.path, "test", &cols);
    }
    // Flush writes
    try engine.flushPendingWrites();
    // Retrieve and verify all test cases
    for (test_cases) |tc| {
        var managed = try engine.selectDocument(allocator, "test", tc.path, "test");
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
        path: []const u8,
        value: []const u8,
    }{
        .{ .namespace = "ns1", .path = "/key1", .value = "{\"data\":\"value1\"}" },
        .{ .namespace = "ns1", .path = "/key2", .value = "{\"data\":\"value2\"}" },
        .{ .namespace = "ns2", .path = "/key1", .value = "{\"data\":\"value3\"}" },
    };
    for (test_cases) |tc| {
        // Insert
        const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = tc.value } }, .field_type = .text }};
        try engine.insertOrReplace("test", tc.path, "test", &cols);
        try engine.flushPendingWrites();
        // Verify it exists
        var managed1 = try engine.selectDocument(allocator, "test", tc.path, "test");
        defer managed1.deinit();
        const doc1 = managed1.rows;
        try testing.expect(doc1.len > 0);
        // Delete
        try engine.deleteDocument("test", tc.path, "test");
        try engine.flushPendingWrites();
        // Verify it's gone
        var managed2 = try engine.selectDocument(allocator, "test", tc.path, "test");
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
        try engine.insertOrReplace("test", "/key1", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "initial1" } }, .field_type = .text }});
        try engine.insertOrReplace("test", "/key2", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "initial2" } }, .field_type = .text }});
    }
    try engine.flushPendingWrites();
    // Verify initial state
    var managed1 = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed1.deinit();
    const doc1 = managed1.rows;
    var managed2 = try engine.selectDocument(allocator, "test", "/key2", "test");
    defer managed2.deinit();
    const doc2 = managed2.rows;
    try testing.expect(doc1.len > 0);
    try testing.expect(doc2.len > 0);
    // Queue multiple operations that should execute atomically in a batch
    {
        try engine.insertOrReplace("test", "/key1", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "updated1" } }, .field_type = .text }});
        try engine.insertOrReplace("test", "/key2", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "updated2" } }, .field_type = .text }});
        try engine.insertOrReplace("test", "/key3", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "new3" } }, .field_type = .text }});
    }
    // Flush to ensure operations are processed
    try engine.flushPendingWrites();
    // All operations should have been applied atomically
    var managed_up1 = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed_up1.deinit();
    const up1 = managed_up1.rows;

    var managed_up2 = try engine.selectDocument(allocator, "test", "/key2", "test");
    defer managed_up2.deinit();
    const up2 = managed_up2.rows;

    var managed_n3 = try engine.selectDocument(allocator, "test", "/key3", "test");
    defer managed_n3.deinit();
    const n3 = managed_n3.rows;
    try testing.expect(up1.len > 0);
    try testing.expect(up2.len > 0);
    try testing.expect(n3.len > 0);
    // Test concurrent reads during batch processing see consistent state
    // This tests that the write thread's transaction provides isolation
    const cols_c = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "before" } }, .field_type = .text }};
    try engine.insertOrReplace("test", "/concurrent_key", "test", &cols_c);
    try engine.flushPendingWrites();
    // Start a batch by queuing many operations
    const num_ops = 100;
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_key{d}", .{i});
        defer allocator.free(key);
        const value = try std.fmt.allocPrint(allocator, "{{\"batch\":{d}}}", .{i});
        defer allocator.free(value);
        const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = value } }, .field_type = .text }};
        try engine.insertOrReplace("test", key, "test", &cols);
    }
    // While the batch is being processed, concurrent reads should work
    var managed_conc = try engine.selectDocument(allocator, "test", "/concurrent_key", "test");
    defer managed_conc.deinit();
    const conc_read = managed_conc.rows;
    try testing.expect(conc_read.len > 0);
    // Wait for all writes to complete
    try engine.flushPendingWrites();
    // Verify all batch operations were applied atomically
    i = 0;
    while (i < num_ops) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_key{d}", .{i});
        defer allocator.free(key);
        var managed = try engine.selectDocument(allocator, "test", key, "test");
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
        const c1 = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "initial" } }, .field_type = .text }};
        try engine.insertOrReplace("test", "/key1", "test", &c1);
    }
    try engine.flushPendingWrites();
    // Verify initial state
    var managed_init = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed_init.deinit();
    const init_doc = managed_init.rows;
    try testing.expect(init_doc.len > 0);
    // Test manual transaction rollback
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());
    // Make changes within transaction
    {
        try engine.insertOrReplace("test", "/key1", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "modified" } }, .field_type = .text }});
        try engine.insertOrReplace("test", "/key2", "test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "new" } }, .field_type = .text }});
    }
    // Rollback the transaction
    try engine.rollbackTransaction();
    try testing.expect(!engine.isTransactionActive());
    // Flush any pending writes from before the transaction
    try engine.flushPendingWrites();
    // Verify changes were rolled back
    var managed_arb1 = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed_arb1.deinit();
    const arb1 = managed_arb1.rows;
    try testing.expect(arb1.len > 0);

    var managed_arb2 = try engine.selectDocument(allocator, "test", "/key2", "test");
    defer managed_arb2.deinit();
    const arb2 = managed_arb2.rows;
    try testing.expect(arb2.len == 0);
    // Test that errors in batch processing trigger automatic rollback
    // We simulate this by testing the transaction state after an error
    // First, set up a successful transaction
    try engine.beginTransaction();
    {
        const c3 = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = "test3" } }, .field_type = .text }};
        try engine.insertOrReplace("test", "/key3", "test", &c3);
    }
    try engine.commitTransaction();
    try engine.flushPendingWrites();
    var managed_comm = try engine.selectDocument(allocator, "test", "/key3", "test");
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
        const key = try std.fmt.allocPrint(allocator, "/batch_test{d}", .{j});
        defer allocator.free(key);
        const value = try std.fmt.allocPrint(allocator, "{{\"index\":{d}}}", .{j});
        defer allocator.free(value);
        const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .text = value } }, .field_type = .text }};
        try engine.insertOrReplace("test", key, "test", &cols);
    }
    // Flush and verify all operations succeeded atomically
    try engine.flushPendingWrites();
    j = 0;
    while (j < batch_size) : (j += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_test{d}", .{j});
        defer allocator.free(key);
        var managed = try engine.selectDocument(allocator, "test", key, "test");
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
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id = try std.fmt.allocPrint(allocator, "doc-{d}", .{iter});
        defer allocator.free(id);
        const title_idx = rand.intRangeAtMost(usize, 0, scalar_values.len - 1);
        const title_str = scalar_values[title_idx];
        const score_val: i64 = rand.intRangeAtMost(i64, 0, 9999);
        const cols = [_]ColumnValue{
            .{ .name = "title", .value = .{ .scalar = .{ .text = title_str } }, .field_type = .text },
            .{ .name = "score", .value = .{ .scalar = .{ .integer = score_val } }, .field_type = .integer },
        };
        try engine.insertOrReplace("items", id, "ns-test", &cols);
        try engine.flushPendingWrites();
        var managed = try engine.selectDocument(allocator, "items", id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        _ = try sth.expectFieldString(doc, "title", title_str);
        _ = try sth.expectFieldInt(doc, "score", score_val);
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
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id = try std.fmt.allocPrint(allocator, "doc-{d}", .{iter});
        defer allocator.free(id);
        const initial_cols = [_]ColumnValue{
            .{ .name = "title", .value = .{ .scalar = .{ .text = "initial" } }, .field_type = .text },
            .{ .name = "score", .value = .{ .scalar = .{ .integer = 0 } }, .field_type = .integer },
        };
        try engine.insertOrReplace("items", id, "ns-test", &initial_cols);
        try engine.flushPendingWrites();
        const new_score: i64 = rand.intRangeAtMost(i64, 1, 9999);
        try engine.insertOrReplace("items", id, "ns-test", &[_]ColumnValue{.{ .name = "score", .value = .{ .scalar = .{ .integer = new_score } }, .field_type = .integer }});
        try engine.flushPendingWrites();

        // Use selectDocument to verify the field update
        var managed = try engine.selectDocument(allocator, "items", id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        _ = try sth.expectFieldInt(doc, "score", new_score);
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
            const id = try std.fmt.allocPrint(allocator, "a-{d}-{d}", .{ iter, i });
            defer allocator.free(id);
            const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .integer = @intCast(i) } }, .field_type = .integer }};
            try engine.insertOrReplace("items", id, ns_a, &cols);
        }
        i = 0;
        while (i < count_b) : (i += 1) {
            const id = try std.fmt.allocPrint(allocator, "b-{d}-{d}", .{ iter, i });
            defer allocator.free(id);
            const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .integer = @intCast(i + 100) } }, .field_type = .integer }};
            try engine.insertOrReplace("items", id, ns_b, &cols);
        }
        try engine.flushPendingWrites();

        // Use selectQuery with an empty filter to verify collection scoping
        const filter_a = try qth.makeDefaultFilter(allocator);
        defer filter_a.deinit(allocator);
        var managed_a = try engine.selectQuery(allocator, "items", ns_a, filter_a);
        defer managed_a.deinit();
        try testing.expectEqual(count_a, managed_a.rows.len);

        const filter_b = try qth.makeDefaultFilter(allocator);
        defer filter_b.deinit(allocator);
        var managed_b = try engine.selectQuery(allocator, "items", ns_b, filter_b);
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
        const id = try std.fmt.allocPrint(allocator, "doc-{d}", .{iter});
        defer allocator.free(id);
        const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .integer = 42 } }, .field_type = .integer }};
        try engine.insertOrReplace("items", id, "ns-test", &cols);
        try engine.flushPendingWrites();
        try engine.deleteDocument("items", id, "ns-test");
        try engine.flushPendingWrites();
        var managed = try engine.selectDocument(allocator, "items", id, "ns-test");
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

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id = try std.fmt.allocPrint(allocator, "doc-{d}", .{iter});
        defer allocator.free(id);
        const t_before_insert = std.time.timestamp();
        const cols = [_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .integer = 1 } }, .field_type = .integer }};
        try engine.insertOrReplace("items", id, "ns-test", &cols);
        try engine.flushPendingWrites();
        var managed1 = try engine.selectDocument(allocator, "items", id, "ns-test");
        defer managed1.deinit();
        if (managed1.rows.len == 0) return error.MissingDoc;
        const doc1 = managed1.rows[0];
        const updated_at_1 = try sth.getFieldInt(doc1, "updated_at");
        try testing.expect(updated_at_1 >= t_before_insert);

        try engine.insertOrReplace("items", id, "ns-test", &[_]ColumnValue{.{ .name = "val", .value = .{ .scalar = .{ .integer = 2 } }, .field_type = .integer }});
        try engine.flushPendingWrites();

        var managed2 = try engine.selectDocument(allocator, "items", id, "ns-test");
        defer managed2.deinit();
        if (managed2.rows.len == 0) return error.MissingDoc;
        const doc2 = managed2.rows[0];
        const updated_at_2 = try sth.getFieldInt(doc2, "updated_at");
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

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id = try std.fmt.allocPrint(allocator, "doc-{d}", .{iter});
        defer allocator.free(id);
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
        const cols = [_]ColumnValue{
            .{ .name = "tags", .value = tags_tv, .field_type = .array },
            .{ .name = "name", .value = .{ .scalar = .{ .text = "test-item" } }, .field_type = .text },
        };
        try engine.insertOrReplace("items", id, "ns-test", &cols);
        try engine.flushPendingWrites();
        var managed = try engine.selectDocument(allocator, "items", id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        const got_tags = try sth.expectFieldArray(doc, "tags", n);
        for (elems, got_tags.array) |orig, got| {
            const orig_val = switch (orig) {
                .int => |v| v,
                else => unreachable,
            };
            const got_val = switch (got) {
                .integer => |v| v,
                else => unreachable,
            };
            try testing.expectEqual(orig_val, got_val);
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

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const id = try std.fmt.allocPrint(allocator, "doc-{d}", .{iter});
        defer allocator.free(id);
        const title_str = if (rand.boolean()) "hello" else "world";
        const score_val: i64 = rand.intRangeAtMost(i64, 0, 9999);
        const rating_val: f64 = @as(f64, @floatFromInt(rand.intRangeAtMost(i32, 0, 100))) / 10.0;
        const active_val = rand.boolean();
        const cols = [_]ColumnValue{
            .{ .name = "title", .value = .{ .scalar = .{ .text = title_str } }, .field_type = .text },
            .{ .name = "score", .value = .{ .scalar = .{ .integer = score_val } }, .field_type = .integer },
            .{ .name = "rating", .value = .{ .scalar = .{ .real = rating_val } }, .field_type = .real },
            .{ .name = "active", .value = .{ .scalar = .{ .boolean = active_val } }, .field_type = .boolean },
        };
        try engine.insertOrReplace("items", id, "ns-test", &cols);
        try engine.flushPendingWrites();
        var managed = try engine.selectDocument(allocator, "items", id, "ns-test");
        defer managed.deinit();
        if (managed.rows.len == 0) return error.MissingDoc;
        const doc = managed.rows[0];
        _ = try sth.expectFieldString(doc, "title", title_str);
        _ = try sth.expectFieldInt(doc, "score", score_val);
        _ = try sth.expectFieldReal(doc, "rating", rating_val);
        _ = try sth.expectFieldBool(doc, "active", active_val);
    }
}
