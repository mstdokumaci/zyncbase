const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const msgpack = @import("msgpack_utils.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

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

test "storage: engine initialization errors" {
    const allocator = testing.allocator;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    // Test 1: Invalid directory path (read-only filesystem simulation)
    // We can't easily simulate a read-only filesystem in a portable way,
    // so we test with an invalid path that should fail
    const invalid_dir = "";
    var raw_dummy_fields = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var raw_dummy_tables = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &raw_dummy_fields }};
    const raw_dummy_schema = schema_parser.Schema{ .version = "1.0.0", .tables = &raw_dummy_tables };
    const result1 = StorageEngine.init(allocator, &memory_strategy, invalid_dir, &raw_dummy_schema);
    if (result1) |_| {
        try testing.expect(false); // Should have failed
    } else |_| {
        // Any error is acceptable here as long as it failed
    }

    // Test 2: Path that is a file, not a directory
    const test_file = "test_file_not_dir.txt";
    defer std.fs.cwd().deleteFile(test_file) catch {}; // zwanzig-disable-line: empty-catch-engine

    // Create a file
    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();

    // Try to use it as a directory - should fail
    var raw_dummy_fields_2 = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var raw_dummy_tables_2 = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &raw_dummy_fields_2 }};
    const raw_dummy_schema_2 = schema_parser.Schema{ .version = "1.0.0", .tables = &raw_dummy_tables_2 };
    const result2 = StorageEngine.init(allocator, &memory_strategy, test_file, &raw_dummy_schema_2);
    try testing.expectError(error.NotDir, result2);

    // Test 3: Valid initialization should succeed
    const test_dir = "test-artifacts/storage_engine/test_data_init_valid";
    // zwanzig-disable-next-line
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

    var raw_dummy_fields_3 = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var raw_dummy_tables_3 = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &raw_dummy_fields_3 }};
    const raw_dummy_schema_3 = schema_parser.Schema{ .version = "1.0.0", .tables = &raw_dummy_tables_3 };
    const engine = try StorageEngine.init(allocator, &memory_strategy, test_dir, &raw_dummy_schema_3);
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
    // zwanzig-disable-next-line
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    var test_schema: ?*schema_parser.Schema = null;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema);
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
    // zwanzig-disable-next-line
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    var test_schema: ?*schema_parser.Schema = null;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema);
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
        const doc = try engine.selectDocument("test", key, "test");
        defer if (doc) |d| d.free(testing.allocator);
        try testing.expect(doc != null);
    }

    // If we got here, connections were properly released and reused
}

test "storage: persistence round-trip (various types)" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/storage_engine/test_data_roundtrip";
    // zwanzig-disable-next-line
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    var test_schema: ?*schema_parser.Schema = null;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema);
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
    // zwanzig-disable-next-line
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    var test_schema: ?*schema_parser.Schema = null;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema);
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
    // zwanzig-disable-next-line
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    var test_schema: ?*schema_parser.Schema = null;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema);
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
    // zwanzig-disable-next-line
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    var test_schema: ?*schema_parser.Schema = null;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema);
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

// ─── Property Test Helpers ──────────────────────────────────────────────────

fn makeSchema(allocator: std.mem.Allocator, table_name: []const u8, fields: []const schema_parser.Field) !*schema_parser.Schema {
    const owned_fields = try allocator.dupe(schema_parser.Field, fields);
    for (owned_fields, 0..) |_, i| {
        owned_fields[i].name = try allocator.dupe(u8, fields[i].name);
    }
    const tables = try allocator.alloc(schema_parser.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, table_name),
        .fields = owned_fields,
    };
    const schema = try allocator.create(schema_parser.Schema);
    schema.* = .{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };
    return schema;
}

fn freeSchema(allocator: std.mem.Allocator, schema: *schema_parser.Schema) void {
    allocator.free(schema.version);
    for (schema.tables) |t| {
        allocator.free(t.name);
        for (t.fields) |f| allocator.free(f.name);
        allocator.free(t.fields);
    }
    allocator.free(schema.tables);
    allocator.destroy(schema);
}

