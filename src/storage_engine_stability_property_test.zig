const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const sth = @import("storage_engine_test_helpers.zig");
const StorageEngine = storage_engine.StorageEngine;
const schema_manager = @import("schema_manager.zig");

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

// ─── Tests ───────────────────────────────────────────────────────────────────

test "storage: stability no crashes on concurrent errors" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-concurrent", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Server should not crash when multiple threads encounter errors simultaneously
    const num_threads = 5;
    var threads: [num_threads]std.Thread = undefined;
    const ThreadContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
        thread_id: usize,
    };
    const workerThread = struct {
        fn run(t_ctx: ThreadContext) void {
            var i: usize = 0;
            const ops = 40;
            while (i < ops) : (i += 1) {
                // Mix of operations that might fail
                const key = std.fmt.allocPrint(t_ctx.allocator, "thread{}_key{}", .{ t_ctx.thread_id, i }) catch continue; // zwanzig-disable-line: swallowed-error
                defer t_ctx.allocator.free(key);
                // Try to set a value
                sth.enqueueDocumentWrite(t_ctx.storage, "test", key, "test", &.{
                    .{ .name = "val", .field_type = .text, .value = .{ .text = key } },
                }) catch continue; // zwanzig-disable-line: swallowed-error
                // Try to get the value
                var managed = t_ctx.storage.selectDocument(t_ctx.allocator, "test", key, "test") catch continue; // zwanzig-disable-line: swallowed-error
                defer managed.deinit();
                _ = managed.value;
                // Try to delete the value
                t_ctx.storage.deleteDocument("test", key, "test") catch continue; // zwanzig-disable-line: swallowed-error
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

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-txn-err", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Server should continue operating after transaction errors
    // Cause a transaction error by trying to commit without beginning
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Server should still be operational - try normal operations
    try sth.enqueueDocumentWrite(storage, "test", "key1", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value1" } },
    });
    try storage.flushPendingWrites();
    var managed = try storage.selectDocument(allocator, "test", "key1", "test");
    defer managed.deinit();
    const doc = managed.value;
    try testing.expect(doc != null);
    // Cause another transaction error
    _ = storage.rollbackTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Server should still be operational
    try sth.enqueueDocumentWrite(storage, "test", "key2", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value2" } },
    });
    try storage.flushPendingWrites();
    var managed2 = try storage.selectDocument(allocator, "test", "key2", "test");
    defer managed2.deinit();
    const doc2 = managed2.value;
    try testing.expect(doc2 != null);
}
test "storage: stability handles rapid error conditions" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-rapid-err", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Server should handle rapid succession of errors without crashing
    // Rapidly trigger transaction errors
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
    }
    // Server should still be operational
    try sth.enqueueDocumentWrite(storage, "test", "key", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value" } },
    });
    try storage.flushPendingWrites();
    var managed = try storage.selectDocument(allocator, "test", "key", "test");
    defer managed.deinit();
    const doc = managed.value;
    try testing.expect(doc != null);
}
test "storage: stability error recovery with valid operations" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-recovery", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Server should recover from errors and continue with valid operations
    // Interleave errors with valid operations
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        // Valid operation
        const key = try std.fmt.allocPrint(allocator, "key{}", .{i});
        defer allocator.free(key);
        try sth.enqueueDocumentWrite(storage, "test", key, "test", &.{
            .{ .name = "val", .field_type = .text, .value = .{ .text = "value" } },
        });
        // Trigger an error
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
        // Another valid operation
        var managed = try storage.selectDocument(allocator, "test", key, "test");
        defer managed.deinit();
        _ = managed.value;
    }
    // Flush and verify server is still operational
    try storage.flushPendingWrites();
    // Verify some data was persisted
    var managed = try storage.selectDocument(allocator, "test", "key0", "test");
    defer managed.deinit();
    const doc = managed.value;
    try testing.expect(doc != null);
}
test "storage: stability resource cleanup after errors" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-resource-cleanup", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Resources should be properly cleaned up after errors
    // Begin a transaction
    try storage.beginTransaction();
    // Add some operations
    try sth.enqueueDocumentWrite(storage, "test", "key1", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value1" } },
    });
    try sth.enqueueDocumentWrite(storage, "test", "key2", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value2" } },
    });
    // Rollback (simulating an error scenario)
    try storage.rollbackTransaction();
    // Verify transaction state is cleaned up
    try testing.expect(!storage.isTransactionActive());
    // Verify we can start a new transaction
    try storage.beginTransaction();
    try sth.enqueueDocumentWrite(storage, "test", "key3", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value3" } },
    });
    try storage.commitTransaction();
    // Verify the committed data is there
    var managed = try storage.selectDocument(allocator, "test", "key3", "test");
    defer managed.deinit();
    const doc = managed.value;
    try testing.expect(doc != null);
}
test "storage: stability mixed error and success scenarios" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-mixed", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Server should handle mixed scenarios of errors and successes
    // Successful transaction
    try storage.beginTransaction();
    try sth.enqueueDocumentWrite(storage, "test", "key1", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value1" } },
    });
    try storage.commitTransaction();
    // Failed transaction (rollback)
    try storage.beginTransaction();
    try sth.enqueueDocumentWrite(storage, "test", "key2", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value2" } },
    });
    try storage.rollbackTransaction();
    // Error (no active transaction)
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Successful operation without transaction
    try sth.enqueueDocumentWrite(storage, "test", "key3", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value3" } },
    });
    try storage.flushPendingWrites();
    // Verify first transaction succeeded
    var managed1 = try storage.selectDocument(allocator, "test", "key1", "test");
    defer managed1.deinit();
    const doc1 = managed1.value;
    try testing.expect(doc1 != null);
    // Verify second transaction was rolled back
    var managed2 = try storage.selectDocument(allocator, "test", "key2", "test");
    defer managed2.deinit();
    const doc2 = managed2.value;
    try testing.expect(doc2 == null);
    // Verify third operation succeeded
    var managed3 = try storage.selectDocument(allocator, "test", "key3", "test");
    defer managed3.deinit();
    const doc3 = managed3.value;
    try testing.expect(doc3 != null);
}
test "storage: stability concurrent reads during write errors" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-concurrent-reads", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Reads should continue working even when writes encounter errors
    // Set up some initial data
    try sth.enqueueDocumentWrite(storage, "test", "key1", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value1" } },
    });
    try sth.enqueueDocumentWrite(storage, "test", "key2", "test", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value2" } },
    });
    try storage.flushPendingWrites();
    const num_reader_threads = 4;
    var reader_threads: [num_reader_threads]std.Thread = undefined;
    const ReaderContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
    };
    const readerThread = struct {
        fn run(r_ctx: ReaderContext) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                // Read operations should succeed
                var managed1 = r_ctx.storage.selectDocument(r_ctx.allocator, "test", "key1", "test") catch continue; // zwanzig-disable-line: swallowed-error
                defer managed1.deinit();
                _ = managed1.value;
                var managed2 = r_ctx.storage.selectDocument(r_ctx.allocator, "test", "key2", "test") catch continue; // zwanzig-disable-line: swallowed-error
                defer managed2.deinit();
                _ = managed2.value;
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
    var managed = try storage.selectDocument(allocator, "test", "key1", "test");
    defer managed.deinit();
    const doc1 = managed.value;
    try testing.expect(doc1 != null);
}
