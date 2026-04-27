const std = @import("std");
const testing = std.testing;

const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

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

    const ThreadContext = struct {
        app: *AppTestContext,
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
                var ws = helpers.createMockWebSocket();
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
        ctx.* = .{ .app = &app, .iterations = 24 };
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

    const connection_count = 32;
    var websockets: [connection_count]WebSocket = undefined;
    var ids: [connection_count]u64 = undefined;

    for (&websockets, 0..) |*ws, idx| {
        ws.* = helpers.createMockWebSocket();
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

    const num_threads = 6;
    const opens_per_thread = 20;
    const expected_count = num_threads * opens_per_thread;
    var ids: [expected_count]u64 = undefined;

    const ThreadContext = struct {
        app: *AppTestContext,
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
                var ws = helpers.createMockWebSocket();
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
