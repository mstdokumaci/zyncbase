const std = @import("std");
const Allocator = std.mem.Allocator;
const MessagePackParser = @import("messagepack_parser.zig").MessagePackParser;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const MessagePackSerializer = @import("messagepack_serializer.zig").MessagePackSerializer;

/// Message handler for WebSocket events
/// Manages connection lifecycle, message parsing, routing, and response handling
pub const MessageHandler = struct {
    allocator: Allocator,
    parser: *MessagePackParser,
    request_handler: *RequestHandler,
    storage_engine: *StorageEngine,
    subscription_manager: *SubscriptionManager,
    cache: *LockFreeCache,
    connection_registry: ConnectionRegistry,
    next_connection_id: std.atomic.Value(u64),

    /// Initialize message handler with all required components
    /// Requirements: 5.1, 5.2, 5.3, 6.1
    pub fn init(
        allocator: Allocator,
        parser: *MessagePackParser,
        request_handler: *RequestHandler,
        storage_engine: *StorageEngine,
        subscription_manager: *SubscriptionManager,
        cache: *LockFreeCache,
    ) !*MessageHandler {
        const self = try allocator.create(MessageHandler);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .parser = parser,
            .request_handler = request_handler,
            .storage_engine = storage_engine,
            .subscription_manager = subscription_manager,
            .cache = cache,
            .connection_registry = try ConnectionRegistry.init(allocator),
            .next_connection_id = std.atomic.Value(u64).init(1),
        };

        return self;
    }

    /// Clean up message handler resources
    pub fn deinit(self: *MessageHandler) void {
        self.connection_registry.deinit();
        self.allocator.destroy(self);
    }

    /// Handle WebSocket connection open event
    /// Generates unique connection ID and adds to registry
    /// Requirements: 5.1, 5.2, 5.3
    pub fn handleOpen(self: *MessageHandler, ws: *WebSocket) !void {
        // Generate unique connection ID (atomic increment)
        const conn_id = self.next_connection_id.fetchAdd(1, .monotonic);

        // Create connection state
        const conn_state = try ConnectionState.init(self.allocator, conn_id);
        errdefer conn_state.deinit(self.allocator);

        // Store in registry
        try self.connection_registry.add(conn_id, conn_state);

        // Associate connection ID with WebSocket
        ws.setUserData(@ptrFromInt(conn_id));

        std.log.info("WebSocket connection opened: id={}", .{conn_id});
    }

    /// Handle WebSocket message event
    /// Parses MessagePack, extracts message info, routes to handler, and sends response
    /// Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.9
    pub fn handleMessage(
        self: *MessageHandler,
        ws: *WebSocket,
        message: []const u8,
        msg_type: MessageType,
    ) !void {
        // Get connection ID from WebSocket user data
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

        // Only handle binary messages (MessagePack)
        if (msg_type != .binary) {
            try self.sendError(ws, "TEXT_NOT_SUPPORTED", "Only binary MessagePack messages are supported");
            return;
        }

        // Parse MessagePack message
        std.log.debug("Incoming message ({}): {x}", .{message.len, message});
        const parsed = self.parser.parse(message) catch |err| {
            std.log.debug("Failed to parse message from connection {}: {}", .{ conn_id, err });
            try self.sendError(ws, "INVALID_MESSAGE", "Failed to parse MessagePack");
            return;
        };
        defer self.parser.freeValue(parsed);

        // Extract message type and correlation ID
        const msg_info = self.extractMessageInfo(parsed) catch |err| {
            std.log.debug("Failed to extract message info from connection {}: {}", .{ conn_id, err });
            try self.sendError(ws, "INVALID_MESSAGE_FORMAT", "Missing required fields: type or id");
            return;
        };

        // Route to appropriate handler
        const response = self.routeMessage(conn_id, msg_info, parsed) catch |err| {
            std.log.debug("Failed to process message from connection {}: {}", .{ conn_id, err });
            try self.sendError(ws, "PROCESSING_FAILED", "Failed to process request");
            return;
        };
        defer self.allocator.free(response);

        // Send response
        std.log.debug("Outgoing response ({}): {x}", .{response.len, response});
        ws.send(response, .binary);
    }

    /// Handle WebSocket connection close event
    /// Removes subscriptions and connection state
    /// Requirements: 5.4, 5.5
    pub fn handleClose(
        self: *MessageHandler,
        ws: *WebSocket,
        code: i32,
        message: []const u8,
    ) !void {
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

        std.log.info("WebSocket connection closed: id={}, code={}, message={s}", .{
            conn_id,
            code,
            message,
        });

        // Get connection state
        const conn_state = self.connection_registry.get(conn_id) catch |err| {
            std.log.debug("Connection {} not found in registry during close: {}", .{ conn_id, err });
            return;
        };

        // Remove all subscriptions for this connection
        for (conn_state.subscription_ids.items) |sub_id| {
            self.subscription_manager.unsubscribe(sub_id) catch |err| {
                std.log.debug("Failed to unsubscribe {} for connection {}: {}", .{ sub_id, conn_id, err });
            };
        }

        // Remove from registry
        try self.connection_registry.remove(conn_id);
    }

    /// Handle WebSocket error event
    /// Cleans up connection state
    /// Requirements: 5.6, 5.7
    pub fn handleError(self: *MessageHandler, ws: *WebSocket) !void {
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

        std.log.debug("WebSocket error on connection: id={}", .{conn_id});

        // Clean up connection state if it exists
        if (self.connection_registry.get(conn_id)) |conn_state| {
            // Remove subscriptions
            for (conn_state.subscription_ids.items) |sub_id| {
                self.subscription_manager.unsubscribe(sub_id) catch |err| {
                    std.log.warn("Failed to unsubscribe {} during error cleanup: {}", .{ sub_id, err });
                };
            }

            // Remove from registry
            self.connection_registry.remove(conn_id) catch |err| {
                std.log.warn("Failed to remove connection {} from registry: {}", .{ conn_id, err });
            };
        } else |_| {
            // Connection not in registry, nothing to clean up
        }
    }

    /// Close all active connections for graceful shutdown
    /// Requirements: 4.4
    pub fn closeAllConnections(self: *MessageHandler) !void {
        var it = self.connection_registry.iterator();
        while (it.next()) |entry| {
            const conn_id = entry.key_ptr.*;
            const conn_state = entry.value_ptr.*;

            // Remove subscriptions
            for (conn_state.subscription_ids.items) |sub_id| {
                self.subscription_manager.unsubscribe(sub_id) catch |err| {
                    std.log.warn("Failed to unsubscribe {} during shutdown: {}", .{ sub_id, err });
                };
            }

            std.log.info("Closed connection: id={}", .{conn_id});
        }

        self.connection_registry.clear();
    }

    /// Extract message type and correlation ID from parsed MessagePack
    /// Requirements: 6.2, 6.9
    pub fn extractMessageInfo(self: *MessageHandler, parsed: MessagePackParser.Value) !MessageInfo {
        _ = self;

        // Extract type and id from MessagePack map
        if (parsed != .map) {
            std.log.debug("parsed is not map, it is {}", .{parsed});
            return error.InvalidMessageFormat;
        }

        var msg_type: ?[]const u8 = null;
        var msg_id: ?u64 = null;

        for (parsed.map) |entry| {
            if (entry.key == .string) {
                if (std.mem.eql(u8, entry.key.string, "type")) {
                    if (entry.value == .string) {
                        msg_type = entry.value.string;
                    }
                } else if (std.mem.eql(u8, entry.key.string, "id")) {
                    if (entry.value == .unsigned) {
                        msg_id = entry.value.unsigned;
                    }
                }
            }
        }

        if (msg_type == null or msg_id == null) {
            return error.MissingRequiredFields;
        }

        return MessageInfo{
            .type = msg_type.?,
            .id = msg_id.?,
        };
    }

    /// Route message to appropriate handler based on type
    /// Requirements: 6.3
    pub fn routeMessage(
        self: *MessageHandler,
        conn_id: u64,
        msg_info: MessageInfo,
        parsed: MessagePackParser.Value,
    ) ![]const u8 {
        // Route based on message type
        if (std.mem.eql(u8, msg_info.type, "StoreSet")) {
            return try self.handleStoreSet(conn_id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreGet")) {
            return try self.handleStoreGet(conn_id, msg_info.id, parsed);
        } else {
            return error.UnknownMessageType;
        }
    }

    /// Handle StoreSet message
    /// Requirements: 16.1, 16.2, 16.3, 16.4
    fn handleStoreSet(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: MessagePackParser.Value,
    ) ![]const u8 {
        _ = conn_id;

        // Extract namespace, path, and value from message
        var namespace: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var value: ?MessagePackParser.Value = null;

        for (parsed.map) |entry| {
            if (entry.key == .string) {
                if (std.mem.eql(u8, entry.key.string, "namespace")) {
                    if (entry.value == .string) {
                        namespace = entry.value.string;
                    }
                } else if (std.mem.eql(u8, entry.key.string, "path")) {
                    if (entry.value == .string) {
                        path = entry.value.string;
                    }
                } else if (std.mem.eql(u8, entry.key.string, "value")) {
                    value = entry.value;
                }
            }
        }

        if (namespace == null or path == null or value == null) {
            return error.MissingRequiredFields;
        }

        // Store in database
        // NOTE: We need to serialize the Value to bytes for storage
        var serializer = MessagePackSerializer.init(self.allocator);
        defer serializer.deinit();
        try self.serializeValue(&serializer, value.?);
        const serialized_value = try serializer.toOwnedSlice();
        defer self.allocator.free(serialized_value);

        try self.storage_engine.set(namespace.?, path.?, serialized_value);

        // Build success response
        return try self.buildSuccessResponse(msg_id);
    }

    /// Handle StoreGet message
    /// Requirements: 16.5, 16.6, 16.7, 16.8, 16.9
    fn handleStoreGet(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: MessagePackParser.Value,
    ) ![]const u8 {
        _ = conn_id;

        // Extract namespace and path from message
        var namespace: ?[]const u8 = null;
        var path: ?[]const u8 = null;

        for (parsed.map) |entry| {
            if (entry.key == .string) {
                if (std.mem.eql(u8, entry.key.string, "namespace")) {
                    if (entry.value == .string) {
                        namespace = entry.value.string;
                    }
                } else if (std.mem.eql(u8, entry.key.string, "path")) {
                    if (entry.value == .string) {
                        path = entry.value.string;
                    }
                }
            }
        }

        if (namespace == null or path == null) {
            return error.MissingRequiredFields;
        }

        // Get from database
        const value_bytes = try self.storage_engine.get(namespace.?, path.?);
        defer if (value_bytes) |v| self.allocator.free(v);

        // Build response with value
        return try self.buildValueResponse(msg_id, value_bytes);
    }

    /// Build success response for StoreSet
    /// Requirements: 16.4
    fn buildSuccessResponse(self: *MessageHandler, msg_id: u64) ![]const u8 {
        var serializer = MessagePackSerializer.init(self.allocator);
        defer serializer.deinit();

        try serializer.writeMapHeader(2);
        try serializer.writeString("type");
        try serializer.writeString("ok");
        try serializer.writeString("id");
        try serializer.writeUint(msg_id);

        return try serializer.toOwnedSlice();
    }

    /// Build value response for StoreGet
    /// Requirements: 16.8, 16.9
    fn buildValueResponse(self: *MessageHandler, msg_id: u64, value_bytes: ?[]const u8) ![]const u8 {
        var serializer = MessagePackSerializer.init(self.allocator);
        defer serializer.deinit();

        if (value_bytes) |v| {
            try serializer.writeMapHeader(3);
            try serializer.writeString("type");
            try serializer.writeString("ok");
            try serializer.writeString("id");
            try serializer.writeUint(msg_id);
            try serializer.writeString("value");
            
            // Append raw MessagePack bytes directly
            try serializer.buf.appendSlice(self.allocator, v);
        } else {
            try serializer.writeMapHeader(3);
            try serializer.writeString("type");
            try serializer.writeString("error");
            try serializer.writeString("id");
            try serializer.writeUint(msg_id);
            try serializer.writeString("code");
            try serializer.writeString("NOT_FOUND");
        }

        return try serializer.toOwnedSlice();
    }

    /// Send error response to client
    /// Requirements: 6.7, 6.8
    fn sendError(self: *MessageHandler, ws: *WebSocket, code: []const u8, message: []const u8) !void {
        var serializer = MessagePackSerializer.init(self.allocator);
        defer serializer.deinit();

        try serializer.writeMapHeader(3);
        try serializer.writeString("type");
        try serializer.writeString("error");
        try serializer.writeString("code");
        try serializer.writeString(code);
        try serializer.writeString("message");
        try serializer.writeString(message);

        const error_msg = try serializer.toOwnedSlice();
        defer self.allocator.free(error_msg);

        ws.send(error_msg, .binary);
    }

    /// Serialize a MessagePack Value back to bytes
    fn serializeValue(self: *MessageHandler, serializer: *MessagePackSerializer, value: MessagePackParser.Value) !void {
        switch (value) {
            .nil => try serializer.writeNil(),
            .boolean => |b| try serializer.writeBool(b),
            .integer => |i| try serializer.writeInt(i),
            .unsigned => |u| try serializer.writeUint(u),
            .float => |f| try serializer.writeFloat(f),
            .string => |s| try serializer.writeString(s),
            .binary => |b| try serializer.writeBinary(b),
            .array => |arr| {
                try serializer.writeArrayHeader(arr.len);
                for (arr) |val| {
                    try self.serializeValue(serializer, val);
                }
            },
            .map => |m| {
                try serializer.writeMapHeader(m.len);
                for (m) |entry| {
                    try self.serializeValue(serializer, entry.key);
                    try self.serializeValue(serializer, entry.value);
                }
            },
        }
    }

    /// Message information extracted from parsed MessagePack
    const MessageInfo = struct {
        type: []const u8,
        id: u64,
    };
};

