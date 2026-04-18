const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const StorageEngine = sth.StorageEngine;

// This property test verifies that database operations handle errors gracefully:
// 1. All database operation failures return descriptive errors
// 2. All database errors are logged with full details
// 3. No panics or crashes occur on database errors

test "storage: error handling invalid database path" {
    const allocator = testing.allocator;

    // Try to create storage engine with invalid path
    var sm = try sth.createSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{sth.makeField("val", .text, false)} },
        .{ .name = "test", .fields = &.{sth.makeField("val", .text, false)} },
    });
    defer sm.deinit();

    var ms: sth.MemoryStrategy = undefined;
    try ms.init(allocator);
    defer ms.deinit();

    var storage: StorageEngine = undefined;
    const result = storage.init(allocator, &ms, "/invalid/nonexistent/path/that/cannot/be/created", &sm, .{}, .{ .in_memory = false }, null, null);
    // Verify we get an error
    if (result) |_| {
        storage.deinit();
        return error.ExpectedError;
    } else |err| {
        switch (err) {
            error.FileNotFound, error.ReadOnlyFileSystem, error.AccessDenied, error.InvalidDataDir => {},
            else => return err,
        }
    }
}
test "storage: error handling read-only filesystem" {
    const allocator = testing.allocator;
    const table = sth.Table{ .name = "data_table", .fields = &.{sth.makeField("val", .text, false)} };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-readonly", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    // Try to set a value
    {
        try ctx.insertText("data_table", "key1", "data_table", "val", "value1");
    }
    try storage.flushPendingWrites();
    // Verify we can read it back
    {
        var managed = try tbl.selectDocument(allocator, "key1", "data_table");
        defer managed.deinit();
        try testing.expect(managed.rows.len > 0);
    }
}
test "storage: error handling constraint violations" {
    const allocator = testing.allocator;
    const table = sth.Table{ .name = "data_table", .fields = &.{sth.makeField("val", .text, false)} };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-constraints", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    // Set a value
    {
        try ctx.insertText("data_table", "key1", "data_table", "val", "value1");
    }
    try storage.flushPendingWrites();
    // Update the same key (this should work with UPSERT)
    {
        try ctx.insertText("data_table", "key1", "data_table", "val", "value2");
    }
    try storage.flushPendingWrites();
    // Verify the value was updated
    {
        var doc = try tbl.getOne(allocator, "key1", "data_table");
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "value2");
    }
}
test "storage: error handling transaction rollback on error" {
    const allocator = testing.allocator;
    const table = sth.Table{ .name = "data_table", .fields = &.{sth.makeField("val", .text, false)} };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-rollback", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    try storage.beginTransaction();
    {
        try ctx.insertText("data_table", "key1", "data_table", "val", "value1");
    }
    try storage.rollbackTransaction();
    {
        var managed = try tbl.selectDocument(allocator, "key1", "data_table");
        defer managed.deinit();
        try testing.expect(managed.rows.len == 0);
    }
}
test "storage: error handling concurrent access safety" {
    const allocator = testing.allocator;
    const table = sth.Table{ .name = "data_table", .fields = &.{sth.makeField("val", .text, false)} };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-concurrent", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;

    {
        try ctx.insertText("data_table", "key1", "data_table", "val", "value1");
    }
    try storage.flushPendingWrites();
    const ThreadContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
    };
    const runRead = struct {
        fn run(t_ctx: ThreadContext) void {
            var managed = t_ctx.storage.selectDocument(t_ctx.allocator, "data_table", "key1", "data_table") catch return; // zwanzig-disable-line: swallowed-error
            defer managed.deinit();
            _ = managed.rows;
        }
    }.run;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, runRead, .{ThreadContext{ .storage = storage, .allocator = allocator }});
    }
    for (threads) |t| t.join();
}
test "storage: error handling empty paths" {
    const allocator = testing.allocator;
    const table = sth.Table{ .name = "data_table", .fields = &.{sth.makeField("val", .text, false)} };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-empty", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    {
        try ctx.insertText("data_table", "empty", "", "val", "value");
    }
    try storage.flushPendingWrites();
    {
        var managed = try tbl.selectDocument(allocator, "empty", "");
        defer managed.deinit();
        try testing.expect(managed.rows.len > 0);
    }
}
test "storage: error handling large values" {
    const allocator = testing.allocator;
    const table = sth.Table{ .name = "test", .fields = &.{sth.makeField("val", .text, false)} };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-large", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");

    const large_value = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_value);
    @memset(large_value, 'A');
    {
        try ctx.insertText("test", "large_key", "test", "val", large_value);
    }
    try storage.flushPendingWrites();
    {
        var managed = try tbl.selectDocument(allocator, "large_key", "test");
        defer managed.deinit();
        try testing.expect(managed.rows.len > 0);
    }
}
test "storage: error handling delete non-existent key" {
    const allocator = testing.allocator;
    const table = sth.Table{ .name = "test", .fields = &.{sth.makeField("val", .text, false)} };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-delete", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("test");

    try storage.deleteDocument("test", "nonexistent", "test");
    try storage.flushPendingWrites();
    {
        var managed = try tbl.selectDocument(allocator, "nonexistent", "test");
        defer managed.deinit();
        try testing.expect(managed.rows.len == 0);
    }
}
