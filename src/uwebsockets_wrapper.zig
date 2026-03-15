const std = @import("std");
const Allocator = std.mem.Allocator;

// C imports for Bun's uWebSockets wrapper
// Using our wrapper header to avoid C++ enum issues
pub const c = @cImport({
    @cInclude("uws_wrapper.h");
});

// Note: We don't need extern declarations since they're in the header
// The actual implementations are in libuwsockets.cpp which is linked by build.zig

/// WebSocket server wrapper using Bun's uWebSockets C API
pub const WebSocketServer = struct {
    app: *c.uws_app_t,
    allocator: Allocator,
    ssl: bool,
    handlers: WebSocketHandlers,
    user_data: ?*anyopaque,

    pub const Config = struct {
        port: u16,
        host: []const u8 = "0.0.0.0",
        ssl: bool = false,
        ssl_cert_path: ?[]const u8 = null,
        ssl_key_path: ?[]const u8 = null,
    };

    pub const Error = error{
        FailedToCreateApp,
        ListenFailed,
        InvalidConfig,
        OutOfMemory,
    };

    /// Initialize WebSocket server
    /// Requirements: 2.1, 2.3
    pub fn init(allocator: Allocator, config: Config) Error!*WebSocketServer {
        const self = try allocator.create(WebSocketServer);
        errdefer allocator.destroy(self);

        // Create uWebSockets app using Bun's wrapper
        // For now, pass empty SSL options (will be enhanced later for SSL support)
        const ssl_options = std.mem.zeroes(c.us_bun_socket_context_options_t);
        const app = c.uws_create_app(
            if (config.ssl) 1 else 0,
            ssl_options,
        );

        if (app == null) {
            return error.FailedToCreateApp;
        }

        self.* = .{
            .app = app.?,
            .allocator = allocator,
            .ssl = config.ssl,
            .handlers = .{},
            .user_data = null,
        };

        return self;
    }

    /// Clean up resources
    /// Requirements: 2.7
    pub fn deinit(self: *WebSocketServer) void {
        // Clear global server if it points to us
        if (global_server == self) {
            global_server = null;
        }

        // Note: uws_app_destroy is not exposed in the C API
        // The app will be cleaned up when the process exits
        self.allocator.destroy(self);
    }

    /// Register WebSocket handlers for a route pattern
    /// Requirements: 2.4
    pub fn registerWebSocketHandlers(
        self: *WebSocketServer,
        pattern: []const u8,
        handlers: WebSocketHandlers,
        user_data: ?*anyopaque,
    ) !void {
        self.handlers = handlers;
        self.user_data = user_data;

        // Store server in global for C callback access
        // Note: This limits us to one server instance, but that's acceptable for MVP
        global_server = self;

        // Create behavior struct with WebSocket configuration
        var behavior = std.mem.zeroes(c.uws_socket_behavior_t);
        behavior.compression = c.UWS_COMPRESS_DISABLED;
        behavior.maxPayloadLength = 10 * 1024 * 1024; // 10MB
        behavior.idleTimeout = 120; // 2 minutes
        behavior.maxBackpressure = 64 * 1024; // 64KB
        behavior.closeOnBackpressureLimit = false;
        behavior.resetIdleTimeoutOnSend = false;
        behavior.sendPingsAutomatically = true;
        behavior.maxLifetime = 0; // Disabled

        // Set callback handlers - these will call our Zig wrappers
        behavior.open = if (handlers.on_open != null) onOpenCallback else null;
        behavior.message = if (handlers.on_message != null) onMessageCallback else null;
        behavior.close = if (handlers.on_close != null) onCloseCallback else null;
        behavior.drain = null; // Not used for MVP
        behavior.ping = null; // Not used for MVP
        behavior.pong = null; // Not used for MVP

        // Register WebSocket route with uWebSockets
        c.uws_ws(
            if (self.ssl) 1 else 0,
            self.app,
            self, // Pass server as upgrade context to access handlers
            pattern.ptr,
            pattern.len,
            0, // id parameter
            &behavior,
        );
    }

    /// Start listening on specified port
    /// Requirements: 2.5
    pub fn listen(self: *WebSocketServer, port: u16) !void {
        // Use uws_app_listen to start listening
        c.uws_app_listen(
            if (self.ssl) 1 else 0,
            self.app,
            port,
            listenCallback,
            self,
        );
    }

    /// Run the event loop (blocks until shutdown)
    /// Requirements: 2.6
    pub fn run(self: *WebSocketServer) void {
        c.uws_app_run(if (self.ssl) 1 else 0, self.app);
    }

    /// Close the server gracefully
    /// Requirements: 2.7
    pub fn close(self: *WebSocketServer) void {
        c.uws_app_close(if (self.ssl) 1 else 0, self.app);
    }
};

