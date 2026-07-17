const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const schema_helpers = @import("schema/test_helpers.zig");
const qth = @import("query/test_helpers.zig");
const tth = @import("typed/test_helpers.zig");
const StorageEngine = sth.StorageEngine;

test "storage: engine initialization errors" {
    const allocator = testing.allocator;
    var ms: sth.MemoryStrategy = undefined;
    try ms.init(allocator);
    defer std.debug.assert(ms.deinit() == .ok);

    // Test 1: Invalid directory path
    const invalid_dir = "";
    var sm1 = try sth.createDummySchema(allocator);
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

    var sm2 = try sth.createDummySchema(allocator);
    defer sm2.deinit();
    var engine2: StorageEngine = undefined;
    const result2 = engine2.init(allocator, &ms, test_file, &sm2, .{}, .{ .in_memory = false }, null, null);
    try testing.expectError(error.NotDir, result2);

    // Test 3: Valid initialization should succeed
    var context_valid = try sth.TestContext.init(allocator, "storage-init-valid");
    defer context_valid.deinit();
    const test_dir = context_valid.test_dir;

    var sm3 = try sth.createDummySchema(allocator);
    defer sm3.deinit();
    var engine3: StorageEngine = undefined;
    try engine3.init(allocator, &ms, test_dir, &sm3, .{}, .{ .in_memory = false, .reader_pool_size = 1 }, null, null);
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
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
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
                try t_ctx.ctx.insertField("test", key, 1, "val", tth.valText(value));
            }
        }
    };
    const ReadThread = struct {
        fn run(eng: *StorageEngine, table_index: usize, thread_id: usize) !void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const key: u128 = (thread_id % (num_threads / 2)) * 1_000 + i + 1;
                const record = try sth.readDoc(testing.allocator, eng, table_index, key, 1);
                defer if (record) |r| r.deinit(testing.allocator);
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
    const record = try test_table.readDoc(allocator, 1, 1);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
}

test "storage: connection pool reuse and release" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "prop-many-ns", table);
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
        const record = try test_table.readDoc(testing.allocator, key, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
    // If we got here, connections were properly released and reused
}

test "storage: persistence round-trip (various types)" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "prop-burst", table);
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
    }
}

test "storage: insert/delete inverse consistency" {
    const allocator = testing.allocator;
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
        try engine.deleteDocument(test_table.metadata.index, tc.id, tc.namespace_id, null, null, null);
        try engine.flushPendingWrites();
        // Verify it's gone
        const record2 = try test_table.readDoc(allocator, tc.id, tc.namespace_id);
        defer if (record2) |r| r.deinit(allocator);
        try testing.expect(record2 == null);
    }
}

test "storage: transaction isolation and consistency" {
    const allocator = testing.allocator;
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
}

test "storage: concurrent batch processing" {
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
        defer ctx.deinit();

        const test_table = try ctx.table("test");
        const record = try test_table.readDoc(allocator, 1, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
}

// Property: Schema updates are reflected in persistence logic
test "storage: schema update integrity" {
    const allocator = testing.allocator;
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
        defer ctx.deinit();

        const test_table = try ctx.table("test");

        // Existing data should be accessible
        const record1 = try test_table.readDoc(allocator, 1, 1);
        defer if (record1) |r| r.deinit(allocator);
        try testing.expect(record1 != null);

        // New data with new field
        try ctx.insertInt("test", 2, 1, "val2", 42);
        try ctx.engine.flushPendingWrites();

        const record2 = try test_table.readDoc(allocator, 2, 1);
        defer if (record2) |r| r.deinit(allocator);
        try testing.expect(record2 != null);
    }
}

// Fuzzy testing of random operations to ensure no crashes
test "storage: random operations fuzzing" {
    const allocator = testing.allocator;
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
                try engine.deleteDocument(0, id, ns, null, null, null);
            },
            2 => {
                // Query
                const test_table = try ctx.table("items");
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
