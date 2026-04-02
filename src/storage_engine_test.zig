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

fn setupEngine(allocator: std.mem.Allocator, memory_strategy: *MemoryStrategy, test_dir: []const u8, table: schema_parser.Table) !EngineTestContext {
    return setupEngineWithOptions(allocator, memory_strategy, test_dir, table, .{ .in_memory = true });
}

fn setupEngineWithOptions(allocator: std.mem.Allocator, memory_strategy: *MemoryStrategy, test_dir: []const u8, table: schema_parser.Table, options: StorageEngine.Options) !EngineTestContext {
    const tables = try allocator.alloc(schema_parser.Table, 1);
    tables[0] = try table.clone(allocator);
    const schema = try allocator.create(schema_parser.Schema);
    schema.* = .{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };

    const engine = try StorageEngine.init(allocator, memory_strategy, test_dir, schema, .{}, options);

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
    var context = try schema_helpers.TestContext.init(allocator, "engine-init");
    defer context.deinit();
    const test_dir = context.test_dir;

    var dummy_fields = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var dummy_tables = try allocator.alloc(schema_parser.Table, 1);
    defer allocator.free(dummy_tables);
    dummy_tables[0] = .{ .name = "_dummy", .fields = &dummy_fields };
    const dummy_schema = schema_parser.Schema{ .version = "1.0.0", .tables = dummy_tables };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try StorageEngine.init(allocator, &memory_strategy, test_dir, &dummy_schema, .{}, .{ .in_memory = false });
    defer engine.deinit();
    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ test_dir, "zyncbase.db" });
    defer allocator.free(db_path);
    const file = try std.fs.cwd().openFile(db_path, .{});
    file.close();
}
test "StorageEngine: insertOrReplace and selectDocument" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-crud");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
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
    var managed = try engine.selectDocument(allocator, "items", "id1", "test_namespace");
    defer managed.deinit();
    const result = managed.value;
    try testing.expect(result != null);
    const key_payload = try msgpack.Payload.strToPayload("val", allocator);
    defer key_payload.free(allocator);
    try testing.expectEqualStrings("test", result.?.map.get(key_payload).?.str.value());
}
test "StorageEngine: selectDocument non-existent key" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-nonexistent");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;
    var managed = try engine.selectDocument(allocator, "items", "nonexistent", "test_namespace");
    defer managed.deinit();
    const result = managed.value;
    try testing.expect(result == null);
}
test "StorageEngine: update existing document" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-update");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
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
    var managed = try engine.selectDocument(allocator, "items", "id1", "test_namespace");
    defer managed.deinit();
    const result = managed.value;
    try testing.expect(result != null);
    const key_payload = try msgpack.Payload.strToPayload("val", allocator);
    defer key_payload.free(allocator);
    try testing.expectEqualStrings("updated", result.?.map.get(key_payload).?.str.value());
}
test "StorageEngine: delete document" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-delete");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;
    // Set a value
    const val_p = try msgpack.Payload.strToPayload("test", allocator);
    defer val_p.free(allocator);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_p }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols);
    try engine.flushPendingWrites();
    // Verify it exists
    var managed = try engine.selectDocument(allocator, "items", "id1", "test_namespace");
    defer managed.deinit();
    const result1 = managed.value;
    try testing.expect(result1 != null);
    // Delete the document
    try engine.deleteDocument("items", "id1", "test_namespace");
    try engine.flushPendingWrites();
    // Verify it's gone
    var managed_after = try engine.selectDocument(allocator, "items", "id1", "test_namespace");
    defer managed_after.deinit();
    const result2 = managed_after.value;
    try testing.expect(result2 == null);
}
test "StorageEngine: query collection" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-query");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("name", .text, false)};
    const table = schema_parser.Table{ .name = "users", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
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
    var managed = try engine.selectCollection(allocator, "users", "test_namespace");
    defer managed.deinit();
    try testing.expectEqual(@as(usize, 2), managed.value.?.arr.len);
}
test "StorageEngine: multiple namespaces" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-namespaces");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
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
    var managed1 = try engine.selectDocument(allocator, "items", "id1", "namespace1");
    defer managed1.deinit();
    const result1 = managed1.value;

    var managed2 = try engine.selectDocument(allocator, "items", "id1", "namespace2");
    defer managed2.deinit();
    const result2 = managed2.value;
    try testing.expect(result1 != null);
    try testing.expect(result2 != null);
    const key_payload = try msgpack.Payload.strToPayload("val", allocator);
    defer key_payload.free(allocator);
    try testing.expectEqualStrings("ns1", result1.?.map.get(key_payload).?.str.value());
    try testing.expectEqualStrings("ns2", result2.?.map.get(key_payload).?.str.value());
}
test "StorageEngine: transaction support" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-tx");
    defer context.deinit();
    const test_dir = context.test_dir;
    var dummy_fields_1 = [_]schema_parser.Field{.{ .name = "val", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null }};
    var dummy_tables_1 = [_]schema_parser.Table{.{ .name = "_dummy", .fields = &dummy_fields_1 }};
    const dummy_schema_1 = schema_parser.Schema{ .version = "1.0.0", .tables = &dummy_tables_1 };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const engine = try StorageEngine.init(allocator, &memory_strategy, test_dir, &dummy_schema_1, .{}, .{ .in_memory = true });
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
    var context = try schema_helpers.TestContext.init(allocator, "engine-auto-rollback");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
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
    var managed1 = try engine.selectDocument(allocator, "items", "id1", "test_ns");
    defer managed1.deinit();
    const result1 = managed1.value;
    try testing.expect(result1 != null);

    var managed2 = try engine.selectDocument(allocator, "items", "id2", "test_ns");
    defer managed2.deinit();
    const result2 = managed2.value;
    try testing.expect(result2 != null);
}
test "StorageEngine: concurrent reads" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-concurrent");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
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
            var managed = try eng.selectDocument(alloc, "items", id, "test_namespace");
            defer managed.deinit();
            const result = managed.value;
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
    var context = try schema_helpers.TestContext.init(allocator, "engine-deinit-flush");
    defer context.deinit();
    const test_dir = context.test_dir;
    const num_keys = 50;
    {
        var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
        var memory_strategy: MemoryStrategy = undefined;
        try memory_strategy.init(allocator);
        defer memory_strategy.deinit();
        const ctx = try setupEngineWithOptions(allocator, &memory_strategy, test_dir, table, .{ .in_memory = false });
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
    var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy_verify: MemoryStrategy = undefined;
    try memory_strategy_verify.init(allocator);
    defer memory_strategy_verify.deinit();
    const verify_ctx = try setupEngineWithOptions(allocator, &memory_strategy_verify, test_dir, table, .{ .in_memory = false });
    defer verify_ctx.deinit();
    const verify_engine = verify_ctx.engine;
    for (0..num_keys) |i| {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "id_{d}", .{i});
        var managed = try verify_engine.selectDocument(allocator, "items", id, "ns");
        defer managed.deinit();
        const result = managed.value;
        try testing.expect(result != null);
    }
}
// Unit test 8.7: client writes blocked during migration
// Simulate an active migration transaction and assert that insertOrReplace / updateField
// return an error.
test "StorageEngine: client writes blocked during migration" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-migration-block");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;
    // Simulate migration in progress by setting migration_active = true
    engine.migration_active.store(true, .release);
    defer engine.migration_active.store(false, .release);
    // insertOrReplace should be blocked
    const val_p = msgpack.Payload.intToPayload(1);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_p }};
    const err1 = engine.insertOrReplace("items", "id1", "ns", &cols);
    try testing.expectError(storage_engine.StorageError.MigrationInProgress, err1);
    // updateField should be blocked
    const err2 = engine.updateField("items", "id1", "ns", "val", val_p);
    try testing.expectError(storage_engine.StorageError.MigrationInProgress, err2);
    // deleteDocument should be blocked
    const err3 = engine.deleteDocument("items", "id1", "ns");
    try testing.expectError(storage_engine.StorageError.MigrationInProgress, err3);
}
test "StorageEngine: manual transaction MUST increment write_seq on commit" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-tx-race");
    defer context.deinit();
    const test_dir = context.test_dir;
    var fields_arr = [_]schema_parser.Field{makeField("val", .text, false)};
    const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;
    // 1. Initial write_seq
    const seq0 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 0), seq0);
    // 2. Begin transaction
    try engine.beginTransaction();
    // 3. Write something
    const val_p = try msgpack.Payload.strToPayload("updated", allocator);
    defer val_p.free(allocator);
    const cols = [_]ColumnValue{.{ .name = "val", .value = val_p }};
    try engine.insertOrReplace("items", "id1", "ns", &cols);
    // 4. Flush batch. This should increment write_seq to 1 (in current code).
    try engine.flushPendingWrites();
    const seq1 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 1), seq1);
    // 5. Commit transaction. This SHOULD increment write_seq to 2.
    try engine.commitTransaction();
    // 6. VERIFY: write_seq should have advanced to 2 to inform readers that
    // the transaction is committed and any data read during it is potentially stale.
    const seq2 = engine.write_seq.load(.acquire);
    std.debug.print("\nSequence after commit: {d} (Expected: 2)\n", .{seq2});
    try testing.expectEqual(@as(u64, 2), seq2);
}
