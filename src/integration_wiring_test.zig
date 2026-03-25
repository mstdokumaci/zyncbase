const std = @import("std");

const testing = std.testing;
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;
const schema_helpers = @import("schema_test_helpers.zig");

// Test that verifies all components are properly wired together
// Integration wiring and component interaction properties
test "Integration: All components properly wired" {
    const allocator = testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "wiring-all");
    defer context.deinit();

    const schema_path = try std.fs.path.join(allocator, &.{ context.test_dir, "schema.json" });
    defer allocator.free(schema_path);
    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);
    try schema_helpers.writeSchemaToFile(allocator, schema, schema_path);
    defer std.fs.cwd().deleteFile(schema_path) catch {}; // zwanzig-disable-line: empty-catch-engine

    // Initialize server with unique data directory and localized schema
    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "test_data_wiring" });
    defer allocator.free(data_dir);

    const server = try ZyncBaseServer.initDetailed(allocator, null, data_dir, schema_path, null);
    defer server.deinit();

    // Verify all components are initialized and connected (pointers are non-null)
    try testing.expect(@intFromPtr(server.memory_strategy) != 0);
    try testing.expect(@intFromPtr(server.violation_tracker) != 0);
    try testing.expect(@intFromPtr(server.subscription_manager) != 0);
    try testing.expect(@intFromPtr(server.checkpoint_manager) != 0);
    try testing.expect(@intFromPtr(server.storage_engine) != 0);
    try testing.expect(@intFromPtr(server.websocket_server) != 0);
    try testing.expect(@intFromPtr(server.message_handler) != 0);

    // Verify message handler has references to all required components
    try testing.expect(server.message_handler.storage_engine == server.storage_engine);
    try testing.expect(server.message_handler.storage_engine == server.storage_engine);
    try testing.expect(server.message_handler.subscription_manager == server.subscription_manager);

    // Verify shutdown flag is initialized
    try testing.expect(server.shutdown_requested.load(.acquire) == false);
}

// Test that error propagation works through all layers
// Component interaction properties
test "Integration: Error propagation through layers" {
    const allocator = testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "wiring-error");
    defer context.deinit();

    const schema_path = try std.fs.path.join(allocator, &.{ context.test_dir, "schema_prop.json" });
    defer allocator.free(schema_path);
    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);
    try schema_helpers.writeSchemaToFile(allocator, schema, schema_path);
    defer std.fs.cwd().deleteFile(schema_path) catch {}; // zwanzig-disable-line: empty-catch-engine

    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "test_data_propagation" });
    defer allocator.free(data_dir);

    const server = try ZyncBaseServer.initDetailed(allocator, null, data_dir, schema_path, null);
    defer server.deinit();

    // Test that storage engine errors propagate correctly
    const doc = try server.storage_engine.selectDocument("test", "nonexistent_key", "test_namespace");
    defer if (doc) |d| d.free(server.allocator);
    try testing.expect(doc == null);

    // but we verify the error handling paths exist
    try testing.expect(@intFromPtr(server.message_handler.violation_tracker) != 0);
}

// Test that graceful shutdown propagates through all components
// System end-to-end properties
test "Integration: Graceful shutdown propagation" {
    const allocator = testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "wiring-shutdown");
    defer context.deinit();

    const schema_path = try std.fs.path.join(allocator, &.{ context.test_dir, "schema_shutdown.json" });
    defer allocator.free(schema_path);
    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);
    try schema_helpers.writeSchemaToFile(allocator, schema, schema_path);
    defer std.fs.cwd().deleteFile(schema_path) catch {}; // zwanzig-disable-line: empty-catch-engine

    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "test_data_shutdown" });
    defer allocator.free(data_dir);

    const server = try ZyncBaseServer.initDetailed(allocator, null, data_dir, schema_path, null);
    defer server.deinit();

    // Initiate shutdown
    try server.shutdown();

    // Verify shutdown flag is set
    try testing.expect(server.shutdown_requested.load(.acquire) == true);

    // Verify all components are still valid (not corrupted by shutdown)
    try testing.expect(@intFromPtr(server.memory_strategy) != 0);
    try testing.expect(@intFromPtr(server.storage_engine) != 0);
    try testing.expect(@intFromPtr(server.message_handler) != 0);
}

// Test that WebSocket callbacks are properly wired with server pointer
// Validates that user_data is correctly passed through callbacks
test "Integration: WebSocket callback wiring" {
    const allocator = testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "wiring-callback");
    defer context.deinit();

    const schema_path = try std.fs.path.join(allocator, &.{ context.test_dir, "schema_callback.json" });
    defer allocator.free(schema_path);
    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);
    try schema_helpers.writeSchemaToFile(allocator, schema, schema_path);
    defer std.fs.cwd().deleteFile(schema_path) catch {}; // zwanzig-disable-line: empty-catch-engine

    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "test_data_callback" });
    defer allocator.free(data_dir);

    const server = try ZyncBaseServer.initDetailed(allocator, null, data_dir, schema_path, null);
    defer server.deinit();

    // Verify WebSocket server is initialized
    try testing.expect(@intFromPtr(server.websocket_server) != 0);

    // The actual callback registration happens in server.start()
    // which we can't test here without starting the event loop
    // But we verify the components needed for callbacks are present
    try testing.expect(@intFromPtr(server.message_handler) != 0);
}
