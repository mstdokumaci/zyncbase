const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const storage_mod = @import("storage_engine.zig");
const StorageEngine = storage_mod.StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;

/// Structured path parsed from a MessagePack array payload.
pub const ParsedPath = union(enum) {
    collection: struct { table: []const u8 },
    document: struct { table: []const u8, id: []const u8 },
    field: struct { table: []const u8, id: []const u8, fields: [][]const u8 },
};

/// Parse a MessagePack array payload into a structured ParsedPath.
/// - If path_payload is not an array → error.InvalidPath
/// - Length 0 → error.InvalidPath
/// - Any non-string element → error.InvalidPath
/// - Length 1 → .collection
/// - Length 2 → .document
/// - Length ≥ 3 → .field (allocates fields slice using allocator)
pub fn parsePath(allocator: std.mem.Allocator, path_payload: msgpack.Payload) !ParsedPath {
    if (path_payload != .arr) return error.InvalidPath;
    const elems = path_payload.arr;
    if (elems.len == 0) return error.InvalidPath;
    for (elems) |elem| {
        if (elem != .str) return error.InvalidPath;
    }
    const table = elems[0].str.value();
    if (elems.len == 1) {
        return .{ .collection = .{ .table = table } };
    }
    const id = elems[1].str.value();
    if (elems.len == 2) {
        return .{ .document = .{ .table = table, .id = id } };
    }
    // Length >= 3: allocate fields slice
    const fields = try allocator.alloc([]const u8, elems.len - 2);
    for (elems[2..], 0..) |elem, i| {
        fields[i] = elem.str.value();
    }
    return .{ .field = .{ .table = table, .id = id, .fields = fields } };
}