/// Per-connection state tracking
pub const ConnectionState = struct {
    id: u64,
    user_id: ?[]const u8,
    namespace: []const u8,
    subscription_ids: std.array_list.Managed(u64),
    created_at: i64,

    pub fn init(allocator: Allocator, id: u64) !*ConnectionState {
        const state = try allocator.create(ConnectionState);
        state.* = .{
            .id = id,
            .user_id = null,
            .namespace = "default",
            .subscription_ids = std.array_list.Managed(u64).init(allocator),
            .created_at = std.time.timestamp(),
        };
        return state;
    }

    pub fn deinit(self: *ConnectionState, allocator: Allocator) void {
        self.subscription_ids.deinit();
        allocator.destroy(self);
    }
};

/// Thread-safe registry for tracking active WebSocket connections
pub const ConnectionRegistry = struct {
    connections: std.AutoHashMap(u64, *ConnectionState),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) !ConnectionRegistry {
        return ConnectionRegistry{
            .connections = std.AutoHashMap(u64, *ConnectionState).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConnectionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.connections.valueIterator();
        while (it.next()) |state| {
            state.*.deinit(self.connections.allocator);
        }

        self.connections.deinit();
    }

    pub fn add(self: *ConnectionRegistry, id: u64, state: *ConnectionState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.connections.put(id, state);
    }

    pub fn get(self: *ConnectionRegistry, id: u64) !*ConnectionState {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.connections.get(id) orelse error.ConnectionNotFound;
    }

    pub fn remove(self: *ConnectionRegistry, id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.fetchRemove(id)) |entry| {
            entry.value.deinit(self.connections.allocator);
        }
    }

    pub fn clear(self: *ConnectionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.connections.valueIterator();
        while (it.next()) |state| {
            state.*.deinit(self.connections.allocator);
        }

        self.connections.clearRetainingCapacity();
    }

    pub fn iterator(self: *ConnectionRegistry) std.AutoHashMap(u64, *ConnectionState).Iterator {
        return self.connections.iterator();
    }
};
