const std = @import("std");
const StorageEngine = @import("storage_engine.zig").StorageEngine;

test "CRUD operations with write thread" {
    const allocator = std.testing.allocator;

    // Create test data directory
    const test_dir = "test-artifact/test_data_crud";
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    std.log.debug("Initializing storage engine...", .{});
    const storage = try StorageEngine.init(allocator, test_dir);
    defer storage.deinit();

    std.log.debug("Testing set() operation...", .{});
    try storage.set("test_namespace", "/users/1", "{\"name\":\"Alice\",\"age\":30}");
    try storage.set("test_namespace", "/users/2", "{\"name\":\"Bob\",\"age\":25}");
    try storage.set("test_namespace", "/posts/1", "{\"title\":\"Hello World\"}");

    std.log.debug("Flushing pending writes...", .{});
    try storage.flushPendingWrites();

    std.log.debug("Testing get() operation...", .{});
    const user1 = try storage.get("test_namespace", "/users/1");
    if (user1) |value| {
        defer allocator.free(value);
        std.log.debug("Retrieved user1: {s}", .{value});
        try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", value);
    } else {
        return error.TestFailed;
    }

    std.log.debug("Testing query() operation...", .{});
    const results = try storage.query("test_namespace", "/users/");
    defer {
        for (results) |result| {
            allocator.free(result.path);
            allocator.free(result.value);
        }
        allocator.free(results);
    }

    std.log.debug("Query returned {} results", .{results.len});
    try std.testing.expectEqual(@as(usize, 2), results.len);

    for (results) |result| {
        std.log.debug("  Path: {s}, Value: {s}", .{ result.path, result.value });
    }

    std.log.debug("Testing delete() operation...", .{});
    try storage.delete("test_namespace", "/users/2");
    try storage.flushPendingWrites();

    const user2 = try storage.get("test_namespace", "/users/2");
    try std.testing.expectEqual(@as(?[]const u8, null), user2);

    std.log.debug("Testing update operation (set on existing key)...", .{});
    try storage.set("test_namespace", "/users/1", "{\"name\":\"Alice Updated\",\"age\":31}");
    try storage.flushPendingWrites();

    const user1_updated = try storage.get("test_namespace", "/users/1");
    if (user1_updated) |value| {
        defer allocator.free(value);
        std.log.debug("Updated user1: {s}", .{value});
        try std.testing.expectEqualStrings("{\"name\":\"Alice Updated\",\"age\":31}", value);
    } else {
        return error.TestFailed;
    }

    std.log.debug("All CRUD operations completed successfully!", .{});
}