/// Message handler for WebSocket events
/// Manages connection lifecycle, message parsing, routing, and response handling
pub const MessageHandler = struct {
    allocator: Allocator,
    violation_tracker: *ViolationTracker,
    request_handler: *RequestHandler,
    storage_engine: *StorageEngine,
    subscription_manager: *SubscriptionManager,
    cache: *LockFreeCache,
    connection_registry: ConnectionRegistry,

    /// Initialize message handler with all required components
    pub fn init(
        allocator: Allocator,
        violation_tracker: *ViolationTracker,
        request_handler: *RequestHandler,
        storage_engine: *StorageEngine,
        subscription_manager: *SubscriptionManager,
        cache: *LockFreeCache,
    ) !*MessageHandler {
        const self = try allocator.create(MessageHandler);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .violation_tracker = violation_tracker,
            .request_handler = request_handler,
            .storage_engine = storage_engine,
            .subscription_manager = subscription_manager,
            .cache = cache,
            .connection_registry = try ConnectionRegistry.init(allocator),
        };

        return self;
    }

    /// Clean up message handler resources
    pub fn deinit(self: *MessageHandler) void {
        self.connection_registry.deinit();
        self.allocator.destroy(self);
    }

    /// Handle WebSocket connection open event
    /// Uses WebSocket pointer as unique connection ID and adds to registry
    pub fn handleOpen(self: *MessageHandler, ws: *WebSocket) !void {
        const conn_id = ws.getConnId();

        // Create connection state
        const conn_state = try ConnectionState.init(self.allocator, conn_id, ws.*);
        errdefer conn_state.deinit(self.allocator);

        // Store in registry
        try self.connection_registry.add(conn_id, conn_state);

        std.log.info("WebSocket connection opened: id={}", .{conn_id});
    }

    /// Handle WebSocket message event
    /// Parses MessagePack, extracts message info, routes to handler, and sends response
    pub fn handleMessage(
        self: *MessageHandler,
        ws: *WebSocket,
        message: []const u8,
        msg_type: MessageType,
    ) !void {
        _ = msg_type;
        // Get stable unique connection ID
        const conn_id = ws.getConnId();

        // Get connection state (increments refcount)
        const conn_state = self.connection_registry.acquireConnection(conn_id) catch |err| {
            std.log.warn("Connection {} not found in registry during message: {}", .{ conn_id, err });
            return;
        };
        defer conn_state.release(self.allocator);

        // Process message under connection mutex to protect arena and state
        conn_state.mutex.lock();
        defer conn_state.mutex.unlock();

        // Use connection's local arena
        const arena_allocator = conn_state.arena.allocator();
        defer conn_state.arenaReset();

        // Parse MessagePack message
        var reader: std.Io.Reader = .fixed(message);
        const parsed = msgpack.decode(arena_allocator, &reader) catch |err| {
            std.log.warn("Failed to parse message from connection {}: {}", .{ conn_id, err });

            // Record violation if it was a security/limit error
            if (isSecurityError(err)) {
                if (try self.violation_tracker.recordViolation(conn_id)) {
                    std.log.warn("Closing connection {} due to repeated security violations", .{conn_id});
                    ws.close();
                    return;
                }
            }

            try self.sendError(ws, "INVALID_MESSAGE", "Failed to parse MessagePack");
            return;
        };

        // Extract message type and correlation ID
        const msg_info = self.extractMessageInfo(parsed) catch |err| {
            std.log.warn("Failed to extract message info from connection {}: {}", .{ conn_id, err });
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
        ws.send(response, .binary);
    }

    /// Handle WebSocket connection close event
    /// Removes subscriptions and connection state
    pub fn handleClose(self: *MessageHandler, ws: *WebSocket, code: i32, message: []const u8) !void {
        const conn_id = ws.getConnId();

        std.log.debug("WebSocket closed: id={}, code={}, reason={s}", .{
            conn_id,
            code,
            message,
        });

        // Get connection state (increments refcount)
        const conn_state = self.connection_registry.acquireConnection(conn_id) catch |err| {
            std.log.debug("Connection {} not found in registry during close: {}", .{ conn_id, err });
            return;
        };
        defer conn_state.release(self.allocator);

        // Cleanup under mutex
        {
            conn_state.mutex.lock();
            defer conn_state.mutex.unlock();

            // Remove all subscriptions for this connection
            for (conn_state.subscription_ids.items) |sub_id| {
                self.subscription_manager.unsubscribe(sub_id) catch |err| {
                    std.log.debug("Failed to unsubscribe {} for connection {}: {}", .{ sub_id, conn_id, err });
                };
            }
        }

        // Remove from registry (decrements registry's refcount)
        try self.connection_registry.remove(conn_id);
    }

    /// Handle WebSocket error event
    /// Cleans up connection state
    pub fn handleError(self: *MessageHandler, ws: *WebSocket) !void {
        const conn_id = ws.getConnId();

        std.log.debug("WebSocket error on connection: id={}", .{conn_id});

        // Clean up connection state if it exists
        if (self.connection_registry.acquireConnection(conn_id)) |conn_state| {
            defer conn_state.release(self.allocator);

            // Cleanup under mutex
            {
                conn_state.mutex.lock();
                defer conn_state.mutex.unlock();

                // Remove subscriptions
                for (conn_state.subscription_ids.items) |sub_id| {
                    self.subscription_manager.unsubscribe(sub_id) catch |err| {
                        std.log.warn("Failed to unsubscribe {} during error cleanup: {}", .{ sub_id, err });
                    };
                }
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
    pub fn closeAllConnections(self: *MessageHandler) !void {
        var snap = try self.connection_registry.snapshot();
        defer snap.deinit();

        var it = snap.valueIterator();
        while (it.next()) |state| {
            const conn_state = state.*;

            // Cleanup under mutex
            {
                conn_state.mutex.lock();
                defer conn_state.mutex.unlock();

                // Remove subscriptions
                for (conn_state.subscription_ids.items) |sub_id| {
                    self.subscription_manager.unsubscribe(sub_id) catch |err| {
                        std.log.warn("Failed to unsubscribe {} during shutdown: {}", .{ sub_id, err });
                    };
                }

                // Close the WebSocket connection
                conn_state.ws.close();
            }

            std.log.info("Closed connection: id={}", .{conn_state.id});
        }

        self.connection_registry.clear();
    }

    /// Extract message type and correlation ID from parsed MessagePack
    pub fn extractMessageInfo(_: *MessageHandler, parsed: msgpack.Payload) !MessageInfo {

        // Extract type and id from MessagePack map
        if (parsed != .map) {
            std.log.debug("parsed is not map, it is {}", .{parsed});
            return error.InvalidMessageFormat;
        }

        var msg_type: ?[]const u8 = null;
        var msg_id: ?u64 = null;

        var it = parsed.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (key == .str) {
                const key_str = key.str.value();
                if (std.mem.eql(u8, key_str, "type")) {
                    if (value == .str) {
                        msg_type = value.str.value();
                    }
                } else if (std.mem.eql(u8, key_str, "id")) {
                    if (value == .uint) {
                        msg_id = value.uint;
                    }
                }
            }
        }

        if (msg_type == null or msg_id == null) {
            return error.MissingRequiredFields;
        }

        return MessageInfo{
            .type = msg_type orelse unreachable,
            .id = msg_id orelse unreachable,
        };
    }

    pub fn routeMessage(
        self: *MessageHandler,
        conn_id: u64,
        msg_info: MessageInfo,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        // Route based on message type
        if (std.mem.eql(u8, msg_info.type, "StoreSet")) {
            return try self.handleStoreSet(conn_id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreGet")) {
            return try self.handleStoreGet(conn_id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreRemove")) {
            return try self.handleStoreRemove(msg_info.id, parsed);
        } else {
            return error.UnknownMessageType;
        }
    }

    fn handleStoreSet(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        // Extract namespace, path, and value from message
        var namespace: ?[]const u8 = null;
        var parsed_path: ?ParsedPath = null;
        var value: ?msgpack.Payload = null;

        var it = parsed.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key == .str) {
                const key_str = key.str.value();
                if (std.mem.eql(u8, key_str, "namespace")) {
                    if (val == .str) {
                        namespace = val.str.value();
                    }
                } else if (std.mem.eql(u8, key_str, "path")) {
                    if (val == .arr) {
                        parsed_path = try parsePath(self.allocator, val);
                    }
                } else if (std.mem.eql(u8, key_str, "value")) {
                    value = val;
                }
            }
        }

        if (namespace == null or parsed_path == null or value == null) {
            return error.MissingRequiredFields;
        }

        // Defer field slice cleanup if it was allocated
        // parsed_path is guaranteed to be non-null by the check above
        defer if ((parsed_path orelse unreachable) == .field) self.allocator.free((parsed_path orelse unreachable).field.fields);

        switch (parsed_path orelse unreachable) {
            .document => |doc| {
                // value is guaranteed to be non-null by the check above
                if ((value orelse unreachable) != .map) return error.InvalidPayload;

                // Convert map to ColumnValue array
                var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue){};
                defer columns.deinit(self.allocator);

                // value is guaranteed to be non-null by the check above
                var val_it = (value orelse unreachable).map.iterator();
                while (val_it.next()) |entry| {
                    if (entry.key_ptr.* != .str) continue;
                    try columns.append(self.allocator, .{
                        .name = entry.key_ptr.*.str.str,
                        .value = entry.value_ptr.*,
                    });
                }

                // namespace is guaranteed to be non-null by the check above
                try self.storage_engine.insertOrReplace(doc.table, doc.id, namespace orelse unreachable, columns.items);
            },
            .field => |f| {
                // If nested fields, we currently flatten them: field1/field2 -> field1_field2
                // For now, only support single depth or simple join
                if (f.fields.len == 1) {
                    // namespace and value are guaranteed to be non-null by the check above
                    try self.storage_engine.updateField(f.table, f.id, namespace orelse unreachable, f.fields[0], value orelse unreachable);
                } else if (f.fields.len > 1) {
                    // Note: Implement deep flattening if needed, or join with _
                    const flattened_field = try std.mem.join(self.allocator, "_", f.fields);
                    defer self.allocator.free(flattened_field);
                    // namespace and value are guaranteed to be non-null by the check above
                    try self.storage_engine.updateField(f.table, f.id, namespace orelse unreachable, flattened_field, value orelse unreachable);
                }
            },
            .collection => return error.InvalidOperation, // Cannot set on a collection
        }

        // Build success response
        return try self.buildSuccessResponse(msg_id);
    }

    fn handleStoreGet(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        // Extract namespace and path from message
        var namespace: ?[]const u8 = null;
        var parsed_path: ?ParsedPath = null;

        var it = parsed.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key == .str) {
                const key_str = key.str.value();
                if (std.mem.eql(u8, key_str, "namespace")) {
                    if (val == .str) {
                        namespace = val.str.value();
                    }
                } else if (std.mem.eql(u8, key_str, "path")) {
                    if (val == .arr) {
                        parsed_path = try parsePath(self.allocator, val);
                    }
                }
            }
        }

        if (namespace == null or parsed_path == null) {
            return error.MissingRequiredFields;
        }

        // Defer field slice cleanup if it was allocated
        // parsed_path is guaranteed to be non-null by the check above
        defer if ((parsed_path orelse unreachable) == .field) self.allocator.free((parsed_path orelse unreachable).field.fields);

        const result_payload: ?msgpack.Payload = switch (parsed_path orelse unreachable) {
            .document => |doc| blk: {
                // namespace is guaranteed to be non-null by the check above
                const stored_doc = self.storage_engine.selectDocument(doc.table, doc.id, namespace orelse unreachable) catch |err| {
                    std.log.err("handleStoreGet: selectDocument error: {}", .{err});
                    return err;
                };

                if (stored_doc == null) {
                    std.log.debug("handleStoreGet: selectDocument returned null for {s}:{s} in {s}", .{ doc.table, doc.id, namespace orelse unreachable });
                    break :blk null; // Return null to indicate not found, will be handled by buildDataResponse
                }
                std.log.debug("handleStoreGet: selectDocument returned document for {s}:{s}", .{ doc.table, doc.id });
                break :blk stored_doc;
            },
            .field => |f| blk: {
                // namespace is guaranteed to be non-null by the check above
                if (f.fields.len == 1) {
                    break :blk try self.storage_engine.selectField(f.table, f.id, namespace orelse unreachable, f.fields[0]);
                } else if (f.fields.len > 1) {
                    const flattened_field = try std.mem.join(self.allocator, "_", f.fields);
                    defer self.allocator.free(flattened_field);
                    break :blk try self.storage_engine.selectField(f.table, f.id, namespace orelse unreachable, flattened_field);
                }
                break :blk null;
            },
            .collection => |c| blk: {
                // namespace is guaranteed to be non-null by the check above
                // Return all documents in the collection
                break :blk try self.storage_engine.selectCollection(c.table, namespace orelse unreachable);
            },
        };

        // Build response
        if (result_payload) |payload| {
            return try self.buildDataResponse(msg_id, payload);
        } else {
            return try self.buildErrorResponse(msg_id, "NOT_FOUND");
        }
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        // Extract namespace and path
        var namespace: ?[]const u8 = null;
        var parsed_path: ?ParsedPath = null;

        var it = parsed.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key == .str) {
                const key_str = key.str.value();
                if (std.mem.eql(u8, key_str, "namespace")) {
                    if (val == .str) {
                        namespace = val.str.value();
                    }
                } else if (std.mem.eql(u8, key_str, "path")) {
                    if (val == .arr) {
                        parsed_path = try parsePath(self.allocator, val);
                    }
                }
            }
        }

        if (namespace == null or parsed_path == null) {
            return error.MissingRequiredFields;
        }

        // Defer field slice cleanup if it was allocated
        // parsed_path is guaranteed to be non-null by the check above
        defer if ((parsed_path orelse unreachable) == .field) self.allocator.free((parsed_path orelse unreachable).field.fields);

        switch (parsed_path orelse unreachable) {
            .document => |doc| {
                // namespace is guaranteed to be non-null by the check above
                try self.storage_engine.deleteDocument(doc.table, doc.id, namespace orelse unreachable);
            },
            .field => |f| {
                // If nested fields, we currently flatten them: field1/field2 -> field1_field2
                if (f.fields.len == 1) {
                    // namespace is guaranteed to be non-null by the check above
                    try self.storage_engine.updateField(f.table, f.id, namespace orelse unreachable, f.fields[0], .nil);
                } else if (f.fields.len > 1) {
                    const flattened_field = try std.mem.join(self.allocator, "_", f.fields);
                    defer self.allocator.free(flattened_field);
                    // namespace is guaranteed to be non-null by the check above
                    try self.storage_engine.updateField(f.table, f.id, namespace orelse unreachable, flattened_field, .nil);
                }
            },
            .collection => return error.InvalidOperation, // Cannot remove a whole collection yet
        }

        return try self.buildSuccessResponse(msg_id);
    }
    fn buildDataResponse(self: *MessageHandler, msg_id: u64, result_payload: msgpack.Payload) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("ok", self.allocator));
        try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));
        try payload.mapPut("value", result_payload); // Note: result_payload is now part of the map, deinit of payload will handle it

        try msgpack.encode(payload, &aw.writer);
        return aw.toOwnedSlice();
    }

    /// Build an error response with a code string.
    fn buildErrorResponse(self: *MessageHandler, msg_id: u64, code: []const u8) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("error", self.allocator));
        try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));
        try payload.mapPut("code", try msgpack.Payload.strToPayload(code, self.allocator));

        try msgpack.encode(payload, &aw.writer);
        return try aw.toOwnedSlice();
    }

    /// Build success response for StoreSet
    fn buildSuccessResponse(self: *MessageHandler, msg_id: u64) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("ok", self.allocator));
        try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));

        try msgpack.encode(payload, &aw.writer);
        return try aw.toOwnedSlice();
    }

    /// Send error response to client
    fn sendError(self: *MessageHandler, ws: *WebSocket, code: []const u8, message: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("error", self.allocator));
        try payload.mapPut("code", try msgpack.Payload.strToPayload(code, self.allocator));
        try payload.mapPut("message", try msgpack.Payload.strToPayload(message, self.allocator));

        try msgpack.encode(payload, &aw.writer);
        const error_msg = try aw.toOwnedSlice();
        defer self.allocator.free(error_msg);

        ws.send(error_msg, .binary);
    }

    fn isSecurityError(err: anyerror) bool {
        return switch (err) {
            error.MaxDepthExceeded,
            error.ArrayTooLarge,
            error.MapTooLarge,
            error.StringTooLong,
            error.BinDataLengthTooLong,
            error.ExtDataTooLarge,
            => true,
            else => false,
        };
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
    ws: WebSocket,
    subscription_ids: std.array_list.Managed(u64),
    created_at: i64,
    arena: std.heap.ArenaAllocator,
    ref_count: std.atomic.Value(u32),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, id: u64, ws: WebSocket) !*ConnectionState {
        const state = try allocator.create(ConnectionState);
        state.* = .{
            .id = id,
            .ws = ws,
            .user_id = null,
            .namespace = "default",
            .subscription_ids = std.array_list.Managed(u64).init(allocator),
            .created_at = std.time.timestamp(),
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .ref_count = std.atomic.Value(u32).init(1),
            .mutex = .{},
        };
        return state;
    }

    pub fn deinit(self: *ConnectionState, allocator: Allocator) void {
        self.subscription_ids.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn acquire(self: *ConnectionState) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *ConnectionState, allocator: Allocator) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            self.deinit(allocator);
        }
    }

    pub fn arenaReset(self: *ConnectionState) void {
        _ = self.arena.reset(.free_all);
    }
};

