const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");

test "StorageEngine: init and deinit" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "_dummy", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "engine-init", table, .{ .in_memory = false });
    defer ctx.deinit();

    const db_path = try std.fs.path.join(allocator, &.{ ctx.test_context.test_dir, "zyncbase.db" });
    defer allocator.free(db_path);
    const file = try std.fs.cwd().openFile(db_path, .{});
    file.close();
}

test "StorageEngine: selectDocument non-existent key" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-nonexistent", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    var managed = try engine.selectDocument(allocator, "items", "nonexistent", "test_namespace");
    defer managed.deinit();
    try testing.expect(managed.value == null);
}

test "StorageEngine: query collection" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("name", .text, false)};
    const table = sth.Table{ .name = "users", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-query", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try sth.enqueueDocumentWrite(engine, "users", "1", "test_namespace", &.{
        .{ .name = "name", .field_type = .text, .value = .{ .text = "Alice" } },
    });
    try sth.enqueueDocumentWrite(engine, "users", "2", "test_namespace", &.{
        .{ .name = "name", .field_type = .text, .value = .{ .text = "Bob" } },
    });
    try engine.flushPendingWrites();

    var managed = try engine.selectCollection(allocator, "users", "test_namespace");
    defer managed.deinit();
    try testing.expectEqual(@as(usize, 2), managed.value.?.arr.len);
}

test "StorageEngine: transaction support" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "_dummy", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-tx", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try testing.expect(!engine.isTransactionActive());
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());
    try testing.expectError(error.TransactionAlreadyActive, engine.beginTransaction());
    try engine.commitTransaction();
    try testing.expect(!engine.isTransactionActive());
    try testing.expectError(error.NoActiveTransaction, engine.commitTransaction());
    try engine.beginTransaction();
    try testing.expect(engine.isTransactionActive());
    try engine.rollbackTransaction();
    try testing.expect(!engine.isTransactionActive());
    try testing.expectError(error.NoActiveTransaction, engine.rollbackTransaction());
}

test "StorageEngine: concurrent reads" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-concurrent", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try sth.enqueueDocumentWrite(engine, "items", "id1", "test_namespace", &.{
        .{ .name = "val", .field_type = .integer, .value = .{ .integer = 1 } },
    });
    try sth.enqueueDocumentWrite(engine, "items", "id2", "test_namespace", &.{
        .{ .name = "val", .field_type = .integer, .value = .{ .integer = 1 } },
    });
    try engine.flushPendingWrites();

    const Thread = struct {
        fn readKey(eng: *sth.StorageEngine, alloc: std.mem.Allocator, id: []const u8) !void {
            var managed = try eng.selectDocument(alloc, "items", id, "test_namespace");
            defer managed.deinit();
            try testing.expect(managed.value != null);
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const id = if (i % 2 == 0) "id1" else "id2";
        thread.* = try std.Thread.spawn(.{}, Thread.readKey, .{ engine, allocator, id });
    }
    for (threads) |thread| thread.join();
}
