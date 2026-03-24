const std = @import("std");

const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const ConnectionRegistry = @import("message_handler.zig").ConnectionRegistry;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test "connection: state deallocation on close" {
    // This property test verifies that for any connection that closes,
    // all associated connection state is deallocated properly.

    // Use a tracking allocator to detect leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.debug("Memory leak detected in connection state deallocation test!", .{});
            @panic("Memory leak in Property 31 test");
        }
    }
    const allocator = gpa.allocator();

    // Test 1: Single connection open and close
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();

        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();

        const conn_id: u64 = 1;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        const state = try memory_strategy.createConnection(conn_id, dummy_ws);

        try registry.add(conn_id, state);

        // Verify connection is in registry
        const retrieved = try registry.acquireConnection(conn_id);
        defer retrieved.release(allocator);
        try testing.expectEqual(conn_id, retrieved.id);

        // Remove connection - should deallocate state once all refs are gone
        registry.remove(conn_id);

        // Verify connection is no longer in registry
        const result = registry.acquireConnection(conn_id);
        if (result) |s| {
            s.release(allocator);
            return error.TestExpectedSuccess;
        } else |err| {
            try testing.expectEqual(error.ConnectionNotFound, err);
        }
    }

    // Test 2: Multiple connections open and close
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();

        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();

        const num_connections = 100;
        var i: u64 = 0;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        while (i < num_connections) : (i += 1) {
            const state = try memory_strategy.createConnection(i, dummy_ws);
            try registry.add(i, state);
        }

        // Close all connections
        i = 0;
        while (i < num_connections) : (i += 1) {
            registry.remove(i);
        }

        // Verify all connections are removed
        i = 0;
        while (i < num_connections) : (i += 1) {
            const result = registry.acquireConnection(i);
            if (result) |s| {
                s.release(allocator);
                return error.TestExpectedError;
            } else |err| {
                try testing.expectEqual(error.ConnectionNotFound, err);
            }
        }
    }

    // Test 3: Connection with subscriptions
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();

        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();

        const conn_id: u64 = 1;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        const state = try memory_strategy.createConnection(conn_id, dummy_ws);

        // Add some subscription IDs
        try state.subscription_ids.append(state.allocator, 100);
        try state.subscription_ids.append(state.allocator, 200);
        try state.subscription_ids.append(state.allocator, 300);

        try registry.add(conn_id, state);

        // Remove connection - should deallocate state including subscription list
        registry.remove(conn_id);

        // Verify connection is removed
        const result = registry.acquireConnection(conn_id);
        if (result) |s| {
            s.release(allocator);
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(error.ConnectionNotFound, err);
        }
    }

    // Test 4: Clear all connections
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();

        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();

        const num_connections = 50;
        var i: u64 = 0;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        while (i < num_connections) : (i += 1) {
            const state = try memory_strategy.createConnection(i, dummy_ws);
            try registry.add(i, state);
        }

        // Clear all connections at once
        registry.clear();

        // Verify all connections are removed
        i = 0;
        while (i < num_connections) : (i += 1) {
            const result = registry.acquireConnection(i);
            if (result) |s| {
                s.release(allocator);
                return error.TestExpectedError;
            } else |err| {
                try testing.expectEqual(error.ConnectionNotFound, err);
            }
        }
    }

    // Test 5: Stress test with many connections
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();

        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();

        const iterations = 1000;
        var iter: usize = 0;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        while (iter < iterations) : (iter += 1) {
            const conn_id = @as(u64, iter);
            const state = try memory_strategy.createConnection(conn_id, dummy_ws);

            // Add some subscriptions
            try state.subscription_ids.append(state.allocator, conn_id * 10);
            try state.subscription_ids.append(state.allocator, conn_id * 10 + 1);

            try registry.add(conn_id, state);

            // Immediately remove
            registry.remove(conn_id);
        }
    }

    // Test 6: Concurrent connection state deallocation
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();

        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();

        const ThreadContext = struct {
            registry: *ConnectionRegistry,
            allocator: std.mem.Allocator,
            start_id: u64,
            count: u64,
            memory_strategy: *MemoryStrategy,
        };

        const worker = struct {
            fn run(ctx: *ThreadContext) void {
                var i: u64 = 0;
                while (i < ctx.count) : (i += 1) {
                    const conn_id = ctx.start_id + i;
                    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
                    const state = ctx.memory_strategy.createConnection(conn_id, dummy_ws) catch unreachable; // zwanzig-disable-line: swallowed-error

                    // Add subscriptions
                    state.subscription_ids.append(state.allocator, conn_id * 100) catch unreachable; // zwanzig-disable-line: swallowed-error
                    state.subscription_ids.append(state.allocator, conn_id * 100 + 1) catch unreachable; // zwanzig-disable-line: swallowed-error

                    ctx.registry.add(conn_id, state) catch unreachable; // zwanzig-disable-line: swallowed-error

                    // Remove immediately
                    ctx.registry.remove(conn_id);
                }
            }
        }.run;

        // Spawn multiple threads
        var contexts: [4]ThreadContext = undefined;
        var threads: [4]std.Thread = undefined;

        for (&contexts, 0..) |*ctx, idx| {
            ctx.* = .{
                .registry = &registry,
                .allocator = allocator,
                .start_id = @as(u64, idx) * 100,
                .count = 100,
                .memory_strategy = &memory_strategy,
            };
            threads[idx] = try std.Thread.spawn(.{}, worker, .{ctx});
        }
        // Wait for all threads
        for (threads) |thread| {
            thread.join();
        }
    }
    // Test 7: Registry deinit deallocates all remaining connections
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        var registry = ConnectionRegistry.init(&memory_strategy);
        const num_connections = 20;
        var i: u64 = 0;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        while (i < num_connections) : (i += 1) {
            const state = try memory_strategy.createConnection(i, dummy_ws);
            try state.subscription_ids.append(state.allocator, i * 10);
            try registry.add(i, state);
        }
        // Deinit should deallocate all remaining connections
        registry.deinit();
    }
}
test "connection: state deallocation edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            @panic("Memory leak in Property 31 edge cases test");
        }
    }
    const allocator = gpa.allocator();
    // Test: Remove non-existent connection (should not crash)
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();
        // Try to remove a connection that doesn't exist
        registry.remove(999);
    }
    // Test: Connection with empty subscription list
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();
        const conn_id: u64 = 1;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        const state = try memory_strategy.createConnection(conn_id, dummy_ws);
        // Don't add any subscriptions
        try registry.add(conn_id, state);
        registry.remove(conn_id);
    }
    // Test: Connection with large subscription list
    {
        var memory_strategy = try MemoryStrategy.init(allocator);
        defer memory_strategy.deinit();
        var registry = ConnectionRegistry.init(&memory_strategy);
        defer registry.deinit();
        const conn_id: u64 = 1;
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        const state = try memory_strategy.createConnection(conn_id, dummy_ws);
        // Add many subscriptions
        var i: u64 = 0;
        while (i < 1000) : (i += 1) {
            try state.subscription_ids.append(state.allocator, i);
        }
        try registry.add(conn_id, state);
        registry.remove(conn_id);
    }
}
