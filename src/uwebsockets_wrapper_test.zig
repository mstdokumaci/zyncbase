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
    const allocator = testing.allocator;

    // Create a temporary directory for certs
    const tmp_dir = "test-artifacts/ssl_tmp";
    std.fs.cwd().makePath(tmp_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const cert_path = tmp_dir ++ "/cert.pem";
    const key_path = tmp_dir ++ "/key.pem";

    // Generate self-signed cert on the fly
    const openssl_cmd = [_][]const u8{ "openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key_path, "-out", cert_path, "-days", "1", "-nodes", "-subj", "/CN=localhost" };
    var child = std.process.Child.init(&openssl_cmd, allocator);
    const term = try child.spawnAndWait();
    try testing.expectEqual(@as(std.process.Child.Term, .{ .Exited = 0 }), term);

    const config = WebSocketServer.Config{
        .port = 8443,
        .host = "127.0.0.1",
        .ssl = true,
        .ssl_cert_path = cert_path,
        .ssl_key_path = key_path,
    };

    const server = try WebSocketServer.init(allocator, config);
    defer server.deinit();

    try testing.expectEqual(true, server.ssl);
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
    const config = WebSocketServer.Config{
        .port = 9005,
        .ssl = false,
    };
    try runFullLifecycleTest(allocator, config, "9005", false);
}

test "WebSocketServer: full server lifecycle with SSL" {
    const allocator = testing.allocator;

    // Create a temporary directory for certs
    const tmp_dir = "test-artifacts/ssl_e2e_tmp";
    std.fs.cwd().makePath(tmp_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const cert_path = tmp_dir ++ "/cert.pem";
    const key_path = tmp_dir ++ "/key.pem";

    // Generate self-signed cert on the fly
    const openssl_cmd = [_][]const u8{ "openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key_path, "-out", cert_path, "-days", "1", "-nodes", "-subj", "/CN=localhost" };
    var child = std.process.Child.init(&openssl_cmd, allocator);
    const term = try child.spawnAndWait();
    try testing.expectEqual(@as(std.process.Child.Term, .{ .Exited = 0 }), term);

    const config = WebSocketServer.Config{
        .port = 9006,
        .ssl = true,
        .ssl_cert_path = cert_path,
        .ssl_key_path = key_path,
    };

    try runFullLifecycleTest(allocator, config, "wss://127.0.0.1:9006/", true);
}

fn runFullLifecycleTest(
    allocator: Allocator,
    config: WebSocketServer.Config,
    client_arg: []const u8,
    ignore_tls: bool,
) !void {
    const server_ready = try allocator.create(std.atomic.Value(bool));
    defer allocator.destroy(server_ready);
    server_ready.* = std.atomic.Value(bool).init(false);

    const server_error = try allocator.create(std.atomic.Value(bool));
    defer allocator.destroy(server_error);
    server_error.* = std.atomic.Value(bool).init(false);

    const server_atomic_ptr = try allocator.create(std.atomic.Value(?*WebSocketServer));
    defer allocator.destroy(server_atomic_ptr);
    server_atomic_ptr.* = std.atomic.Value(?*WebSocketServer).init(null);

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
        err: *std.atomic.Value(bool),
        server_ptr: *std.atomic.Value(?*WebSocketServer),
        handlers: WebSocketHandlers,

        fn runServer(ctx: @This()) void {
            const server = WebSocketServer.init(ctx.allocator, ctx.config) catch {
                ctx.err.store(true, .seq_cst);
                return;
            };
            ctx.server_ptr.store(server, .seq_cst);

            server.registerWebSocketHandlers("/*", ctx.handlers, null);

            c.uws_app_get(if (server.ssl) 1 else 0, @ptrCast(server.app), "/", 1, struct {
                fn handler(res: ?*c.uws_res_t, _: ?*c.uws_req_t, user_data: ?*anyopaque) callconv(.c) void {
                    const is_ssl: bool = @intFromPtr(user_data) != 0;
                    c.uws_res_end(if (is_ssl) 1 else 0, res, "OK", 2, true);
                }
            }.handler, @ptrFromInt(@as(usize, if (server.ssl) 1 else 0)));

            server.listen(ctx.config.port) catch {
                ctx.err.store(true, .seq_cst);
                return;
            };

            server.run();
        }
    };

    const server_ctx = ServerContext{
        .allocator = allocator,
        .config = config,
        .ready = server_ready,
        .err = server_error,
        .server_ptr = server_atomic_ptr,
        .handlers = handlers,
    };

    const server_thread = try std.Thread.spawn(.{}, ServerContext.runServer, .{server_ctx});

    // Wait for server to be ready or fail
    var timeout_counter: usize = 0;
    while (true) {
        if (server_error.load(.seq_cst)) {
            return error.ServerInitializationFailed;
        }
        if (server_atomic_ptr.load(.seq_cst)) |s| {
            if (s.is_listening.load(.monotonic)) {
                break;
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
        timeout_counter += 1;
        if (timeout_counter > 50) {
            return error.ServerStartTimeout;
        }
    }

    const server = server_atomic_ptr.load(.seq_cst) orelse return error.NullServerPointer;

    // Execute Bun client
    const client_cmd = [_][]const u8{ "bun", "tests/integration/websocket_client.ts", client_arg };
    var child = std.process.Child.init(&client_cmd, allocator);

    // Set environment variable if TLS should be ignored
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    if (ignore_tls) {
        try env_map.put("NODE_TLS_REJECT_UNAUTHORIZED", "0");
    }
    child.env_map = &env_map;

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 10 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    // Shutdown server
    server.close();

    // Safety join: ThreadSanitizer will detect if we exit before the thread is gone
    server_thread.join();

    // Now it's safe to deinit
    server.deinit();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Client stdout: {s}\n", .{stdout});
                std.debug.print("Client stderr: {s}\n", .{stderr});
            }
            try testing.expectEqual(@as(u32, 0), code);
        },
        else => {
            std.debug.print("Client stderr: {s}\n", .{stderr});
            return error.TestFailed;
        },
    }
}
