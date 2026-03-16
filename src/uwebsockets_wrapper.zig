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
    listen_socket: ?*c.struct_us_listen_socket_t = null,
    loop: ?*anyopaque = null,
    close_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
            .listen_socket = null,
            .loop = null,
            .close_requested = std.atomic.Value(bool).init(false),
        };

        return self;
    }

    /// Clean up resources
    /// Requirements: 2.7
    pub fn deinit(self: *WebSocketServer) void {
        // Note: uws_app_destroy is not exposed in the C API
        // The app will be cleaned up when the process exits
        self.allocator.destroy(self);
    }

    /// Register WebSocket handlers for a specific pattern
    /// Requirements: 2.2, 2.5
    pub fn registerWebSocketHandlers(self: *WebSocketServer, pattern: []const u8, handlers: WebSocketHandlers, user_data: ?*anyopaque) void {
        self.handlers = handlers;
        self.user_data = user_data;
        
        // Create the C handlers struct (behavior)
        var behavior = std.mem.zeroes(c.uws_socket_behavior_t);
        behavior.maxPayloadLength = 16 * 1024 * 1024;
        behavior.idleTimeout = 120;
        behavior.sendPingsAutomatically = true;
        
        // Setup upgrade context (user_data)
        const ssl_flag: c_int = if (self.ssl) 1 else 0;
        const id = @intFromPtr(self); // Use server pointer as ID
        behavior.upgrade = onUpgradeCallback;
        behavior.open = onOpenCallback;
        behavior.message = onMessageCallback;
        behavior.close = onCloseCallback;
        behavior.drain = onDrainCallback;
        
        // Use verified signature for uws_ws (from vendor/bun/src/deps/uws/App.zig)
        c.uws_ws(
            ssl_flag,
            @ptrCast(self.app),
            self, // ctx
            pattern.ptr,
            pattern.len,
            id,
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

    pub fn run(self: *WebSocketServer) void {
        c.uws_app_run(if (self.ssl) 1 else 0, self.app);
    }

    /// Close the server gracefully
    /// Requirements: 2.7
    pub fn close(self: *WebSocketServer) void {
        // Set request flag
        self.close_requested.store(true, .monotonic);

        // Wake up loop to notice exit flag
        if (self.loop) |loop| {
            c.us_wakeup_loop(loop);
        }
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

        const opcode: c_int = switch (msg_type) {
            .text => c.UWS_OPCODE_TEXT,
            .binary => c.UWS_OPCODE_BINARY,
        };

        _ = c.uws_ws_send(
            if (self.ssl) 1 else 0,
            self.ws.?,
            message.ptr,
            message.len,
            @intCast(opcode),
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

fn listenCallback(listen_socket: ?*c.struct_us_listen_socket_t, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data) |ud| {
        const server: *WebSocketServer = @ptrCast(@alignCast(ud));
        server.listen_socket = listen_socket;
        // Capture the loop pointer from the thread where listen is called
        server.loop = c.uws_get_loop();
        
        // Register post handler to handle thread-safe close
        c.uws_loop_addPostHandler(server.loop, server, postHandler);
    }
}

fn postHandler(ctx: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (ctx == null) return;
    const server: *WebSocketServer = @ptrCast(@alignCast(ctx.?));
    
    if (server.close_requested.load(.monotonic)) {
        // Signal loop to exit
        c.set_bun_is_exiting(1);

        // Close listen socket if it exists
        if (server.listen_socket) |ls| {
            c.us_listen_socket_close(if (server.ssl) 1 else 0, ls);
            server.listen_socket = null;
        }

        // Close app
        c.uws_app_close(if (server.ssl) 1 else 0, server.app);
    }
}

fn onOpenCallback(ws: ?*c.uws_websocket_t) callconv(.c) void {
    if (ws == null) return;
    
    // Get server context from WebSocket user data (set during upgrade)
    // We assume SSL is not enabled for now to call c.uws_ws_get_user_data(0, ...)
    // Or we need a way to know if it's SSL. 
    // Since we only have one SSL flag in the server, and the connection is part of that server...
    // But we don't know which server yet!
    // TRICK: We can call uws_ws_get_user_data for BOTH 0 and 1 if we are careful?
    // Actually, uWS implementation of getUserData is often the same for both.
    const server_ptr = c.uws_ws_get_user_data(0, ws) orelse c.uws_ws_get_user_data(1, ws) orelse return;
    const server: *WebSocketServer = @ptrCast(@alignCast(server_ptr));

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

fn onMessageCallback(
    ws: ?*c.uws_websocket_t,
    message: [*c]const u8,
    length: usize,
    opcode: c.uws_opcode_t,
) callconv(.c) void {
    if (ws == null or message == null) return;

    const server_ptr = c.uws_ws_get_user_data(0, ws) orelse c.uws_ws_get_user_data(1, ws) orelse return;
    const server: *WebSocketServer = @ptrCast(@alignCast(server_ptr));

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

fn onCloseCallback(
    ws: ?*c.uws_websocket_t,
    code: c_int,
    message: [*c]const u8,
    length: usize,
) callconv(.c) void {
    if (ws == null) return;

    const server_ptr = c.uws_ws_get_user_data(0, ws) orelse c.uws_ws_get_user_data(1, ws) orelse return;
    const server: *WebSocketServer = @ptrCast(@alignCast(server_ptr));

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

fn onDrainCallback(ws: ?*c.uws_websocket_t) callconv(.c) void {
    if (ws == null) return;
}

fn onUpgradeCallback(upgrade_context: ?*anyopaque, res: ?*c.uws_res_t, req: ?*c.uws_req_t, context: ?*c.uws_socket_context_t, id: usize) callconv(.c) void {
    _ = id;
    if (upgrade_context == null) return;
    const server: *WebSocketServer = @ptrCast(@alignCast(upgrade_context.?));
    const ssl: c_int = if (server.ssl) 1 else 0;

    var key: [*c]const u8 = undefined;
    const key_len = c.uws_req_get_header(@ptrCast(req), "sec-websocket-key", "sec-websocket-key".len, &key);

    var protocol: [*c]const u8 = undefined;
    const protocol_len = c.uws_req_get_header(@ptrCast(req), "sec-websocket-protocol", "sec-websocket-protocol".len, &protocol);

    var extensions: [*c]const u8 = undefined;
    const extensions_len = c.uws_req_get_header(@ptrCast(req), "sec-websocket-extensions", "sec-websocket-extensions".len, &extensions);

    _ = c.uws_res_upgrade(ssl, res, upgrade_context, key, key_len, protocol, protocol_len, extensions, extensions_len, context);
}
