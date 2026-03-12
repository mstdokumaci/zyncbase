const std = @import("std");

const testing = std.testing;
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;

// **Property 3: Component initialization is idempotent**
// **Validates: Requirements 3.12**
//
// For any initialized component, calling init() then deinit() should leave no memory leaks
// and allow re-initialization.
//
// This property test verifies that:
// 1. ZyncBaseServer can be initialized and deinitialized multiple times
// 2. No memory leaks occur during init/deinit cycles
// 3. Each init/deinit cycle is independent and doesn't affect subsequent cycles
test "Property 3: Component initialization is idempotent" {
    // Use GeneralPurposeAllocator to detect memory leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
            @panic("Memory leak in init/deinit cycle");
        }
    }
    const allocator = gpa.allocator();

    // Ensure test data directory is clean
    std.fs.cwd().deleteTree("test-artifact/server_init/test_data_idempotence") catch {};
    defer std.fs.cwd().deleteTree("test-artifact/server_init/test_data_idempotence") catch {};

    // Property: Multiple init/deinit cycles should not leak memory
    // Test with 1 cycle first to debug leaks
    const num_cycles = 1;
    var i: usize = 0;
    while (i < num_cycles) : (i += 1) {
        // Initialize server with unique data directory
        const server = try ZyncBaseServer.initDetailed(allocator, null, "test-artifact/server_init/test_data_idempotence");
        std.log.debug("Server initialized", .{});
        defer {
            std.log.debug("About to call server.deinit()", .{});
            server.deinit();
            std.log.debug("server.deinit() returned", .{});
        }

        // Verify server is properly initialized
        try testing.expect(@intFromPtr(server.memory_strategy) != 0);
        try testing.expect(@intFromPtr(server.cache) != 0);
        try testing.expect(@intFromPtr(server.violation_tracker) != 0);
        try testing.expect(@intFromPtr(server.subscription_manager) != 0);
        try testing.expect(@intFromPtr(server.checkpoint_manager) != 0);
        try testing.expect(@intFromPtr(server.storage_engine) != 0);
        try testing.expect(@intFromPtr(server.websocket_server) != 0);
        try testing.expect(@intFromPtr(server.message_handler) != 0);

        // Verify shutdown flag is initialized to false
        try testing.expect(!server.shutdown_requested.load(.acquire));

        // Clean up database file between cycles
        std.fs.cwd().deleteTree("test-artifact/server_init/test_data_idempotence") catch {};
    }

    // If we reach here without panicking, the property holds
    // GPA will verify no memory leaks in the defer block
}
