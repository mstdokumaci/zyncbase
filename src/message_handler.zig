const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const storage_mod = @import("storage_engine.zig");
const StorageEngine = storage_mod.StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const Connection = @import("memory_strategy.zig").Connection;
const SecurityConfig = @import("config_loader.zig").Config.SecurityConfig;

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
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    storage_engine: *StorageEngine,
    subscription_manager: *SubscriptionManager,
    security_config: SecurityConfig,
    connection_registry: ConnectionRegistry,

    /// Initialize message handler with all required components
    pub fn init(
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        violation_tracker: *ViolationTracker,
        storage_engine: *StorageEngine,
        subscription_manager: *SubscriptionManager,
        security_config: SecurityConfig,
    ) !*MessageHandler {
        const self = try allocator.create(MessageHandler);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .violation_tracker = violation_tracker,
            .storage_engine = storage_engine,
            .subscription_manager = subscription_manager,
            .security_config = security_config,
            // SAFETY: connection_registry is initialized via self.connection_registry.init below
            .connection_registry = undefined,
        };
        self.connection_registry.init(memory_strategy);

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

        // Enforce maximum connections
        const current_count = self.connection_registry.map.count();
        if (current_count >= 100_000) {
            std.log.warn("Rejecting connection {}: max connections (100000) reached", .{conn_id});
            try self.sendError(ws, "MAX_CONNECTIONS_REACHED", "Server has reached the maximum number of concurrent connections");
            ws.close();
            return;
        }

        // Acquire connection state strongly initialized from the pool
        const conn = try self.memory_strategy.createConnection(conn_id, ws.*);

        // Store in registry
        try self.connection_registry.add(conn_id, conn);

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
        const conn = self.connection_registry.acquireConnection(conn_id) catch |err| {
            std.log.warn("Connection {} not found in registry during message: {}", .{ conn_id, err });
            return;
        };
        defer conn.release(self.allocator);

        // 1. Enforce rate limiting under isolated lock
        if (self.security_config.max_messages_per_second > 0) {
            const is_rate_limited = blk: {
                conn.mutex.lock();
                defer conn.mutex.unlock();

                const now_us = std.time.microTimestamp();
                const burst_capacity: f64 = @floatFromInt(self.security_config.max_messages_per_second * 2);

                if (conn.last_request_time == null) {
                    // First request for this connection: grant full burst
                    conn.request_tokens = burst_capacity;
                    conn.last_request_time = now_us;
                } else {
                    const elapsed_us = now_us - conn.last_request_time.?;
                    // Basic token bucket / leak rate
                    const rate_limit: f64 = @floatFromInt(self.security_config.max_messages_per_second);
                    const tokens_to_add: f64 = @as(f64, @floatFromInt(@max(@as(i64, 0), elapsed_us))) * (rate_limit / 1_000_000.0);

                    conn.request_tokens = @min(burst_capacity, conn.request_tokens + tokens_to_add);
                    conn.last_request_time = now_us;
                }

                if (conn.request_tokens < 1.0) break :blk true;
                conn.request_tokens -= 1.0;
                break :blk false;
            };

            if (is_rate_limited) {
                std.log.warn("Rate limit exceeded for connection {}: tokens={d:.2} (limit={d}/s, burst={d})", .{
                    conn_id,
                    conn.request_tokens,
                    self.security_config.max_messages_per_second,
                    self.security_config.max_messages_per_second * 2,
                });
                try self.sendError(ws, "RATE_LIMITED", "Too many requests");
                return;
            }
        }

        // 2. Message processing (Independent of connection state currently)
        // Acquire dynamic parsing arena from the pool
        const arena = try self.memory_strategy.acquireArena();
        defer self.memory_strategy.releaseArena(arena);
        const arena_allocator = arena.allocator();

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
        // Note: Currently none of the handlers access Connection state under the lock.
        // If they start doing so, we should acquire the lock specifically inside those handlers.
        const response = self.routeMessage(arena_allocator, conn_id, msg_info, parsed) catch |err| {
            std.log.debug("Failed to process message from connection {}: {}", .{ conn_id, err });
            try self.sendError(ws, "INTERNAL_ERROR", "Failed to process request");
            return;
        };

        // Send response (Outside lock to avoid blocking on backpressure)
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
        self.connection_registry.remove(conn_id);
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
            self.connection_registry.remove(conn_id);
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
        arena_allocator: std.mem.Allocator,
        conn_id: u64,
        msg_info: MessageInfo,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        // Route based on message type
        if (std.mem.eql(u8, msg_info.type, "StoreSet")) {
            return try self.handleStoreSet(arena_allocator, conn_id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreGet")) {
            return try self.handleStoreGet(arena_allocator, conn_id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreRemove")) {
            return try self.handleStoreRemove(arena_allocator, msg_info.id, parsed);
        } else {
            return error.UnknownMessageType;
        }
    }

    const ResolvedField = struct {
        name: []const u8,
        allocated: bool,
    };

    /// Resolves a ParsedPath.field's segments into a single flattened column name.
    /// For single-segment paths, returns the segment directly (no allocation).
    /// For multi-segment paths, joins with "__" (caller must free).
    fn resolveFieldName(allocator: std.mem.Allocator, fields: []const []const u8) !ResolvedField {
        if (fields.len == 1) {
            return .{ .name = fields[0], .allocated = false };
        }
        return .{
            .name = try std.mem.join(allocator, "__", fields),
            .allocated = true,
        };
    }

    const StoreFields = struct {
        namespace: []const u8,
        path: ParsedPath,
        value: ?msgpack.Payload,
    };

    /// Extracts common store operation fields from a parsed MsgPack message.
    fn extractStoreFields(
        self: *MessageHandler,
        allocator: std.mem.Allocator,
        parsed: msgpack.Payload,
        require_value: bool,
    ) !StoreFields {
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
                    if (val == .str) namespace = val.str.value();
                } else if (std.mem.eql(u8, key_str, "path")) {
                    if (val == .arr) {
                        // Handle the edge case of duplicate "path" key in MsgPack to avoid leaking the first allocation.
                        if (parsed_path) |p| {
                            if (p == .field) self.allocator.free(p.field.fields);
                        }
                        parsed_path = try parsePath(allocator, val);
                    }
                } else if (std.mem.eql(u8, key_str, "value")) {
                    value = val;
                }
            }
        }

        if (namespace == null or parsed_path == null) {
            if (parsed_path) |p| {
                if (p == .field) self.allocator.free(p.field.fields);
            }
            return error.MissingRequiredFields;
        }
        if (require_value and value == null) {
            if (parsed_path.? == .field) self.allocator.free(parsed_path.?.field.fields);
            return error.MissingRequiredFields;
        }

        return .{
            .namespace = namespace.?,
            .path = parsed_path.?,
            .value = value,
        };
    }

    fn handleStoreSet(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        const fields = try self.extractStoreFields(self.allocator, parsed, true);
        defer if (fields.path == .field) self.allocator.free(fields.path.field.fields);

        const namespace = fields.namespace;
        const value = fields.value orelse return error.MissingRequiredFields;

        // Validate array fields before any write to prevent partial writes.
        switch (fields.path) {
            .document => |doc| {
                // Find the table in the schema
                var schema_table: ?@import("schema_parser.zig").Table = null;
                for (self.storage_engine.schema.tables) |t| {
                    if (std.mem.eql(u8, t.name, doc.table)) {
                        schema_table = t;
                        break;
                    }
                }
                if (schema_table) |tbl| {
                    // Only validate if value is a map (non-map values will be rejected later)
                    if (value == .map) {
                        // Iterate the value map and validate array fields
                        var val_it = value.map.iterator();
                        while (val_it.next()) |entry| {
                            if (entry.key_ptr.* != .str) continue;
                            const field_name = entry.key_ptr.*.str.value();
                            for (tbl.fields) |field| {
                                if (std.mem.eql(u8, field.name, field_name)) {
                                    if (field.sql_type == .array) {
                                        msgpack.ensureLiteralArray(entry.value_ptr.*) catch {
                                            return try buildErrorResponse(arena_allocator, msg_id, "INVALID_ARRAY_ELEMENT");
                                        };
                                    }
                                    break;
                                }
                            }
                        }
                    }
                }
            },
            .field => |f| {
                // Find the table and field in the schema
                for (self.storage_engine.schema.tables) |t| {
                    if (std.mem.eql(u8, t.name, f.table)) {
                        // Determine the effective field name (flattened if multiple)
                        const resolved = try resolveFieldName(self.allocator, f.fields);
                        defer if (resolved.allocated) self.allocator.free(resolved.name);
                        const effective_field = resolved.name;

                        for (t.fields) |fld| {
                            if (std.mem.eql(u8, fld.name, effective_field)) {
                                if (fld.sql_type == .array) {
                                    msgpack.ensureLiteralArray(value) catch {
                                        return try buildErrorResponse(arena_allocator, msg_id, "INVALID_ARRAY_ELEMENT");
                                    };
                                }
                                break;
                            }
                        }
                        break;
                    }
                }
            },
            .collection => {}, // Will be rejected below
        }

        switch (fields.path) {
            .document => |doc| {
                if (value != .map) return error.InvalidPayload;

                // Recursively flatten nested objects into field_prop columns
                var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue){};
                defer columns.deinit(self.allocator);

                try self.flattenPayloadMap(arena_allocator, "", value.map, &columns);

                self.storage_engine.insertOrReplace(doc.table, doc.id, namespace, columns.items) catch |err| return sendStorageErrorResponse(arena_allocator, msg_id, err);

                // Free the column names allocated by flattenPayloadMap
                for (columns.items) |col| {
                    arena_allocator.free(col.name);
                }
            },
            .field => |f| {
                const resolved = try resolveFieldName(self.allocator, f.fields);
                defer if (resolved.allocated) self.allocator.free(resolved.name);
                self.storage_engine.updateField(f.table, f.id, namespace, resolved.name, value) catch |err| return sendStorageErrorResponse(arena_allocator, msg_id, err);
            },
            .collection => return error.InvalidOperation, // Cannot set on a collection
        }

        // Build success response
        return try buildSuccessResponse(arena_allocator, msg_id);
    }

    fn handleStoreGet(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;

        const fields = try self.extractStoreFields(self.allocator, parsed, false);
        defer if (fields.path == .field) self.allocator.free(fields.path.field.fields);

        const namespace = fields.namespace;

        const result_payload: ?msgpack.Payload = switch (fields.path) {
            .document => |doc| blk: {
                const stored_doc = self.storage_engine.selectDocument(doc.table, doc.id, namespace) catch |err| return sendStorageErrorResponse(arena_allocator, msg_id, err);

                if (stored_doc == null) {
                    std.log.debug("handleStoreGet: selectDocument returned null for {s}:{s} in {s}", .{ doc.table, doc.id, namespace });
                    break :blk null; // Return null to indicate not found, will be handled by buildDataResponse
                }
                std.log.debug("handleStoreGet: selectDocument returned document for {s}:{s}", .{ doc.table, doc.id });
                break :blk stored_doc;
            },
            .field => |f| blk: {
                const resolved = try resolveFieldName(self.allocator, f.fields);
                defer if (resolved.allocated) self.allocator.free(resolved.name);
                break :blk self.storage_engine.selectField(f.table, f.id, namespace, resolved.name) catch |err| return sendStorageErrorResponse(arena_allocator, msg_id, err);
            },
            .collection => |c| blk: {
                // Return all documents in the collection
                break :blk self.storage_engine.selectCollection(c.table, namespace) catch |err| return sendStorageErrorResponse(arena_allocator, msg_id, err);
            },
        };
        defer if (result_payload) |p| p.free(self.allocator);

        const final_result = if (result_payload) |p| blk: {
            switch (p) {
                .map => break :blk try unflattenPayloadMap(arena_allocator, p.map),
                .arr => |arr| {
                    // Possible collection result
                    const unflattened_arr = try arena_allocator.alloc(msgpack.Payload, arr.len);
                    for (arr, 0..) |item, i| {
                        if (item == .map) {
                            unflattened_arr[i] = try unflattenPayloadMap(arena_allocator, item.map);
                        } else {
                            unflattened_arr[i] = try msgpack.clonePayload(item, arena_allocator);
                        }
                    }
                    break :blk msgpack.Payload{ .arr = unflattened_arr };
                },
                else => break :blk try msgpack.clonePayload(p, arena_allocator),
            }
        } else .nil;

        // Build response
        // If the result is null (e.g., document not found), return success with null value
        // instead of an error, per the finalized error taxonomy spec.
        return try buildDataResponse(arena_allocator, msg_id, final_result);
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        const fields = try self.extractStoreFields(self.allocator, parsed, false);
        defer if (fields.path == .field) self.allocator.free(fields.path.field.fields);

        const namespace = fields.namespace;

        switch (fields.path) {
            .document => |doc| {
                self.storage_engine.deleteDocument(doc.table, doc.id, namespace) catch |err| return sendStorageErrorResponse(arena_allocator, msg_id, err);
            },
            .field => |f| {
                const resolved = try resolveFieldName(self.allocator, f.fields);
                defer if (resolved.allocated) self.allocator.free(resolved.name);
                self.storage_engine.updateField(f.table, f.id, namespace, resolved.name, .nil) catch |err| return sendStorageErrorResponse(arena_allocator, msg_id, err);
            },
            .collection => return error.InvalidOperation, // Cannot remove a whole collection yet
        }

        return try buildSuccessResponse(arena_allocator, msg_id);
    }

    /// Send error response to client
    fn sendError(self: *MessageHandler, ws: *WebSocket, code: []const u8, message: []const u8) !void {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(self.allocator);

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("error", self.allocator));
        try payload.mapPut("code", try msgpack.Payload.strToPayload(code, self.allocator));
        try payload.mapPut("message", try msgpack.Payload.strToPayload(message, self.allocator));

        try msgpack.encode(payload, list.writer(self.allocator));
        const error_msg = try list.toOwnedSlice(self.allocator);
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
    pub const MessageInfo = struct {
        type: []const u8,
        id: u64,
    };

    /// Recursively flatten a MessagePack map into a flat list of ColumnValue pairs.
    /// Nested objects result in keys joined by '__', matching the schema parser's flattening.
    fn flattenPayloadMap(
        self: *MessageHandler,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        map: anytype,
        columns: *std.ArrayListUnmanaged(storage_mod.ColumnValue),
    ) !void {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* != .str) continue;
            const key = entry.key_ptr.*.str.value();
            const value = entry.value_ptr.*;

            // Security/Protocol: Forbid "__" in client-provided keys to avoid internal collisions.
            if (std.mem.containsAtLeast(u8, key, 1, "__")) {
                // Since this is a recursive function and we want to return a clean error to the client,
                // we'll let this propogate. MessageHandler should handle it.
                return error.InvalidFieldName;
            }

            const name = if (prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}__{s}", .{ prefix, key })
            else
                try allocator.dupe(u8, key);

            switch (value) {
                .map => |m| {
                    try self.flattenPayloadMap(allocator, name, m, columns);
                    allocator.free(name);
                },
                else => try columns.append(self.allocator, .{
                    .name = name,
                    .value = value,
                }),
            }
        }
    }
};

