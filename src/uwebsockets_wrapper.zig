const std = @import("std");
const Allocator = std.mem.Allocator;

// C imports for Bun's uWebSockets wrapper
pub const c = @cImport({
    @cInclude("uws_wrapper.h");
});

const SocketUserData = struct {
    server: *WebSocketServer,
    client_id: ?[]const u8,
};

/// WebSocket server wrapper using Bun's uWebSockets C API
pub const WebSocketServer = struct {
    app: *c.uws_app_t,
    allocator: Allocator,
    ssl: bool,
    handlers: WebSocketHandlers = .{},
    user_data: ?*anyopaque = null,
    listen_socket: ?*c.struct_us_listen_socket_t = null,
    loop: std.atomic.Value(?*anyopaque) = std.atomic.Value(?*anyopaque).init(null),
    close_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    is_closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    is_listening: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    post_handler: ?*const fn (?*anyopaque) void = null,
    post_handler_ctx: ?*anyopaque = null,
    drain_handler: ?*const fn (?*anyopaque, u64) void = null,
    drain_handler_ctx: ?*anyopaque = null,

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
    pub fn init(self: *WebSocketServer, allocator: Allocator, config: Config) Error!void {
        var ssl_options = std.mem.zeroes(c.us_bun_socket_context_options_t);
        if (config.ssl) {
            if (config.ssl_cert_path) |cert| {
                ssl_options.cert_file_name = @ptrCast(cert);
            }
            if (config.ssl_key_path) |key| {
                ssl_options.key_file_name = @ptrCast(key);
            }
        }

        const app = c.uws_create_app(
            if (config.ssl) 1 else 0,
            ssl_options,
        );

        if (app == null) {
            return error.FailedToCreateApp;
        }

        self.app = app.?;
        self.allocator = allocator;
        self.ssl = config.ssl;
        self.handlers = .{};
        self.user_data = null;
        self.listen_socket = null;
        self.loop = std.atomic.Value(?*anyopaque).init(null);
        self.close_requested = std.atomic.Value(bool).init(false);
        self.is_closing = std.atomic.Value(bool).init(false);
        self.is_listening = std.atomic.Value(bool).init(false);
        self.post_handler = null;
        self.post_handler_ctx = null;
        self.drain_handler = null;
        self.drain_handler_ctx = null;
    }

    /// Clean up resources.
    /// CAUTION: Must be called only after the event loop (run()) has exited.
    /// In multi-threaded environments, ensure the server thread has joined.
    pub fn deinit(_: *WebSocketServer) void {
        // Only infrastructure cleanup (none currently)
    }

    /// Register WebSocket handlers for a specific pattern
    pub fn registerWebSocketHandlers(self: *WebSocketServer, pattern: []const u8, handlers: WebSocketHandlers, user_data: ?*anyopaque) void {
        self.handlers = handlers;
        self.user_data = user_data;

        var behavior = std.mem.zeroes(c.uws_socket_behavior_t);
        behavior.maxPayloadLength = 16 * 1024 * 1024;
        behavior.maxBackpressure = 16 * 1024 * 1024;
        behavior.idleTimeout = 120;
        behavior.sendPingsAutomatically = true;

        const ssl_flag: c_int = if (self.ssl) 1 else 0;
        const id = @intFromPtr(self);

        behavior.upgrade = onUpgradeCallback;
        if (self.ssl) {
            behavior.open = onOpenCallbackSSL;
            behavior.message = onMessageCallbackSSL;
            behavior.close = onCloseCallbackSSL;
            behavior.drain = onDrainCallbackSSL;
        } else {
            behavior.open = onOpenCallbackNoSSL;
            behavior.message = onMessageCallbackNoSSL;
            behavior.close = onCloseCallbackNoSSL;
            behavior.drain = onDrainCallbackNoSSL;
        }

        c.uws_ws(
            ssl_flag,
            @ptrCast(self.app),
            self, // upgrade_context: passed to uws_res_upgrade, becomes per-socket user data
            pattern.ptr,
            pattern.len,
            id,
            &behavior,
        );
    }

    /// Start listening on specified port
    pub fn listen(self: *WebSocketServer, port: u16) !void {
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

    /// Close the server gracefully.
    /// NOTE: This sets a global exit flag (set_bun_is_exiting(1)) which may affect
    /// other uWebSockets instances in the same process.
    pub fn close(self: *WebSocketServer) void {
        self.close_requested.store(true, .monotonic);
        if (self.loop.load(.acquire)) |loop| {
            c.us_wakeup_loop(loop);
        }
    }
};

/// The result of a WebSocket send operation.
pub const SendStatus = enum(c_uint) {
    /// The kernel send buffer is full; uWS has internally buffered the frame.
    /// The drain callback will fire when the buffer clears.
    backpressure = 0,
    /// Frame was handed to the kernel successfully.
    success = 1,
    /// The connection is dead or the internal backpressure limit was hit.
    /// The frame was discarded. Callers should close the connection.
    dropped = 2,
};

/// WebSocket connection wrapper
pub const WebSocket = struct {
    ws: ?*c.uws_websocket_t,
    ssl: bool,
    user_data: ?*anyopaque = null, // Mock data for testing
    client_id: ?[]const u8 = null,

    /// Send a message and return the delivery status.
    /// Callers must inspect the result — never discard it silently.
    pub fn send(self: *WebSocket, message: []const u8, msg_type: MessageType) SendStatus {
        if (self.ws == null) return .dropped;
        const opcode: c_uint = switch (msg_type) {
            .text => c.UWS_OPCODE_TEXT,
            .binary => c.UWS_OPCODE_BINARY,
        };
        return @enumFromInt(c.uws_ws_send(if (self.ssl) 1 else 0, self.ws.?, message.ptr, message.len, opcode));
    }

    pub fn close(self: *WebSocket) void {
        if (self.ws == null) return;
        c.uws_ws_close(if (self.ssl) 1 else 0, self.ws.?);
    }

    pub fn getClientId(self: WebSocket) ?[]const u8 {
        return self.client_id;
    }

    /// Returns a unique identifier for the connection.
    /// For real WebSockets, this is the memory address of the C object.
    /// For mock WebSockets, this is the value stored in user_data.
    pub fn getConnId(self: WebSocket) u64 {
        if (self.ws) |ws_ptr| {
            return @intFromPtr(ws_ptr);
        }
        return @as(u64, @intFromPtr(self.user_data));
    }
};

pub const MessageType = enum(c_int) {
    text = 1,
    binary = 2,
};

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
        const loop = c.uws_get_loop();
        server.loop.store(loop, .release);
        c.uws_loop_addPostHandler(loop, server, postHandler);
        server.is_listening.store(true, .release);
    }
}

