const std = @import("std");

pub const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
pub const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
pub const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("lock_free_cache_test.zig");
    _ = @import("uwebsockets_wrapper_test.zig");
    _ = @import("uwebsockets_wrapper_property_test.zig");
    _ = @import("messagepack_parser_test.zig");
    _ = @import("hook_server_client_test.zig");
    _ = @import("hook_server_client_property_test.zig");
    _ = @import("checkpoint_manager_test.zig");
    _ = @import("checkpoint_manager_property_test.zig");
    _ = @import("subscription_manager_test.zig");
    _ = @import("subscription_manager_property_test.zig");
    _ = @import("subscription_manager_perf_test.zig");
    _ = @import("request_handler_test.zig");
    _ = @import("memory_safety_property_test.zig");
    _ = @import("config_loader_test.zig");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting ZyncBase WebSocket server...", .{});

    // Create WebSocket server
    const server = try WebSocketServer.init(allocator, .{
        .port = 9001,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // Register WebSocket handlers
    try server.registerWebSocketHandlers(
        "/*",
        .{
            .on_open = onWebSocketOpen,
            .on_message = onWebSocketMessage,
            .on_close = onWebSocketClose,
        },
        null,
    );

    // Start listening
    try server.listen(9001);

    std.log.info("WebSocket server listening on 127.0.0.1:9001", .{});

    // Run event loop (blocks until shutdown)
    server.run();
}

fn onWebSocketOpen(ws: *WebSocket, user_data: ?*anyopaque) void {
    _ = user_data;
    std.log.info("WebSocket connection opened", .{});
    _ = ws;
}

fn onWebSocketMessage(
    ws: *WebSocket,
    message: []const u8,
    msg_type: @import("uwebsockets_wrapper.zig").MessageType,
    user_data: ?*anyopaque,
) void {
    _ = user_data;
    std.log.info("Received message: type={s}, length={d}", .{
        @tagName(msg_type),
        message.len,
    });

    // Echo the message back
    ws.send(message, msg_type);
}

fn onWebSocketClose(
    ws: *WebSocket,
    code: i32,
    message: []const u8,
    user_data: ?*anyopaque,
) void {
    _ = ws;
    _ = user_data;
    std.log.info("WebSocket connection closed: code={d}, message={s}", .{
        code,
        message,
    });
}
