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

const EngineTestContext = struct {
    engine: *StorageEngine,
    schema: *schema_parser.Schema,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const EngineTestContext) void {
        self.engine.deinit();
        schema_parser.freeSchema(self.allocator, self.schema.*);
        self.allocator.destroy(self.schema);
    }
};

fn setupEngine(allocator: std.mem.Allocator, test_dir: []const u8, table: schema_parser.Table) !EngineTestContext {
    const tables = try allocator.alloc(schema_parser.Table, 1);
    tables[0] = try table.clone(allocator);
    const schema = try allocator.create(schema_parser.Schema);
    schema.* = .{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };

    const engine = try StorageEngine.init(allocator, test_dir, schema);

    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.writer_conn.execMulti(ddl_z, .{});

    return .{ .engine = engine, .schema = schema, .allocator = allocator };
}

test "StorageEngine: init and deinit" {
    const allocator = testing.allocator;

    // Create temporary directory for test
    const test_dir = "test-artifacts/unit/storage_engine/test_data_init";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var dummy_fields = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var dummy_tables = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &dummy_fields }};
    const dummy_schema = schema_parser.Schema{ .version = "1.0.0", .tables = &dummy_tables };
    const engine = try StorageEngine.init(allocator, test_dir, &dummy_schema);
    defer engine.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ test_dir, "zyncbase.db" });
    defer allocator.free(db_path);

    const file = try std.fs.cwd().openFile(db_path, .{});
    file.close();
}

test "StorageEngine: insertOrReplace and selectDocument" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_set_get";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set a value
    const val_p = try msgpack.Payload.strToPayload("test", allocator);
    defer val_p.free(allocator);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_p }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols);

    // Flush writes
    try engine.flushPendingWrites();

    // Get the value
    const result = try engine.selectDocument("items", "id1", "test_namespace");
    defer if (result) |v| v.free(allocator);

    try testing.expect(result != null);
    const key_payload = try msgpack.Payload.strToPayload("val", allocator);
    defer key_payload.free(allocator);
    try testing.expectEqualStrings("test", result.?.map.get(key_payload).?.str.value());
}

test "StorageEngine: selectDocument non-existent key" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_get_nonexistent";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    const result = try engine.selectDocument("items", "nonexistent", "test_namespace");
    try testing.expect(result == null);
}

test "StorageEngine: update existing document" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_update";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set initial value
    const val_p1 = try msgpack.Payload.strToPayload("initial", allocator);
    defer val_p1.free(allocator);
    const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_p1 }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols1);
    try engine.flushPendingWrites();

    // Update value
    const val_p2 = try msgpack.Payload.strToPayload("updated", allocator);
    defer val_p2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_p2 }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols2);
    try engine.flushPendingWrites();

    // Get the value
    const result = try engine.selectDocument("items", "id1", "test_namespace");
    defer if (result) |v| v.free(allocator);

    try testing.expect(result != null);
    const key_payload = try msgpack.Payload.strToPayload("val", allocator);
    defer key_payload.free(allocator);
    try testing.expectEqualStrings("updated", result.?.map.get(key_payload).?.str.value());
}

test "StorageEngine: delete document" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_delete";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set a value
    const val_p = try msgpack.Payload.strToPayload("test", allocator);
    defer val_p.free(allocator);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_p }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols);
    try engine.flushPendingWrites();

    // Verify it exists
    const result1 = try engine.selectDocument("items", "id1", "test_namespace");
    defer if (result1) |v| v.free(allocator);
    try testing.expect(result1 != null);

    // Delete the document
    try engine.deleteDocument("items", "id1", "test_namespace");
    try engine.flushPendingWrites();

    // Verify it's gone
    const result2 = try engine.selectDocument("items", "id1", "test_namespace");
    try testing.expect(result2 == null);
}

test "StorageEngine: query collection" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_query";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("name", .text, false)};
    const table = schema_parser.Table{ .name = "users", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set multiple documents
    const val_p1 = try msgpack.Payload.strToPayload("Alice", allocator);
    defer val_p1.free(allocator);
    const cols1 = [_]ColumnValue{.{ .name = "name", .value = val_p1 }};
    try engine.insertOrReplace("users", "1", "test_namespace", &cols1);

    const val_p2 = try msgpack.Payload.strToPayload("Bob", allocator);
    defer val_p2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "name", .value = val_p2 }};
    try engine.insertOrReplace("users", "2", "test_namespace", &cols2);
    try engine.flushPendingWrites();

    // Query for collection
    const results = try engine.selectCollection("users", "test_namespace");
    defer results.free(allocator);

    try testing.expectEqual(@as(usize, 2), results.arr.len);
}

