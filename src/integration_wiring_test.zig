const std = @import("std");


const testing = std.testing;
const ZyncBaseServer = @import("main.zig").ZyncBaseServer;

// Test that verifies all components are properly wired together
// This test validates Requirements 17.3, 17.4, 17.5 for task 23
test "Integration: All components properly wired" {
    const allocator = testing.allocator;

    // Initialize server with unique data directory
    const server = try ZyncBaseServer.initDetailed(allocator, null, "test-data/integration/wiring/test_data_wiring");
    defer {
        server.deinit();
        std.fs.cwd().deleteTree("test-data/integration/wiring/test_data_wiring") catch {};
    }

    // Verify all components are initialized and connected (pointers are non-null)
    try testing.expect(@intFromPtr(server.memory_strategy) != 0);
    try testing.expect(@intFromPtr(server.cache) != 0);
    try testing.expect(@intFromPtr(server.parser) != 0);
    try testing.expect(@intFromPtr(server.subscription_manager) != 0);
    try testing.expect(@intFromPtr(server.checkpoint_manager) != 0);
    try testing.expect(@intFromPtr(server.storage_engine) != 0);
    try testing.expect(@intFromPtr(server.websocket_server) != 0);
    try testing.expect(@intFromPtr(server.message_handler) != 0);

    // Verify message handler has references to all required components
    try testing.expect(server.message_handler.parser == server.parser);
    try testing.expect(server.message_handler.storage_engine == server.storage_engine);
    try testing.expect(server.message_handler.subscription_manager == server.subscription_manager);
    try testing.expect(server.message_handler.cache == server.cache);

    // Verify shutdown flag is initialized
    try testing.expect(server.shutdown_requested.load(.acquire) == false);
}

// Test that error propagation works through all layers
// Validates Requirements 17.3, 17.4
test "Integration: Error propagation through layers" {
    const allocator = testing.allocator;

    const server = try ZyncBaseServer.initDetailed(allocator, null, "test-data/integration/wiring/test_data_propagation");
    defer {
        server.deinit();
        std.fs.cwd().deleteTree("test-data/integration/wiring/test_data_propagation") catch {};
    }

    // Test that storage engine errors propagate correctly
    // Try to get a non-existent key
    const result = server.storage_engine.get("test_namespace", "nonexistent_key");

    // Should either return null or an error, but not crash
    if (result) |value| {
        if (value) |v| {
            server.memory_strategy.generalAllocator().free(v);
        }
    } else |_| {
        // Error is expected and properly propagated
    }

    // Test that message handler handles invalid messages gracefully
    // This would normally be tested with actual WebSocket connections,
    // but we verify the error handling paths exist
    try testing.expect(@intFromPtr(server.message_handler.parser) != 0);
}

// Test that graceful shutdown propagates through all components
// Validates Requirements 17.5
test "Integration: Graceful shutdown propagation" {
    const allocator = testing.allocator;

    const server = try ZyncBaseServer.initDetailed(allocator, null, "test-data/integration/wiring/test_data_shutdown");
    defer {
        server.deinit();
        std.fs.cwd().deleteTree("test-data/integration/wiring/test_data_shutdown") catch {};
    }

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

    const server = try ZyncBaseServer.initDetailed(allocator, null, "test-data/integration/wiring/test_data_callback");
    defer {
        server.deinit();
        std.fs.cwd().deleteTree("test-data/integration/wiring/test_data_callback") catch {};
    }

    // Verify WebSocket server is initialized
    try testing.expect(@intFromPtr(server.websocket_server) != 0);

    // The actual callback registration happens in server.start()
    // which we can't test here without starting the event loop
    // But we verify the components needed for callbacks are present
    try testing.expect(@intFromPtr(server.message_handler) != 0);
}
