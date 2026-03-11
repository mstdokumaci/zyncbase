const std = @import("std");
const StorageEngine = @import("src/storage_engine.zig").StorageEngine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test data directory
    const test_dir = "test_data_crud";
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    std.log.info("Initializing storage engine...", .{});
    const storage = try StorageEngine.init(allocator, test_dir);
    defer storage.deinit();

    std.log.info("Testing set() operation...", .{});
    try storage.set("test_namespace", "/users/1", "{\"name\":\"Alice\",\"age\":30}");
    try storage.set("test_namespace", "/users/2", "{\"name\":\"Bob\",\"age\":25}");
    try storage.set("test_namespace", "/posts/1", "{\"title\":\"Hello World\"}");

    std.log.info("Flushing pending writes...", .{});
    try storage.flushPendingWrites();

    std.log.info("Testing get() operation...", .{});
    const user1 = try storage.get("test_namespace", "/users/1");
    if (user1) |value| {
        defer allocator.free(value);
        std.log.info("Retrieved user1: {s}", .{value});
        if (!std.mem.eql(u8, value, "{\"name\":\"Alice\",\"age\":30}")) {
            std.log.err("Unexpected value for user1", .{});
            return error.TestFailed;
        }
    } else {
        std.log.err("Failed to retrieve user1", .{});
        return error.TestFailed;
    }

    std.log.info("Testing query() operation...", .{});
    const results = try storage.query("test_namespace", "/users/");
    defer {
        for (results) |result| {
            allocator.free(result.path);
            allocator.free(result.value);
        }
        allocator.free(results);
    }

    std.log.info("Query returned {} results", .{results.len});
    if (results.len != 2) {
        std.log.err("Expected 2 results, got {}", .{results.len});
        return error.TestFailed;
    }

    for (results) |result| {
        std.log.info("  Path: {s}, Value: {s}", .{ result.path, result.value });
    }

    std.log.info("Testing delete() operation...", .{});
    try storage.delete("test_namespace", "/users/2");
    try storage.flushPendingWrites();

    const user2 = try storage.get("test_namespace", "/users/2");
    if (user2) |value| {
        defer allocator.free(value);
        std.log.err("User2 should have been deleted but was found: {s}", .{value});
        return error.TestFailed;
    }

    std.log.info("Testing update operation (set on existing key)...", .{});
    try storage.set("test_namespace", "/users/1", "{\"name\":\"Alice Updated\",\"age\":31}");
    try storage.flushPendingWrites();

    const user1_updated = try storage.get("test_namespace", "/users/1");
    if (user1_updated) |value| {
        defer allocator.free(value);
        std.log.info("Updated user1: {s}", .{value});
        if (!std.mem.eql(u8, value, "{\"name\":\"Alice Updated\",\"age\":31}")) {
            std.log.err("Unexpected value for updated user1", .{});
            return error.TestFailed;
        }
    } else {
        std.log.err("Failed to retrieve updated user1", .{});
        return error.TestFailed;
    }

    std.log.info("All CRUD operations completed successfully!", .{});
}
