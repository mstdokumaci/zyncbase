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
    map: std.AutoHashMap(u64, *Connection),

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
        schema_manager: *const Schema,
    ) !void {
        // Pre-build SchemaSync message once at startup
        const schema_sync_msg = try wire.encodeSchemaSync(allocator, schema_manager);

        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .message_handler = message_handler,
            .map = std.AutoHashMap(u64, *Connection).init(memory_strategy.generalAllocator()),
            .mutex = .{},
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
        self.map.deinit();
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

    /// Entry point for WebSocket open events
    pub fn onOpen(self: *ConnectionManager, ws: *WebSocket) !void {
        const conn_id = ws.getConnId();

        self.message_handler.violation_tracker.clearViolations(conn_id);

        const external_user_id = ws.getClientId() orelse {
            std.log.warn("Rejecting connection {}: missing external identity", .{conn_id});
            ws.close();
            return error.MissingExternalIdentity;
        };
        if (external_user_id.len == 0) {
            std.log.warn("Rejecting connection {}: empty external identity", .{conn_id});
            ws.close();
            return error.MissingExternalIdentity;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.count() >= self.max_connections) {
            std.log.warn("Rejecting connection {}: limit reached", .{conn_id});
            ws.close();
            return;
        }

        // Acquire from pool and activate
        const conn = try self.memory_strategy.acquireConnection();
        var inserted = false;
        errdefer if (!inserted) {
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        };

        conn.activate(ws.getConnId(), ws.*);
        try conn.setExternalUserId(external_user_id);

        const connected_msg = try wire.encodeConnected(self.allocator, conn.user_id);
        defer self.allocator.free(connected_msg);

        try self.map.put(conn_id, conn);
        inserted = true;
        std.log.info("Client connected: id={}", .{conn_id});

        // Handshake messages are critical — a dropped send means the connection
        // is already dead. Close it so the client reconnects cleanly.
        conn.sendDirect(connected_msg) catch {
            std.log.warn("Connection {}: dropped on connected message, closing", .{conn_id});
            conn.ws.close();
            return;
        };
        conn.sendDirect(self.schema_sync_msg) catch {
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
            self.message_handler.sendErrorRaw(ws, null, wire.getWireError(error.InvalidMessageType)) catch |err| {
                std.log.err("Failed to send error response for invalid message type: {}", .{err});
            };
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
};
