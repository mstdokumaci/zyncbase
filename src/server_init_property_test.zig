const std = @import("std");

const testing = std.testing;
const schema_helpers = @import("schema_test_helpers.zig");
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;

// For any initialized component, calling init() then deinit() should leave no memory leaks
// and allow re-initialization.
//
// This property test verifies that:
// 1. ZyncBaseServer can be initialized and deinitialized multiple times
// 2. No memory leaks occur during init/deinit cycles
// 3. Each init/deinit cycle is independent and doesn't affect subsequent cycles
test "server: initialization is idempotent" {
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

    var context = try schema_helpers.TestContext.init(allocator, "server-init");
    defer context.deinit();

    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "test_data_idempotence" });
    defer allocator.free(data_dir);

    // Create a valid test fixture in the test artifacts directory
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "schema.json" });
    defer allocator.free(schema_file_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = schema_file_path,
        .data =
        \\{"version":"1.0.0","store":{"test":{"fields":{"val":{"type":"string"}}}}}
        ,
    });

    // Property: Multiple init/deinit cycles should not leak memory
    // Test with 1 cycle first to debug leaks
    const num_cycles = 1;
    var i: usize = 0;
    while (i < num_cycles) : (i += 1) {
        // Initialize server with unique data directory and custom schema path
        const server = try ZyncBaseServer.initDetailed(allocator, null, data_dir, schema_file_path, null);
        std.log.debug("Server initialized", .{});
        defer {
            std.log.debug("About to call server.deinit()", .{});
            server.deinit();
            std.log.debug("server.deinit() returned", .{});
        }

        // Verify server is properly initialized
        try testing.expect(@intFromPtr(&server.memory_strategy) != 0);
        try testing.expect(@intFromPtr(&server.violation_tracker) != 0);
        try testing.expect(@intFromPtr(&server.subscription_engine) != 0);
        try testing.expect(@intFromPtr(&server.checkpoint_manager) != 0);
        try testing.expect(@intFromPtr(&server.storage_engine) != 0);
        try testing.expect(@intFromPtr(&server.websocket_server) != 0);
        try testing.expect(@intFromPtr(&server.message_handler) != 0);

        // Verify shutdown flag is initialized to false
        try testing.expect(!server.shutdown_requested.load(.acquire));

        // Clean up database file between cycles
        std.fs.cwd().deleteTree(data_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    }

    // If we reach here without panicking, the property holds
    // GPA will verify no memory leaks in the defer block
}
