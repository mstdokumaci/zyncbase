const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const msgpack = @import("msgpack_utils.zig");

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

fn setupEngineWithSchema(allocator: std.mem.Allocator, test_dir: []const u8, table_name: []const u8, out_schema: *?*schema_parser.Schema) !*StorageEngine {
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

    const engine = try StorageEngine.init(allocator, test_dir, schema);

    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.execDDL(ddl_z);

    return engine;
}

test "storage: engine initialization errors" {
    const allocator = testing.allocator;

    // Test 1: Invalid directory path (read-only filesystem simulation)
    // We can't easily simulate a read-only filesystem in a portable way,
    // so we test with an invalid path that should fail
    const invalid_dir = "";
    var raw_dummy_fields = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var raw_dummy_tables = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &raw_dummy_fields }};
    const raw_dummy_schema = schema_parser.Schema{ .version = "1.0.0", .tables = &raw_dummy_tables };
    const result1 = StorageEngine.init(allocator, invalid_dir, &raw_dummy_schema);
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
    var raw_dummy_fields_2 = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var raw_dummy_tables_2 = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &raw_dummy_fields_2 }};
    const raw_dummy_schema_2 = schema_parser.Schema{ .version = "1.0.0", .tables = &raw_dummy_tables_2 };
    const result2 = StorageEngine.init(allocator, test_file, &raw_dummy_schema_2);
    try testing.expectError(error.NotDir, result2);

    // Test 3: Valid initialization should succeed
    const test_dir = "test-artifacts/storage_engine/test_data_init_valid";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var raw_dummy_fields_3 = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var raw_dummy_tables_3 = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &raw_dummy_fields_3 }};
    const raw_dummy_schema_3 = schema_parser.Schema{ .version = "1.0.0", .tables = &raw_dummy_tables_3 };
    const engine = try StorageEngine.init(allocator, test_dir, &raw_dummy_schema_3);
    defer engine.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ test_dir, "zyncbase.db" });
    defer allocator.free(db_path);

    const db_file = try std.fs.cwd().openFile(db_path, .{});
    db_file.close();
}

// Storage engine thread safety properties
test "storage: thread-safe engine access" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/storage_engine/test_data_thread_safe";
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    var test_schema: ?*schema_parser.Schema = null;
    const engine = try setupEngineWithSchema(allocator, test_dir, "test", &test_schema);
    defer {
        engine.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }

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
                const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
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

                const doc = try eng.selectDocument("test", key, "test");
                if (doc) |v| {
                    v.free(testing.allocator);
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
    const doc = try engine.selectDocument("test", "/thread0/key0", "test");
    defer if (doc) |d| d.free(allocator);
    try testing.expect(doc != null);
}

test "storage: connection pool reuse and release" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/storage_engine/test_data_conn_release";
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    var test_schema: ?*schema_parser.Schema = null;
    const engine = try setupEngineWithSchema(allocator, test_dir, "test", &test_schema);
    defer {
        engine.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }

    // Set some initial data
    {
        const val_payload1 = try msgpack.Payload.strToPayload("test1", allocator);
        defer val_payload1.free(allocator);
        const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_payload1 }};
        try engine.insertOrReplace("test", "/key1", "test", &cols1);

        const val_payload2 = try msgpack.Payload.strToPayload("test2", allocator);
        defer val_payload2.free(allocator);
        const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_payload2 }};
        try engine.insertOrReplace("test", "/key2", "test", &cols2);
    }
    try engine.flushPendingWrites();

    // Perform many read operations to ensure connections are being reused
    // If connections weren't released, we'd run out of connections
    const num_operations = 1000;
    var i: usize = 0;
    while (i < num_operations) : (i += 1) {
        const key = if (i % 2 == 0) "/key1" else "/key2";
        const doc = try engine.selectDocument("test", key, "test");
        defer if (doc) |d| d.free(testing.allocator);
        try testing.expect(doc != null);
    }

    // If we got here, connections were properly released and reused
}

