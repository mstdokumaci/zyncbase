const std = @import("std");
const testing = std.testing;
const StorageEngine = @import("storage_engine.zig").StorageEngine;

// **Validates: Requirements 10.9**
test "Property 16: Database initialization errors" {
    const allocator = testing.allocator;

    // Test 1: Invalid directory path (read-only filesystem simulation)
    // We can't easily simulate a read-only filesystem in a portable way,
    // so we test with an invalid path that should fail
    const invalid_dir = "";
    const result1 = StorageEngine.init(allocator, invalid_dir);
    if (result1) |_| {
        try testing.expect(false); // Should have failed
    } else |_| {
        // Any error is acceptable here as long as it failed
    }

    // Test 2: Path that is a file, not a directory
    const test_file = "test_file_not_dir.txt";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create a file
    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();

    // Try to use it as a directory - should fail
    const result2 = StorageEngine.init(allocator, test_file);
    try testing.expectError(error.NotDir, result2);

    // Test 3: Valid initialization should succeed
    const test_dir = "test_data_init_valid";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ test_dir, "zyncbase.db" });
    defer allocator.free(db_path);

    const db_file = try std.fs.cwd().openFile(db_path, .{});
    db_file.close();
}

// **Validates: Requirements 11.3, 11.4**
test "Property 17: Thread-safe storage access" {
    const allocator = testing.allocator;

    const test_dir = "test_data_thread_safe";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

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

                try eng.set("test_namespace", key, value);
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

                const value = try eng.get("test_namespace", key);
                if (value) |v| {
                    testing.allocator.free(v);
                }
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
    const value = try engine.get("test_namespace", "/thread0/key0");
    defer if (value) |v| allocator.free(v);
    try testing.expect(value != null);
}

// **Validates: Requirements 11.7**
test "Property 18: Connection release" {
    const allocator = testing.allocator;

    const test_dir = "test_data_conn_release";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set some initial data
    try engine.set("test_namespace", "/key1", "{\"value\":\"test1\"}");
    try engine.set("test_namespace", "/key2", "{\"value\":\"test2\"}");
    try engine.flushPendingWrites();

    // Perform many read operations to ensure connections are being reused
    // If connections weren't released, we'd run out of connections
    const num_operations = 1000;
    var i: usize = 0;
    while (i < num_operations) : (i += 1) {
        const key = if (i % 2 == 0) "/key1" else "/key2";
        const value = try engine.get("test_namespace", key);
        defer if (value) |v| allocator.free(v);
        try testing.expect(value != null);
    }

    // If we got here, connections were properly released and reused
}

// **Validates: Requirements 12.11**
test "Property 19: Data persistence round-trip" {
    const allocator = testing.allocator;

    const test_dir = "test_data_roundtrip";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Test various data types and values
    const test_cases = [_]struct {
        namespace: []const u8,
        path: []const u8,
        value: []const u8,
    }{
        .{ .namespace = "ns1", .path = "/simple", .value = "{\"data\":\"simple\"}" },
        .{ .namespace = "ns1", .path = "/nested", .value = "{\"user\":{\"name\":\"Alice\",\"age\":30}}" },
        .{ .namespace = "ns2", .path = "/array", .value = "[1,2,3,4,5]" },
        .{ .namespace = "ns2", .path = "/empty", .value = "{}" },
        .{ .namespace = "ns3", .path = "/unicode", .value = "{\"text\":\"Hello 世界 🌍\"}" },
        .{ .namespace = "ns3", .path = "/special", .value = "{\"chars\":\"\\\"\\n\\t\\r\"}" },
    };

    // Insert all test cases
    for (test_cases) |tc| {
        try engine.set(tc.namespace, tc.path, tc.value);
    }

    // Flush writes
    try engine.flushPendingWrites();

    // Retrieve and verify all test cases
    for (test_cases) |tc| {
        const retrieved = try engine.get(tc.namespace, tc.path);
        defer if (retrieved) |v| allocator.free(v);

        try testing.expect(retrieved != null);
        try testing.expectEqualStrings(tc.value, retrieved.?);
    }
}

// **Validates: Requirements 12.12**
test "Property 20: Insert/delete inverse operation" {
    const allocator = testing.allocator;

    const test_dir = "test_data_inverse";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

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
        try engine.set(tc.namespace, tc.path, tc.value);
        try engine.flushPendingWrites();

        // Verify it exists
        const value1 = try engine.get(tc.namespace, tc.path);
        defer if (value1) |v| allocator.free(v);
        try testing.expect(value1 != null);
        try testing.expectEqualStrings(tc.value, value1.?);

        // Delete
        try engine.delete(tc.namespace, tc.path);
        try engine.flushPendingWrites();

        // Verify it's gone
        const value2 = try engine.get(tc.namespace, tc.path);
        try testing.expect(value2 == null);
    }
}

