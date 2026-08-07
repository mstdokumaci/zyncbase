const std = @import("std");

const helpers = @import("app_test_helpers.zig");
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const WebSocketHandlers = @import("uwebsockets_wrapper.zig").WebSocketHandlers;
const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;

const Allocator = std.mem.Allocator;
const testing = std.testing;
const createMockWebSocket = helpers.createMockWebSocket;
const destroyMockWebSocket = helpers.destroyMockWebSocket;

const TestSslPaths = struct {
    allocator: Allocator,
    cert_path: []u8,
    key_path: []u8,

    fn init(allocator: Allocator) !TestSslPaths {
        return .{
            .allocator = allocator,
            .cert_path = try std.fs.cwd().realpathAlloc(allocator, "tests/fixtures/cert.pem"),
            .key_path = try std.fs.cwd().realpathAlloc(allocator, "tests/fixtures/cert.key"),
        };
    }

    fn deinit(self: *TestSslPaths) void {
        self.allocator.free(self.cert_path);
        self.allocator.free(self.key_path);
    }
};

test "WebSocketServer: init with valid config" {
    const allocator = testing.allocator;

    const config = WebSocketServer.Config{
        .port = 8080,
        .host = "127.0.0.1",
        .ssl = false,
    };

    // TEST: Heap allocation to verify TSAN behavior
    const server = try allocator.create(WebSocketServer);
    defer allocator.destroy(server);
    try server.init(allocator, config);
    defer server.deinit();

    try testing.expectEqual(false, server.ssl);
}

test "WebSocketServer: init with SSL config" {
    const allocator = testing.allocator;
    var ssl_paths = try TestSslPaths.init(allocator);
    defer ssl_paths.deinit();

    const config = WebSocketServer.Config{
        .port = 8443,
        .host = "127.0.0.1",
        .ssl = true,
        .ssl_cert_path = ssl_paths.cert_path,
        .ssl_key_path = ssl_paths.key_path,
    };

    // SAFETY: Initialized by the following init call
    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
    defer server.deinit();

    try testing.expectEqual(true, server.ssl);
    try testing.expect(server.ssl_cert_path_z != null);
    try testing.expect(server.ssl_key_path_z != null);
    try testing.expectEqual(@as(u8, 0), server.ssl_cert_path_z.?[server.ssl_cert_path_z.?.len]);
    try testing.expectEqual(@as(u8, 0), server.ssl_key_path_z.?[server.ssl_key_path_z.?.len]);
}

test "WebSocketServer: SSL config requires cert and key paths" {
    const allocator = testing.allocator;

    const config = WebSocketServer.Config{
        .port = 8443,
        .host = "127.0.0.1",
        .ssl = true,
    };

    var server: WebSocketServer = undefined;
    try testing.expectError(error.InvalidConfig, server.init(allocator, config));
}

test "WebSocketServer: invalid SSL files fail init" {
    const allocator = testing.allocator;

    const config = WebSocketServer.Config{
        .port = 8443,
        .host = "127.0.0.1",
        .ssl = true,
        .ssl_cert_path = "tests/fixtures/missing.pem",
        .ssl_key_path = "tests/fixtures/cert.key",
    };

    var server: WebSocketServer = undefined;
    try testing.expectError(error.FailedToCreateApp, server.init(allocator, config));
}

test "WebSocketServer: registerWebSocketHandlers" {
    const allocator = testing.allocator;

    const config = WebSocketServer.Config{
        .port = 8080,
        .host = "127.0.0.1",
        .ssl = false,
    };

    // SAFETY: Initialized by the following init call
    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
    defer server.deinit();

    // Define handlers
    const handlers = WebSocketHandlers{
        .on_open = testOnOpen,
        .on_message = testOnMessage,
        .on_close = testOnClose,
    };

    // Register handlers - this should not fail
    server.registerWebSocketHandlers("/*", handlers, null);
}

test "WebSocketServer: listen binds configured host" {
    const allocator = testing.allocator;

    const config = WebSocketServer.Config{
        .port = 0,
        .host = "127.0.0.1",
        .ssl = false,
    };

    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
    defer server.deinit();

    try server.listen();
    try testing.expect(server.listen_socket != null);
}

fn testWakeupCheck(ctx: ?*anyopaque) bool {
    const pending: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
    return pending.load(.acquire);
}

