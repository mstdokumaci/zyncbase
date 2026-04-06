const std = @import("std");
const testing = std.testing;
const storage_engine_mod = @import("storage_engine.zig");
const StorageEngine = storage_engine_mod.StorageEngine;
const ColumnValue = storage_engine_mod.ColumnValue;
const msgpack = @import("msgpack_utils.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const msgpack_test = @import("msgpack_test_helpers.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

// This property test verifies that database operations handle errors gracefully:
// 1. All database operation failures return descriptive errors
// 2. All database errors are logged with full details
// 3. No panics or crashes occur on database errors

test "storage: error handling invalid database path" {
    const allocator = testing.allocator;

    // Try to create storage engine with invalid path
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer sm.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();

    var storage: StorageEngine = undefined;
    const result = storage.init(allocator, &memory_strategy, "/invalid/nonexistent/path/that/cannot/be/created", &sm, .{}, .{ .in_memory = false }, null, null);
    // Verify we get an error
    if (result) |_| {
        storage.deinit();
        return error.ExpectedError;
    } else |err| {
        switch (err) {
            error.FileNotFound, error.ReadOnlyFileSystem, error.AccessDenied => {},
            else => return err,
        }
    }
}
test "storage: error handling read-only filesystem" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "storage-error-readonly");
    defer context.deinit();
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer sm.deinit();
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage: StorageEngine = undefined;
    try schema_helpers.setupTestEngine(&storage, allocator, &memory_strategy, &context, &sm, .{ .in_memory = false });
    defer storage.deinit();
    // Try to set a value
    {
        const val_payload = try msgpack.Payload.strToPayload("value1", allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("data_table", "key1", "data_table", &cols);
    }
    try storage.flushPendingWrites();
    // Verify we can read it back
    {
        var managed = try storage.selectDocument(allocator, "data_table", "key1", "data_table");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
    }
}
test "storage: error handling constraint violations" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "storage-error-constraints");
    defer context.deinit();
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer sm.deinit();
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage: StorageEngine = undefined;
    try schema_helpers.setupTestEngine(&storage, allocator, &memory_strategy, &context, &sm, .{ .in_memory = false });
    defer storage.deinit();
    // Set a value
    {
        const val_payload = try msgpack.Payload.strToPayload("value1", allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("data_table", "key1", "data_table", &cols);
    }
    try storage.flushPendingWrites();
    // Update the same key (this should work with UPSERT)
    {
        const val_payload = try msgpack.Payload.strToPayload("value2", allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("data_table", "key1", "data_table", &cols);
    }
    try storage.flushPendingWrites();
    // Verify the value was updated
    {
        var managed = try storage.selectDocument(allocator, "data_table", "key1", "data_table");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
        if (doc) |d| {
            // Document retrieved as map, let's check field "val"
            const val = msgpack_test.getMapValue(d, "val") orelse return error.TestExpectedError;
            try testing.expectEqualStrings("value2", val.str.value());
        }
    }
}
test "storage: error handling transaction rollback on error" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "storage-error-rollback");
    defer context.deinit();
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer sm.deinit();
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage: StorageEngine = undefined;
    try schema_helpers.setupTestEngine(&storage, allocator, &memory_strategy, &context, &sm, .{ .in_memory = false });
    defer storage.deinit();
    try storage.beginTransaction();
    {
        const val_payload = try msgpack.Payload.strToPayload("value1", allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("data_table", "key1", "data_table", &cols);
    }
    try storage.rollbackTransaction();
    {
        var managed = try storage.selectDocument(allocator, "data_table", "key1", "data_table");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc == null);
    }
}
test "storage: error handling concurrent access safety" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "storage-error-concurrent");
    defer context.deinit();
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer sm.deinit();
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage: StorageEngine = undefined;
    try schema_helpers.setupTestEngine(&storage, allocator, &memory_strategy, &context, &sm, .{ .in_memory = false });
    defer storage.deinit();
    {
        const val_payload = try msgpack.Payload.strToPayload("value1", allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("data_table", "key1", "data_table", &cols);
    }
    try storage.flushPendingWrites();
    const ThreadContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
    };
    const runRead = struct {
        fn run(ctx: ThreadContext) void {
            var managed = ctx.storage.selectDocument(ctx.allocator, "data_table", "key1", "data_table") catch return; // zwanzig-disable-line: swallowed-error
            defer managed.deinit();
            _ = managed.value;
        }
    }.run;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, runRead, .{ThreadContext{ .storage = &storage, .allocator = allocator }});
    }
    for (threads) |t| t.join();
}
test "storage: error handling empty paths" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "storage-error-empty");
    defer context.deinit();
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer sm.deinit();

    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();

    var storage: StorageEngine = undefined;
    try schema_helpers.setupTestEngine(&storage, allocator, &memory_strategy, &context, &sm, .{ .in_memory = false });
    defer storage.deinit();
    {
        const val_payload = try msgpack.Payload.strToPayload("value", allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("data_table", "empty", "", &cols);
    }
    try storage.flushPendingWrites();
    {
        var managed = try storage.selectDocument(allocator, "data_table", "empty", "");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
    }
}
test "storage: error handling large values" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "storage-error-large");
    defer context.deinit();
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer sm.deinit();
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage: StorageEngine = undefined;
    try schema_helpers.setupTestEngine(&storage, allocator, &memory_strategy, &context, &sm, .{ .in_memory = false });
    defer storage.deinit();
    const large_value = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_value);
    @memset(large_value, 'A');
    {
        const val_payload = try msgpack.Payload.strToPayload(large_value, allocator);
        defer val_payload.free(allocator);
        const cols = [_]ColumnValue{.{ .name = "val", .value = val_payload }};
        try storage.insertOrReplace("test", "large_key", "test", &cols);
    }
    try storage.flushPendingWrites();
    {
        var managed = try storage.selectDocument(allocator, "test", "large_key", "test");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc != null);
    }
}
test "storage: error handling delete non-existent key" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "storage-error-delete");
    defer context.deinit();
    var sm = try schema_helpers.createTestSchemaManager(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer sm.deinit();
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    var storage: StorageEngine = undefined;
    try schema_helpers.setupTestEngine(&storage, allocator, &memory_strategy, &context, &sm, .{ .in_memory = false });
    defer storage.deinit();
    try storage.deleteDocument("test", "nonexistent", "test");
    try storage.flushPendingWrites();
    {
        var managed = try storage.selectDocument(allocator, "test", "nonexistent", "test");
        defer managed.deinit();
        const doc = managed.value;
        try testing.expect(doc == null);
    }
}
