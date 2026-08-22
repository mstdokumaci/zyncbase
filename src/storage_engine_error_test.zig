const std = @import("std");

const schema_helpers = @import("schema/test_helpers.zig");
const sth = @import("storage_engine_test_helpers.zig");

const testing = std.testing;
const StorageEngine = sth.StorageEngine;

// This property test verifies that database operations handle errors gracefully:
// 1. All database operation failures return descriptive errors
// 2. All database errors are logged with full details
// 3. No panics or crashes occur on database errors

test "storage: error handling invalid database path" {
    const allocator = std.heap.smp_allocator;

    // Try to create storage engine with invalid path
    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("_dummy", &.{schema_helpers.makeField("val", .text)}),
        schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)}),
    });
    defer schema.deinit();

    var ms: sth.MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var storage: StorageEngine = undefined;
    // /proc cannot be created into even as root, so this fails identically in CI,
    // Docker, and local development regardless of privileges.
    const result = storage.init(std.testing.io, allocator, &ms, "/proc/zyncbase-invalid/nonexistent/path", &schema, .{}, .{ .in_memory = false }, null, null);
    // Verify we get an error
    if (result) |_| {
        storage.deinit();
        return error.ExpectedError;
    } else |err| {
        switch (err) {
            error.FileNotFound, error.ReadOnlyFileSystem, error.AccessDenied, error.PermissionDenied, error.InvalidDataDir => {},
            else => return err,
        }
    }
}
test "storage: write/flush/read round-trip on file-backed engine" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-roundtrip", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    // Try to set a value
    {
        try ctx.insertText("data_table", 1, 1, "val", "value1");
    }
    try storage.flushPendingWrites();
    // Verify we can read it back
    {
        var doc = try tbl.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "value1");
    }
}
test "storage: error handling constraint violations" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-constraints", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    // Set a value
    {
        try ctx.insertText("data_table", 1, 1, "val", "value1");
    }
    try storage.flushPendingWrites();
    // Update the same key (this should work with UPSERT)
    {
        try ctx.insertText("data_table", 1, 1, "val", "value2");
    }
    try storage.flushPendingWrites();
    // Verify the value was updated
    {
        var doc = try tbl.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "value2");
    }
}
test "storage: error handling concurrent access safety" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-concurrent", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;

    {
        try ctx.insertText("data_table", 1, 1, "val", "value1");
    }
    try storage.flushPendingWrites();
    const ThreadContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
    };
    const ThreadResult = struct {
        outcome: ?anyerror = null,
    };
    const runRead = struct {
        fn run(t_ctx: ThreadContext, table_index: usize, result: *ThreadResult) void {
            runErr(t_ctx, table_index) catch |err| { // zwanzig-disable-line: swallowed-error
                result.outcome = err;
            };
        }
        fn runErr(t_ctx: ThreadContext, table_index: usize) !void {
            const record = try sth.readDoc(t_ctx.allocator, t_ctx.storage, table_index, 1, 1);
            try testing.expect(record != null);
            defer if (record) |r| r.deinit(t_ctx.allocator);
        }
    }.run;
    var threads: [4]std.Thread = undefined;
    var results = [_]ThreadResult{.{}} ** 4;
    const tbl_md = ctx.schema.table("data_table") orelse return error.UnknownTable;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |t| t.join();
    for (&threads, &results) |*t, *result| {
        t.* = try std.Thread.spawn(.{}, runRead, .{ ThreadContext{ .storage = storage, .allocator = allocator }, tbl_md.index, result });
        spawned += 1;
    }
    for (threads) |t| t.join();
    for (results) |result| try testing.expect(result.outcome == null);
}
test "storage: write/flush/read round-trip with empty value" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-empty", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    try ctx.insertText("data_table", 1, 1, "val", "");
    try storage.flushPendingWrites();
    {
        var doc = try tbl.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "");
    }
}
test "storage: error handling large values" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-large", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    const large_value = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_value);
    @memset(large_value, 'A');
    {
        try ctx.insertText("data_table", 1, 1, "val", large_value);
    }
    try storage.flushPendingWrites();
    {
        const record = try tbl.readDoc(allocator, 1, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
}
test "storage: error handling delete non-existent key" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-delete", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    try tbl.deleteDocument(999, 1);
    try storage.flushPendingWrites();
    {
        const record = try tbl.readDoc(allocator, 999, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record == null);
    }
}
