const std = @import("std");

const schema_helpers = @import("schema/test_helpers.zig");
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;

const testing = std.testing;

// For any initialized component, calling init() then deinit() should leave no memory leaks
// and allow re-initialization.
//
// This property test verifies that:
// 1. ZyncBaseServer can be initialized and deinitialized multiple times
// 2. No memory leaks occur during init/deinit cycles
// 3. Each init/deinit cycle is independent and doesn't affect subsequent cycles
test "server: initialization is idempotent" {
    // Use DebugAllocator to detect memory leaks
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_file_path,
        .data =
        \\{"version":"1.0.0","store":{"test":{"fields":{"val":{"type":"string"}}}}}
        ,
    });

    // Property: Multiple init/deinit cycles should not leak memory
    const num_cycles = 2;
    for (0..num_cycles) |_| {
        // Initialize server with unique data directory and custom schema path
        // The block scope ensures deinit runs before the next cycle re-creates
        // the data directory (deleteTree after the block).
        {
            const server = try ZyncBaseServer.initDetailed(std.testing.io, std.testing.environ, allocator, null, data_dir, schema_file_path, null);
            defer server.deinit();

            // Verify server is properly initialized
            try testing.expect(server.schema.tables.len > 0);
            const loaded_data_dir = server.config.data_dir;
            try testing.expectEqualStrings(data_dir, loaded_data_dir);

            // Verify shutdown flag is initialized to false
            try testing.expect(!server.shutdown_requested.load(.acquire));
        }

        // Clean up database file between cycles
        std.Io.Dir.cwd().deleteTree(std.testing.io, data_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    }

    // If we reach here without panicking, the property holds
    // GPA will verify no memory leaks in the defer block
}
