const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
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
    next_connection_id: std.atomic.Value(u64),

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
    pub fn handleOpen(self: *MessageHandler, ws: *WebSocket) !void {
        // Generate unique connection ID (atomic increment)
        const conn_id = self.next_connection_id.fetchAdd(1, .monotonic);

        // Create connection state
        const conn_state = try ConnectionState.init(self.allocator, conn_id, ws.*);
        errdefer conn_state.deinit(self.allocator);

        // Store in registry
        try self.connection_registry.add(conn_id, conn_state);

        // Associate connection ID with WebSocket
        ws.setUserData(@ptrFromInt(conn_id));

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
        // Get connection ID from WebSocket user data
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

        // Only handle binary messages (MessagePack)
        if (msg_type != .binary) {
            try self.sendError(ws, "TEXT_NOT_SUPPORTED", "Only binary MessagePack messages are supported");
            return;
        }

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
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

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
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

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
            .type = msg_type.?,
            .id = msg_id.?,
        };
    }

    /// Route message to appropriate handler based on type
    pub fn routeMessage(
        self: *MessageHandler,
        conn_id: u64,
        msg_info: MessageInfo,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        // Route based on message type
        if (std.mem.eql(u8, msg_info.type, "StoreSet")) {
            if (self.storage_engine.schema != null) {
                return try self.handleStoreSetTyped(conn_id, msg_info.id, parsed);
            }
            return try self.handleStoreSet(conn_id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreGet")) {
            if (self.storage_engine.schema != null) {
                return try self.handleStoreGetTyped(conn_id, msg_info.id, parsed);
            }
            return try self.handleStoreGet(conn_id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreRemove")) {
            if (self.storage_engine.schema != null) {
                return try self.handleStoreRemoveTyped(conn_id, msg_info.id, parsed);
            }
            return try self.handleStoreRemove(msg_info.id, parsed);
        } else {
            return error.UnknownMessageType;
        }
    }

    /// Handle StoreSet message
    fn handleStoreSet(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        // Extract namespace, path, and value from message
        var namespace: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var path_is_allocated = false;
        defer if (path_is_allocated) if (path) |p| self.allocator.free(p);

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
                        const parsed_path = parsePath(self.allocator, val) catch return error.InvalidPath;
                        // Convert ParsedPath back to slash-joined string for backward compat with storage_engine.set/get
                        path = try self.parsedPathToString(parsed_path);
                        path_is_allocated = true;
                        // Free fields slice if it was allocated (field variant)
                        if (parsed_path == .field) self.allocator.free(parsed_path.field.fields);
                    } else if (try self.parsePathFromPayload(val)) |p| {
                        path = p.path;
                        path_is_allocated = p.allocated;
                    }
                } else if (std.mem.eql(u8, key_str, "value")) {
                    value = val;
                }
            }
        }

        if (namespace == null or path == null or value == null) {
            return error.MissingRequiredFields;
        }

        // Store in database
        // NOTE: We need to serialize the Value to bytes for storage
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try msgpack.encode(value.?, &aw.writer);
        const serialized_value = try aw.toOwnedSlice();
        defer self.allocator.free(serialized_value);

        try self.storage_engine.set(namespace.?, path.?, serialized_value);

        // Build success response
        return try self.buildSuccessResponse(msg_id);
    }

    /// Handle StoreGet message
    fn handleStoreGet(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        // Extract namespace and path from message
        var namespace: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var path_is_allocated = false;
        defer if (path_is_allocated) if (path) |p| self.allocator.free(p);

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
                        const parsed_path = parsePath(self.allocator, val) catch return error.InvalidPath;
                        path = try self.parsedPathToString(parsed_path);
                        path_is_allocated = true;
                        if (parsed_path == .field) self.allocator.free(parsed_path.field.fields);
                    } else if (try self.parsePathFromPayload(val)) |p| {
                        path = p.path;
                        path_is_allocated = p.allocated;
                    }
                }
            }
        }

        if (namespace == null or path == null) {
            return error.MissingRequiredFields;
        }

        // Get from database
        const value_bytes = try self.storage_engine.get(namespace.?, path.?);
        if (value_bytes) |v| {
            defer self.allocator.free(v);
            return try self.buildValueResponse(msg_id, v);
        }

        // Exact match not found, try collection query
        const query_results = try self.storage_engine.query(namespace.?, path.?);
        defer {
            for (query_results) |result| {
                self.allocator.free(result.path);
                self.allocator.free(result.value);
            }
            self.allocator.free(query_results);
        }

        if (query_results.len > 0) {
            return try self.buildQueryResponse(msg_id, query_results);
        }

        // Nothing found
        return try self.buildValueResponse(msg_id, null);
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        // Extract namespace and path
        var namespace: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var path_is_allocated = false;
        defer if (path_is_allocated) if (path) |p| self.allocator.free(p);

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
                    if (try self.parsePathFromPayload(val)) |p| {
                        path = p.path;
                        path_is_allocated = p.allocated;
                    }
                }
            }
        }

        if (namespace == null or path == null) {
            return error.MissingRequiredFields;
        }

        // Delete from storage engine
        try self.storage_engine.delete(namespace.?, path.?);

        // Build success response
        return try self.buildSuccessResponse(msg_id);
    }

    // ─── Typed handlers (schema-aware path) ──────────────────────────────────

    /// Handle StoreSet using typed StorageEngine methods (schema must be loaded).
    fn handleStoreSetTyped(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        var namespace: ?[]const u8 = null;
        var path_payload: ?msgpack.Payload = null;
        var value_payload: ?msgpack.Payload = null;

        var it = parsed.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key == .str) {
                const k = key.str.value();
                if (std.mem.eql(u8, k, "namespace")) {
                    if (val == .str) namespace = val.str.value();
                } else if (std.mem.eql(u8, k, "path")) {
                    path_payload = val;
                } else if (std.mem.eql(u8, k, "value")) {
                    value_payload = val;
                }
            }
        }

        if (namespace == null or path_payload == null or value_payload == null) {
            return error.MissingRequiredFields;
        }

        const pp = parsePath(self.allocator, path_payload.?) catch {
            return try self.buildErrorResponse(msg_id, "INVALID_PATH");
        };
        defer if (pp == .field) self.allocator.free(pp.field.fields);

        switch (pp) {
            .collection => return error.InvalidPath, // can't set a whole collection
            .document => |d| {
                // value must be a map; each key becomes a ColumnValue
                if (value_payload.? != .map) return error.InvalidMessageFormat;
                var cols = std.ArrayListUnmanaged(@import("storage_engine.zig").ColumnValue){};
                defer cols.deinit(self.allocator);
                var vit = value_payload.?.map.iterator();
                while (vit.next()) |ve| {
                    if (ve.key_ptr.* != .str) continue;
                    try cols.append(self.allocator, .{ .name = ve.key_ptr.*.str.value(), .value = ve.value_ptr.* });
                }
                try self.storage_engine.insertOrReplace(d.table, d.id, namespace.?, cols.items);
            },
            .field => |f| {
                // single field update
                const field_name = f.fields[0];
                try self.storage_engine.updateField(f.table, f.id, namespace.?, field_name, value_payload.?);
            },
        }

        return try self.buildSuccessResponse(msg_id);
    }

    /// Handle StoreGet using typed StorageEngine methods (schema must be loaded).
    fn handleStoreGetTyped(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        var namespace: ?[]const u8 = null;
        var path_payload: ?msgpack.Payload = null;

        var it = parsed.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key == .str) {
                const k = key.str.value();
                if (std.mem.eql(u8, k, "namespace")) {
                    if (val == .str) namespace = val.str.value();
                } else if (std.mem.eql(u8, k, "path")) {
                    path_payload = val;
                }
            }
        }

        if (namespace == null or path_payload == null) {
            return error.MissingRequiredFields;
        }

        const pp = parsePath(self.allocator, path_payload.?) catch {
            return try self.buildErrorResponse(msg_id, "INVALID_PATH");
        };
        defer if (pp == .field) self.allocator.free(pp.field.fields);

        switch (pp) {
            .collection => |c| {
                const result = try self.storage_engine.selectCollection(c.table, namespace.?);
                // result ownership transferred to buildTypedValueResponse
                return try self.buildTypedValueResponse(msg_id, result);
            },
            .document => |d| {
                const result = try self.storage_engine.selectDocument(d.table, d.id, namespace.?);
                if (result) |r| {
                    return try self.buildTypedValueResponse(msg_id, r);
                }
                return try self.buildErrorResponse(msg_id, "NOT_FOUND");
            },
            .field => |f| {
                const result = try self.storage_engine.selectField(f.table, f.id, namespace.?, f.fields[0]);
                if (result) |r| {
                    return try self.buildTypedValueResponse(msg_id, r);
                }
                return try self.buildErrorResponse(msg_id, "NOT_FOUND");
            },
        }
    }

    /// Handle StoreRemove using typed StorageEngine methods (schema must be loaded).
    fn handleStoreRemoveTyped(
        self: *MessageHandler,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        var namespace: ?[]const u8 = null;
        var path_payload: ?msgpack.Payload = null;

        var it = parsed.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key == .str) {
                const k = key.str.value();
                if (std.mem.eql(u8, k, "namespace")) {
                    if (val == .str) namespace = val.str.value();
                } else if (std.mem.eql(u8, k, "path")) {
                    path_payload = val;
                }
            }
        }

        if (namespace == null or path_payload == null) {
            return error.MissingRequiredFields;
        }

        const pp = parsePath(self.allocator, path_payload.?) catch {
            return try self.buildErrorResponse(msg_id, "INVALID_PATH");
        };
        defer if (pp == .field) self.allocator.free(pp.field.fields);

        switch (pp) {
            .collection => return error.InvalidPath, // can't delete a whole collection via this path
            .document => |d| {
                try self.storage_engine.deleteDocument(d.table, d.id, namespace.?);
            },
            .field => return error.InvalidPath, // field-level delete not supported
        }

        return try self.buildSuccessResponse(msg_id);
    }

    /// Build a typed value response (value is already a Payload).
    fn buildTypedValueResponse(self: *MessageHandler, msg_id: u64, value: msgpack.Payload) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("ok", self.allocator));
        try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));
        try payload.mapPut("value", value);

        try msgpack.encode(payload, &aw.writer);
        return try aw.toOwnedSlice();
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

    /// Build value response for StoreGet
    fn buildValueResponse(self: *MessageHandler, msg_id: u64, value_bytes: ?[]const u8) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        if (value_bytes) |v| {
            try payload.mapPut("type", try msgpack.Payload.strToPayload("ok", self.allocator));
            try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));

            // For the value, we can decode it first or send it as binary
            // Since it's already MessagePack, decoding it into a Payload is safest
            var reader: std.Io.Reader = .fixed(v);
            const val_payload = try msgpack.decode(self.allocator, &reader);
            try payload.mapPut("value", val_payload);
        } else {
            try payload.mapPut("type", try msgpack.Payload.strToPayload("error", self.allocator));
            try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));
            try payload.mapPut("code", try msgpack.Payload.strToPayload("NOT_FOUND", self.allocator));
        }

        try msgpack.encode(payload, &aw.writer);
        return try aw.toOwnedSlice();
    }

    /// Build query response for StoreGet (collections)
    fn buildQueryResponse(
        self: *MessageHandler,
        msg_id: u64,
        results: []const @import("storage_engine.zig").QueryResult,
    ) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("ok", self.allocator));
        try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));

        var value_map = msgpack.Payload.mapPayload(self.allocator);
        errdefer value_map.free(self.allocator);

        for (results) |res| {
            var reader: std.Io.Reader = .fixed(res.value);
            const val_payload = try msgpack.decode(self.allocator, &reader);
            try value_map.mapPut(res.path, val_payload);
        }

        try payload.mapPut("value", value_map);

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

    fn parsePathFromPayload(self: *MessageHandler, payload: msgpack.Payload) !?struct { path: []const u8, allocated: bool } {
        if (payload == .str) {
            return .{ .path = payload.str.value(), .allocated = false };
        } else if (payload == .arr) {
            var path_buf: std.ArrayList(u8) = .{};
            errdefer path_buf.deinit(self.allocator);
            for (payload.arr, 0..) |segment, i| {
                if (segment != .str) return error.InvalidPathSegment;
                if (i > 0) try path_buf.append(self.allocator, '/');
                try path_buf.appendSlice(self.allocator, segment.str.value());
            }
            return .{ .path = try path_buf.toOwnedSlice(self.allocator), .allocated = true };
        }
        return null;
    }

    /// Convert a ParsedPath back to a slash-joined string for backward compat with storage_engine.set/get.
    /// Caller owns the returned slice.
    fn parsedPathToString(self: *MessageHandler, pp: ParsedPath) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);
        switch (pp) {
            .collection => |c| {
                try buf.appendSlice(self.allocator, c.table);
            },
            .document => |d| {
                try buf.appendSlice(self.allocator, d.table);
                try buf.append(self.allocator, '/');
                try buf.appendSlice(self.allocator, d.id);
            },
            .field => |f| {
                try buf.appendSlice(self.allocator, f.table);
                try buf.append(self.allocator, '/');
                try buf.appendSlice(self.allocator, f.id);
                for (f.fields) |field| {
                    try buf.append(self.allocator, '/');
                    try buf.appendSlice(self.allocator, field);
                }
            },
        }
        return buf.toOwnedSlice(self.allocator);
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
