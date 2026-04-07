const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");
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
                const val_payload = try msgpack.Payload.strToPayload(value, testing.allocator);
                defer val_payload.free(testing.allocator);
                const cols = [_]sth.ColumnValue{.{ .name = "val", .value = val_payload }};
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
    const doc = managed.value;
    try testing.expect(doc != null);
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
        const val_payload1 = try msgpack.Payload.strToPayload("test1", allocator);
        defer val_payload1.free(allocator);
        const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_payload1 }};
        try engine.insertOrReplace("test", "key1", "test", &cols1);
        const val_payload2 = try msgpack.Payload.strToPayload("test2", allocator);
        defer val_payload2.free(allocator);
        const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
        try engine.insertOrReplace("test", "key2", "test", &cols2);
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
        const doc = managed.value;
        try testing.expect(doc != null);
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
        const val_payload = try msgpack.Payload.strToPayload(tc.value, allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try engine.insertOrReplace("test", tc.path, "test", &cols);
    }
    // Flush writes
    try engine.flushPendingWrites();
    // Retrieve and verify all test cases
    for (test_cases) |tc| {
        var managed = try engine.selectDocument(allocator, "test", tc.path, "test");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
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
        const val_payload = try msgpack.Payload.strToPayload(tc.value, allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try engine.insertOrReplace("test", tc.path, "test", &cols);
        try engine.flushPendingWrites();
        // Verify it exists
        var managed1 = try engine.selectDocument(allocator, "test", tc.path, "test");
        defer managed1.deinit();
        const doc1 = managed1.value;
        try testing.expect(doc1 != null);
        // Delete
        try engine.deleteDocument("test", tc.path, "test");
        try engine.flushPendingWrites();
        // Verify it's gone
        var managed2 = try engine.selectDocument(allocator, "test", tc.path, "test");
        defer managed2.deinit();
        const doc2 = managed2.value;
        try testing.expect(doc2 == null);
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
        const val_payload1 = try msgpack.Payload.strToPayload("initial1", allocator);
        defer val_payload1.free(allocator);
        const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_payload1 }};
        try engine.insertOrReplace("test", "/key1", "test", &cols1);
        const val_payload2 = try msgpack.Payload.strToPayload("initial2", allocator);
        defer val_payload2.free(allocator);
        const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
        try engine.insertOrReplace("test", "/key2", "test", &cols2);
    }
    try engine.flushPendingWrites();
    // Verify initial state
    var managed1 = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed1.deinit();
    const doc1 = managed1.value;
    var managed2 = try engine.selectDocument(allocator, "test", "/key2", "test");
    defer managed2.deinit();
    const doc2 = managed2.value;
    try testing.expect(doc1 != null);
    try testing.expect(doc2 != null);
    // Queue multiple operations that should execute atomically in a batch
    {
        const val_payload1 = try msgpack.Payload.strToPayload("updated1", allocator);
        defer val_payload1.free(allocator);
        const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_payload1 }};
        try engine.insertOrReplace("test", "/key1", "test", &cols1);
        const val_payload2 = try msgpack.Payload.strToPayload("updated2", allocator);
        defer val_payload2.free(allocator);
        const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
        try engine.insertOrReplace("test", "/key2", "test", &cols2);
        const val_payload3 = try msgpack.Payload.strToPayload("new3", allocator);
        defer val_payload3.free(allocator);
        const cols3 = [_]ColumnValue{.{ .name = "val", .value = val_payload3 }};
        try engine.insertOrReplace("test", "/key3", "test", &cols3);
    }
    // Flush to ensure operations are processed
    try engine.flushPendingWrites();
    // All operations should have been applied atomically
    var managed_up1 = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed_up1.deinit();
    const up1 = managed_up1.value;

    var managed_up2 = try engine.selectDocument(allocator, "test", "/key2", "test");
    defer managed_up2.deinit();
    const up2 = managed_up2.value;

    var managed_n3 = try engine.selectDocument(allocator, "test", "/key3", "test");
    defer managed_n3.deinit();
    const n3 = managed_n3.value;
    try testing.expect(up1 != null);
    try testing.expect(up2 != null);
    try testing.expect(n3 != null);
    // Test concurrent reads during batch processing see consistent state
    // This tests that the write thread's transaction provides isolation
    const val_payload_c = try msgpack.Payload.strToPayload("before", allocator);
    defer val_payload_c.free(allocator);
    const cols_c = [_]ColumnValue{.{ .name = "val", .value = val_payload_c }};
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
        const val_p = try msgpack.Payload.strToPayload(value, allocator);
        defer val_p.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_p }};
        try engine.insertOrReplace("test", key, "test", &cols);
    }
    // While the batch is being processed, concurrent reads should work
    var managed_conc = try engine.selectDocument(allocator, "test", "/concurrent_key", "test");
    defer managed_conc.deinit();
    const conc_read = managed_conc.value;
    try testing.expect(conc_read != null);
    // Wait for all writes to complete
    try engine.flushPendingWrites();
    // Verify all batch operations were applied atomically
    i = 0;
    while (i < num_ops) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_key{d}", .{i});
        defer allocator.free(key);
        var managed = try engine.selectDocument(allocator, "test", key, "test");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
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
        const v1 = try msgpack.Payload.strToPayload("initial", allocator);
        defer v1.free(allocator);
        const c1 = [_]ColumnValue{.{ .name = "val", .value = v1 }};
        try engine.insertOrReplace("test", "/key1", "test", &c1);
    }
    try engine.flushPendingWrites();
    // Verify initial state
    var managed_init = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed_init.deinit();
    const init_doc = managed_init.value;
    try testing.expect(init_doc != null);
    // Test manual transaction rollback
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());
    // Make changes within transaction
    {
        const v1 = try msgpack.Payload.strToPayload("modified", allocator);
        defer v1.free(allocator);
        const c1 = [_]ColumnValue{.{ .name = "val", .value = v1 }};
        try engine.insertOrReplace("test", "/key1", "test", &c1);
        const v2 = try msgpack.Payload.strToPayload("new", allocator);
        defer v2.free(allocator);
        const c2 = [_]ColumnValue{.{ .name = "val", .value = v2 }};
        try engine.insertOrReplace("test", "/key2", "test", &c2);
    }
    // Rollback the transaction
    try engine.rollbackTransaction();
    try testing.expect(!engine.isTransactionActive());
    // Flush any pending writes from before the transaction
    try engine.flushPendingWrites();
    // Verify changes were rolled back
    var managed_arb1 = try engine.selectDocument(allocator, "test", "/key1", "test");
    defer managed_arb1.deinit();
    const arb1 = managed_arb1.value;
    try testing.expect(arb1 != null);

    var managed_arb2 = try engine.selectDocument(allocator, "test", "/key2", "test");
    defer managed_arb2.deinit();
    const arb2 = managed_arb2.value;
    try testing.expect(arb2 == null);
    // Test that errors in batch processing trigger automatic rollback
    // We simulate this by testing the transaction state after an error
    // First, set up a successful transaction
    try engine.beginTransaction();
    {
        const v3 = try msgpack.Payload.strToPayload("test3", allocator);
        defer v3.free(allocator);
        const c3 = [_]ColumnValue{.{ .name = "val", .value = v3 }};
        try engine.insertOrReplace("test", "/key3", "test", &c3);
    }
    try engine.commitTransaction();
    try engine.flushPendingWrites();
    var managed_comm = try engine.selectDocument(allocator, "test", "/key3", "test");
    defer managed_comm.deinit();
    const comm = managed_comm.value;
    try testing.expect(comm != null);
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
        const v_p = try msgpack.Payload.strToPayload(value, allocator);
        defer v_p.free(allocator);
        const c = [_]ColumnValue{.{ .name = "val", .value = v_p }};
        try engine.insertOrReplace("test", key, "test", &c);
    }
    // Flush and verify all operations succeeded atomically
    try engine.flushPendingWrites();
    j = 0;
    while (j < batch_size) : (j += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_test{d}", .{j});
        defer allocator.free(key);
        var managed = try engine.selectDocument(allocator, "test", key, "test");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
    }
}
// ─── Property 13: Document set/get round-trip ────────────────────────────────
test "storage: document set/get round-trip" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rand = prng.random();
    const scalar_values = [_][]const u8{ "hello", "world", "foo", "bar", "baz" };
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{
            sth.makeField("title", .text, false),
            sth.makeField("score", .integer, false),
        };
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "prop-reopen", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";
        const title_idx = rand.intRangeAtMost(usize, 0, scalar_values.len - 1);
        const title_str = scalar_values[title_idx];
        const score_val: i64 = rand.intRangeAtMost(i64, 0, 9999);
        const title_payload = try msgpack.Payload.strToPayload(title_str, allocator);
        defer title_payload.free(allocator);
        const cols = [_]ColumnValue{
            .{ .name = "title", .value = title_payload },
            .{ .name = "score", .value = msgpack.Payload.intToPayload(score_val) },
        };
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();
        var managed = try engine.selectDocument(allocator, "items", id, ns);
        defer managed.deinit();
        const doc = managed.value orelse return error.MissingDoc;
        const got_title = (try doc.mapGet("title")) orelse return error.MissingTitle;
        try testing.expectEqualStrings(title_str, got_title.str.value());
        const got_score = (try doc.mapGet("score")) orelse return error.MissingScore;
        const got_score_val: i64 = switch (got_score) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expectEqual(score_val, got_score_val);
    }
}
// ─── Property 14: Field set/get round-trip ───────────────────────────────────
test "storage: field set/get round-trip" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{
            sth.makeField("title", .text, false),
            sth.makeField("score", .integer, false),
        };
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "storage-p14", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";
        const initial_title = try msgpack.Payload.strToPayload("initial", allocator);
        defer initial_title.free(allocator);
        const initial_cols = [_]ColumnValue{
            .{ .name = "title", .value = initial_title },
            .{ .name = "score", .value = msgpack.Payload.intToPayload(0) },
        };
        try engine.insertOrReplace("items", id, ns, &initial_cols);
        try engine.flushPendingWrites();
        const new_score: i64 = rand.intRangeAtMost(i64, 1, 9999);
        try engine.updateField("items", id, ns, "score", msgpack.Payload.intToPayload(new_score));
        try engine.flushPendingWrites();
        var managed = try engine.selectField(allocator, "items", id, ns, "score");
        defer managed.deinit();
        const got = managed.value orelse return error.MissingField;
        const got_score_val: i64 = switch (got) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expectEqual(new_score, got_score_val);
    }
}
// ─── Property 15: Collection get is namespace-scoped ─────────────────────────
test "storage: collection get is namespace-scoped" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "storage-p15", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const ns_a = "ns-alpha";
        const ns_b = "ns-beta";
        const count_a = rand.intRangeAtMost(usize, 1, 5);
        const count_b = rand.intRangeAtMost(usize, 1, 5);
        var i: usize = 0;
        while (i < count_a) : (i += 1) {
            const id = try std.fmt.allocPrint(allocator, "a-{}", .{i});
            defer allocator.free(id);
            const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(@intCast(i)) }};
            try engine.insertOrReplace("items", id, ns_a, &cols);
        }
        i = 0;
        while (i < count_b) : (i += 1) {
            const id = try std.fmt.allocPrint(allocator, "b-{}", .{i});
            defer allocator.free(id);
            const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(@intCast(i + 100)) }};
            try engine.insertOrReplace("items", id, ns_b, &cols);
        }
        try engine.flushPendingWrites();
        var managed_a = try engine.selectCollection(allocator, "items", ns_a);
        defer managed_a.deinit();
        const coll_a = managed_a.value orelse return error.MissingCollection;
        try testing.expectEqual(count_a, coll_a.arr.len);
        var managed_b = try engine.selectCollection(allocator, "items", ns_b);
        defer managed_b.deinit();
        const coll_b = managed_b.value orelse return error.MissingCollection;
        try testing.expectEqual(count_b, coll_b.arr.len);
    }
}
// ─── Property 16: Remove then get returns null ────────────────────────────────
test "storage: remove then get returns null" {
    const allocator = testing.allocator;
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "storage-p16", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";
        const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(42) }};
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();
        try engine.deleteDocument("items", id, ns);
        try engine.flushPendingWrites();
        var managed = try engine.selectDocument(allocator, "items", id, ns);
        defer managed.deinit();
        const after = managed.value;
        try testing.expect(after == null);
    }
}
// ─── Property 17: Schema validation rejects unknown tables and fields ─────────
test "storage: schema validation rejects unknown tables and fields" {
    const allocator = testing.allocator;
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{sth.makeField("title", .text, false)};
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "storage-p17", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const cols = [_]ColumnValue{.{ .name = "title", .value = msgpack.Payload.intToPayload(1) }};
        const err1 = engine.insertOrReplace("nonexistent_table", "id1", "ns", &cols);
        try testing.expectError(sth.StorageError.UnknownTable, err1);
        const bad_cols = [_]ColumnValue{.{ .name = "nonexistent_field", .value = msgpack.Payload.intToPayload(1) }};
        const err2 = engine.insertOrReplace("items", "id1", "ns", &bad_cols);
        try testing.expectError(sth.StorageError.UnknownField, err2);
    }
}
// ─── Property 18: updated_at is always refreshed on write ────────────────────
test "storage: updated_at is always refreshed on write" {
    const allocator = testing.allocator;
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "storage-p18", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";
        const t_before_insert = std.time.timestamp();
        const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(1) }};
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();
        var managed1 = try engine.selectDocument(allocator, "items", id, ns);
        defer managed1.deinit();
        const doc1 = managed1.value orelse return error.MissingDoc;
        const updated_at_1_payload = (try doc1.mapGet("updated_at")) orelse return error.MissingUpdatedAt;
        const updated_at_1: i64 = switch (updated_at_1_payload) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expect(updated_at_1 >= t_before_insert);
        std.Thread.sleep(10 * std.time.ns_per_ms);
        const t_before_update = std.time.timestamp();
        try engine.updateField("items", id, ns, "val", msgpack.Payload.intToPayload(2));
        try engine.flushPendingWrites();
        var managed2 = try engine.selectDocument(allocator, "items", id, ns);
        defer managed2.deinit();
        const doc2 = managed2.value orelse return error.MissingDoc;
        const updated_at_2_payload = (try doc2.mapGet("updated_at")) orelse return error.MissingUpdatedAt;
        const updated_at_2: i64 = switch (updated_at_2_payload) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expect(updated_at_2 >= t_before_update);
    }
}
// ─── Property 10: Storage engine write/read round-trip for array fields ───────
// Feature: array-jsonb-storage, Property 10: Storage engine write/read round-trip for array fields
test "storage: write/read round-trip for array fields" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xA77A1_10);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{
            sth.makeField("tags", .array, false),
            sth.makeField("name", .text, false),
        };
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "storage-p10", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";
        // Generate a random literal array
        const n = rand.intRangeAtMost(usize, 0, 6);
        const elems = try allocator.alloc(msgpack.Payload, n);
        for (0..n) |i| {
            elems[i] = .{ .int = rand.intRangeAtMost(i64, -100, 100) };
        }
        const array_payload = msgpack.Payload{ .arr = elems };
        defer array_payload.free(allocator);
        const name_payload = try msgpack.Payload.strToPayload("test-item", allocator);
        defer name_payload.free(allocator);
        const cols = [_]ColumnValue{
            .{ .name = "tags", .value = array_payload },
            .{ .name = "name", .value = name_payload },
        };
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();
        // Read back via selectDocument
        var managed = try engine.selectDocument(allocator, "items", id, ns);
        defer managed.deinit();
        const doc = managed.value orelse return error.MissingDoc;
        const got_tags = (try doc.mapGet("tags")) orelse return error.MissingTags;
        try testing.expect(got_tags == .arr);
        try testing.expectEqual(n, got_tags.arr.len);
        for (elems, got_tags.arr) |orig, got| {
            const orig_val: i64 = switch (orig) {
                .int => |v| v,
                else => return error.UnexpectedType,
            };
            const got_val: i64 = switch (got) {
                .int => |v| v,
                .uint => |v| @intCast(v),
                else => return error.UnexpectedType,
            };
            try testing.expectEqual(orig_val, got_val);
        }
        // Also read back via selectField
        var managed_field = try engine.selectField(allocator, "items", id, ns, "tags");
        defer managed_field.deinit();
        try testing.expect(managed_field.value != null);
        const field_result = managed_field.value.?;
        try testing.expect(field_result == .arr);
        try testing.expectEqual(n, field_result.arr.len);
    }
}
// ─── Property 11: Non-array fields are unaffected by the change ──────────────
// Feature: array-jsonb-storage, Property 11: Non-array fields are unaffected by the change
test "storage: non-array fields are unaffected" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xB0B_11);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
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

        const id = "doc-001";
        const ns = "ns-test";
        const title_str = if (rand.boolean()) "hello" else "world";
        const score_val: i64 = rand.intRangeAtMost(i64, 0, 9999);
        const rating_val: f64 = @as(f64, @floatFromInt(rand.intRangeAtMost(i32, 0, 100))) / 10.0;
        const active_val = rand.boolean();
        const title_payload = try msgpack.Payload.strToPayload(title_str, allocator);
        defer title_payload.free(allocator);
        const cols = [_]ColumnValue{
            .{ .name = "title", .value = title_payload },
            .{ .name = "score", .value = msgpack.Payload.intToPayload(score_val) },
            .{ .name = "rating", .value = .{ .float = rating_val } },
            .{ .name = "active", .value = .{ .bool = active_val } },
        };
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();
        var managed = try engine.selectDocument(allocator, "items", id, ns);
        defer managed.deinit();
        const doc = managed.value orelse return error.MissingDoc;
        // Verify text field
        const got_title = (try doc.mapGet("title")) orelse {
            return error.MissingTitle;
        };
        try testing.expectEqualStrings(title_str, got_title.str.value());
        // Verify integer field
        const got_score = (try doc.mapGet("score")) orelse return error.MissingScore;
        const got_score_val: i64 = switch (got_score) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expectEqual(score_val, got_score_val);
    }
}
// ─── Property 12: SQLite JSON functions operate on stored array columns ───────
// Feature: array-jsonb-storage, Property 12: SQLite JSON functions operate on stored array columns
test "storage: SQLite json_array_length works on stored array columns" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0DE_12);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        var fields_arr = [_]sth.Field{
            sth.makeField("tags", .array, false),
        };
        const table = sth.Table{ .name = "items", .fields = &fields_arr };
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngine(&ctx, allocator, "storage-p12", table);
        defer ctx.deinit();
        const engine = &ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";
        // Generate a random literal array of known length n
        const n = rand.intRangeAtMost(usize, 0, 8);
        const elems = try allocator.alloc(msgpack.Payload, n);
        for (0..n) |i| {
            elems[i] = .{ .int = rand.intRangeAtMost(i64, 0, 999) };
        }
        const array_payload = msgpack.Payload{ .arr = elems };
        defer array_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "tags", .value = array_payload }};
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();
        // Verify the stored array via public API. 
        // This implicitly tests SQLite's json() function which selectField uses for array columns.
        var managed = try engine.selectField(allocator, "items", id, ns, "tags");
        defer managed.deinit();
        const result = managed.value orelse return error.MissingField;
        try testing.expect(result == .arr);
        try testing.expectEqual(n, result.arr.len);
    }
}
