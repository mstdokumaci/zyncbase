const std = @import("std");
const StorageEngine = @import("storage_engine.zig").StorageEngine;

test "CRUD operations with write thread" {
    const allocator = std.testing.allocator;

    // Create test data directory
    const test_dir = "test_data_crud";
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    std.debug.print("\nInitializing storage engine...\n", .{});
    const storage = try StorageEngine.init(allocator, test_dir);
    defer storage.deinit();

    std.debug.print("Testing set() operation...\n", .{});
    try storage.set("test_namespace", "/users/1", "{\"name\":\"Alice\",\"age\":30}");
    try storage.set("test_namespace", "/users/2", "{\"name\":\"Bob\",\"age\":25}");
    try storage.set("test_namespace", "/posts/1", "{\"title\":\"Hello World\"}");

    std.debug.print("Flushing pending writes...\n", .{});
    try storage.flushPendingWrites();

    std.debug.print("Testing get() operation...\n", .{});
    const user1 = try storage.get("test_namespace", "/users/1");
    if (user1) |value| {
        defer allocator.free(value);
        std.debug.print("Retrieved user1: {s}\n", .{value});
        try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", value);
    } else {
        return error.TestFailed;
    }

    std.debug.print("Testing query() operation...\n", .{});
    const results = try storage.query("test_namespace", "/users/");
    defer {
        for (results) |result| {
            allocator.free(result.path);
            allocator.free(result.value);
        }
        allocator.free(results);
    }

    std.debug.print("Query returned {} results\n", .{results.len});
    try std.testing.expectEqual(@as(usize, 2), results.len);

    for (results) |result| {
        std.debug.print("  Path: {s}, Value: {s}\n", .{ result.path, result.value });
    }

    std.debug.print("Testing delete() operation...\n", .{});
    try storage.delete("test_namespace", "/users/2");
    try storage.flushPendingWrites();

    const user2 = try storage.get("test_namespace", "/users/2");
    try std.testing.expectEqual(@as(?[]const u8, null), user2);

    std.debug.print("Testing update operation (set on existing key)...\n", .{});
    try storage.set("test_namespace", "/users/1", "{\"name\":\"Alice Updated\",\"age\":31}");
    try storage.flushPendingWrites();

    const user1_updated = try storage.get("test_namespace", "/users/1");
    if (user1_updated) |value| {
        defer allocator.free(value);
        std.debug.print("Updated user1: {s}\n", .{value});
        try std.testing.expectEqualStrings("{\"name\":\"Alice Updated\",\"age\":31}", value);
    } else {
        return error.TestFailed;
    }

    std.debug.print("All CRUD operations completed successfully!\n", .{});
}