/// Thread-safe registry for tracking active WebSocket connections.
pub const ConnectionRegistry = struct {
    const Map = std.AutoHashMap(u64, *Connection);

    map: Map,
    mutex: std.Thread.Mutex,
    memory_strategy: *MemoryStrategy,

    pub fn init(self: *ConnectionRegistry, memory_strategy: *MemoryStrategy) void {
        self.* = ConnectionRegistry{
            .map = Map.init(memory_strategy.generalAllocator()),
            .mutex = .{},
            .memory_strategy = memory_strategy,
        };
    }

    pub fn deinit(self: *ConnectionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.valueIterator();
        while (it.next()) |conn| {
            conn.*.release(self.memory_strategy.generalAllocator());
        }
        self.map.deinit();
    }

    pub fn add(self: *ConnectionRegistry, id: u64, conn: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(id, conn);
    }

    pub fn remove(self: *ConnectionRegistry, id: u64) void {
        self.mutex.lock();
        const maybe_conn = self.map.fetchRemove(id);
        self.mutex.unlock();

        if (maybe_conn) |entry| {
            entry.value.release(self.memory_strategy.generalAllocator());
        }
    }

    pub fn acquireConnection(self: *ConnectionRegistry, id: u64) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        const conn = self.map.get(id) orelse {
            return error.ConnectionNotFound;
        };
        _ = conn.ref_count.fetchAdd(1, .monotonic);
        return conn;
    }

    pub fn clear(self: *ConnectionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.valueIterator();
        while (it.next()) |conn| {
            conn.*.release(self.memory_strategy.generalAllocator());
        }
        self.map.clearRetainingCapacity();
    }

    pub const Snapshot = struct {
        map: Map,
        memory_strategy: *MemoryStrategy,

        pub fn deinit(self: *Snapshot) void {
            var it = self.map.valueIterator();
            while (it.next()) |conn| {
                conn.*.release(self.memory_strategy.generalAllocator());
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
        while (it.next()) |conn| {
            _ = conn.*.ref_count.fetchAdd(1, .monotonic);
        }
        return Snapshot{
            .map = new_map,
            .memory_strategy = self.memory_strategy,
        };
    }
};

fn buildDataResponse(msgpack_allocator: Allocator, msg_id: u64, result_payload: msgpack.Payload) ![]const u8 {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(msgpack_allocator);

    var payload = msgpack.Payload.mapPayload(msgpack_allocator);
    defer payload.free(msgpack_allocator);

    try payload.mapPut("type", try msgpack.Payload.strToPayload("ok", msgpack_allocator));
    try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));
    try payload.mapPut("value", result_payload);

    try msgpack.encode(payload, list.writer(msgpack_allocator));
    return try list.toOwnedSlice(msgpack_allocator);
}

