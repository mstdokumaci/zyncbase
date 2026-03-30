const std = @import("std");
const Allocator = std.mem.Allocator;
const Connection = @import("connection.zig").Connection;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const MessageHandler = @import("message_handler.zig").MessageHandler;
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

    pub fn init(
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        message_handler: *MessageHandler,
    ) !*ConnectionManager {
        const self = try allocator.create(ConnectionManager);
        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .message_handler = message_handler,
            .map = std.AutoHashMap(u64, *Connection).init(memory_strategy.generalAllocator()),
            .mutex = .{},
        };
        return self;
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
        self.allocator.destroy(self);
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

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.count() >= self.max_connections) {
            std.log.warn("Rejecting connection {}: limit reached", .{conn_id});
            ws.close();
            return;
        }

        // Acquire from pool and activate
        const conn = try self.memory_strategy.acquireConnection();
        conn.activate(ws.getConnId(), ws.*);

        try self.map.put(conn_id, conn);
        std.log.info("Client connected: id={}", .{conn_id});
    }

    /// Entry point for WebSocket message events
    pub fn onMessage(self: *ConnectionManager, ws: *WebSocket, data: []const u8, msg_type: MessageType) void {
        const conn_id = ws.getConnId();

        // 1. Explicitly reject non-binary frames at the entry point.
        // ZyncBase uses binary MessagePack for all communications.
        if (msg_type != .binary) {
            std.log.warn("Rejected non-binary (text) message from connection {}", .{conn_id});
            self.message_handler.sendError(ws, "INVALID_MESSAGE_TYPE", "Only binary MessagePack frames are supported") catch |err| {
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

        // 3. Ensure resources are returned even if execution below fails
        defer {
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }

        // 4. Relay to MessageHandler (The Brain)
        self.message_handler.handleMessage(conn, data) catch |err| {
            std.log.debug("MessageHandler error for connection {}: {}", .{ conn_id, err });
        };
    }

    /// Entry point for WebSocket close events
    pub fn onClose(self: *ConnectionManager, ws: *WebSocket, code: i32, reason: []const u8) void {
        const conn_id = ws.getConnId();
        _ = code;
        _ = reason;

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
};
