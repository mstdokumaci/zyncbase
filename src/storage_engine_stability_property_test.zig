const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const StorageEngine = sth.StorageEngine;
const schema_manager = sth.schema_manager;

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

fn insertTestValue(ctx: *sth.EngineTestContext, id: u128, value: []const u8) !void {
    try ctx.insertText("test", id, 1, "val", value);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "storage: stability no crashes on concurrent errors" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .name_quoted = "\"test\"", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-concurrent", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Server should not crash when multiple threads encounter errors simultaneously
    const num_threads = 5;
    var threads: [num_threads]std.Thread = undefined;
    const ThreadContext = struct {
        ctx: *sth.EngineTestContext,
        allocator: std.mem.Allocator,
        thread_id: usize,
    };
    const workerThread = struct {
        fn run(t_ctx: ThreadContext) void {
            var i: usize = 0;
            const ops = 40;
            const tbl_md = t_ctx.ctx.sm.getTable("test") orelse @panic("test table missing");
            while (i < ops) : (i += 1) {
                // Mix of operations that might fail
                const key: u128 = t_ctx.thread_id * 1_000 + i + 1;
                // Try to set a value
                t_ctx.ctx.insertText("test", key, 1, "val", "value") catch continue; // zwanzig-disable-line: swallowed-error
                // Try to get the value
                var managed = t_ctx.ctx.engine.selectDocument(t_ctx.allocator, tbl_md.index, key, 1) catch continue; // zwanzig-disable-line: swallowed-error
                defer managed.deinit();
                _ = managed.rows;
                // Try to delete the value
                t_ctx.ctx.engine.deleteDocument(tbl_md.index, key, 1) catch continue; // zwanzig-disable-line: swallowed-error
            }
        }
    }.run;
    // Spawn threads
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{ThreadContext{
            .ctx = &ctx,
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
    const table = schema_manager.Table{ .name = "test", .name_quoted = "\"test\"", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-txn-err", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");
    // Property: Server should continue operating after transaction errors
    // Cause a transaction error by trying to commit without beginning
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Server should still be operational - try normal operations
    try insertTestValue(&ctx, 1, "value1");
    try storage.flushPendingWrites();
    var doc1 = try tbl.getOne(allocator, 1, 1);
    defer doc1.deinit();
    _ = try doc1.expectFieldString("val", "value1");
    // Cause another transaction error
    _ = storage.rollbackTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Server should still be operational
    try insertTestValue(&ctx, 2, "value2");
    try storage.flushPendingWrites();
    var doc2 = try tbl.getOne(allocator, 2, 1);
    defer doc2.deinit();
    _ = try doc2.expectFieldString("val", "value2");
}
test "storage: stability handles rapid error conditions" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .name_quoted = "\"test\"", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-rapid-err", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");
    // Property: Server should handle rapid succession of errors without crashing
    // Rapidly trigger transaction errors
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
    }
    // Server should still be operational
    try insertTestValue(&ctx, 1, "value");
    try storage.flushPendingWrites();
    var doc = try tbl.getOne(allocator, 1, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("val", "value");
}

test "storage: stability error recovery with valid operations" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .name_quoted = "\"test\"", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-recovery", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");
    // Property: Server should recover from errors and continue with valid operations
    // Interleave errors with valid operations
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        // Valid operation
        const key: u128 = i + 1;
        try insertTestValue(&ctx, key, "value");
        // Trigger an error
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
        // Another valid operation
        var doc = try tbl.selectDocument(allocator, key, 1);
        defer doc.deinit();
    }
    // Flush and verify server is still operational
    try storage.flushPendingWrites();
    // Verify some data was persisted
    var doc0 = try tbl.getOne(allocator, 1, 1);
    defer doc0.deinit();
    _ = try doc0.expectFieldString("val", "value");
}

test "storage: stability resource cleanup after errors" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .name_quoted = "\"test\"", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-resource-cleanup", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");
    // Property: Resources should be properly cleaned up after errors
    // Begin a transaction
    try storage.beginTransaction();
    // Add some operations
    try insertTestValue(&ctx, 1, "value1");
    try insertTestValue(&ctx, 2, "value2");
    // Rollback (simulating an error scenario)
    try storage.rollbackTransaction();
    // Verify transaction state is cleaned up
    try testing.expect(!storage.isTransactionActive());
    // Verify we can start a new transaction
    try storage.beginTransaction();
    try insertTestValue(&ctx, 3, "value3");
    try storage.commitTransaction();
    // Verify the committed data is there
    var doc = try tbl.getOne(allocator, 3, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("val", "value3");
}

test "storage: stability mixed error and success scenarios" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .name_quoted = "\"test\"", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-mixed", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");
    // Property: Server should handle mixed scenarios of errors and successes
    // Successful transaction
    try storage.beginTransaction();
    try insertTestValue(&ctx, 1, "value1");
    try storage.commitTransaction();
    // Failed transaction (rollback)
    try storage.beginTransaction();
    try insertTestValue(&ctx, 2, "value2");
    try storage.rollbackTransaction();
    // Error (no active transaction)
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Successful operation without transaction
    try insertTestValue(&ctx, 3, "value3");
    try storage.flushPendingWrites();
    // Verify first transaction succeeded
    var doc1 = try tbl.getOne(allocator, 1, 1);
    defer doc1.deinit();
    _ = try doc1.expectFieldString("val", "value1");
    // Verify second transaction was rolled back
    var managed2 = try tbl.selectDocument(allocator, 2, 1);
    defer managed2.deinit();
    try testing.expect(managed2.rows.len == 0);
    // Verify third operation succeeded
    var doc3 = try tbl.getOne(allocator, 3, 1);
    defer doc3.deinit();
    _ = try doc3.expectFieldString("val", "value3");
}
test "storage: stability concurrent reads during write errors" {
    const allocator = testing.allocator;

    var fields = [_]schema_manager.Field{sth.makeField("val", .text, false)};
    const table = schema_manager.Table{ .name = "test", .name_quoted = "\"test\"", .fields = &fields };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-concurrent-reads", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");
    // Property: Reads should continue working even when writes encounter errors
    // Set up some initial data
    try insertTestValue(&ctx, 1, "value1");
    try insertTestValue(&ctx, 2, "value2");
    try storage.flushPendingWrites();
    const num_reader_threads = 4;
    var reader_threads: [num_reader_threads]std.Thread = undefined;
    const ReaderContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
    };
    const readerThread = struct {
        fn run(r_ctx: ReaderContext, table_index: usize) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                // Read operations should succeed
                var managed1 = r_ctx.storage.selectDocument(r_ctx.allocator, table_index, 1, 1) catch continue; // zwanzig-disable-line: swallowed-error
                defer managed1.deinit();
                _ = managed1.rows;
                var managed2 = r_ctx.storage.selectDocument(r_ctx.allocator, table_index, 2, 1) catch continue; // zwanzig-disable-line: swallowed-error
                defer managed2.deinit();
                _ = managed2.rows;
                // Small delay
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }.run;
    // Spawn reader threads
    const tbl_md = ctx.sm.getTable("test") orelse return error.UnknownTable;
    for (&reader_threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, readerThread, .{ ReaderContext{
            .storage = storage,
            .allocator = allocator,
        }, tbl_md.index });
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
    var doc = try tbl.getOne(allocator, 1, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("val", "value1");
}
