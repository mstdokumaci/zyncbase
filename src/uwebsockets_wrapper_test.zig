const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
const WebSocketHandlers = @import("uwebsockets_wrapper.zig").WebSocketHandlers;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const c = @import("uwebsockets_wrapper.zig").c;

test "WebSocketServer: init with valid config" {
    const allocator = testing.allocator;

    const config = WebSocketServer.Config{
        .port = 8080,
        .host = "127.0.0.1",
        .ssl = false,
    };

    const server = try WebSocketServer.init(allocator, config);
    defer server.deinit();

    try testing.expectEqual(false, server.ssl);
}

test "WebSocketServer: init with SSL config" {
    // Skip this test as it requires valid certificates to not crash in uWS
    return error.SkipZigTest;
}

test "WebSocketServer: registerWebSocketHandlers" {
    const allocator = testing.allocator;

    const config = WebSocketServer.Config{
        .port = 8080,
        .host = "127.0.0.1",
        .ssl = false,
    };

    const server = try WebSocketServer.init(allocator, config);
    defer server.deinit();

    // Define handlers
    const handlers = WebSocketHandlers{
        .on_open = testOnOpen,
        .on_message = testOnMessage,
        .on_close = testOnClose,
        .on_error = null,
    };

    // Register handlers - this should not fail
    server.registerWebSocketHandlers("/*", handlers, null);
}

// Test handler functions
fn testOnOpen(ws: *WebSocket, user_data: ?*anyopaque) void {
    _ = ws;
    _ = user_data;
}

fn testOnMessage(ws: *WebSocket, message: []const u8, msg_type: MessageType, user_data: ?*anyopaque) void {
    _ = ws;
    _ = message;
    _ = msg_type;
    _ = user_data;
}

fn testOnClose(ws: *WebSocket, code: i32, message: []const u8, user_data: ?*anyopaque) void {
    _ = ws;
    _ = code;
    _ = message;
    _ = user_data;
}

test "MessageType: enum values" {
    try testing.expectEqual(@as(c_int, 1), @intFromEnum(MessageType.text));
    try testing.expectEqual(@as(c_int, 2), @intFromEnum(MessageType.binary));
}

test "WebSocketServer: full server lifecycle" {
    const allocator = testing.allocator;
    
    const server_ready = try allocator.create(std.atomic.Value(bool));
    defer allocator.destroy(server_ready);
    server_ready.* = std.atomic.Value(bool).init(false);
    
    const server_atomic_ptr = try allocator.create(std.atomic.Value(?*WebSocketServer));
    defer allocator.destroy(server_atomic_ptr);
    server_atomic_ptr.* = std.atomic.Value(?*WebSocketServer).init(null);

    const config = WebSocketServer.Config{
        .port = 9005,
    };

    const handlers = WebSocketHandlers{
        .on_open = struct {
            fn handler(_: *WebSocket, _: ?*anyopaque) void {}
        }.handler,
        .on_message = struct {
            fn handler(ws: *WebSocket, message: []const u8, _: MessageType, _: ?*anyopaque) void {
                ws.send(message, .text);
            }
        }.handler,
    };

    const ServerContext = struct {
        allocator: Allocator,
        config: WebSocketServer.Config,
        ready: *std.atomic.Value(bool),
        server_ptr: *std.atomic.Value(?*WebSocketServer),
        handlers: WebSocketHandlers,
        port: u16,

        fn runServer(ctx: @This()) void {
            // Initialize server on the server thread
            const server = WebSocketServer.init(ctx.allocator, ctx.config) catch return;
            ctx.server_ptr.store(server, .seq_cst);

            // Register WebSocket handlers on the server thread
            server.registerWebSocketHandlers("/*", ctx.handlers, null);

            // Add health check on the server thread
            c.uws_app_get(0, @ptrCast(server.app), "/", 1, struct {
                fn handler(res: ?*c.uws_res_t, _: ?*c.uws_req_t, _: ?*anyopaque) callconv(.c) void {
                    c.uws_res_end(0, res, "OK", 2, true);
                }
            }.handler, null);

            // Listen on the server thread
            server.listen(ctx.port) catch return;

            ctx.ready.store(true, .seq_cst);
            server.run();
            // NOTE: We don't deinit here because the main thread might still be calling close()
        }
    };

    const server_ctx = ServerContext{
        .allocator = allocator,
        .config = config,
        .ready = server_ready,
        .server_ptr = server_atomic_ptr,
        .handlers = handlers,
        .port = 9005,
    };

    const server_thread = try std.Thread.spawn(.{}, ServerContext.runServer, .{server_ctx});

    // Wait for server to be ready
    var timeout_counter: usize = 0;
    while (!server_ready.load(.seq_cst)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        timeout_counter += 1;
        if (timeout_counter > 50) { // 5 seconds timeout
            return error.ServerStartTimeout;
        }
    }
    
    const server = server_atomic_ptr.load(.seq_cst).?;

    // Execute Bun client
    const client_cmd = [_][]const u8{ "bun", "tests/integration/websocket_client.ts", "9005" };
    var child = std.process.Child.init(&client_cmd, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 10 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    // Shutdown server from main thread
    server.close();
    server_thread.join();
    
    // Now it's safe to deinit
    server.deinit();

    switch (term) {
        .Exited => |code| {
            try testing.expectEqual(@as(u32, 0), code);
        },
        else => return error.TestFailed,
    }
}
