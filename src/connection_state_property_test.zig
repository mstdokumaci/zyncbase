const std = @import("std");


const testing = std.testing;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const ConnectionState = @import("message_handler.zig").ConnectionState;
const ConnectionRegistry = @import("message_handler.zig").ConnectionRegistry;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test "Property 31: Connection state deallocation" {
    // **Property 31: Connection state deallocation**
    // **Validates: Requirements 17.6**
    //
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
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const conn_id: u64 = 1;
        const state = try ConnectionState.init(allocator, conn_id);

        try registry.add(conn_id, state);

        // Verify connection is in registry
        const retrieved = try registry.get(conn_id);
        try testing.expectEqual(conn_id, retrieved.id);

        // Remove connection - should deallocate state
        try registry.remove(conn_id);

        // Verify connection is no longer in registry
        const result = registry.get(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }

    // Test 2: Multiple connections open and close
    {
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const num_connections = 100;
        var i: u64 = 0;
        while (i < num_connections) : (i += 1) {
            const state = try ConnectionState.init(allocator, i);
            try registry.add(i, state);
        }

        // Close all connections
        i = 0;
        while (i < num_connections) : (i += 1) {
            try registry.remove(i);
        }

        // Verify all connections are removed
        i = 0;
        while (i < num_connections) : (i += 1) {
            const result = registry.get(i);
            try testing.expectError(error.ConnectionNotFound, result);
        }
    }

    // Test 3: Connection with subscriptions
    {
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const conn_id: u64 = 1;
        const state = try ConnectionState.init(allocator, conn_id);

        // Add some subscription IDs
        try state.subscription_ids.append(100);
        try state.subscription_ids.append(200);
        try state.subscription_ids.append(300);

        try registry.add(conn_id, state);

        // Remove connection - should deallocate state including subscription list
        try registry.remove(conn_id);

        // Verify connection is removed
        const result = registry.get(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }

    // Test 4: Clear all connections
    {
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const num_connections = 50;
        var i: u64 = 0;
        while (i < num_connections) : (i += 1) {
            const state = try ConnectionState.init(allocator, i);
            try registry.add(i, state);
        }

        // Clear all connections at once
        registry.clear();

        // Verify all connections are removed
        i = 0;
        while (i < num_connections) : (i += 1) {
            const result = registry.get(i);
            try testing.expectError(error.ConnectionNotFound, result);
        }
    }

    // Test 5: Stress test with many connections
    {
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const iterations = 1000;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            const conn_id = @as(u64, iter);
            const state = try ConnectionState.init(allocator, conn_id);

            // Add some subscriptions
            try state.subscription_ids.append(conn_id * 10);
            try state.subscription_ids.append(conn_id * 10 + 1);

            try registry.add(conn_id, state);

            // Immediately remove
            try registry.remove(conn_id);
        }
    }

    // Test 6: Concurrent connection state deallocation
    {
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const ThreadContext = struct {
            registry: *ConnectionRegistry,
            allocator: std.mem.Allocator,
            start_id: u64,
            count: u64,
        };

        const worker = struct {
            fn run(ctx: *ThreadContext) void {
                var i: u64 = 0;
                while (i < ctx.count) : (i += 1) {
                    const conn_id = ctx.start_id + i;
                    const state = ConnectionState.init(ctx.allocator, conn_id) catch unreachable;

                    // Add subscriptions
                    state.subscription_ids.append(conn_id * 100) catch unreachable;
                    state.subscription_ids.append(conn_id * 100 + 1) catch unreachable;

                    ctx.registry.add(conn_id, state) catch unreachable;

                    // Remove immediately
                    ctx.registry.remove(conn_id) catch unreachable;
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
        var registry = try ConnectionRegistry.init(allocator);

        const num_connections = 20;
        var i: u64 = 0;
        while (i < num_connections) : (i += 1) {
            const state = try ConnectionState.init(allocator, i);
            try state.subscription_ids.append(i * 10);
            try registry.add(i, state);
        }

        // Deinit should deallocate all remaining connections
        registry.deinit();
    }
}

test "Property 31: Connection state deallocation - edge cases" {
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
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        // Try to remove a connection that doesn't exist
        try registry.remove(999);
    }

    // Test: Connection with empty subscription list
    {
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const conn_id: u64 = 1;
        const state = try ConnectionState.init(allocator, conn_id);
        // Don't add any subscriptions

        try registry.add(conn_id, state);
        try registry.remove(conn_id);
    }

    // Test: Connection with large subscription list
    {
        var registry = try ConnectionRegistry.init(allocator);
        defer registry.deinit();

        const conn_id: u64 = 1;
        const state = try ConnectionState.init(allocator, conn_id);

        // Add many subscriptions
        var i: u64 = 0;
        while (i < 1000) : (i += 1) {
            try state.subscription_ids.append(i);
        }

        try registry.add(conn_id, state);
        try registry.remove(conn_id);
    }
}
