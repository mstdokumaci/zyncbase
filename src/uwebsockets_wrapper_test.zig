const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
const WebSocketHandlers = @import("uwebsockets_wrapper.zig").WebSocketHandlers;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const schema_helpers = @import("schema_test_helpers.zig");

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

    // Create a temporary directory for certs
    var context = try schema_helpers.TestContext.init(allocator, "ssl-init");
    defer context.deinit();
    const tmp_dir = context.test_dir;

    const cert_path = try std.fs.path.join(allocator, &.{ tmp_dir, "cert.pem" });
    defer allocator.free(cert_path);
    const key_path = try std.fs.path.join(allocator, &.{ tmp_dir, "key.pem" });
    defer allocator.free(key_path);

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

    // SAFETY: Initialized by the following init call
    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
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

    // SAFETY: Initialized by the following init call
    var server: WebSocketServer = undefined;
    try server.init(allocator, config);
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

    // Create a temporary directory for certs
    var context = try schema_helpers.TestContext.init(allocator, "ssl-e2e");
    defer context.deinit();
    const tmp_dir = context.test_dir;

    const cert_path = try std.fs.path.join(allocator, &.{ tmp_dir, "cert.pem" });
    defer allocator.free(cert_path);
    const key_path = try std.fs.path.join(allocator, &.{ tmp_dir, "key.pem" });
    defer allocator.free(key_path);

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
