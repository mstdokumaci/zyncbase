const std = @import("std");
const testing = std.testing;
const helpers = @import("../app_test_helpers.zig");
const violation_tracker_helpers = @import("../violation_tracker_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const createMockWebSocket = helpers.createMockWebSocket;
const WebSocket = @import("../uwebsockets_wrapper.zig").WebSocket;

test "ConnectionManager - init and deinit" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-init", &.{});
    defer app.deinit();

    try testing.expectEqual(@as(usize, 0), app.connection_manager.map.count());
}

test "ConnectionManager - onOpen and onClose" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-open", &.{});
    defer app.deinit();

    var dummy_ws = createMockWebSocket(app.memory_strategy.generalAllocator());

    // Test onOpen
    {
        const sc = try app.openScopedConnection(&dummy_ws);
        defer sc.deinit();
        try testing.expectEqual(@as(usize, 1), app.connection_manager.map.count());
        try testing.expectEqual(dummy_ws.getConnId(), sc.conn.id);
    }

    // Test onClose (after sc.deinit() has run)
    try testing.expectEqual(@as(usize, 0), app.connection_manager.map.count());
}

test "ConnectionManager - onOpen rejects missing external identity" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-missing-identity", &.{});
    defer app.deinit();

    var dummy_ws = WebSocket{
        .ws = null,
        .ssl = false,
        .user_data = @ptrFromInt(999),
        .session = null,
    };
    try testing.expectError(error.MissingSession, app.connection_manager.onOpen(&dummy_ws));
    try testing.expectEqual(@as(usize, 0), app.connection_manager.map.count());
}

test "ConnectionManager - onClose clears violation state" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-violations", &.{});
    defer app.deinit();

    var dummy_ws = createMockWebSocket(app.memory_strategy.generalAllocator());
    const conn_id = dummy_ws.getConnId();

    {
        const sc = try app.openScopedConnection(&dummy_ws);
        defer sc.deinit();

        _ = try app.violation_tracker.recordViolation(conn_id);
        try testing.expectEqual(@as(u32, 1), violation_tracker_helpers.getViolationCount(&app.violation_tracker, conn_id));
    }

    try testing.expectEqual(@as(u32, 0), violation_tracker_helpers.getViolationCount(&app.violation_tracker, conn_id));
}

test "ConnectionManager - onOpen clears stale violation state" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-stale-violations", &.{});
    defer app.deinit();

    {
        var dummy_ws = createMockWebSocket(app.memory_strategy.generalAllocator());
        const conn_id = dummy_ws.getConnId();

        {
            const sc = try app.openScopedConnection(&dummy_ws);
            defer sc.deinit();
        }

        _ = try app.violation_tracker.recordViolation(conn_id);
        try testing.expectEqual(@as(u32, 1), violation_tracker_helpers.getViolationCount(&app.violation_tracker, conn_id));
    }

    {
        var dummy_ws = createMockWebSocket(app.memory_strategy.generalAllocator());
        const conn_id = dummy_ws.getConnId();

        const sc = try app.openScopedConnection(&dummy_ws);
        defer sc.deinit();

        try testing.expectEqual(@as(u32, 0), violation_tracker_helpers.getViolationCount(&app.violation_tracker, conn_id));
    }
}

test "ConnectionManager - max connections" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "cm-max", &.{});
    defer app.deinit();

    // Set a small limit for testing
    app.connection_manager.max_connections = 2;

    var ws1 = createMockWebSocket(app.memory_strategy.generalAllocator());
    var ws2 = createMockWebSocket(app.memory_strategy.generalAllocator());
    var ws3 = createMockWebSocket(app.memory_strategy.generalAllocator());

    // Open 2 connections (at the limit)
    const sc1 = try app.openScopedConnection(&ws1);
    defer sc1.deinit();
    const sc2 = try app.openScopedConnection(&ws2);
    defer sc2.deinit();

    try testing.expectEqual(@as(usize, 2), app.connection_manager.map.count());

    // Third connection should be rejected (close called on ws)
    // Note: AppTestContext.openScopedConnection calls manager.onOpen
    // We should check if it's in the map.
    app.connection_manager.onOpen(&ws3) catch unreachable;
    try testing.expectEqual(@as(usize, 2), app.connection_manager.map.count());
    // The connection should not be in the map
    try testing.expectError(error.ConnectionNotFound, app.connection_manager.acquireConnection(ws3.getConnId()));
}

test "ConnectionManager - acquire and release" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-id-reuse", &.{});
    defer app.deinit();

    var ws = createMockWebSocket(app.memory_strategy.generalAllocator());
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();

    // Manual acquire incrementing refcount
    const conn = try app.connection_manager.acquireConnection(ws.getConnId());

    // We now have 3 references:
    // 1. Owned by the ConnectionManager (onOpen)
    // 2. Owned by the ScopedConnection (sc)
    // 3. Owned by this 'conn' pointer (manual acquire)
    // All 3 must be released for the memory to return to the pool.

    // sc.deinit() will drop its reference (sc.conn.release()) and call onClose.
    // onClose will drop manager's reference.
    // The connection will still exist until we drop our manual reference.

    // Drop our manual reference
    if (conn.release()) app.memory_strategy.releaseConnection(conn);
}