/// Build an error response with a code string.
fn buildErrorResponse(msgpack_allocator: Allocator, msg_id: u64, code: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(msgpack_allocator);

    var payload = msgpack.Payload.mapPayload(msgpack_allocator);
    defer payload.free(msgpack_allocator);

    try payload.mapPut("type", try msgpack.Payload.strToPayload("error", msgpack_allocator));
    try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));
    try payload.mapPut("code", try msgpack.Payload.strToPayload(code, msgpack_allocator));

    try msgpack.encode(payload, list.writer(msgpack_allocator));
    return try list.toOwnedSlice(msgpack_allocator);
}

/// Build success response for StoreSet
fn buildSuccessResponse(msgpack_allocator: Allocator, msg_id: u64) ![]const u8 {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(msgpack_allocator);

    var payload = msgpack.Payload.mapPayload(msgpack_allocator);
    defer payload.free(msgpack_allocator);

    try payload.mapPut("type", try msgpack.Payload.strToPayload("ok", msgpack_allocator));
    try payload.mapPut("id", msgpack.Payload.uintToPayload(msg_id));

    try msgpack.encode(payload, list.writer(msgpack_allocator));
    return try list.toOwnedSlice(msgpack_allocator);
}

fn sendStorageErrorResponse(msgpack_allocator: Allocator, msg_id: u64, err: anyerror) ![]const u8 {
    const code = if (err == error.UnknownTable)
        "COLLECTION_NOT_FOUND"
    else if (err == error.UnknownField)
        "FIELD_NOT_FOUND"
    else if (err == error.TypeMismatch)
        "SCHEMA_VALIDATION_FAILED"
    else if (err == error.InvalidFieldName)
        "INVALID_FIELD_NAME"
    else
        return err;

    return try buildErrorResponse(msgpack_allocator, msg_id, code);
}

