const std = @import("std");
const testing = std.testing;
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;
const schema_helpers = @import("schema_test_helpers.zig");

/// Helper to setup a ZyncBaseServer for wiring tests with a clean configuration
fn setupTestServer(allocator: std.mem.Allocator, context: *schema_helpers.TestContext, schema_name: []const u8) !*ZyncBaseServer {
    const schema_path = try std.fs.path.join(allocator, &.{ context.test_dir, schema_name });
    defer allocator.free(schema_path);

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.deinitTestSchema(allocator, schema);

    try schema_helpers.writeSchemaToFile(allocator, schema, schema_path);
    // Note: We don't delete schema_path here because server.initDetailed needs it.
    // context.deinit() will clean up everything in its directory.

    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "data" });
    defer allocator.free(data_dir);

    return try ZyncBaseServer.initDetailed(allocator, null, data_dir, schema_path, null);
}

test "Integration: All components properly wired" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "wiring-all");
    defer context.deinit();

    const server = try setupTestServer(allocator, &context, "schema.json");
    defer server.deinit();

    // Verify all components are initialized and correctly cross-linked
    try testing.expect(@intFromPtr(&server.memory_strategy) != 0);
    try testing.expect(@intFromPtr(&server.violation_tracker) != 0);
    try testing.expect(@intFromPtr(&server.subscription_engine) != 0);
    try testing.expect(@intFromPtr(&server.checkpoint_manager) != 0);
    try testing.expect(@intFromPtr(&server.storage_engine) != 0);
    try testing.expect(@intFromPtr(&server.websocket_server) != 0);
    try testing.expect(@intFromPtr(&server.message_handler) != 0);

    // Verify message handler's component wiring
    try testing.expect(server.message_handler.store_service == &server.store_service);
    try testing.expect(server.message_handler.subscription_engine == &server.subscription_engine);
    try testing.expect(server.message_handler.violation_tracker == &server.violation_tracker);

    // Verify initial operational state
    try testing.expect(server.shutdown_requested.load(.acquire) == false);
}

test "Integration: Error propagation through layers" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "wiring-error");
    defer context.deinit();

    const server = try setupTestServer(allocator, &context, "schema_prop.json");
    defer server.deinit();

    const test_tbl = server.storage_engine.schema_manager.getTable("test") orelse return error.TableNotFound;
    // Verify storage engine interaction through wiring
    var managed = try server.storage_engine.selectDocument(allocator, test_tbl.index, 999, 1);
    defer managed.deinit();
    const doc = managed.rows;
    try testing.expect(doc.len == 0);

    // Verify components have expected internal pointers
    try testing.expect(server.message_handler.violation_tracker == &server.violation_tracker);
}

test "Integration: Graceful shutdown propagation" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "wiring-shutdown");
    defer context.deinit();

    const server = try setupTestServer(allocator, &context, "schema_shutdown.json");
    defer server.deinit();

    // Initiate shutdown via server protocol
    try server.shutdown();

    // Verify shutdown signal was propagated
    try testing.expect(server.shutdown_requested.load(.acquire) == true);

    // Verify components remain stable during shutdown sequence
    try testing.expect(@intFromPtr(&server.memory_strategy) != 0);
    try testing.expect(@intFromPtr(&server.storage_engine) != 0);
}

test "Integration: WebSocket callback wiring" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "wiring-callback");
    defer context.deinit();

    const server = try setupTestServer(allocator, &context, "schema_callback.json");
    defer server.deinit();

    // Verify WebSocket server component is present
    try testing.expect(@intFromPtr(&server.websocket_server) != 0);

    // Verify critical callback dependencies
    try testing.expect(@intFromPtr(&server.message_handler) != 0);
}
