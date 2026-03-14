const std = @import("std");

const testing = std.testing;
const StorageEngine = @import("storage_engine.zig").StorageEngine;

// **Property 24: Server stability on database errors**
// Storage engine stability properties
//
// This property test verifies that the server remains stable when database errors occur:
// 1. No panics or crashes on database errors
// 2. Server continues operating after database errors
// 3. Error recovery mechanisms work correctly
// 4. Concurrent operations remain safe during errors
//
// We test various error scenarios to ensure the server never crashes:
// - Multiple concurrent operations during errors
// - Rapid error conditions
// - Error recovery and retry logic
// - Resource cleanup after errors

test "storage: stability no crashes on concurrent errors" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/stability/concurrent_errors";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var storage = try StorageEngine.init(allocator, tmp_path);
    defer storage.deinit();

    // Property: Server should not crash when multiple threads encounter errors simultaneously
    const num_threads = 8;
    const operations_per_thread = 50;

    var threads: [num_threads]std.Thread = undefined;

    const ThreadContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
        thread_id: usize,
    };

    const workerThread = struct {
        fn run(ctx: ThreadContext) void {
            var i: usize = 0;
            while (i < operations_per_thread) : (i += 1) {
                // Mix of operations that might fail
                const key = std.fmt.allocPrint(ctx.allocator, "thread{}_key{}", .{ ctx.thread_id, i }) catch continue;
                defer ctx.allocator.free(key);

                // Try to set a value
                ctx.storage.set("test", key, "value") catch {
                    continue;
                };

                // Try to get the value
                const value = ctx.storage.get("test", key) catch {
                    continue;
                };
                if (value) |v| ctx.allocator.free(v);

                // Try to delete the value
                ctx.storage.delete("test", key) catch {
                    continue;
                };
            }
        }
    }.run;

    // Spawn threads
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{ThreadContext{
            .storage = storage,
            .allocator = allocator,
            .thread_id = i,
        }});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // If we reach here, the server didn't crash - test passes
    try storage.flushPendingWrites();
}

test "storage: stability continues after transaction errors" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/stability/transaction_errors";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var storage = try StorageEngine.init(allocator, tmp_path);
    defer storage.deinit();

    // Property: Server should continue operating after transaction errors

    // Cause a transaction error by trying to commit without beginning
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };

    // Server should still be operational - try normal operations
    try storage.set("test", "key1", "value1");
    try storage.flushPendingWrites();

    const value = try storage.get("test", "key1");
    try testing.expect(value != null);
    defer if (value) |v| allocator.free(v);

    // Cause another transaction error
    _ = storage.rollbackTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };

    // Server should still be operational
    try storage.set("test", "key2", "value2");
    try storage.flushPendingWrites();

    const value2 = try storage.get("test", "key2");
    try testing.expect(value2 != null);
    defer if (value2) |v| allocator.free(v);
}

test "storage: stability handles rapid error conditions" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/stability/rapid_errors";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var storage = try StorageEngine.init(allocator, tmp_path);
    defer storage.deinit();

    // Property: Server should handle rapid succession of errors without crashing

    // Rapidly trigger transaction errors
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
    }

    // Server should still be operational
    try storage.set("test", "key", "value");
    try storage.flushPendingWrites();

    const value = try storage.get("test", "key");
    try testing.expect(value != null);
    defer if (value) |v| allocator.free(v);
}

test "storage: stability error recovery with valid operations" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/stability/recovery";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var storage = try StorageEngine.init(allocator, tmp_path);
    defer storage.deinit();

    // Property: Server should recover from errors and continue with valid operations

    // Interleave errors with valid operations
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        // Valid operation
        const key = try std.fmt.allocPrint(allocator, "key{}", .{i});
        defer allocator.free(key);

        try storage.set("test", key, "value");

        // Trigger an error
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };

        // Another valid operation
        const value = try storage.get("test", key);
        if (value) |v| allocator.free(v);
    }

    // Flush and verify server is still operational
    try storage.flushPendingWrites();

    // Verify some data was persisted
    const value = try storage.get("test", "key0");
    try testing.expect(value != null);
    defer if (value) |v| allocator.free(v);
}

test "storage: stability resource cleanup after errors" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/stability/resource_cleanup";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var storage = try StorageEngine.init(allocator, tmp_path);
    defer storage.deinit();

    // Property: Resources should be properly cleaned up after errors

    // Begin a transaction
    try storage.beginTransaction();

    // Add some operations
    try storage.set("test", "key1", "value1");
    try storage.set("test", "key2", "value2");

    // Rollback (simulating an error scenario)
    try storage.rollbackTransaction();

    // Verify transaction state is cleaned up
    try testing.expect(!storage.isTransactionActive());

    // Verify we can start a new transaction
    try storage.beginTransaction();
    try storage.set("test", "key3", "value3");
    try storage.commitTransaction();

    // Verify the committed data is there
    const value = try storage.get("test", "key3");
    try testing.expect(value != null);
    defer if (value) |v| allocator.free(v);
}

test "storage: stability mixed error and success scenarios" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/stability/mixed_scenarios";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var storage = try StorageEngine.init(allocator, tmp_path);
    defer storage.deinit();

    // Property: Server should handle mixed scenarios of errors and successes

    // Successful transaction
    try storage.beginTransaction();
    try storage.set("test", "key1", "value1");
    try storage.commitTransaction();

    // Failed transaction (rollback)
    try storage.beginTransaction();
    try storage.set("test", "key2", "value2");
    try storage.rollbackTransaction();

    // Error (no active transaction)
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };

    // Successful operation without transaction
    try storage.set("test", "key3", "value3");
    try storage.flushPendingWrites();

    // Verify first transaction succeeded
    const value1 = try storage.get("test", "key1");
    try testing.expect(value1 != null);
    defer if (value1) |v| allocator.free(v);

    // Verify second transaction was rolled back
    const value2 = try storage.get("test", "key2");
    try testing.expect(value2 == null);

    // Verify third operation succeeded
    const value3 = try storage.get("test", "key3");
    try testing.expect(value3 != null);
    defer if (value3) |v| allocator.free(v);
}

test "storage: stability concurrent reads during write errors" {
    const allocator = testing.allocator;

    const tmp_path = "test-artifacts/stability/concurrent_reads";
    std.fs.cwd().makePath(tmp_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var storage = try StorageEngine.init(allocator, tmp_path);
    defer storage.deinit();

    // Property: Reads should continue working even when writes encounter errors

    // Set up some initial data
    try storage.set("test", "key1", "value1");
    try storage.set("test", "key2", "value2");
    try storage.flushPendingWrites();

    const num_reader_threads = 4;
    var reader_threads: [num_reader_threads]std.Thread = undefined;

    const ReaderContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
    };

    const readerThread = struct {
        fn run(ctx: ReaderContext) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                // Read operations should succeed
                const value1 = ctx.storage.get("test", "key1") catch continue;
                defer if (value1) |v| ctx.allocator.free(v);

                const value2 = ctx.storage.get("test", "key2") catch continue;
                defer if (value2) |v| ctx.allocator.free(v);

                // Small delay
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }.run;

    // Spawn reader threads
    for (&reader_threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, readerThread, .{ReaderContext{
            .storage = storage,
            .allocator = allocator,
        }});
    }

    // Meanwhile, cause some transaction errors
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    // Wait for reader threads
    for (reader_threads) |thread| {
        thread.join();
    }

    // Verify data is still intact
    const value1 = try storage.get("test", "key1");
    try testing.expect(value1 != null);
    defer if (value1) |v| allocator.free(v);
}