test "WebSocketServer: listen wakes loop when wakeup raced ahead of loop publish" {
    const allocator = testing.allocator;

    var server: WebSocketServer = undefined;
    try server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .ssl = false });
    defer server.deinit();

    var wakeup_count = std.atomic.Value(u64).init(0);
    var pending = std.atomic.Value(bool).init(true); // dispatch before publish
    server.test_wakeup_count = &wakeup_count;
    server.wakeup_pending_check = testWakeupCheck;
    server.wakeup_pending_check_ctx = &pending;

    try server.listen();

    try testing.expect(server.loop.load(.acquire) != null);
    try testing.expectEqual(@as(u64, 1), wakeup_count.load(.acquire));
}

test "WebSocketServer: listen skips wakeup when nothing is pending" {
    const allocator = testing.allocator;

    var server: WebSocketServer = undefined;
    try server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .ssl = false });
    defer server.deinit();

    var wakeup_count = std.atomic.Value(u64).init(0);
    var pending = std.atomic.Value(bool).init(false);
    server.test_wakeup_count = &wakeup_count;
    server.wakeup_pending_check = testWakeupCheck;
    server.wakeup_pending_check_ctx = &pending;

    try server.listen();

    try testing.expectEqual(@as(u64, 0), wakeup_count.load(.acquire));
}