fn findNestedMap(map: *msgpack.Map, name: []const u8) ?*msgpack.Map {
    var it = map.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), name)) {
            if (entry.value_ptr.* == .map) {
                return &entry.value_ptr.*.map;
            }
            return null;
        }
    }
    return null;
}

fn putRecursive(allocator: std.mem.Allocator, current_map: *msgpack.Map, full_key: []const u8, value: msgpack.Payload) !void {
    const sep_idx = std.mem.indexOf(u8, full_key, "__");
    if (sep_idx == null) {
        const k = try msgpack.Payload.strToPayload(full_key, allocator);
        try current_map.put(k, value);
        return;
    }

    const dirname = full_key[0..sep_idx.?];
    const basename = full_key[sep_idx.? + 2 ..];

    // SAFETY: next_map is initialized in either the if or else block below
    var next_map: *msgpack.Map = undefined;
    if (findNestedMap(current_map, dirname)) |m| {
        next_map = m;
    } else {
        const k = try msgpack.Payload.strToPayload(dirname, allocator);
        try current_map.put(k, .{ .map = msgpack.Map.init(allocator) });
        // Re-fetch nested map because the put operation might have caused the
        // parent map's hash table to reallocate, invalidating existing pointers to its entries.
        next_map = findNestedMap(current_map, dirname) orelse return error.InternalError;
    }

    try putRecursive(allocator, next_map, basename, value);
}

fn unflattenPayloadMap(allocator: std.mem.Allocator, flattened: msgpack.Map) !msgpack.Payload {
    var root_map = msgpack.Map.init(allocator);
    errdefer root_map.deinit();

    var it = flattened.map.iterator();
    while (it.next()) |entry| {
        // Skip NULL values from unset SQLite columns.
        if (entry.value_ptr.* == .nil) continue;

        if (entry.key_ptr.* != .str) {
            const val = try msgpack.clonePayload(entry.value_ptr.*, allocator);
            try root_map.put(entry.key_ptr.*, val);
            continue;
        }

        const full_key = entry.key_ptr.*.str.value();
        const val = try msgpack.clonePayload(entry.value_ptr.*, allocator);
        errdefer val.free(allocator);

        try putRecursive(allocator, &root_map, full_key, val);
    }

    return .{ .map = root_map };
}