test "StorageEngine: multiple namespaces" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_namespaces";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set values in different namespaces
    const val_p1 = try msgpack.Payload.strToPayload("ns1", allocator);
    defer val_p1.free(allocator);
    const cols1 = [_]ColumnValue{.{ .name = "val", .value = val_p1 }};
    try engine.insertOrReplace("items", "id1", "namespace1", &cols1);

    const val_p2 = try msgpack.Payload.strToPayload("ns2", allocator);
    defer val_p2.free(allocator);
    const cols2 = [_]ColumnValue{.{ .name = "val", .value = val_p2 }};
    try engine.insertOrReplace("items", "id1", "namespace2", &cols2);
    try engine.flushPendingWrites();

    // Get values from different namespaces
    const result1 = try engine.selectDocument("items", "id1", "namespace1");
    defer if (result1) |v| v.free(allocator);
    const result2 = try engine.selectDocument("items", "id1", "namespace2");
    defer if (result2) |v| v.free(allocator);

    try testing.expect(result1 != null);
    try testing.expect(result2 != null);
    const key_payload = try msgpack.Payload.strToPayload("val", allocator);
    defer key_payload.free(allocator);
    try testing.expectEqualStrings("ns1", result1.?.map.get(key_payload).?.str.value());
    try testing.expectEqualStrings("ns2", result2.?.map.get(key_payload).?.str.value());
}

test "StorageEngine: transaction support" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_transaction";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var dummy_fields_1 = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var dummy_tables_1 = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &dummy_fields_1 }};
    const dummy_schema_1 = schema_parser.Schema{ .version = "1.0.0", .tables = &dummy_tables_1 };
    const engine = try StorageEngine.init(allocator, test_dir, &dummy_schema_1);
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

    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Queue some operations
    const val_p = try msgpack.Payload.strToPayload("value1", allocator);
    defer val_p.free(allocator);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_p }};
    try engine.insertOrReplace("items", "id1", "test_ns", &cols);
    try engine.insertOrReplace("items", "id2", "test_ns", &cols);

    // Wait for operations to be processed
    try engine.flushPendingWrites();

    // Verify no transaction is active after batch completes
    try testing.expect(!engine.isTransactionActive());

    // Verify data was written
    const result1 = try engine.selectDocument("items", "id1", "test_ns");
    defer if (result1) |v| v.free(allocator);
    try testing.expect(result1 != null);

    const result2 = try engine.selectDocument("items", "id2", "test_ns");
    defer if (result2) |v| v.free(allocator);
    try testing.expect(result2 != null);
}

test "StorageEngine: concurrent reads" {
    const allocator = testing.allocator;

    const test_dir = "test-artifacts/unit/storage_engine/test_data_concurrent";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

    const ctx = try setupEngine(allocator, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set some values
    const cols1 = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(1) }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols1);
    try engine.insertOrReplace("items", "id2", "test_namespace", &cols1);
    try engine.flushPendingWrites();

    // Perform multiple concurrent reads
    const Thread = struct {
        fn readKey(eng: *StorageEngine, alloc: std.mem.Allocator, id: []const u8) !void {
            const result = try eng.selectDocument("items", id, "test_namespace");
            defer if (result) |v| v.free(alloc);
            try testing.expect(result != null);
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const id = if (i % 2 == 0) "id1" else "id2";
        thread.* = try std.Thread.spawn(.{}, Thread.readKey, .{ engine, allocator, id });
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
        var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        const ctx = try setupEngine(allocator, test_dir, table);
        const engine = ctx.engine;
        // Enqueue a burst of writes without waiting — deinit must flush them.
        for (0..num_keys) |i| {
            var id_buf: [32]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "id_{d}", .{i});
            const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(1) }};
            try engine.insertOrReplace("items", id, "ns", &cols);
        }
        ctx.deinit(); // must not return until all writes are on disk
    }

    // Reopen the same database and verify every key is present.
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    const verify_ctx = try setupEngine(allocator, test_dir, table);
    defer verify_ctx.deinit();
    const verify_engine = verify_ctx.engine;

    for (0..num_keys) |i| {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "id_{d}", .{i});
        const result = try verify_engine.selectDocument("items", id, "ns");
        defer if (result) |v| v.free(allocator);
        try testing.expect(result != null);
    }
}
