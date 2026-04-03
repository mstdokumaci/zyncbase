const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");

test "StorageEngine: init and deinit" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "_dummy", .fields = &fields_arr };
    var ctx = try sth.setupEngineWithOptions(allocator, "engine-init", table, .{ .in_memory = false });
    defer ctx.deinit();

    // Verify database file was created
    const db_path = try std.fs.path.join(allocator, &.{ ctx.test_context.test_dir, "zyncbase.db" });
    defer allocator.free(db_path);
    const file = try std.fs.cwd().openFile(db_path, .{});
    file.close();
}
test "StorageEngine: insertOrReplace and selectDocument" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-crud", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set a value
    const val_p = try msgpack.Payload.strToPayload("test", allocator);
    defer val_p.free(allocator);
    const cols = [_]sth.ColumnValue{.{ .name = "val", .value = val_p }};
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
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-nonexistent", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    var managed = try engine.selectDocument(allocator, "items", "nonexistent", "test_namespace");
    defer managed.deinit();
    const result = managed.value;
    try testing.expect(result == null);
}
test "StorageEngine: update existing document" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-update", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set initial value
    const val_p1 = try msgpack.Payload.strToPayload("initial", allocator);
    defer val_p1.free(allocator);
    const cols1 = [_]sth.ColumnValue{.{ .name = "val", .value = val_p1 }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols1);
    try engine.flushPendingWrites();
    // Update value
    const val_p2 = try msgpack.Payload.strToPayload("updated", allocator);
    defer val_p2.free(allocator);
    const cols2 = [_]sth.ColumnValue{.{ .name = "val", .value = val_p2 }};
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
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-delete", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set a value
    const val_p = try msgpack.Payload.strToPayload("test", allocator);
    defer val_p.free(allocator);
    const cols = [_]sth.ColumnValue{.{ .name = "val", .value = val_p }};
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
    var fields_arr = [_]sth.Field{sth.makeField("name", .text, false)};
    const table = sth.Table{ .name = "users", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-query", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set multiple documents
    const val_p1 = try msgpack.Payload.strToPayload("Alice", allocator);
    defer val_p1.free(allocator);
    const cols1 = [_]sth.ColumnValue{.{ .name = "name", .value = val_p1 }};
    try engine.insertOrReplace("users", "1", "test_namespace", &cols1);
    const val_p2 = try msgpack.Payload.strToPayload("Bob", allocator);
    defer val_p2.free(allocator);
    const cols2 = [_]sth.ColumnValue{.{ .name = "name", .value = val_p2 }};
    try engine.insertOrReplace("users", "2", "test_namespace", &cols2);
    try engine.flushPendingWrites();
    // Query for collection
    var managed = try engine.selectCollection(allocator, "users", "test_namespace");
    defer managed.deinit();
    try testing.expectEqual(@as(usize, 2), managed.value.?.arr.len);
}
test "StorageEngine: multiple namespaces" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-namespaces", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set values in different namespaces
    const val_p1 = try msgpack.Payload.strToPayload("ns1", allocator);
    defer val_p1.free(allocator);
    const cols1 = [_]sth.ColumnValue{.{ .name = "val", .value = val_p1 }};
    try engine.insertOrReplace("items", "id1", "namespace1", &cols1);
    const val_p2 = try msgpack.Payload.strToPayload("ns2", allocator);
    defer val_p2.free(allocator);
    const cols2 = [_]sth.ColumnValue{.{ .name = "val", .value = val_p2 }};
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
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "_dummy", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-tx", table);
    defer ctx.deinit();
    const engine = ctx.engine;

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
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-auto-rollback", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Queue some operations
    const val_p = try msgpack.Payload.strToPayload("value1", allocator);
    defer val_p.free(allocator);
    const cols = [_]sth.ColumnValue{.{ .name = "val", .value = val_p }};
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
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-concurrent", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Set some values
    const cols1 = [_]sth.ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(1) }};
    try engine.insertOrReplace("items", "id1", "test_namespace", &cols1);
    try engine.insertOrReplace("items", "id2", "test_namespace", &cols1);
    try engine.flushPendingWrites();
    // Perform multiple concurrent reads
    const Thread = struct {
        fn readKey(eng: *sth.StorageEngine, alloc: std.mem.Allocator, id: []const u8) !void {
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
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    const num_keys = 50;
    var test_dir: []const u8 = undefined;

    {
        // Enqueue a burst of writes without waiting — deinit must flush them.
        var ctx = try sth.setupEngineWithOptions(allocator, "engine-deinit-flush", table, .{ .in_memory = false });
        // We dupe the test_dir because deinitNoCleanup will free the copy in ctx,
        // but we need it for the second part of the test.
        test_dir = try allocator.dupe(u8, ctx.test_context.test_dir);
        const engine = ctx.engine;

        for (0..num_keys) |i| {
            var id_buf: [32]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "id_{d}", .{i});
            const key_val = try msgpack.Payload.strToPayload("val", allocator);
            defer key_val.free(allocator);
            const cols = [_]sth.ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(@intCast(i)) }};
            try engine.insertOrReplace("items", id, "ns", &cols);
        }
        // deinitNoCleanup will stop the engine but NOT delete the files.
        ctx.deinitNoCleanup();
    }
    defer allocator.free(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

    // Reopen the same database and verify every key is present.
    // We use setupEngineWithDir which reuses the existing data.
    var verify_ctx = try sth.setupEngineWithDir(allocator, test_dir, table, .{
        .in_memory = false,
    });
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
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-migration-block", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // Simulate migration in progress
    engine.migration_active.store(true, .release);
    defer engine.migration_active.store(false, .release);
    // insertOrReplace should be blocked
    const val_p = msgpack.Payload.intToPayload(1);
    const cols = [_]sth.ColumnValue{.{ .name = "val", .value = val_p }};
    const err1 = engine.insertOrReplace("items", "id1", "ns", &cols);
    try testing.expectError(sth.StorageError.MigrationInProgress, err1);
    // updateField should be blocked
    const err2 = engine.updateField("items", "id1", "ns", "val", val_p);
    try testing.expectError(sth.StorageError.MigrationInProgress, err2);
    // deleteDocument should be blocked
    const err3 = engine.deleteDocument("items", "id1", "ns");
    try testing.expectError(sth.StorageError.MigrationInProgress, err3);
}
test "StorageEngine: manual transaction MUST increment write_seq on commit" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx = try sth.setupEngine(allocator, "engine-tx-race", table);
    defer ctx.deinit();
    const engine = ctx.engine;

    // 1. Initial write_seq
    // sth.setupEngine executes DDL, so write_seq starts at 1
    const seq0 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 1), seq0);
    // 2. Begin transaction
    try engine.beginTransaction();
    // 3. Write something
    const val_p = try msgpack.Payload.strToPayload("updated", allocator);
    defer val_p.free(allocator);
    const cols = [_]sth.ColumnValue{.{ .name = "val", .value = val_p }};
    try engine.insertOrReplace("items", "id1", "ns", &cols);
    // 4. Flush batch. This should increment write_seq to 2.
    try engine.flushPendingWrites();
    const seq1 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 2), seq1);
    // 5. Commit transaction. This SHOULD increment write_seq to 3.
    try engine.commitTransaction();
    // 6. VERIFY: write_seq should have advanced to 3
    const seq2 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 3), seq2);
}