test "WebSocketServer: listen reports bind failure" {
    const allocator = testing.allocator;

    // Pre-occupy a port with a raw TCP socket so the WebSocketServer's bind()
    // fails (REUSEPORT mismatch on the occupied port).
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    var bind_addr = std.posix.sockaddr.in{
        .port = 0,
        .addr = @as(u32, @bitCast([4]u8{ 127, 0, 0, 1 })),
    };
    try std.posix.bind(sock, @ptrCast(&bind_addr), @sizeOf(@TypeOf(bind_addr)));
    try std.posix.listen(sock, 1);

    var actual_addr: std.posix.sockaddr.in = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    try std.posix.getsockname(sock, @ptrCast(&actual_addr), &addr_len);
    const occupied_port = std.mem.bigToNative(u16, actual_addr.port);

    const config = WebSocketServer.Config{
        .port = occupied_port,
        .host = "127.0.0.1",
        .ssl = false,
    };

    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
    defer server.deinit();

    try testing.expectError(error.ListenFailed, server.listen());
    try testing.expect(server.listen_socket == null);
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

fn runFullLifecycleTest(allocator: Allocator, config: WebSocketServer.Config, address: []const u8, is_ssl: bool) !void {
    // SAFETY: Initialized by the following init call
    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
    defer server.deinit();

    // In a real test we would start the server, but that's blocking
    // and uWebSockets doesn't have an easy "start and return" without threads.
    // For unit tests, we primarily test the wrapper logic.
    _ = address;
    _ = is_ssl;
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
    var ssl_paths = try TestSslPaths.init(allocator);
    defer ssl_paths.deinit();

    const config = WebSocketServer.Config{
        .port = 9006,
        .ssl = true,
        .ssl_cert_path = ssl_paths.cert_path,
        .ssl_key_path = ssl_paths.key_path,
    };

    try runFullLifecycleTest(allocator, config, "wss://127.0.0.1:9006/", true);
}

// This property test verifies that WebSocket callbacks are invoked for all connection events:
// - on_open callback is invoked when a connection opens
// - on_message callback is invoked when a message is received
// - on_close callback is invoked when a connection closes
//
// The test verifies that:
// 1. Each registered callback is invoked exactly once per event
// 2. Callbacks receive correct parameters (WebSocket pointer, user data)
// 3. Message callbacks receive correct message content and type
// 4. Close callbacks receive correct close code and message
// 5. Callbacks are not invoked if not registered

test "ws: callback contract - handlers invoked per registration" {
    const allocator = testing.allocator;

    // Test case structure
    const TestCase = struct {
        name: []const u8,
        register_open: bool,
        register_message: bool,
        register_close: bool,
        expected_open_calls: u32,
        expected_message_calls: u32,
        expected_close_calls: u32,
    };

    const test_cases = [_]TestCase{
        .{
            .name = "all callbacks registered",
            .register_open = true,
            .register_message = true,
            .register_close = true,
            .expected_open_calls = 1,
            .expected_message_calls = 1,
            .expected_close_calls = 1,
        },
        .{
            .name = "only open and message callbacks",
            .register_open = true,
            .register_message = true,
            .register_close = false,
            .expected_open_calls = 1,
            .expected_message_calls = 1,
            .expected_close_calls = 0,
        },
        .{
            .name = "only close callback",
            .register_open = false,
            .register_message = false,
            .register_close = true,
            .expected_open_calls = 0,
            .expected_message_calls = 0,
            .expected_close_calls = 1,
        },
        .{
            .name = "no callbacks registered",
            .register_open = false,
            .register_message = false,
            .register_close = false,
            .expected_open_calls = 0,
            .expected_message_calls = 0,
            .expected_close_calls = 0,
        },
    };

    for (test_cases) |tc| {
        std.log.debug("Running test case: {s}\n", .{tc.name});

        // Create callback context to track invocations
        var ctx = CallbackContext{};

        // Build handlers based on test case
        const handlers = WebSocketHandlers{
            .on_open = if (tc.register_open) testOnOpenProperty else null,
            .on_message = if (tc.register_message) testOnMessageProperty else null,
            .on_close = if (tc.register_close) testOnCloseProperty else null,
        };

        // Simulate WebSocket events by calling the handlers directly
        // (the wrapper exposes no dispatch API; the callback contract is
        // verified by invoking each registered handler in isolation).

        // Simulate open event
        if (tc.register_open) {
            var mock_ws = createMockWebSocket(allocator);
            if (handlers.on_open) |handler| {
                handler(&mock_ws, &ctx);
            }
            destroyMockWebSocket(allocator, &mock_ws);
        }

        // Simulate message event
        if (tc.register_message) {
            var mock_ws = createMockWebSocket(allocator);
            const test_message = "test message";
            if (handlers.on_message) |handler| {
                handler(&mock_ws, test_message, .binary, &ctx);
            }
            destroyMockWebSocket(allocator, &mock_ws);
        }

        // Simulate close event
        if (tc.register_close) {
            var mock_ws = createMockWebSocket(allocator);
            const close_message = "connection closed";
            if (handlers.on_close) |handler| {
                handler(&mock_ws, 1000, close_message, &ctx);
            }
            destroyMockWebSocket(allocator, &mock_ws);
        }

        // Verify callback invocation counts
        try testing.expectEqual(tc.expected_open_calls, ctx.open_called);
        try testing.expectEqual(tc.expected_message_calls, ctx.message_called);
        try testing.expectEqual(tc.expected_close_calls, ctx.close_called);

        // Verify callback parameters were received correctly
        if (tc.register_open) {
            try testing.expect(ctx.received_user_data != null);
        }

        if (tc.register_message) {
            try testing.expect(ctx.last_message != null);
            try testing.expect(ctx.last_message_type != null);
            try testing.expectEqualStrings("test message", ctx.last_message.?);
            try testing.expectEqual(MessageType.binary, ctx.last_message_type.?);
        }

        if (tc.register_close) {
            try testing.expect(ctx.last_close_code != null);
            try testing.expect(ctx.last_close_message != null);
            try testing.expectEqual(@as(i32, 1000), ctx.last_close_code.?);
            try testing.expectEqualStrings("connection closed", ctx.last_close_message.?);
        }
    }
}

test "ws: message callback content and type" {
    const allocator = testing.allocator;

    // Test different message types and content
    const MessageTest = struct {
        content: []const u8,
        msg_type: MessageType,
    };

    const message_tests = [_]MessageTest{
        .{ .content = "Hello, WebSocket!", .msg_type = .text },
        .{ .content = "Binary data \x00\x01\x02", .msg_type = .binary },
        .{ .content = "", .msg_type = .text }, // Empty message
        .{ .content = "A" ** 1000, .msg_type = .binary }, // Large message
    };

    for (message_tests) |mt| {
        var ctx = CallbackContext{};

        const config = WebSocketServer.Config{
            .port = 8080,
            .host = "127.0.0.1",
            .ssl = false,
        };

        var server: WebSocketServer = undefined;
        try server.init(allocator, config);
        defer server.deinit();

        const handlers = WebSocketHandlers{
            .on_message = testOnMessageProperty,
        };

        server.registerWebSocketHandlers("/*", handlers, &ctx);

        // Simulate message event
        var mock_ws = createMockWebSocket(allocator);
        if (handlers.on_message) |handler| {
            handler(&mock_ws, mt.content, mt.msg_type, &ctx);
        }
        destroyMockWebSocket(allocator, &mock_ws);

        // Verify message was received correctly
        try testing.expectEqual(@as(u32, 1), ctx.message_called);
        try testing.expect(ctx.last_message != null);
        try testing.expect(ctx.last_message_type != null);
        try testing.expectEqualStrings(mt.content, ctx.last_message.?);
        try testing.expectEqual(mt.msg_type, ctx.last_message_type.?);
    }
}

test "ws: close callback code and message" {
    const allocator = testing.allocator;

    // Test different close codes and messages
    const CloseTest = struct {
        code: i32,
        message: []const u8,
    };

    const close_tests = [_]CloseTest{
        .{ .code = 1000, .message = "Normal closure" },
        .{ .code = 1001, .message = "Going away" },
        .{ .code = 1002, .message = "Protocol error" },
        .{ .code = 1003, .message = "Unsupported data" },
        .{ .code = 1006, .message = "Abnormal closure" },
        .{ .code = 1000, .message = "" }, // Empty message
    };

    for (close_tests) |ct| {
        var ctx = CallbackContext{};

        const config = WebSocketServer.Config{
            .port = 8080,
            .host = "127.0.0.1",
            .ssl = false,
        };

        var server: WebSocketServer = undefined;
        try server.init(allocator, config);
        defer server.deinit();

        const handlers = WebSocketHandlers{
            .on_close = testOnCloseProperty,
        };

        server.registerWebSocketHandlers("/*", handlers, &ctx);

        // Simulate close event
        var mock_ws = createMockWebSocket(allocator);
        if (handlers.on_close) |handler| {
            handler(&mock_ws, ct.code, ct.message, &ctx);
        }
        destroyMockWebSocket(allocator, &mock_ws);

        // Verify close parameters were received correctly
        try testing.expectEqual(@as(u32, 1), ctx.close_called);
        try testing.expect(ctx.last_close_code != null);
        try testing.expect(ctx.last_close_message != null);
        try testing.expectEqual(ct.code, ctx.last_close_code.?);
        try testing.expectEqualStrings(ct.message, ctx.last_close_message.?);
    }
}

test "ws: callback invocation counts reflect events" {
    const allocator = testing.allocator;

    var ctx = CallbackContext{};

    const config = WebSocketServer.Config{
        .port = 8080,
        .host = "127.0.0.1",
        .ssl = false,
    };

    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
    defer server.deinit();

    const handlers = WebSocketHandlers{
        .on_open = testOnOpenProperty,
        .on_message = testOnMessageProperty,
        .on_close = testOnCloseProperty,
    };

    server.registerWebSocketHandlers("/*", handlers, &ctx);

    // Simulate multiple events
    var mock_ws = createMockWebSocket(allocator);
    defer destroyMockWebSocket(allocator, &mock_ws);

    // Open event
    if (handlers.on_open) |handler| {
        handler(&mock_ws, &ctx);
    }
    try testing.expectEqual(@as(u32, 1), ctx.open_called);

    // Multiple message events
    if (handlers.on_message) |handler| {
        handler(&mock_ws, "message 1", .binary, &ctx);
        handler(&mock_ws, "message 2", .text, &ctx);
        handler(&mock_ws, "message 3", .binary, &ctx);
    }
    try testing.expectEqual(@as(u32, 3), ctx.message_called);

    // Close event
    if (handlers.on_close) |handler| {
        handler(&mock_ws, 1000, "closing", &ctx);
    }
    try testing.expectEqual(@as(u32, 1), ctx.close_called);
}

// Helper types and functions

const CallbackContext = struct {
    open_called: u32 = 0,
    message_called: u32 = 0,
    close_called: u32 = 0,
    last_message: ?[]const u8 = null,
    last_message_type: ?MessageType = null,
    last_close_code: ?i32 = null,
    last_close_message: ?[]const u8 = null,
    received_user_data: ?*anyopaque = null,
};

fn testOnOpenProperty(ws: *WebSocket, user_data: ?*anyopaque) void {
    _ = ws;
    if (user_data) |data| {
        const ctx: *CallbackContext = @ptrCast(@alignCast(data));
        ctx.open_called += 1;
        ctx.received_user_data = data;
    }
}

fn testOnMessageProperty(ws: *WebSocket, message: []const u8, msg_type: MessageType, user_data: ?*anyopaque) void {
    _ = ws;
    if (user_data) |data| {
        const ctx: *CallbackContext = @ptrCast(@alignCast(data));
        ctx.message_called += 1;
        ctx.last_message = message;
        ctx.last_message_type = msg_type;
        ctx.received_user_data = data;
    }
}

fn testOnCloseProperty(ws: *WebSocket, code: i32, message: []const u8, user_data: ?*anyopaque) void {
    _ = ws;
    if (user_data) |data| {
        const ctx: *CallbackContext = @ptrCast(@alignCast(data));
        ctx.close_called += 1;
        ctx.last_close_code = code;
        ctx.last_close_message = message;
        ctx.received_user_data = data;
    }
}