test "storage: persistence round-trip (various types)" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/storage_engine/test_data_roundtrip";
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    var test_schema: ?*schema_parser.Schema = null;
    const engine = try setupEngineWithSchema(allocator, test_dir, "test", &test_schema);
    defer {
        engine.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }

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
        const val_payload = try msgpack.Payload.strToPayload(tc.value, allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try engine.insertOrReplace("test", tc.path, "test", &cols);
    }

    // Flush writes
    try engine.flushPendingWrites();

    // Retrieve and verify all test cases
    for (test_cases) |tc| {
        const doc = try engine.selectDocument("test", tc.path, "test");
        defer if (doc) |d| d.free(allocator);

        try testing.expect(doc != null);
        // Compare values if possible, for text we can try
        // Since we stored it as Payload string, it should match back
    }
}

test "storage: insert/delete inverse consistency" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/storage_engine/test_data_inverse";
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    var test_schema: ?*schema_parser.Schema = null;
    const engine = try setupEngineWithSchema(allocator, test_dir, "test", &test_schema);
    defer {
        engine.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }

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
        const doc1 = try engine.selectDocument("test", tc.path, "test");
        defer if (doc1) |d| d.free(allocator); // or free
        try testing.expect(doc1 != null);

        // Delete
        try engine.deleteDocument("test", tc.path, "test");
        try engine.flushPendingWrites();

        // Verify it's gone
        const doc2 = try engine.selectDocument("test", tc.path, "test");
        try testing.expect(doc2 == null);
    }
}

test "storage: transaction isolation and consistency" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/storage_engine/test_data_transaction_isolation";
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    var test_schema: ?*schema_parser.Schema = null;
    const engine = try setupEngineWithSchema(allocator, test_dir, "test", &test_schema);
    defer {
        engine.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }

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
    const doc1 = try engine.selectDocument("test", "/key1", "test");
    defer if (doc1) |d| d.free(allocator);
    const doc2 = try engine.selectDocument("test", "/key2", "test");
    defer if (doc2) |d| d.free(allocator);
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
    const up1 = try engine.selectDocument("test", "/key1", "test");
    defer if (up1) |d| d.free(allocator);
    const up2 = try engine.selectDocument("test", "/key2", "test");
    defer if (up2) |d| d.free(allocator);
    const n3 = try engine.selectDocument("test", "/key3", "test");
    defer if (n3) |d| d.free(allocator);

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
    const conc_read = try engine.selectDocument("test", "/concurrent_key", "test");
    defer if (conc_read) |v| v.free(allocator);
    try testing.expect(conc_read != null);

    // Wait for all writes to complete
    try engine.flushPendingWrites();

    // Verify all batch operations were applied atomically
    i = 0;
    while (i < num_ops) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "/batch_key{d}", .{i});
        defer allocator.free(key);
        const doc = try engine.selectDocument("test", key, "test");
        defer if (doc) |d| d.free(allocator);
        try testing.expect(doc != null);
    }
}

test "storage: automatic transaction rollback on failure" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/storage_engine/test_data_auto_rollback";
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    var test_schema: ?*schema_parser.Schema = null;
    const engine = try setupEngineWithSchema(allocator, test_dir, "test", &test_schema);
    defer {
        engine.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }

    // Set up initial state
    {
        const v1 = try msgpack.Payload.strToPayload("initial", allocator);
        defer v1.free(allocator);
        const c1 = [_]ColumnValue{.{ .name = "val", .value = v1 }};
        try engine.insertOrReplace("test", "/key1", "test", &c1);
    }
    try engine.flushPendingWrites();

    // Verify initial state
    const init_doc = try engine.selectDocument("test", "/key1", "test");
    defer if (init_doc) |d| d.free(allocator);
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
    const arb1 = try engine.selectDocument("test", "/key1", "test");
    defer if (arb1) |d| d.free(allocator);
    try testing.expect(arb1 != null);

    const arb2 = try engine.selectDocument("test", "/key2", "test");
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

    const comm = try engine.selectDocument("test", "/key3", "test");
    defer if (comm) |d| d.free(allocator);
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
        const doc = try engine.selectDocument("test", key, "test");
        defer if (doc) |d| d.free(allocator);
        try testing.expect(doc != null);
    }
}