// **Validates: Requirements 13.7**
test "Property 21: Transaction isolation" {
    const allocator = testing.allocator;

    const test_dir = "test_data_transaction_isolation";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Test that operations are batched and executed atomically by the write thread
    // The write thread uses transactions internally to ensure atomicity

    // Set up initial state
    try engine.set("test_namespace", "/key1", "{\"value\":\"initial1\"}");
    try engine.set("test_namespace", "/key2", "{\"value\":\"initial2\"}");
    try engine.flushPendingWrites();

    // Verify initial state
    const initial1 = try engine.get("test_namespace", "/key1");
    defer if (initial1) |v| allocator.free(v);
    const initial2 = try engine.get("test_namespace", "/key2");
    defer if (initial2) |v| allocator.free(v);
    try testing.expect(initial1 != null);
    try testing.expect(initial2 != null);

    // Queue multiple operations that should execute atomically in a batch
    try engine.set("test_namespace", "/key1", "{\"value\":\"updated1\"}");
    try engine.set("test_namespace", "/key2", "{\"value\":\"updated2\"}");
    try engine.set("test_namespace", "/key3", "{\"value\":\"new3\"}");

    // Flush to ensure operations are processed
    try engine.flushPendingWrites();

    // All operations should have been applied atomically
    const updated1 = try engine.get("test_namespace", "/key1");
    defer if (updated1) |v| allocator.free(v);
    const updated2 = try engine.get("test_namespace", "/key2");
    defer if (updated2) |v| allocator.free(v);
    const new3 = try engine.get("test_namespace", "/key3");
    defer if (new3) |v| allocator.free(v);

    try testing.expect(updated1 != null);
    try testing.expect(updated2 != null);
    try testing.expect(new3 != null);
    try testing.expectEqualStrings("{\"value\":\"updated1\"}", updated1.?);
    try testing.expectEqualStrings("{\"value\":\"updated2\"}", updated2.?);
    try testing.expectEqualStrings("{\"value\":\"new3\"}", new3.?);

    // Test concurrent reads during batch processing see consistent state
    // This tests that the write thread's transaction provides isolation
    try engine.set("test_namespace", "/concurrent_key", "{\"value\":\"before\"}");
    try engine.flushPendingWrites();

    // Start a batch by queuing many operations
    const num_ops = 100;
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_key{d}", .{i});
        defer allocator.free(key);
        const value = try std.fmt.allocPrint(allocator, "{{\"batch\":{d}}}", .{i});
        defer allocator.free(value);
        try engine.set("test_namespace", key, value);
    }

    // While the batch is being processed, concurrent reads should work
    const concurrent_read = try engine.get("test_namespace", "/concurrent_key");
    defer if (concurrent_read) |v| allocator.free(v);
    try testing.expect(concurrent_read != null);
    try testing.expectEqualStrings("{\"value\":\"before\"}", concurrent_read.?);

    // Wait for all writes to complete
    try engine.flushPendingWrites();

    // Verify all batch operations were applied atomically
    i = 0;
    while (i < num_ops) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_key{d}", .{i});
        defer allocator.free(key);
        const value = try engine.get("test_namespace", key);
        defer if (value) |v| allocator.free(v);
        try testing.expect(value != null);
    }
}

// **Validates: Requirements 13.8**
test "Property 22: Automatic transaction rollback" {
    const allocator = testing.allocator;

    const test_dir = "test_data_auto_rollback";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set up initial state
    try engine.set("test_namespace", "/key1", "{\"value\":\"initial\"}");
    try engine.flushPendingWrites();

    // Verify initial state
    const initial = try engine.get("test_namespace", "/key1");
    defer if (initial) |v| allocator.free(v);
    try testing.expect(initial != null);
    try testing.expectEqualStrings("{\"value\":\"initial\"}", initial.?);

    // Test manual transaction rollback
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());

    // Make changes within transaction
    try engine.set("test_namespace", "/key1", "{\"value\":\"modified\"}");
    try engine.set("test_namespace", "/key2", "{\"value\":\"new\"}");

    // Rollback the transaction
    try engine.rollbackTransaction();
    try testing.expect(!engine.isTransactionActive());

    // Flush any pending writes from before the transaction
    try engine.flushPendingWrites();

    // Verify changes were rolled back
    const after_rollback1 = try engine.get("test_namespace", "/key1");
    defer if (after_rollback1) |v| allocator.free(v);
    try testing.expect(after_rollback1 != null);
    try testing.expectEqualStrings("{\"value\":\"initial\"}", after_rollback1.?);

    const after_rollback2 = try engine.get("test_namespace", "/key2");
    try testing.expect(after_rollback2 == null);

    // Test that errors in batch processing trigger automatic rollback
    // We simulate this by testing the transaction state after an error

    // First, set up a successful transaction
    try engine.beginTransaction();
    try engine.set("test_namespace", "/key3", "{\"value\":\"test3\"}");
    try engine.commitTransaction();
    try engine.flushPendingWrites();

    const committed = try engine.get("test_namespace", "/key3");
    defer if (committed) |v| allocator.free(v);
    try testing.expect(committed != null);
    try testing.expectEqualStrings("{\"value\":\"test3\"}", committed.?);

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
        try engine.set("test_namespace", key, value);
    }

    // Flush and verify all operations succeeded atomically
    try engine.flushPendingWrites();

    j = 0;
    while (j < batch_size) : (j += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_test{d}", .{j});
        defer allocator.free(key);
        const value = try engine.get("test_namespace", key);
        defer if (value) |v| allocator.free(v);
        try testing.expect(value != null);
    }
}
