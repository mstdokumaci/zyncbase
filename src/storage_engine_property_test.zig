const std = @import("std");
const testing = std.testing;
const StorageEngine = @import("storage_engine.zig").StorageEngine;

// **Validates: Requirements 10.9**
test "Property 16: Database initialization errors" {
    const allocator = testing.allocator;

    // Test 1: Invalid directory path (read-only filesystem simulation)
    // We can't easily simulate a read-only filesystem in a portable way,
    // so we test with an invalid path that should fail
    const invalid_dir = "/proc/invalid_test_dir_that_should_not_exist_12345";
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
