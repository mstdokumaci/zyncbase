const std = @import("std");
const testing = std.testing;
const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const WebSocketHandlers = @import("uwebsockets_wrapper.zig").WebSocketHandlers;

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

    const config = WebSocketServer.Config{
        .port = 8443,
        .host = "127.0.0.1",
        .ssl = true,
        .ssl_cert_path = "test_cert.pem",
        .ssl_key_path = "test_key.pem",
    };

    // This will fail because we don't have test certificates
    // But it tests the initialization path
    const server = WebSocketServer.init(allocator, config) catch |err| {
        // Expected to fail without actual certificates
        try testing.expect(err == error.FailedToCreateApp);
        return;
    };
    defer server.deinit();
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
    try server.registerWebSocketHandlers("/*", handlers, null);
}

// Test handler functions
fn testOnOpen(ws: *WebSocket, user_data: ?*anyopaque) void {
    _ = ws;
    _ = user_data;
    // Handler called on connection open
}

fn testOnMessage(ws: *WebSocket, message: []const u8, msg_type: MessageType, user_data: ?*anyopaque) void {
    _ = ws;
    _ = message;
    _ = msg_type;
    _ = user_data;
    // Handler called on message received
}

fn testOnClose(ws: *WebSocket, code: i32, message: []const u8, user_data: ?*anyopaque) void {
    _ = ws;
    _ = code;
    _ = message;
    _ = user_data;
    // Handler called on connection close
}

test "MessageType: enum values" {
    try testing.expectEqual(@as(c_int, 1), @intFromEnum(MessageType.text));
    try testing.expectEqual(@as(c_int, 2), @intFromEnum(MessageType.binary));
}

// Integration test for full lifecycle - requires running server
test "WebSocketServer: full server lifecycle" {
    if (true) return error.SkipZigTest; // Skip until we have integration test infrastructure

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

    // Register handlers
    try server.registerWebSocketHandlers("/*", handlers, null);

    // Start listening
    try server.listen(8080);

    // In a real test, we would:
    // 1. Start the server in a separate thread with server.run()
    // 2. Connect a WebSocket client
    // 3. Send/receive messages
    // 4. Verify handlers are called
    // 5. Close connection
    // 6. Shutdown server with server.close()

    server.close();
}