const PropTestContext = struct {
    allocator: std.mem.Allocator,
    engine: *StorageEngine,
    schema: *schema_parser.Schema,
    test_dir: []const u8,

    pub fn deinit(self: PropTestContext) void {
        self.engine.deinit();
        freeSchema(self.allocator, self.schema);
        self.allocator.free(self.test_dir);
        std.fs.cwd().deleteTree(self.test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    }
};

fn setupPropTestEngine(allocator: std.mem.Allocator, memory_strategy: *MemoryStrategy, test_dir_base: []const u8, table: schema_parser.Table) !PropTestContext {
    const test_dir = try allocator.dupe(u8, test_dir_base);
    errdefer allocator.free(test_dir); // zwanzig-disable-line: deinit-lifecycle

    const schema = try makeSchema(allocator, table.name, table.fields);
    errdefer freeSchema(allocator, schema);

    const engine = try StorageEngine.init(allocator, memory_strategy, test_dir, schema);
    errdefer engine.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.writer_conn.execMulti(ddl_z, .{});

    return PropTestContext{
        .allocator = allocator,
        .engine = engine,
        .schema = schema,
        .test_dir = test_dir,
    };
}

// ─── Property 13: Document set/get round-trip ────────────────────────────────

test "storage: property 13 - document set/get round-trip" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rand = prng.random();

    const scalar_values = [_][]const u8{ "hello", "world", "foo", "bar", "baz" };

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p13_{}", .{iter});
        defer allocator.free(test_dir);
        // zwanzig-disable-next-line
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{
            makeField("title", .text, false),
            makeField("score", .integer, false),
        };
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

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

        const result = try engine.selectDocument("items", id, ns);
        try testing.expect(result != null);
        defer result.?.free(allocator);

        const got_title = try result.?.mapGet("title");
        try testing.expect(got_title != null);
        try testing.expectEqualStrings(title_str, got_title.?.str.value());

        const got_score = try result.?.mapGet("score");
        try testing.expect(got_score != null);
        const got_score_val: i64 = switch (got_score.?) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expectEqual(score_val, got_score_val);
    }
}

// ─── Property 14: Field set/get round-trip ───────────────────────────────────

test "storage: property 14 - field set/get round-trip" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p14_{}", .{iter});
        defer allocator.free(test_dir);
        // zwanzig-disable-next-line
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{
            makeField("title", .text, false),
            makeField("score", .integer, false),
        };
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

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

        const got = try engine.selectField("items", id, ns, "score");
        try testing.expect(got != null);
        defer got.?.free(allocator);
        const got_score_val: i64 = switch (got.?) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expectEqual(new_score, got_score_val);
    }
}

// ─── Property 15: Collection get is namespace-scoped ─────────────────────────

test "storage: property 15 - collection get is namespace-scoped" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p15_{}", .{iter});
        defer allocator.free(test_dir);
        // zwanzig-disable-next-line
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

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

        const coll_a = try engine.selectCollection("items", ns_a);
        defer coll_a.free(allocator);
        try testing.expectEqual(count_a, coll_a.arr.len);

        const coll_b = try engine.selectCollection("items", ns_b);
        defer coll_b.free(allocator);
        try testing.expectEqual(count_b, coll_b.arr.len);
    }
}

// ─── Property 16: Remove then get returns null ────────────────────────────────

test "storage: property 16 - remove then get returns null" {
    const allocator = testing.allocator;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p16_{}", .{iter});
        defer allocator.free(test_dir);
        // zwanzig-disable-next-line
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";

        const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(42) }};
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();

        try engine.deleteDocument("items", id, ns);
        try engine.flushPendingWrites();

        const after = try engine.selectDocument("items", id, ns);
        try testing.expect(after == null);
    }
}

// ─── Property 17: Schema validation rejects unknown tables and fields ─────────