/// Thread-safe registry for tracking active WebSocket connections using COW
pub const ConnectionRegistry = struct {
    const Map = std.AutoHashMap(u64, *ConnectionState);

    map: Map,
    mutex: std.Thread.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !ConnectionRegistry {
        return ConnectionRegistry{
            .map = Map.init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConnectionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.valueIterator();
        while (it.next()) |state| {
            state.*.release(self.allocator);
        }
        self.map.deinit();
    }

    pub fn add(self: *ConnectionRegistry, id: u64, state: *ConnectionState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(id, state);
    }

    pub fn remove(self: *ConnectionRegistry, id: u64) !void {
        self.mutex.lock();
        const maybe_state = self.map.fetchRemove(id);
        self.mutex.unlock();

        if (maybe_state) |entry| {
            entry.value.release(self.allocator);
        }
    }

    pub fn acquireConnection(self: *ConnectionRegistry, id: u64) !*ConnectionState {
        self.mutex.lock();
        defer self.mutex.unlock();
        const state = self.map.get(id) orelse return error.ConnectionNotFound;
        state.acquire();
        return state;
    }

    pub fn clear(self: *ConnectionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.valueIterator();
        while (it.next()) |state| {
            state.*.release(self.allocator);
        }
        self.map.clearRetainingCapacity();
    }

    /// Note: Snapshot is now a bit more expensive as it must clone under lock
    /// to remain thread-safe.
    pub const Snapshot = struct {
        map: Map,
        allocator: Allocator,

        pub fn deinit(self: *Snapshot) void {
            var it = self.map.valueIterator();
            while (it.next()) |state| {
                state.*.release(self.allocator);
            }
            self.map.deinit();
        }

        pub fn count(self: Snapshot) usize {
            return self.map.count();
        }

        pub fn iterator(self: *Snapshot) Map.Iterator {
            return self.map.iterator();
        }

        pub fn valueIterator(self: *Snapshot) Map.ValueIterator {
            return self.map.valueIterator();
        }
    };

    pub fn snapshot(self: *ConnectionRegistry) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        var new_map = try self.map.clone();
        var it = new_map.valueIterator();
        while (it.next()) |state| {
            state.*.acquire();
        }
        return Snapshot{
            .map = new_map,
            .allocator = self.allocator,
        };
    }
};