fn postHandler(ctx: ?*anyopaque, loop_ptr: ?*anyopaque) callconv(.c) void {
    if (ctx == null) return;
    const server: *WebSocketServer = @ptrCast(@alignCast(ctx.?));

    if (server.post_handler) |handler| {
        handler(server.post_handler_ctx);
    }

    // Ensure we only perform shutdown once
    if (server.close_requested.load(.monotonic) and !server.is_closing.swap(true, .acquire)) {
        c.set_bun_is_exiting(1);
        if (server.listen_socket) |ls| {
            c.us_listen_socket_close(if (server.ssl) 1 else 0, ls);
            server.listen_socket = null;
        }
        c.uws_app_close(if (server.ssl) 1 else 0, server.app);

        // Wake up the loop to ensure it runs one more iteration to finalize resource state
        // and exit when num_polls hits zero.
        if (loop_ptr) |loop| {
            c.us_wakeup_loop(loop);
        }
    }
}

// Specialized callbacks to avoid SSL probing hacks

fn getSocketUserData(ws: ?*c.uws_websocket_t, is_ssl: bool) ?*SocketUserData {
    if (ws == null) return null;
    const ptr = c.uws_ws_get_user_data(if (is_ssl) 1 else 0, ws) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn onOpen(ws: ?*c.uws_websocket_t, is_ssl: bool) void {
    if (ws == null) return;
    const socket_data = getSocketUserData(ws, is_ssl) orelse return;
    const server = socket_data.server;
    var zig_ws = WebSocket{ .ws = ws.?, .ssl = server.ssl, .client_id = socket_data.client_id };
    if (server.handlers.on_open) |handler| handler(&zig_ws, server.user_data);
}

fn onMessage(ws: ?*c.uws_websocket_t, message: [*c]const u8, length: usize, opcode: c.uws_opcode_t, is_ssl: bool) void {
    if (ws == null or message == null) return;
    const socket_data = getSocketUserData(ws, is_ssl) orelse return;
    const server = socket_data.server;
    var zig_ws = WebSocket{ .ws = ws.?, .ssl = server.ssl, .client_id = socket_data.client_id };
    const msg_type: MessageType = if (opcode == c.UWS_OPCODE_TEXT) .text else .binary;
    if (server.handlers.on_message) |handler| handler(&zig_ws, message[0..length], msg_type, server.user_data);
}

fn onClose(ws: ?*c.uws_websocket_t, code: c_int, message: [*c]const u8, length: usize, is_ssl: bool) void {
    if (ws == null) return;
    const socket_data = getSocketUserData(ws, is_ssl) orelse return;
    const server = socket_data.server;
    var zig_ws = WebSocket{ .ws = ws.?, .ssl = server.ssl, .client_id = socket_data.client_id };
    const msg_slice = if (message != null) message[0..length] else "";
    if (server.handlers.on_close) |handler| handler(&zig_ws, code, msg_slice, server.user_data);
    if (socket_data.client_id) |client_id| server.allocator.free(client_id);
    server.allocator.destroy(socket_data);
}

// C callback entry points

fn onOpenCallbackNoSSL(ws: ?*c.uws_websocket_t) callconv(.c) void {
    onOpen(ws, false);
}
fn onOpenCallbackSSL(ws: ?*c.uws_websocket_t) callconv(.c) void {
    onOpen(ws, true);
}

fn onMessageCallbackNoSSL(ws: ?*c.uws_websocket_t, msg: [*c]const u8, len: usize, op: c.uws_opcode_t) callconv(.c) void {
    onMessage(ws, msg, len, op, false);
}
fn onMessageCallbackSSL(ws: ?*c.uws_websocket_t, msg: [*c]const u8, len: usize, op: c.uws_opcode_t) callconv(.c) void {
    onMessage(ws, msg, len, op, true);
}

fn onCloseCallbackNoSSL(ws: ?*c.uws_websocket_t, code: c_int, msg: [*c]const u8, len: usize) callconv(.c) void {
    onClose(ws, code, msg, len, false);
}
fn onCloseCallbackSSL(ws: ?*c.uws_websocket_t, code: c_int, msg: [*c]const u8, len: usize) callconv(.c) void {
    onClose(ws, code, msg, len, true);
}

fn onDrain(ws: ?*c.uws_websocket_t, is_ssl: bool) void {
    if (ws == null) return;
    const socket_data = getSocketUserData(ws, is_ssl) orelse return;
    const server = socket_data.server;
    if (server.drain_handler) |handler| {
        handler(server.drain_handler_ctx, @intFromPtr(ws.?));
    }
}

fn onDrainCallbackNoSSL(ws: ?*c.uws_websocket_t) callconv(.c) void {
    onDrain(ws, false);
}
fn onDrainCallbackSSL(ws: ?*c.uws_websocket_t) callconv(.c) void {
    onDrain(ws, true);
}

fn onUpgradeCallback(upgrade_context: ?*anyopaque, res: ?*c.uws_res_t, req: ?*c.uws_req_t, context: ?*c.uws_socket_context_t, _: usize) callconv(.c) void {
    if (upgrade_context == null) return;
    const server: *WebSocketServer = @ptrCast(@alignCast(upgrade_context.?));
    const ssl: c_int = if (server.ssl) 1 else 0;

    // SAFETY: These pointers are initialized by the calls to uws_req_get_header below
    var key: [*c]const u8 = undefined;
    const key_len = c.uws_req_get_header(@ptrCast(req), "sec-websocket-key", "sec-websocket-key".len, &key);
    // SAFETY: proto is initialized by the c.uws_req_get_header call below
    var proto: [*c]const u8 = undefined;
    const proto_len = c.uws_req_get_header(@ptrCast(req), "sec-websocket-protocol", "sec-websocket-protocol".len, &proto);
    // SAFETY: ext is initialized by the c.uws_req_get_header call below
    var ext: [*c]const u8 = undefined;
    const ext_len = c.uws_req_get_header(@ptrCast(req), "sec-websocket-extensions", "sec-websocket-extensions".len, &ext);

    const socket_data = server.allocator.create(SocketUserData) catch |err| {
        std.log.err("Failed to allocate WebSocket user data: {}", .{err});
        return;
    };

    var client_id: ?[]const u8 = null;
    // SAFETY: Populated by uws_req_get_query C API which handles length mapping.
    var client_id_ptr: [*c]const u8 = undefined;
    const client_id_len = c.uws_req_get_query(@ptrCast(req), "clientId", "clientId".len, &client_id_ptr);
    if (client_id_len > 0) {
        client_id = server.allocator.dupe(u8, client_id_ptr[0..client_id_len]) catch |err| {
            std.log.err("Failed to copy clientId query param: {}", .{err});
            server.allocator.destroy(socket_data);
            return;
        };
    }

    socket_data.* = .{
        .server = server,
        .client_id = client_id,
    };

    _ = c.uws_res_upgrade(ssl, res, socket_data, key, key_len, proto, proto_len, ext, ext_len, context);
}
