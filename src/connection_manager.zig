const std = @import("std");
const Allocator = std.mem.Allocator;
const Connection = @import("connection.zig").Connection;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const Schema = @import("schema.zig").Schema;
const wire = @import("wire.zig");
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;

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

    pub fn init(
        self: *ConnectionManager,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        message_handler: *MessageHandler,
        schema: *const Schema,
        max_connections: usize,
    ) !void {
        // Pre-build SchemaSync message once at startup
        const schema_sync_msg = try wire.encodeSchemaSync(allocator, schema);

        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .message_handler = message_handler,
            .map = .empty,
            .mutex = .{},
            .max_connections = max_connections,
            .schema_sync_msg = schema_sync_msg,
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
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

    /// Close all active connections for graceful shutdown
    pub fn closeAllConnections(self: *ConnectionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.map.valueIterator();
        while (it.next()) |state| {
            const conn = state.*;
            conn.ws.close();
            // We don't remove from map here, onClose will handle that when uWS confirms
        }
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

        const connected_msg = try wire.encodeConnected(self.allocator, conn.getExternalUserId());
        defer self.allocator.free(connected_msg);

        try self.map.put(self.allocator, conn_id, conn);
        inserted = true;
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
            if (wire.encodeError(self.allocator, null, wire.getWireError(error.InvalidMessageType))) |error_msg| {
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
            const c = self.map.get(conn_id) orelse return;
            c.acquire();
            break :blk c;
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

    /// Send ServerDisconnect message to all active connections and initiate socket close
    pub fn sendDisconnectToAll(self: *ConnectionManager, code: []const u8, message: []const u8) void {
        const msg = wire.encodeServerDisconnect(self.allocator, code, message) catch |err| {
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

    pub fn sweepExpiredTokens(self: *ConnectionManager, grace_period_seconds: u32) void {
        const now = std.time.timestamp();
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
            const msg = wire.encodeServerDisconnect(self.allocator, "TOKEN_EXPIRED", "Your authentication token has expired.") catch |err| {
                std.log.err("Failed to encode TOKEN_EXPIRED: {}", .{err});
                _ = conn.release();
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
};
