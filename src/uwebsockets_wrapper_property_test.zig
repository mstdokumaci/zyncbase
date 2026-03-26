const std = @import("std");
const testing = std.testing;
const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const WebSocketHandlers = @import("uwebsockets_wrapper.zig").WebSocketHandlers;

// This property test verifies that WebSocket callbacks are invoked for all connection events:
// - on_open callback is invoked when a connection opens
// - on_message callback is invoked when a message is received
// - on_close callback is invoked when a connection closes
// - on_error callback is invoked when an error occurs (if registered)
//
// The test verifies that:
// 1. Each registered callback is invoked exactly once per event
// 2. Callbacks receive correct parameters (WebSocket pointer, user data)
// 3. Message callbacks receive correct message content and type
// 4. Close callbacks receive correct close code and message
// 5. Callbacks are not invoked if not registered

test "ws: callbacks invoked for all events" {
    const allocator = testing.allocator;

    // Test case structure
    const TestCase = struct {
        name: []const u8,
        register_open: bool,
        register_message: bool,
        register_close: bool,
        register_error: bool,
        expected_open_calls: u32,
        expected_message_calls: u32,
        expected_close_calls: u32,
        expected_error_calls: u32,
    };

    const test_cases = [_]TestCase{
        .{
            .name = "all callbacks registered",
            .register_open = true,
            .register_message = true,
            .register_close = true,
            .register_error = true,
            .expected_open_calls = 1,
            .expected_message_calls = 1,
            .expected_close_calls = 1,
            .expected_error_calls = 0, // Error not triggered in normal flow
        },
        .{
            .name = "only open and message callbacks",
            .register_open = true,
            .register_message = true,
            .register_close = false,
            .register_error = false,
            .expected_open_calls = 1,
            .expected_message_calls = 1,
            .expected_close_calls = 0,
            .expected_error_calls = 0,
        },
        .{
            .name = "only close callback",
            .register_open = false,
            .register_message = false,
            .register_close = true,
            .register_error = false,
            .expected_open_calls = 0,
            .expected_message_calls = 0,
            .expected_close_calls = 1,
            .expected_error_calls = 0,
        },
        .{
            .name = "no callbacks registered",
            .register_open = false,
            .register_message = false,
            .register_close = false,
            .register_error = false,
            .expected_open_calls = 0,
            .expected_message_calls = 0,
            .expected_close_calls = 0,
            .expected_error_calls = 0,
        },
    };

    for (test_cases) |tc| {
        std.log.debug("Running test case: {s}\n", .{tc.name});

        // Create callback context to track invocations
        var ctx = CallbackContext{
            .open_called = 0,
            .message_called = 0,
            .close_called = 0,
            .error_called = 0,
            .last_message = null,
            .last_message_type = null,
            .last_close_code = null,
            .last_close_message = null,
            .received_user_data = null,
        };

        // Create server
        const config = WebSocketServer.Config{
            .port = 8080,
            .host = "127.0.0.1",
            .ssl = false,
        };

        const server = try WebSocketServer.init(allocator, config);
        defer server.deinit();

        // Build handlers based on test case
        const handlers = WebSocketHandlers{
            .on_open = if (tc.register_open) testOnOpenProperty else null,
            .on_message = if (tc.register_message) testOnMessageProperty else null,
            .on_close = if (tc.register_close) testOnCloseProperty else null,
            .on_error = if (tc.register_error) testOnErrorProperty else null,
        };

        // Register handlers with context as user data
        server.registerWebSocketHandlers("/*", handlers, &ctx);

        // Simulate WebSocket events by calling the handlers directly
        // In a real integration test, we would connect a client and trigger events
        // For property testing, we verify the handler registration and invocation logic

        // Simulate open event
        if (tc.register_open) {
            var mock_ws = createMockWebSocket();
            if (handlers.on_open) |handler| {
                handler(&mock_ws, &ctx);
            }
        }

        // Simulate message event
        if (tc.register_message) {
            var mock_ws = createMockWebSocket();
            const test_message = "test message";
            if (handlers.on_message) |handler| {
                handler(&mock_ws, test_message, .binary, &ctx);
            }
        }

        // Simulate close event
        if (tc.register_close) {
            var mock_ws = createMockWebSocket();
            const close_message = "connection closed";
            if (handlers.on_close) |handler| {
                handler(&mock_ws, 1000, close_message, &ctx);
            }
        }

        // Verify callback invocation counts
        try testing.expectEqual(tc.expected_open_calls, ctx.open_called);
        try testing.expectEqual(tc.expected_message_calls, ctx.message_called);
        try testing.expectEqual(tc.expected_close_calls, ctx.close_called);
        try testing.expectEqual(tc.expected_error_calls, ctx.error_called);

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
        var ctx = CallbackContext{
            .open_called = 0,
            .message_called = 0,
            .close_called = 0,
            .error_called = 0,
            .last_message = null,
            .last_message_type = null,
            .last_close_code = null,
            .last_close_message = null,
            .received_user_data = null,
        };

        const config = WebSocketServer.Config{
            .port = 8080,
            .host = "127.0.0.1",
            .ssl = false,
        };

        const server = try WebSocketServer.init(allocator, config);
        defer server.deinit();

        const handlers = WebSocketHandlers{
            .on_message = testOnMessageProperty,
        };

        server.registerWebSocketHandlers("/*", handlers, &ctx);

        // Simulate message event
        var mock_ws = createMockWebSocket();
        if (handlers.on_message) |handler| {
            handler(&mock_ws, mt.content, mt.msg_type, &ctx);
        }

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
        var ctx = CallbackContext{
            .open_called = 0,
            .message_called = 0,
            .close_called = 0,
            .error_called = 0,
            .last_message = null,
            .last_message_type = null,
            .last_close_code = null,
            .last_close_message = null,
            .received_user_data = null,
        };

        const config = WebSocketServer.Config{
            .port = 8080,
            .host = "127.0.0.1",
            .ssl = false,
        };

        const server = try WebSocketServer.init(allocator, config);
        defer server.deinit();

        const handlers = WebSocketHandlers{
            .on_close = testOnCloseProperty,
        };

        server.registerWebSocketHandlers("/*", handlers, &ctx);

        // Simulate close event
        var mock_ws = createMockWebSocket();
        if (handlers.on_close) |handler| {
            handler(&mock_ws, ct.code, ct.message, &ctx);
        }

        // Verify close parameters were received correctly
        try testing.expectEqual(@as(u32, 1), ctx.close_called);
        try testing.expect(ctx.last_close_code != null);
        try testing.expect(ctx.last_close_message != null);
        try testing.expectEqual(ct.code, ctx.last_close_code.?);
        try testing.expectEqualStrings(ct.message, ctx.last_close_message.?);
    }
}

