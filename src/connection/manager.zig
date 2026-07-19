const std = @import("std");
const Allocator = std.mem.Allocator;
const Connection = @import("state.zig").Connection;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const MessageHandler = @import("../message_handler.zig").MessageHandler;
const Schema = @import("../schema/types.zig").Schema;
const send_queue_type = @import("send_queue.zig").send_queue;
const wire_encode = @import("../wire/encode.zig");
const wire_errors = @import("../wire/errors.zig");
const WebSocket = @import("../uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("../uwebsockets_wrapper.zig").MessageType;
const Notifier = @import("../threading/notifier.zig").Notifier;
const c = @import("../uwebsockets_wrapper.zig").c;

/// ConnectionManager handles the lifecycle of client sessions and acts as a relay
/// between the raw network events and the application logic (MessageHandler).
pub const ConnectionManager = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    message_handler: *MessageHandler,

    /// Map of connection IDs to Connection objects
    map: std.AutoHashMapUnmanaged(u64, *Connection),

    /// Mutex for protecting the map during concurrent access
    mutex: std.Thread.Mutex,

    /// Maximum number of concurrent connections allowed
    max_connections: usize = 100_000,

    /// Pre-encoded SchemaSync message sent to every new connection on open.
    schema_sync_msg: []const u8,

    /// Grace period for expired tokens (seconds), used by the timer sweep.
    token_grace_period_seconds: u32 = 0,

    /// uWS timer for periodic token expiry sweeps (replaces timestamp poll).
    token_sweep_timer: ?*c.struct_us_timer_t = null,

    /// Atomic connection count for cheap shutdown polling (maintained alongside map count).
    active_connection_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Notifier fired when the last connection closes during shutdown.
    last_conn_notifier: Notifier = .{},

    pub fn init(
        self: *ConnectionManager,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        message_handler: *MessageHandler,
        schema: *const Schema,
        max_connections: usize,
        token_grace_period_seconds: u32,
    ) !void {
        // Pre-build SchemaSync message once at startup
        const schema_sync_msg = try wire_encode.encodeSchemaSync(allocator, schema);

        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .message_handler = message_handler,
            .map = .empty,
            .mutex = .{},
            .max_connections = max_connections,
            .schema_sync_msg = schema_sync_msg,
            .token_grace_period_seconds = token_grace_period_seconds,
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
        self.stopTokenSweepTimer();

        self.mutex.lock();
        var it = self.map.valueIterator();
        while (it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            // Ensure all logical cleanup (unsubscriptions) is performed before manager shuts down
            self.message_handler.teardownSession(conn);
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }
        self.map.deinit(self.allocator);
        self.mutex.unlock();

        self.allocator.free(self.schema_sync_msg);
    }

    pub fn onOpen(self: *ConnectionManager, ws: *WebSocket) !void {
        const conn_id = ws.getConnId();

        self.message_handler.violation_tracker.clearViolations(conn_id);

        var sess = ws.takeSession() orelse {
            std.log.warn("Rejecting connection {}: missing session", .{conn_id});
            ws.close();
            return error.MissingSession;
        };
        var sess_transferred = false;
        errdefer if (!sess_transferred) sess.deinit(self.allocator);
        if (sess.external_id.len == 0) {
            std.log.warn("Rejecting connection {}: empty external identity", .{conn_id});
            ws.close();
            return error.MissingSession;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.count() >= self.max_connections) {
            std.log.warn("Rejecting connection {}: limit reached", .{conn_id});
            sess.deinit(self.allocator);
            ws.close();
            return;
        }

        const conn = try self.memory_strategy.acquireConnection();
        var inserted = false;
        errdefer if (!inserted) {
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        };

        conn.activate(ws.getConnId(), ws.*);
        conn.setSession(sess);
        sess_transferred = true;

        const connected_msg = try wire_encode.encodeConnected(self.allocator, conn.getExternalUserId());
        defer self.allocator.free(connected_msg);

        try self.map.put(self.allocator, conn_id, conn);
        inserted = true;
        _ = self.active_connection_count.fetchAdd(1, .acq_rel);
        std.log.info("Client connected: id={}", .{conn_id});

        conn.send(connected_msg) catch {
            std.log.warn("Connection {}: dropped on connected message, closing", .{conn_id});
            conn.ws.close();
            return;
        };
        conn.send(self.schema_sync_msg) catch {
            std.log.warn("Connection {}: dropped on schema_sync message, closing", .{conn_id});
            conn.ws.close();
            return;
        };
    }

    /// Entry point for WebSocket message events
    pub fn onMessage(self: *ConnectionManager, ws: *WebSocket, data: []const u8, msg_type: MessageType) void {
        const conn_id = ws.getConnId();

        // 1. Explicitly reject non-binary frames at the entry point.
        // ZyncBase uses binary MessagePack for all communications.
        if (msg_type != .binary) {
            std.log.warn("Rejected non-binary (text) message from connection {}", .{conn_id});
            if (wire_encode.encodeError(self.allocator, null, wire_errors.getWireError(error.InvalidMessageType))) |error_msg| {
                defer self.allocator.free(error_msg);
                switch (ws.send(error_msg, .binary)) {
                    .success, .backpressure => {},
                    .dropped => ws.close(),
                }
            } else |err| {
                std.log.err("Failed to encode error response for invalid message type: {}", .{err});
            }
            return;
        }

        // 2. Thread-safe lookup with reference counting
        const conn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const existing = self.map.get(conn_id) orelse return;
            existing.acquire();
            break :blk existing;
        };

        // 3. Release the connection after message handling
        defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

        self.message_handler.handleMessage(conn, data) catch |err| {
            std.log.debug("MessageHandler error for connection {}: {}", .{ conn_id, err });
        };
    }

    /// Entry point for WebSocket close events
    pub fn onClose(self: *ConnectionManager, ws: *WebSocket) void {
        const conn_id = ws.getConnId();

        const maybe_conn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.map.fetchRemove(conn_id);
        };

        if (maybe_conn) |entry| {
            const conn = entry.value;

            // Perform full session teardown (unsubscriptions and metadata clearing)
            self.message_handler.teardownSession(conn);

            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
            _ = self.active_connection_count.fetchSub(1, .acq_rel);
            if (self.active_connection_count.load(.acquire) == 0) {
                self.last_conn_notifier.notify();
            }
            std.log.info("Client disconnected: id={}", .{conn_id});
        }
    }

    /// Helper to get a stable reference to a connection (increments refcount)
    pub fn acquireConnection(self: *ConnectionManager, id: u64) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        const conn = self.map.get(id) orelse return error.ConnectionNotFound;
        conn.acquire();
        return conn;
    }

    /// Broadcast helper as a method on ConnectionManager.
    pub fn sendToConnection(self: *ConnectionManager, conn_id: u64, data: []const u8) void {
        const conn = self.acquireConnection(conn_id) catch return;
        defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

        conn.send(data) catch |err| switch (err) {
            error.Dropped => {
                std.log.warn("Connection {} dropped by uWS, closing", .{conn_id});
                conn.ws.close();
            },
            error.Full => {
                std.log.warn("Connection {} outbox full (slow client), closing", .{conn_id});
                conn.ws.close();
            },
            else => {
                std.log.err("Connection {} unexpected send error: {}", .{ conn_id, err });
                conn.ws.close();
            },
        };
    }

    /// Called by the uWS drain callback. Flushes queued delta messages for the given connection.
    /// Closes the connection if uWS signals it is dead (DROPPED).
    pub fn flushOutbox(self: *ConnectionManager, conn_id: u64) void {
        self.mutex.lock();
        const conn = self.map.get(conn_id) orelse {
            self.mutex.unlock();
            return;
        };
        conn.acquire();
        self.mutex.unlock();

        defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

        switch (conn.flushOutbox()) {
            .success, .backpressure => {},
            .dropped => {
                std.log.warn("Connection {}: dropped during drain flush, closing", .{conn_id});
                conn.ws.close();
            },
        }
    }

    /// Drain SendQueue and send messages to connections. Must be called from event loop thread.
    /// Called in notifyPostHandler after dispatcher polls.
    pub fn drainSendQueue(self: *ConnectionManager, send_queue: *send_queue_type) void {
        while (send_queue.pop()) |entry| {
            defer entry.deinit();

            const conn = self.acquireConnection(entry.conn_id) catch |err| {
                std.log.warn("Connection {} not found during send queue drain: {}", .{ entry.conn_id, err });
                continue;
            };
            defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

            conn.send(entry.data) catch |err| switch (err) {
                error.Dropped => {
                    std.log.warn("Connection {} dropped by uWS, closing", .{entry.conn_id});
                    conn.ws.close();
                },
                error.Full => {
                    std.log.warn("Connection {} outbox full (slow client), closing", .{entry.conn_id});
                    conn.ws.close();
                },
                else => {
                    std.log.err("Connection {} unexpected send error: {}", .{ entry.conn_id, err });
                    conn.ws.close();
                },
            };
        }
    }

    /// Send ServerDisconnect message to all active connections and initiate socket close
    pub fn sendDisconnectToAll(self: *ConnectionManager, code: []const u8, message: []const u8) void {
        const msg = wire_encode.encodeServerDisconnect(self.allocator, code, message) catch |err| {
            std.log.err("Failed to encode ServerDisconnect: {}", .{err});
            return;
        };
        defer self.allocator.free(msg);

        var connections = std.ArrayListUnmanaged(*Connection).empty;
        defer connections.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.map.valueIterator();
            while (it.next()) |state| {
                const conn = state.*;
                conn.acquire();
                connections.append(self.allocator, conn) catch |err| {
                    std.log.err("Failed to add connection to disconnect list: {}", .{err});
                    if (conn.release()) {
                        self.memory_strategy.releaseConnection(conn);
                    }
                };
            }
        }

        for (connections.items) |conn| {
            conn.send(msg) catch |err| {
                std.log.warn("Failed to send ServerDisconnect to connection {}: {}", .{ conn.id, err });
            };
            conn.ws.close();
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }
    }

    pub fn sweepExpiredTokens(self: *ConnectionManager) void {
        const now = std.time.timestamp();
        const grace_period_seconds = self.token_grace_period_seconds;
        var to_close: std.ArrayListUnmanaged(*Connection) = .empty;
        defer to_close.deinit(self.allocator);

        self.mutex.lock();

        var it = self.map.valueIterator();
        while (it.next()) |state| {
            const conn = state.*;
            if (conn.session) |sess| {
                if (now >= sess.token_expires_at + @as(i64, @intCast(grace_period_seconds))) {
                    conn.acquire();
                    to_close.append(self.allocator, conn) catch |err| {
                        std.log.err("Failed to add expired connection to close list: {}", .{err});
                        if (conn.release()) {
                            self.memory_strategy.releaseConnection(conn);
                        }
                    };
                }
            }
        }

        self.mutex.unlock();

        for (to_close.items) |conn| {
            const msg = wire_encode.encodeServerDisconnect(self.allocator, "TOKEN_EXPIRED", "Your authentication token has expired.") catch |err| {
                std.log.err("Failed to encode TOKEN_EXPIRED: {}", .{err});
                conn.ws.close();
                if (conn.release()) {
                    self.memory_strategy.releaseConnection(conn);
                }
                continue;
            };
            conn.send(msg) catch |err| {
                std.log.warn("Failed to send TOKEN_EXPIRED to connection {}: {}", .{ conn.id, err });
            };
            self.allocator.free(msg);
            conn.ws.close();
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }
    }

    pub fn setLastConnectionNotifier(self: *ConnectionManager, n: Notifier) void {
        self.last_conn_notifier = n;
    }

    pub fn startTokenSweepTimer(self: *ConnectionManager, loop: *c.struct_us_loop_t) !void {
        const timer = c.us_create_timer(loop, 1, @sizeOf(*ConnectionManager)) orelse
            return error.TimerCreateFailed;

        const ext = c.us_timer_ext(timer);
        @memcpy(@as([*]u8, @ptrCast(ext))[0..@sizeOf(*ConnectionManager)], std.mem.asBytes(&self));

        c.us_timer_set(timer, tokenSweepCallback, 15_000, 15_000);
        self.token_sweep_timer = timer;
    }

    pub fn stopTokenSweepTimer(self: *ConnectionManager) void {
        if (self.token_sweep_timer) |t| {
            c.us_timer_close(t);
            self.token_sweep_timer = null;
        }
    }

    fn tokenSweepCallback(t: ?*c.struct_us_timer_t) callconv(.c) void {
        const timer = t orelse return;
        const self = extractConnectionManagerPtr(timer);
        self.sweepExpiredTokens();
    }

    fn extractConnectionManagerPtr(t: *c.struct_us_timer_t) *ConnectionManager {
        const ext = c.us_timer_ext(t);
        // SAFETY: The extension slot was written by startTokenSweepTimer with a valid *ConnectionManager pointer.
        var ptr: *ConnectionManager = undefined;
        @memcpy(std.mem.asBytes(&ptr), @as([*]u8, @ptrCast(ext))[0..@sizeOf(*ConnectionManager)]);
        return ptr;
    }
};

// Default send-broadcast helper used by other modules (e.g. presence manager).
pub fn sendToConnection(ctx: *anyopaque, conn_id: u64, data: []const u8) void {
    const cm: *ConnectionManager = @ptrCast(@alignCast(ctx));
    cm.sendToConnection(conn_id, data);
}
