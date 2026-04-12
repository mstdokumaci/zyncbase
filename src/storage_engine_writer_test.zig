const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");

fn expectTextField(
    allocator: std.mem.Allocator,
    engine: *sth.StorageEngine,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    field: []const u8,
    expected: []const u8,
) !void {
    var managed = try engine.selectField(allocator, table, id, namespace, field);
    defer managed.deinit();
    const got = managed.value orelse return error.MissingField;
    try testing.expectEqualStrings(expected, got.str.value());
}

test "StorageEngine.Writer: insert and select basic" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{
        sth.makeField("name", .text, false),
        sth.makeField("age", .integer, false),
    };
    const table = sth.Table{ .name = "users", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "writer-basic", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try sth.enqueueDocumentWrite(engine, "users", "id1", "ns", &.{
        .{ .name = "name", .field_type = .text, .value = .{ .text = "Alice" } },
        .{ .name = "age", .field_type = .integer, .value = .{ .integer = 30 } },
    });
    try engine.flushPendingWrites();

    try expectTextField(allocator, engine, "users", "id1", "ns", "name", "Alice");
    var managed_age = try engine.selectField(allocator, "users", "id1", "ns", "age");
    defer managed_age.deinit();
    try testing.expectEqual(@as(i64, 30), managed_age.value.?.int);
}

test "StorageEngine.Writer: update existing document" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "writer-update", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try sth.enqueueDocumentWrite(engine, "items", "id1", "test_namespace", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "initial" } },
    });
    try engine.flushPendingWrites();

    try sth.enqueueDocumentWrite(engine, "items", "id1", "test_namespace", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "updated" } },
    });
    try engine.flushPendingWrites();

    try expectTextField(allocator, engine, "items", "id1", "test_namespace", "val", "updated");
}

test "StorageEngine.Writer: delete document" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "writer-delete", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try sth.enqueueDocumentWrite(engine, "items", "id1", "test_namespace", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "test" } },
    });
    try engine.flushPendingWrites();

    try engine.deleteDocument("items", "id1", "test_namespace");
    try engine.flushPendingWrites();

    var managed = try engine.selectDocument(allocator, "items", "id1", "test_namespace");
    defer managed.deinit();
    try testing.expect(managed.value == null);
}

test "StorageEngine.Writer: multiple namespaces" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "writer-namespaces", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try sth.enqueueDocumentWrite(engine, "items", "id1", "namespace1", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "ns1" } },
    });
    try sth.enqueueDocumentWrite(engine, "items", "id1", "namespace2", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "ns2" } },
    });
    try engine.flushPendingWrites();

    try expectTextField(allocator, engine, "items", "id1", "namespace1", "val", "ns1");
    try expectTextField(allocator, engine, "items", "id1", "namespace2", "val", "ns2");
}

test "StorageEngine.Writer: automatic rollback in batch operations" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "writer-auto-rollback", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try sth.enqueueDocumentWrite(engine, "items", "id1", "test_ns", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value1" } },
    });
    try sth.enqueueDocumentWrite(engine, "items", "id2", "test_ns", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "value1" } },
    });
    try engine.flushPendingWrites();

    try testing.expect(!engine.isTransactionActive());
    var managed1 = try engine.selectDocument(allocator, "items", "id1", "test_ns");
    defer managed1.deinit();
    try testing.expect(managed1.value != null);
    var managed2 = try engine.selectDocument(allocator, "items", "id2", "test_ns");
    defer managed2.deinit();
    try testing.expect(managed2.value != null);
}

test "StorageEngine.Writer: all pending writes are flushed before deinit returns" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    const num_keys = 50;
    var test_dir: []const u8 = undefined;

    {
        var ctx: sth.EngineTestContext = undefined;
        try sth.setupEngineWithOptions(&ctx, allocator, "writer-deinit-flush", table, .{ .in_memory = false });
        errdefer ctx.deinit();
        test_dir = try allocator.dupe(u8, ctx.test_context.test_dir);
        const engine = &ctx.engine;

        for (0..num_keys) |i| {
            var id_buf: [32]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "id_{d}", .{i});
            try sth.enqueueDocumentWrite(engine, "items", id, "ns", &.{
                .{ .name = "val", .field_type = .integer, .value = .{ .integer = @intCast(i) } },
            });
        }
        ctx.deinitNoCleanup();
    }
    defer allocator.free(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {}; // zwanzig-disable-line: empty-catch-engine

    var verify_ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithDir(&verify_ctx, allocator, test_dir, table, .{
        .in_memory = false,
    });
    defer verify_ctx.deinit();
    const verify_engine = &verify_ctx.engine;

    for (0..num_keys) |i| {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "id_{d}", .{i});
        var managed = try verify_engine.selectDocument(allocator, "items", id, "ns");
        defer managed.deinit();
        try testing.expect(managed.value != null);
    }
}

test "StorageEngine.Writer: client writes blocked during migration" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "writer-migration-block", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    engine.migration_active.store(true, .release);
    defer engine.migration_active.store(false, .release);

    const err1 = sth.enqueueDocumentWrite(engine, "items", "id1", "ns", &.{
        .{ .name = "val", .field_type = .integer, .value = .{ .integer = 1 } },
    });
    try testing.expectError(sth.StorageError.MigrationInProgress, err1);

    const err2 = sth.enqueueFieldWrite(engine, "items", "id1", "ns", "val", .integer, .{ .integer = 1 });
    try testing.expectError(sth.StorageError.MigrationInProgress, err2);

    const err3 = engine.deleteDocument("items", "id1", "ns");
    try testing.expectError(sth.StorageError.MigrationInProgress, err3);
}

test "StorageEngine.Writer: manual transaction increments write_seq on commit" {
    const allocator = testing.allocator;
    var fields_arr = [_]sth.Field{sth.makeField("val", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "writer-tx-race", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    const seq0 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 1), seq0);

    try engine.beginTransaction();
    try sth.enqueueDocumentWrite(engine, "items", "id1", "ns", &.{
        .{ .name = "val", .field_type = .text, .value = .{ .text = "updated" } },
    });
    try engine.flushPendingWrites();
    const seq1 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 2), seq1);

    try engine.commitTransaction();
    const seq2 = engine.write_seq.load(.acquire);
    try testing.expectEqual(@as(u64, 3), seq2);
}
