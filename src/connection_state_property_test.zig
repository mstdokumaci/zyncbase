const std = @import("std");
const testing = std.testing;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const helpers = @import("app_test_helpers.zig");
const createMockWebSocket = helpers.createMockWebSocket;
const AppTestContext = helpers.AppTestContext;

test "connection: state deallocation on close" {
    // This property test verifies that for any connection that closes,
    // all associated connection state is deallocated properly.
    const allocator = testing.allocator;

    // Test 1: Single connection open and close
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-basic", &.{});
        defer app.deinit();

        var dummy_ws = createMockWebSocket();
        const conn_id = dummy_ws.getConnId();

        // onOpen handles acquisition, init, and adding to map
        try app.manager.onOpen(&dummy_ws);

        // Verify connection is in manager
        const retrieved = try app.manager.acquireConnection(conn_id);
        defer if (retrieved.release()) app.releaseConnection(retrieved);
        try testing.expectEqual(conn_id, retrieved.id);

        // Remove connection - should deallocate state once all refs are gone
        app.manager.onClose(&dummy_ws, 1000, "normal");

        // Verify connection is no longer in manager
        const result = app.manager.acquireConnection(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }

    // Test 2: Multiple connections open and close
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-p2", &.{});
        defer app.deinit();

        const num_connections = 24;
        var websockets: [num_connections]WebSocket = undefined;
        for (&websockets) |*ws| {
            ws.* = createMockWebSocket();
            try app.manager.onOpen(ws);
        }

        // Close all connections
        for (&websockets) |*ws| {
            app.manager.onClose(ws, 1000, "normal");
        }

        // Verify all connections are removed
        for (&websockets) |*ws| {
            const result = app.manager.acquireConnection(ws.getConnId());
            try testing.expectError(error.ConnectionNotFound, result);
        }
    }

    // Test 3: Connection with subscriptions
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-p3", &.{});
        defer app.deinit();

        var dummy_ws = createMockWebSocket();
        const conn_id = dummy_ws.getConnId();
        try app.manager.onOpen(&dummy_ws);

        const state = try app.manager.acquireConnection(conn_id);
        defer if (state.release()) app.releaseConnection(state);

        // Add some subscription IDs
        try state.subscription_ids.append(state.allocator, 100);
        try state.subscription_ids.append(state.allocator, 200);
        try state.subscription_ids.append(state.allocator, 300);

        // Remove connection - should deallocate state including subscription list
        app.manager.onClose(&dummy_ws, 1000, "normal");

        // Verify connection is removed
        const result = app.manager.acquireConnection(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }

    // Test 4: Clear all connections at once
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-p4", &.{});
        defer app.deinit();

        const num_connections = 12;
        var websockets: [num_connections]WebSocket = undefined;
        for (&websockets) |*ws| {
            ws.* = createMockWebSocket();
            try app.manager.onOpen(ws);
        }

        // Clear all connections at once
        app.closeAllConnections();

        // Verify all connections are removed
        for (&websockets) |*ws| {
            const result = app.manager.acquireConnection(ws.getConnId());
            try testing.expectError(error.ConnectionNotFound, result);
        }
    }

    // Test 5: Stress test with many connections
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-p5", &.{});
        defer app.deinit();

        const iterations = 160;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            var dummy_ws = createMockWebSocket();
            const conn_id = dummy_ws.getConnId();
            try app.manager.onOpen(&dummy_ws);

            const state = try app.manager.acquireConnection(conn_id);
            defer if (state.release()) app.releaseConnection(state);

            // Add some subscriptions
            try state.subscription_ids.append(state.allocator, conn_id * 10);
            try state.subscription_ids.append(state.allocator, conn_id * 10 + 1);

            // Immediately remove
            app.manager.onClose(&dummy_ws, 1000, "normal");
        }
    }

    // Test 6: Concurrent connection state deallocation
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-p6", &.{});
        defer app.deinit();

        const worker = struct {
            fn run(ctx: *AppTestContext, count: u64) void {
                var i: u64 = 0;
                while (i < count) : (i += 1) {
                    var dummy_ws = createMockWebSocket();
                    const conn_id = dummy_ws.getConnId();

                    ctx.manager.onOpen(&dummy_ws) catch unreachable; // zwanzig-disable-line: swallowed-error

                    const state = ctx.manager.acquireConnection(conn_id) catch unreachable; // zwanzig-disable-line: swallowed-error
                    state.subscription_ids.append(state.allocator, conn_id * 100) catch unreachable; // zwanzig-disable-line: swallowed-error
                    state.subscription_ids.append(state.allocator, conn_id * 100 + 1) catch unreachable; // zwanzig-disable-line: swallowed-error
                    if (state.release()) ctx.releaseConnection(state);

                    // Remove immediately
                    ctx.manager.onClose(&dummy_ws, 1000, "normal");
                }
            }
        }.run;

        // Spawn multiple threads
        var threads: [3]std.Thread = undefined;
        for (&threads) |*t| {
            t.* = try std.Thread.spawn(.{}, worker, .{ &app, 24 });
        }
        // Wait for all threads
        for (threads) |thread| {
            thread.join();
        }
    }

    // Test 7: Registry deinit deallocates all remaining connections
    {
        var deinit_app: AppTestContext = undefined;
        try deinit_app.init(allocator, "state-p7", &.{});
        // We don't defer app.deinit() here so we can call it manually to verify it handles remaining conns
        // Wait, app.deinit() is exactly what we want to test.

        const num_connections = 8;
        var websockets: [num_connections]WebSocket = undefined;
        for (&websockets, 0..) |*ws, i| {
            ws.* = createMockWebSocket();
            try deinit_app.manager.onOpen(ws);
            const state = try deinit_app.manager.acquireConnection(ws.getConnId());
            defer if (state.release()) deinit_app.releaseConnection(state);
            try state.subscription_ids.append(state.allocator, i * 10);
        }
        // Deinit should deallocate all remaining connections
        deinit_app.deinit();
    }
}

test "connection: state deallocation edge cases" {
    const allocator = testing.allocator;

    // Test: Remove non-existent connection (should not crash)
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-inverse", &.{});
        defer app.deinit();

        // Try to remove a connection that doesn't exist
        var dummy_ws = createMockWebSocket();
        app.manager.onClose(&dummy_ws, 1000, "normal");
    }

    // Test: Connection with empty subscription list
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-e2", &.{});
        defer app.deinit();

        var dummy_ws = createMockWebSocket();
        try app.manager.onOpen(&dummy_ws);
        // Don't add any subscriptions
        app.manager.onClose(&dummy_ws, 1000, "normal");
    }

    // Test: Connection with large subscription list
    {
        var app: AppTestContext = undefined;
        try app.init(allocator, "state-e3", &.{});
        defer app.deinit();

        var dummy_ws = createMockWebSocket();
        const conn_id = dummy_ws.getConnId();
        try app.manager.onOpen(&dummy_ws);
        const state = try app.manager.acquireConnection(conn_id);
        defer if (state.release()) app.releaseConnection(state);

        // Add many subscriptions
        var i: u64 = 0;
        while (i < 128) : (i += 1) {
            try state.subscription_ids.append(state.allocator, i);
        }
        app.manager.onClose(&dummy_ws, 1000, "normal");
    }
}