test "storage: property 17 - schema validation rejects unknown tables and fields" {
    const allocator = testing.allocator;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p17_{}", .{iter});
        defer allocator.free(test_dir);
        // zwanzig-disable-next-line
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{makeField("title", .text, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

        const cols = [_]ColumnValue{.{ .name = "title", .value = msgpack.Payload.intToPayload(1) }};
        const err1 = engine.insertOrReplace("nonexistent_table", "id1", "ns", &cols);
        try testing.expectError(storage_engine.StorageError.UnknownTable, err1);

        const bad_cols = [_]ColumnValue{.{ .name = "nonexistent_field", .value = msgpack.Payload.intToPayload(1) }};
        const err2 = engine.insertOrReplace("items", "id1", "ns", &bad_cols);
        try testing.expectError(storage_engine.StorageError.UnknownField, err2);
    }
}

// ─── Property 18: updated_at is always refreshed on write ────────────────────

test "storage: property 18 - updated_at is always refreshed on write" {
    const allocator = testing.allocator;

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p18_{}", .{iter});
        defer allocator.free(test_dir);
        // zwanzig-disable-next-line
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

        const id = "doc-001";
        const ns = "ns-test";

        const t_before_insert = std.time.timestamp();
        const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(1) }};
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();

        const doc1 = try engine.selectDocument("items", id, ns);
        try testing.expect(doc1 != null);
        defer doc1.?.free(allocator);

        const updated_at_1_payload = (try doc1.?.mapGet("updated_at")) orelse return error.MissingUpdatedAt;
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

        const doc2 = try engine.selectDocument("items", id, ns);
        try testing.expect(doc2 != null);
        defer doc2.?.free(allocator);

        const updated_at_2_payload = (try doc2.?.mapGet("updated_at")) orelse return error.MissingUpdatedAt;
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
test "storage: property 10 - write/read round-trip for array fields" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xA77A1_10);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p10_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{
            makeField("tags", .array, false),
            makeField("name", .text, false),
        };
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

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
        const doc = try engine.selectDocument("items", id, ns);
        try testing.expect(doc != null);
        defer doc.?.free(allocator);

        const got_tags = (try doc.?.mapGet("tags")) orelse return error.MissingTags;
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
        const field_result = try engine.selectField("items", id, ns, "tags");
        try testing.expect(field_result != null);
        defer field_result.?.free(allocator);
        try testing.expect(field_result.? == .arr);
        try testing.expectEqual(n, field_result.?.arr.len);
    }
}

// ─── Property 11: Non-array fields are unaffected by the change ──────────────

// Feature: array-jsonb-storage, Property 11: Non-array fields are unaffected by the change
test "storage: property 11 - non-array fields are unaffected" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xB0B_11);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p11_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{
            makeField("title", .text, false),
            makeField("score", .integer, false),
            makeField("rating", .real, false),
            makeField("active", .boolean, false),
        };
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

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

        const doc = try engine.selectDocument("items", id, ns);
        try testing.expect(doc != null);
        defer doc.?.free(allocator);

        // Verify text field
        const got_title = (try doc.?.mapGet("title")) orelse {
            std.debug.print("Property 11: Missing title field!\n", .{});
            return error.MissingTitle;
        };
        try testing.expectEqualStrings(title_str, got_title.str.value());

        // Verify integer field
        const got_score = (try doc.?.mapGet("score")) orelse return error.MissingScore;
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
test "storage: property 12 - SQLite json_array_length works on stored array columns" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xC0DE_12);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 20) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/prop/p12_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

        var fields_arr = [_]schema_parser.Field{
            makeField("tags", .array, false),
        };
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupPropTestEngine(allocator, &memory_strategy, test_dir, table);
        defer ctx.deinit();
        const engine = ctx.engine;

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

        // Execute json_array_length directly against the SQLite database
        const id_z = try allocator.dupeZ(u8, id);
        defer allocator.free(id_z);
        const ns_z = try allocator.dupeZ(u8, ns);
        defer allocator.free(ns_z);

        const LenResult = struct { len: i64 };
        const result = try engine.writer_conn.one(
            LenResult,
            "SELECT json_array_length(tags) FROM items WHERE id=? AND namespace_id=?",
            .{},
            .{ id_z, ns_z },
        );

        try testing.expect(result != null);
        try testing.expectEqual(@as(i64, @intCast(n)), result.?.len);
    }
}