fn connectionCount(app: *AppTestContext) usize {
    app.connection_manager.mutex.lock();
    defer app.connection_manager.mutex.unlock();
    return app.connection_manager.map.count();
}

test "ConnectionManager: concurrent lifecycle drains to empty" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-property-lifecycle", &.{});
    defer app.deinit();

    const gpa = app.memory_strategy.generalAllocator();

    const ThreadContext = struct {
        app: *AppTestContext,
        allocator: std.mem.Allocator,
        iterations: usize,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            runInternal(ctx) catch |err| {
                std.log.err("connection lifecycle property failed: {}", .{err});
                ctx.failure = err;
            };
        }

        fn runInternal(ctx: *@This()) !void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var ws = helpers.createMockWebSocket(ctx.allocator);
                try ctx.app.connection_manager.onOpen(&ws);

                const conn = try ctx.app.connection_manager.acquireConnection(ws.getConnId());
                try testing.expectEqual(ws.getConnId(), conn.id);

                ctx.app.connection_manager.onClose(&ws);
                if (conn.release()) {
                    ctx.app.releaseConnection(conn);
                }
            }
        }
    };

    var contexts: [6]ThreadContext = undefined;
    var threads: [6]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{ .app = &app, .allocator = gpa, .iterations = 24 };
        threads[idx] = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }

    for (threads) |thread| {
        thread.join();
    }

    for (contexts) |ctx| {
        if (ctx.failure) |err| return err;
    }

    try testing.expectEqual(@as(usize, 0), connectionCount(&app));
}

test "ConnectionManager: concurrent reads preserve live set" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-property-reads", &.{});
    defer app.deinit();

    const gpa = app.memory_strategy.generalAllocator();
    const connection_count = 32;
    var websockets: [connection_count]WebSocket = undefined;
    var ids: [connection_count]u64 = undefined;

    for (&websockets, 0..) |*ws, idx| {
        ws.* = helpers.createMockWebSocket(gpa);
        try app.connection_manager.onOpen(ws);
        ids[idx] = ws.getConnId();
    }

    const ThreadContext = struct {
        app: *AppTestContext,
        ids: []const u64,
        iterations: usize,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            runInternal(ctx) catch |err| {
                std.log.err("connection read property failed: {}", .{err});
                ctx.failure = err;
            };
        }

        fn runInternal(ctx: *@This()) !void {
            var iteration: usize = 0;
            while (iteration < ctx.iterations) : (iteration += 1) {
                for (ctx.ids) |id| {
                    const conn = try ctx.app.connection_manager.acquireConnection(id);
                    if (conn.release()) {
                        ctx.app.releaseConnection(conn);
                    }
                }
            }
        }
    };

    var contexts: [4]ThreadContext = undefined;
    var threads: [4]std.Thread = undefined;
    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{ .app = &app, .ids = ids[0..], .iterations = 12 };
        threads[idx] = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }

    for (threads) |thread| {
        thread.join();
    }

    for (contexts) |ctx| {
        if (ctx.failure) |err| return err;
    }

    try testing.expectEqual(@as(usize, connection_count), connectionCount(&app));

    for (&websockets) |*ws| {
        app.connection_manager.onClose(ws);
    }
    try testing.expectEqual(@as(usize, 0), connectionCount(&app));
}

test "ConnectionManager: generated IDs are unique under concurrent opens" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-property-unique-ids", &.{});
    defer app.deinit();

    const gpa = app.memory_strategy.generalAllocator();
    const num_threads = 6;
    const opens_per_thread = 20;
    const expected_count = num_threads * opens_per_thread;
    var ids: [expected_count]u64 = undefined;

    const ThreadContext = struct {
        app: *AppTestContext,
        allocator: std.mem.Allocator,
        ids: []u64,
        offset: usize,
        count: usize,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            runInternal(ctx) catch |err| {
                std.log.err("connection id property failed: {}", .{err});
                ctx.failure = err;
            };
        }

        fn runInternal(ctx: *@This()) !void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                var ws = helpers.createMockWebSocket(ctx.allocator);
                try ctx.app.connection_manager.onOpen(&ws);
                ctx.ids[ctx.offset + i] = ws.getConnId();
                ctx.app.connection_manager.onClose(&ws);
            }
        }
    };

    var contexts: [num_threads]ThreadContext = undefined;
    var threads: [num_threads]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{
            .app = &app,
            .allocator = gpa,
            .ids = ids[0..],
            .offset = idx * opens_per_thread,
            .count = opens_per_thread,
        };
        threads[idx] = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }

    for (threads) |thread| {
        thread.join();
    }

    for (contexts) |ctx| {
        if (ctx.failure) |err| return err;
    }

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    for (ids) |id| {
        try testing.expect(!seen.contains(id));
        try seen.put(id, {});
    }

    try testing.expectEqual(@as(usize, expected_count), seen.count());
    try testing.expectEqual(@as(usize, 0), connectionCount(&app));
}