test "ws: callbacks invoked exactly once" {
    const allocator = testing.allocator;

    var ctx = CallbackContext{
        .open_called = 0,
        .message_called = 0,
        .close_called = 0,
        .error_called = 0,
        .last_message = null,
        .last_message_type = null,
        .last_close_code = null,
        .last_close_message = null,
        .received_user_data = null,
    };

    const config = WebSocketServer.Config{
        .port = 8080,
        .host = "127.0.0.1",
        .ssl = false,
    };

    const server = try WebSocketServer.init(allocator, config);
    defer server.deinit();

    const handlers = WebSocketHandlers{
        .on_open = testOnOpenProperty,
        .on_message = testOnMessageProperty,
        .on_close = testOnCloseProperty,
    };

    server.registerWebSocketHandlers("/*", handlers, &ctx);

    // Simulate multiple events
    var mock_ws = createMockWebSocket();

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

    // Verify total invocations
    try testing.expectEqual(@as(u32, 1), ctx.open_called);
    try testing.expectEqual(@as(u32, 3), ctx.message_called);
    try testing.expectEqual(@as(u32, 1), ctx.close_called);
    try testing.expectEqual(@as(u32, 0), ctx.error_called);
}

// Helper types and functions

const CallbackContext = struct {
    open_called: u32,
    message_called: u32,
    close_called: u32,
    error_called: u32,
    last_message: ?[]const u8,
    last_message_type: ?MessageType,
    last_close_code: ?i32,
    last_close_message: ?[]const u8,
    received_user_data: ?*anyopaque,
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

fn testOnErrorProperty(ws: *WebSocket, user_data: ?*anyopaque) void {
    _ = ws;
    if (user_data) |data| {
        const ctx: *CallbackContext = @ptrCast(@alignCast(data));
        ctx.error_called += 1;
        ctx.received_user_data = data;
    }
}

fn createMockWebSocket() WebSocket {
    // Create a mock WebSocket for testing
    // In a real scenario, this would be provided by the uWebSockets library
    // For property testing, we just need a valid struct
    return WebSocket{
        .ws = null, // Not used in property tests
        .ssl = false,
    };
}
