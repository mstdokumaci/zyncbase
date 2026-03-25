const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const msgpack = @import("msgpack_utils.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const schema_helpers = @import("schema_test_helpers.zig");

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

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn makeField(name: []const u8, sql_type: schema_parser.FieldType, required: bool) schema_parser.Field {
    return .{
        .name = name,
        .sql_type = sql_type,
        .required = required,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

fn setupEngineWithSchema(allocator: std.mem.Allocator, memory_strategy: *MemoryStrategy, test_dir: []const u8, table_name: []const u8, out_schema: *?*schema_parser.Schema) !*StorageEngine {
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = table_name, .fields = &fields_arr };

    const tables = try allocator.alloc(schema_parser.Table, 1);
    tables[0] = try table.clone(allocator);

    const schema = try allocator.create(schema_parser.Schema);
    schema.* = .{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };

    out_schema.* = schema;

    const engine = try StorageEngine.init(allocator, memory_strategy, test_dir, schema);

    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.execDDL(ddl_z);

    return engine;
}

test "storage: stability no crashes on concurrent errors" {
    const allocator = testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "stability-concurrent");
    defer context.deinit();
    const tmp_path = context.test_dir;

    var raw_dummy_fields = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var raw_dummy_tables = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &raw_dummy_fields }};
    const raw_dummy_schema = schema_parser.Schema{ .version = "1.0.0", .tables = &raw_dummy_tables };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage = try StorageEngine.init(allocator, &memory_strategy, tmp_path, &raw_dummy_schema);
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
                // zwanzig-disable-next-line: swallowed-error
                const key = std.fmt.allocPrint(ctx.allocator, "thread{}_key{}", .{ ctx.thread_id, i }) catch continue; // zwanzig-disable-line: swallowed-error
                defer ctx.allocator.free(key);
                // Try to set a value
                // zwanzig-disable-next-line: swallowed-error
                const val_payload = msgpack.Payload.strToPayload(key, ctx.allocator) catch continue; // zwanzig-disable-line: swallowed-error
                defer val_payload.free(ctx.allocator);
                const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
                // zwanzig-disable-next-line: swallowed-error
                ctx.storage.insertOrReplace("test", key, "test", &cols) catch continue; // zwanzig-disable-line: swallowed-error
                // Try to get the value
                // zwanzig-disable-next-line: swallowed-error
                const doc = ctx.storage.selectDocument("test", key, "test") catch continue; // zwanzig-disable-line: swallowed-error
                if (doc) |d| d.free(ctx.allocator);
                // Try to delete the value
                // zwanzig-disable-next-line: swallowed-error
                ctx.storage.deleteDocument("test", key, "test") catch continue; // zwanzig-disable-line: swallowed-error
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
    var context = try schema_helpers.TestContext.init(allocator, "stability-txn-err");
    defer context.deinit();
    const tmp_path = context.test_dir;
    var test_schema: ?*schema_parser.Schema = null;
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage = try setupEngineWithSchema(allocator, &memory_strategy, tmp_path, "test", &test_schema);
    defer {
        storage.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    // Property: Server should continue operating after transaction errors
    // Cause a transaction error by trying to commit without beginning
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Server should still be operational - try normal operations
    const val_payload = try msgpack.Payload.strToPayload("value1", allocator);
    defer val_payload.free(allocator);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
    try storage.insertOrReplace("test", "key1", "test", &cols);
    try storage.flushPendingWrites();
    const doc = try storage.selectDocument("test", "key1", "test");
    try testing.expect(doc != null);
    if (doc) |d| d.free(allocator);
    // Cause another transaction error
    _ = storage.rollbackTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Server should still be operational
    const val_payload2 = try msgpack.Payload.strToPayload("value2", allocator);
    defer val_payload2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
    try storage.insertOrReplace("test", "key2", "test", &cols2);
    try storage.flushPendingWrites();
    const doc2 = try storage.selectDocument("test", "key2", "test");
    try testing.expect(doc2 != null);
    if (doc2) |d| d.free(allocator);
}
test "storage: stability handles rapid error conditions" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "stability-rapid-err");
    defer context.deinit();
    const tmp_path = context.test_dir;
    var test_schema_1: ?*schema_parser.Schema = null;
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage = try setupEngineWithSchema(allocator, &memory_strategy, tmp_path, "test", &test_schema_1);
    defer {
        storage.deinit();
        if (test_schema_1) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    // Property: Server should handle rapid succession of errors without crashing
    // Rapidly trigger transaction errors
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
    }
    // Server should still be operational
    const val_payload = try msgpack.Payload.strToPayload("value", allocator);
    defer val_payload.free(allocator);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
    try storage.insertOrReplace("test", "key", "test", &cols);
    try storage.flushPendingWrites();
    const doc = try storage.selectDocument("test", "key", "test");
    try testing.expect(doc != null);
    if (doc) |d| d.free(allocator);
}
test "storage: stability error recovery with valid operations" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "stability-recovery");
    defer context.deinit();
    const tmp_path = context.test_dir;
    var test_schema_2: ?*schema_parser.Schema = null;
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage = try setupEngineWithSchema(allocator, &memory_strategy, tmp_path, "test", &test_schema_2);
    defer {
        storage.deinit();
        if (test_schema_2) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    // Property: Server should recover from errors and continue with valid operations
    // Interleave errors with valid operations
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        // Valid operation
        const key = try std.fmt.allocPrint(allocator, "key{}", .{i});
        defer allocator.free(key);
        const val_payload = try msgpack.Payload.strToPayload("value", allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("test", key, "test", &cols);
        // Trigger an error
        _ = storage.commitTransaction() catch |err| {
            try testing.expectEqual(error.NoActiveTransaction, err);
        };
        // Another valid operation
        const doc = try storage.selectDocument("test", key, "test");
        if (doc) |d| d.free(allocator);
    }
    // Flush and verify server is still operational
    try storage.flushPendingWrites();
    // Verify some data was persisted
    const doc = try storage.selectDocument("test", "key0", "test");
    try testing.expect(doc != null);
    if (doc) |d| d.free(allocator);
}
test "storage: stability resource cleanup after errors" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "stability-resource-cleanup");
    defer context.deinit();
    const tmp_path = context.test_dir;
    var test_schema_3: ?*schema_parser.Schema = null;
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage = try setupEngineWithSchema(allocator, &memory_strategy, tmp_path, "test", &test_schema_3);
    defer {
        storage.deinit();
        if (test_schema_3) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    // Property: Resources should be properly cleaned up after errors
    // Begin a transaction
    try storage.beginTransaction();
    // Add some operations
    const val_payload1 = try msgpack.Payload.strToPayload("value1", allocator);
    defer val_payload1.free(allocator);
    const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_payload1 }};
    try storage.insertOrReplace("test", "key1", "test", &cols1);
    const val_payload2 = try msgpack.Payload.strToPayload("value2", allocator);
    defer val_payload2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
    try storage.insertOrReplace("test", "key2", "test", &cols2);
    // Rollback (simulating an error scenario)
    try storage.rollbackTransaction();
    // Verify transaction state is cleaned up
    try testing.expect(!storage.isTransactionActive());
    // Verify we can start a new transaction
    try storage.beginTransaction();
    const val_payload3 = try msgpack.Payload.strToPayload("value3", allocator);
    defer val_payload3.free(allocator);
    const cols3 = [_]ColumnValue{.{ .name = "val", .value = val_payload3 }};
    try storage.insertOrReplace("test", "key3", "test", &cols3);
    try storage.commitTransaction();
    // Verify the committed data is there
    const doc = try storage.selectDocument("test", "key3", "test");
    try testing.expect(doc != null);
    if (doc) |d| d.free(allocator);
}
test "storage: stability mixed error and success scenarios" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "stability-mixed");
    defer context.deinit();
    const tmp_path = context.test_dir;
    var test_schema_4: ?*schema_parser.Schema = null;
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage = try setupEngineWithSchema(allocator, &memory_strategy, tmp_path, "test", &test_schema_4);
    defer {
        storage.deinit();
        if (test_schema_4) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    // Property: Server should handle mixed scenarios of errors and successes
    // Successful transaction
    try storage.beginTransaction();
    const val_payload1 = try msgpack.Payload.strToPayload("value1", allocator);
    defer val_payload1.free(allocator);
    const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_payload1 }};
    try storage.insertOrReplace("test", "key1", "test", &cols1);
    try storage.commitTransaction();
    // Failed transaction (rollback)
    try storage.beginTransaction();
    const val_payload2 = try msgpack.Payload.strToPayload("value2", allocator);
    defer val_payload2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
    try storage.insertOrReplace("test", "key2", "test", &cols2);
    try storage.rollbackTransaction();
    // Error (no active transaction)
    _ = storage.commitTransaction() catch |err| {
        try testing.expectEqual(error.NoActiveTransaction, err);
    };
    // Successful operation without transaction
    const val_payload3 = try msgpack.Payload.strToPayload("value3", allocator);
    defer val_payload3.free(allocator);
    const cols3 = [_]ColumnValue{.{ .name = "val", .value = val_payload3 }};
    try storage.insertOrReplace("test", "key3", "test", &cols3);
    try storage.flushPendingWrites();
    // Verify first transaction succeeded
    const doc1 = try storage.selectDocument("test", "key1", "test");
    try testing.expect(doc1 != null);
    defer doc1.?.free(allocator);
    // Verify second transaction was rolled back
    const doc2 = try storage.selectDocument("test", "key2", "test");
    try testing.expect(doc2 == null);
    // Verify third operation succeeded
    const doc3 = try storage.selectDocument("test", "key3", "test");
    try testing.expect(doc3 != null);
    if (doc3) |d| d.free(allocator);
}
test "storage: stability concurrent reads during write errors" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "stability-concurrent-reads");
    defer context.deinit();
    const tmp_path = context.test_dir;
    var test_schema_5: ?*schema_parser.Schema = null;
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage = try setupEngineWithSchema(allocator, &memory_strategy, tmp_path, "test", &test_schema_5);
    defer {
        storage.deinit();
        if (test_schema_5) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    // Property: Reads should continue working even when writes encounter errors
    // Set up some initial data
    const val_payload1 = try msgpack.Payload.strToPayload("value1", allocator);
    defer val_payload1.free(allocator);
    const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_payload1 }};
    try storage.insertOrReplace("test", "key1", "test", &cols1);
    const val_payload2 = try msgpack.Payload.strToPayload("value2", allocator);
    defer val_payload2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
    try storage.insertOrReplace("test", "key2", "test", &cols2);
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
                // zwanzig-disable-next-line: swallowed-error
                const doc1 = ctx.storage.selectDocument("test", "key1", "test") catch continue; // zwanzig-disable-line: swallowed-error
                if (doc1) |d| d.free(ctx.allocator);
                // zwanzig-disable-next-line: swallowed-error
                const doc2 = ctx.storage.selectDocument("test", "key2", "test") catch continue; // zwanzig-disable-line: swallowed-error
                if (doc2) |d| d.free(ctx.allocator);
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
    const doc1 = try storage.selectDocument("test", "key1", "test");
    try testing.expect(doc1 != null);
    defer doc1.?.free(allocator);
}
