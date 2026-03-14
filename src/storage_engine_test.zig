const std = @import("std");
const testing = std.testing;
const StorageEngine = @import("storage_engine.zig").StorageEngine;

test "StorageEngine: init and deinit" {
    const allocator = testing.allocator;

    // Create temporary directory for test
    const test_dir = "test-artifacts/unit/storage_engine/test_data_init";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ test_dir, "zyncbase.db" });
    defer allocator.free(db_path);

    const file = try std.fs.cwd().openFile(db_path, .{});
    file.close();
}

test "StorageEngine: set and get" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_set_get";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set a value
    try engine.set("test_namespace", "/path/to/key", "{\"value\":\"test\"}");

    // Flush writes
    try engine.flushPendingWrites();

    // Get the value
    const value = try engine.get("test_namespace", "/path/to/key");
    defer if (value) |v| allocator.free(v);

    try testing.expect(value != null);
    try testing.expectEqualStrings("{\"value\":\"test\"}", value.?);
}

test "StorageEngine: get non-existent key" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_get_nonexistent";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    const value = try engine.get("test_namespace", "/nonexistent");
    try testing.expect(value == null);
}

test "StorageEngine: update existing key" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_update";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set initial value
    try engine.set("test_namespace", "/key", "{\"value\":\"initial\"}");
    try engine.flushPendingWrites();

    // Update value
    try engine.set("test_namespace", "/key", "{\"value\":\"updated\"}");
    try engine.flushPendingWrites();

    // Get the value
    const value = try engine.get("test_namespace", "/key");
    defer if (value) |v| allocator.free(v);

    try testing.expect(value != null);
    try testing.expectEqualStrings("{\"value\":\"updated\"}", value.?);
}

test "StorageEngine: delete key" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_delete";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set a value
    try engine.set("test_namespace", "/key", "{\"value\":\"test\"}");
    try engine.flushPendingWrites();

    // Verify it exists
    const value1 = try engine.get("test_namespace", "/key");
    defer if (value1) |v| allocator.free(v);
    try testing.expect(value1 != null);

    // Delete the key
    try engine.delete("test_namespace", "/key");
    try engine.flushPendingWrites();

    // Verify it's gone
    const value2 = try engine.get("test_namespace", "/key");
    try testing.expect(value2 == null);
}

test "StorageEngine: query with prefix" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_query";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set multiple values with same prefix
    try engine.set("test_namespace", "/users/1", "{\"name\":\"Alice\"}");
    try engine.set("test_namespace", "/users/2", "{\"name\":\"Bob\"}");
    try engine.set("test_namespace", "/posts/1", "{\"title\":\"Post 1\"}");
    try engine.flushPendingWrites();

    // Query for /users/ prefix
    const results = try engine.query("test_namespace", "/users/");
    defer {
        for (results) |result| {
            allocator.free(result.path);
            allocator.free(result.value);
        }
        allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
}

test "StorageEngine: multiple namespaces" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_namespaces";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set values in different namespaces
    try engine.set("namespace1", "/key", "{\"value\":\"ns1\"}");
    try engine.set("namespace2", "/key", "{\"value\":\"ns2\"}");
    try engine.flushPendingWrites();

    // Get values from different namespaces
    const value1 = try engine.get("namespace1", "/key");
    defer if (value1) |v| allocator.free(v);
    const value2 = try engine.get("namespace2", "/key");
    defer if (value2) |v| allocator.free(v);

    try testing.expect(value1 != null);
    try testing.expect(value2 != null);
    try testing.expectEqualStrings("{\"value\":\"ns1\"}", value1.?);
    try testing.expectEqualStrings("{\"value\":\"ns2\"}", value2.?);
}

test "StorageEngine: transaction support" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_transaction";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

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

    const test_dir = "test-artifacts/unit/storage_engine/test_data_auto_rollback";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Queue some operations
    try engine.set("test_ns", "key1", "value1");
    try engine.set("test_ns", "key2", "value2");

    // Wait for operations to be processed
    try engine.flushPendingWrites();

    // Verify no transaction is active after batch completes
    try testing.expect(!engine.isTransactionActive());

    // Verify data was written
    const value1 = try engine.get("test_ns", "key1");
    defer if (value1) |v| allocator.free(v);
    try testing.expect(value1 != null);
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try engine.get("test_ns", "key2");
    defer if (value2) |v| allocator.free(v);
    try testing.expect(value2 != null);
    try testing.expectEqualStrings("value2", value2.?);
}

test "StorageEngine: concurrent reads" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_concurrent";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const engine = try StorageEngine.init(allocator, test_dir);
    defer engine.deinit();

    // Set some values
    try engine.set("test_namespace", "/key1", "{\"value\":\"test1\"}");
    try engine.set("test_namespace", "/key2", "{\"value\":\"test2\"}");
    try engine.flushPendingWrites();

    // Perform multiple concurrent reads
    const Thread = struct {
        fn readKey(eng: *StorageEngine, alloc: std.mem.Allocator, key: []const u8) !void {
            const value = try eng.get("test_namespace", key);
            defer if (value) |v| alloc.free(v);
            try testing.expect(value != null);
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const key = if (i % 2 == 0) "/key1" else "/key2";
        thread.* = try std.Thread.spawn(.{}, Thread.readKey, .{ engine, allocator, key });
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
    //
    // We verify the behavioral guarantee directly: enqueue writes, call deinit,
    // then reopen the same DB file and confirm every write was persisted.
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_deinit_flush";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const num_keys = 50;

    {
        const engine = try StorageEngine.init(allocator, test_dir);
        // Enqueue a burst of writes without waiting — deinit must flush them.
        for (0..num_keys) |i| {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "/key/{d}", .{i});
            try engine.set("ns", key, "1");
        }
        engine.deinit(); // must not return until all writes are on disk
    }

    // Reopen the same database and verify every key is present.
    const verify_engine = try StorageEngine.init(allocator, test_dir);
    defer verify_engine.deinit();

    for (0..num_keys) |i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "/key/{d}", .{i});
        const value = try verify_engine.get("ns", key);
        defer if (value) |v| allocator.free(v);
        try testing.expect(value != null);
    }
}