/// WebSocket connection wrapper
pub const WebSocket = struct {
    ws: ?*c.uws_websocket_t,
    ssl: bool,
    user_data: ?*anyopaque = null, // For testing purposes

    /// Send a message through the WebSocket
    pub fn send(self: *WebSocket, message: []const u8, msg_type: MessageType) void {
        if (self.ws == null) return; // Mock WebSocket, no-op

        const opcode: c.uws_opcode_t = switch (msg_type) {
            .text => c.UWS_OPCODE_TEXT,
            .binary => c.UWS_OPCODE_BINARY,
        };

        _ = c.uws_ws_send(
            if (self.ssl) 1 else 0,
            self.ws.?,
            message.ptr,
            message.len,
            opcode,
        );
    }

    /// Close the WebSocket connection
    pub fn close(self: *WebSocket) void {
        if (self.ws == null) return; // Mock WebSocket, no-op
        c.uws_ws_close(if (self.ssl) 1 else 0, self.ws.?);
    }

    /// Get user data associated with this WebSocket
    pub fn getUserData(self: *WebSocket) ?*anyopaque {
        // In tests (when ws is null), use the user_data field
        if (self.ws == null) {
            return self.user_data;
        }
        return c.uws_ws_get_user_data(if (self.ssl) 1 else 0, self.ws.?);
    }

    /// Set user data for this WebSocket
    pub fn setUserData(self: *WebSocket, user_data: ?*anyopaque) void {
        // In tests (when ws is null), use the user_data field
        if (self.ws == null) {
            self.user_data = user_data;
            return;
        }
        // Note: uws_ws_set_user_data is not exposed in the C API
        // User data is typically managed during connection open
    }
};

/// Message type enum
pub const MessageType = enum(c_int) {
    text = 1,
    binary = 2,
};

/// WebSocket event handlers
pub const WebSocketHandlers = struct {
    on_open: ?*const fn (*WebSocket, ?*anyopaque) void = null,
    on_message: ?*const fn (*WebSocket, []const u8, MessageType, ?*anyopaque) void = null,
    on_close: ?*const fn (*WebSocket, i32, []const u8, ?*anyopaque) void = null,
    on_error: ?*const fn (*WebSocket, ?*anyopaque) void = null,
};

// Global storage for server context (needed for C callbacks)
// This is a workaround since C callbacks can't capture Zig context directly
var global_server: ?*WebSocketServer = null;

/// Listen callback - called when server starts listening
fn listenCallback(listen_socket: ?*c.struct_us_listen_socket_t, user_data: ?*anyopaque) callconv(.c) void {
    _ = listen_socket;
    _ = user_data;
    // Server is now listening
    std.log.info("WebSocket server listening", .{});
}

/// C callback wrapper for WebSocket open event
/// Requirements: 2.9
fn onOpenCallback(ws: ?*c.uws_websocket_t) callconv(.c) void {
    if (ws == null) return;

    // Get server context from global (set during registerWebSocketHandlers)
    const server = global_server orelse return;

    // Create Zig WebSocket wrapper
    var zig_ws = WebSocket{
        .ws = ws.?,
        .ssl = server.ssl,
    };

    // Call Zig handler if registered
    if (server.handlers.on_open) |handler| {
        handler(&zig_ws, server.user_data);
    }
}

/// C callback wrapper for WebSocket message event
/// Requirements: 2.9
fn onMessageCallback(
    ws: ?*c.uws_websocket_t,
    message: [*c]const u8,
    length: usize,
    opcode: c.uws_opcode_t,
) callconv(.c) void {
    if (ws == null or message == null) return;

    // Get server context
    const server = global_server orelse return;

    // Create Zig WebSocket wrapper
    var zig_ws = WebSocket{
        .ws = ws.?,
        .ssl = server.ssl,
    };

    // Convert message to slice
    const msg_slice = message[0..length];

    // Determine message type
    const msg_type: MessageType = switch (opcode) {
        c.UWS_OPCODE_TEXT => .text,
        c.UWS_OPCODE_BINARY => .binary,
        else => .binary,
    };

    // Call Zig handler if registered
    if (server.handlers.on_message) |handler| {
        handler(&zig_ws, msg_slice, msg_type, server.user_data);
    }
}

/// C callback wrapper for WebSocket close event
/// Requirements: 2.9
fn onCloseCallback(
    ws: ?*c.uws_websocket_t,
    code: c_int,
    message: [*c]const u8,
    length: usize,
) callconv(.c) void {
    if (ws == null) return;

    // Get server context
    const server = global_server orelse return;

    // Create Zig WebSocket wrapper
    var zig_ws = WebSocket{
        .ws = ws.?,
        .ssl = server.ssl,
    };

    // Convert message to slice
    const msg_slice = if (message != null) message[0..length] else "";

    // Call Zig handler if registered
    if (server.handlers.on_close) |handler| {
        handler(&zig_ws, code, msg_slice, server.user_data);
    }
}
