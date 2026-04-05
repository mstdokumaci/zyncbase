const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const storage_mod = @import("storage_engine.zig");
const StorageEngine = storage_mod.StorageEngine;
const subscription_mod = @import("subscription_engine.zig");
const SubscriptionEngine = subscription_mod.SubscriptionEngine;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const Connection = @import("connection.zig").Connection;
const SecurityConfig = @import("config_loader.zig").Config.SecurityConfig;
const query_parser = @import("query_parser.zig");
const SchemaManager = @import("schema_manager.zig").SchemaManager;

/// Message handler for WebSocket events
/// Manages connection lifecycle, message parsing, routing, and response handling
pub const MessageHandler = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    storage_engine: *StorageEngine,
    subscription_engine: *SubscriptionEngine,
    schema_manager: *const SchemaManager,
    connection_manager: ?*anyopaque = null, // Type-erased back-reference to ConnectionManager
    security_config: SecurityConfig,

    /// Initialize message handler with all required components
    pub fn init(
        self: *MessageHandler,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        violation_tracker: *ViolationTracker,
        storage_engine: *StorageEngine,
        subscription_engine: *SubscriptionEngine,
        schema_manager: *const SchemaManager,
        security_config: SecurityConfig,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .violation_tracker = violation_tracker,
            .storage_engine = storage_engine,
            .subscription_engine = subscription_engine,
            .schema_manager = schema_manager,
            .security_config = security_config,
            .connection_manager = null,
        };
    }

    pub fn setConnectionManager(self: *MessageHandler, manager: *anyopaque) void {
        self.connection_manager = manager;
    }

    /// Clean up message handler resources
    pub fn deinit(self: *MessageHandler) void {
        _ = self;
    }

    /// Handle WebSocket message event
    /// Parses MessagePack, extracts message info, routes to handler, and sends response
    pub fn handleMessage(
        self: *MessageHandler,
        conn: *Connection,
        message: []const u8,
    ) !void {
        const ws = &conn.ws;
        const conn_id = conn.id;

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
                try self.sendError(ws, "RATE_LIMITED", "Too many requests", null);
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

            try self.sendError(ws, "INVALID_MESSAGE", "Failed to parse MessagePack", null);
            return;
        };

        // Extract message type and correlation ID
        const msg_info = self.extractMessageInfo(parsed) catch |err| {
            std.log.warn("Failed to extract message info from connection {}: {}", .{ conn_id, err });
            try self.sendError(ws, "INVALID_MESSAGE_FORMAT", "Missing required fields: type or id", null);
            return;
        };

        // Route to appropriate handler
        // Note: Currently none of the handlers access Connection state under the lock.
        // If they start doing so, we should acquire the lock specifically inside those handlers.
        const response = self.routeMessage(arena_allocator, conn, msg_info, parsed) catch |err| {
            std.log.debug("Failed to process message from connection {}: {}", .{ conn_id, err });
            const code = mapErrorToCode(err);
            try self.sendError(ws, code, "Request failed", msg_info.id);
            return;
        };

        // Send response (Outside lock to avoid blocking on backpressure)
        ws.send(response, .binary);
    }

    /// Perform logical teardown of a session (unsubscriptions) and free related memory.
    pub fn teardownSession(self: *MessageHandler, conn: *Connection) void {
        conn.mutex.lock();
        defer conn.mutex.unlock();

        // 1. Unsubscribe from all topics using the connection's current list
        for (conn.subscription_ids.items) |sub_id| {
            self.subscription_engine.unsubscribe(conn.id, sub_id) catch |err| {
                std.log.debug("Failed to unsubscribe {} for connection {}: {}", .{ sub_id, conn.id, err });
            };
        }

        // 2. Clear session-specific memory (user_id, namespace, and list pointers)
        conn.resetSession();
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
        conn: *Connection,
        msg_info: MessageInfo,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        // Route based on message type
        if (std.mem.eql(u8, msg_info.type, "StoreSet")) {
            return try self.handleStoreSet(arena_allocator, conn.id, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreSubscribe")) {
            return try self.handleStoreSubscribe(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreUnsubscribe")) {
            return try self.handleStoreUnsubscribe(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreQuery")) {
            return try self.handleStoreQuery(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreLoadMore")) {
            return try self.handleStoreLoadMore(arena_allocator, conn, msg_info.id, parsed);
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
        segments: []const []const u8,
        value: ?msgpack.Payload,
    };

    /// Extracts common store operation fields from a parsed MsgPack message.
    fn extractStoreFields(
        self: *MessageHandler,
        allocator: std.mem.Allocator,
        parsed: msgpack.Payload,
        require_value: bool,
    ) !StoreFields {
        _ = self;
        var namespace: ?[]const u8 = null;
        var segments: ?[]const []const u8 = null;
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
                        if (segments) |s| {
                            allocator.free(s);
                            segments = null;
                        }
                        const elems = val.arr;
                        if (elems.len < 2) return error.InvalidPath;
                        const s = try allocator.alloc([]const u8, elems.len);
                        for (elems, 0..) |elem, i| {
                            if (elem != .str) {
                                allocator.free(s);
                                return error.InvalidPath;
                            }
                            s[i] = elem.str.value();
                        }
                        segments = s;
                    }
                } else if (std.mem.eql(u8, key_str, "value")) {
                    value = val;
                }
            }
        }

        if (namespace == null or segments == null) {
            if (segments) |s| allocator.free(s);
            return error.MissingRequiredFields;
        }
        if (require_value and value == null) {
            allocator.free(segments.?);
            return error.MissingRequiredFields;
        }

        return .{
            .namespace = namespace.?,
            .segments = segments.?,
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
        defer self.allocator.free(fields.segments);

        const namespace = fields.namespace;
        const value = fields.value orelse return error.MissingRequiredFields;
        const segments = fields.segments;
        const table = segments[0];
        const doc_id = segments[1];

        // Determine table metadata for validation
        const tbl_md = self.schema_manager.getTable(table) orelse {
            return try buildErrorResponse(arena_allocator, msg_id, "COLLECTION_NOT_FOUND");
        };

        const is_full_doc = (segments.len == 2);
        if (is_full_doc) {
            if (value != .map) return error.InvalidPayload;

            var it = value.map.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* != .str) continue;
                const field_name = entry.key_ptr.*.str.value();

                // Validate field exists and check type-specific constraints (like arrays)
                if (tbl_md.getField(field_name)) |field| {
                    if (field.sql_type == .array) {
                        msgpack.ensureLiteralArray(entry.value_ptr.*) catch {
                            return try buildErrorResponse(arena_allocator, msg_id, "INVALID_ARRAY_ELEMENT");
                        };
                    }
                } else {
                    // Reject unknown fields to prevent pollution, except for built-ins
                    if (!std.mem.eql(u8, field_name, "id") and
                        !std.mem.eql(u8, field_name, "namespace_id") and
                        !std.mem.eql(u8, field_name, "created_at") and
                        !std.mem.eql(u8, field_name, "updated_at"))
                    {
                        return try buildErrorResponse(arena_allocator, msg_id, "FIELD_NOT_FOUND");
                    }
                }
            }

            var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue){};
            defer columns.deinit(self.allocator);

            var it2 = value.map.iterator();
            while (it2.next()) |entry| {
                if (entry.key_ptr.* != .str) continue;
                try columns.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, entry.key_ptr.*.str.value()),
                    .value = entry.value_ptr.*,
                });
            }

            const capture = self.subscription_engine.hasSubscriptions(namespace, table);
            try self.storage_engine.insertOrReplace(table, doc_id, namespace, columns.items, capture);

            for (columns.items) |col| {
                self.allocator.free(col.name);
            }
        } else {
            // Partial update / deep path
            const resolved = try resolveFieldName(self.allocator, segments[2..]);
            defer if (resolved.allocated) self.allocator.free(resolved.name);
            const effective_field = resolved.name;

            // Validate against schema
            if (tbl_md.getField(effective_field)) |fld| {
                if (fld.sql_type == .array) {
                    msgpack.ensureLiteralArray(value) catch {
                        return try buildErrorResponse(arena_allocator, msg_id, "INVALID_ARRAY_ELEMENT");
                    };
                }
            } else {
                return try buildErrorResponse(arena_allocator, msg_id, "FIELD_NOT_FOUND");
            }

            const col = [_]storage_mod.ColumnValue{.{ .name = effective_field, .value = value }};
            const capture = self.subscription_engine.hasSubscriptions(namespace, table);
            try self.storage_engine.insertOrReplace(table, doc_id, namespace, &col, capture);
        }

        return try buildSuccessResponse(arena_allocator, msg_id);
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        const fields = try self.extractStoreFields(self.allocator, parsed, false);
        defer self.allocator.free(fields.segments);

        const namespace = fields.namespace;
        const segments = fields.segments;
        const table = segments[0];
        const doc_id = segments[1];

        if (segments.len == 2) {
            const capture = self.subscription_engine.hasSubscriptions(namespace, table);
            try self.storage_engine.deleteDocument(table, doc_id, namespace, capture);
        } else {
            const resolved = try resolveFieldName(self.allocator, segments[2..]);
            defer if (resolved.allocated) self.allocator.free(resolved.name);
            const capture = self.subscription_engine.hasSubscriptions(namespace, table);
            try self.storage_engine.updateField(table, doc_id, namespace, resolved.name, .nil, capture);
        }

        return try buildSuccessResponse(arena_allocator, msg_id);
    }

    /// Send error response to client
    pub fn sendError(self: *MessageHandler, ws: *WebSocket, code: []const u8, message: []const u8, msg_id: ?u64) !void {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(self.allocator);

        var payload = msgpack.Payload.mapPayload(self.allocator);
        defer payload.free(self.allocator);

        try payload.mapPut("type", try msgpack.Payload.strToPayload("error", self.allocator));
        try payload.mapPut("code", try msgpack.Payload.strToPayload(code, self.allocator));
        try payload.mapPut("message", try msgpack.Payload.strToPayload(message, self.allocator));
        if (msg_id) |id| {
            try payload.mapPut("id", msgpack.Payload.uintToPayload(id));
        }

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

    fn mapErrorToCode(err: anyerror) []const u8 {
        return switch (err) {
            error.UnknownTable => "COLLECTION_NOT_FOUND",
            error.UnknownField => "FIELD_NOT_FOUND",
            error.TypeMismatch, error.ConstraintViolation => "SCHEMA_VALIDATION_FAILED",
            error.InvalidFieldName => "INVALID_FIELD_NAME",
            error.InvalidMessageFormat, error.InvalidPayload, error.InvalidConditionFormat, error.InvalidOperatorCode, error.InvalidSortFormat, error.InvalidSubscriptionId => "INVALID_MESSAGE",
            error.MissingRequiredFields, error.MissingSubscriptionId => "INVALID_MESSAGE_FORMAT",
            error.SubscriptionNotFound => "SUBSCRIPTION_NOT_FOUND",
            error.AuthFailed => "AUTH_FAILED",
            error.TokenExpired => "TOKEN_EXPIRED",
            error.PermissionDenied => "PERMISSION_DENIED",
            error.NamespaceUnauthorized => "NAMESPACE_UNAUTHORIZED",
            error.MaxDepthExceeded => "MESSAGE_TOO_LARGE",
            error.RateLimited => "RATE_LIMITED",
            error.HookServerUnavailable => "HOOK_SERVER_UNAVAILABLE",
            error.HookDenied => "HOOK_DENIED",
            else => "INTERNAL_ERROR",
        };
    }

    fn getPayloadFromMap(self: *MessageHandler, map: msgpack.Map, key: []const u8) ?msgpack.Payload {
        _ = self;
        var it = map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), key)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    fn getStringFromMap(self: *MessageHandler, map: msgpack.Map, key: []const u8) ?[]const u8 {
        const val = self.getPayloadFromMap(map, key) orelse return null;
        if (val == .str) return val.str.value();
        return null;
    }

    fn encodeCursor(allocator: Allocator, cursor: msgpack.Payload) ![]const u8 {
        const json_cursor = try msgpack.payloadToJson(cursor, allocator);
        defer allocator.free(json_cursor);

        const encoded_len = std.base64.standard.Encoder.calcSize(json_cursor.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        _ = std.base64.standard.Encoder.encode(encoded, json_cursor);
        return encoded;
    }

    fn cursorFromTuplePayload(allocator: Allocator, tuple: msgpack.Payload) !query_parser.Cursor {
        if (tuple != .arr or tuple.arr.len != 2) return error.InvalidMessageFormat;
        if (tuple.arr[1] != .str) return error.InvalidMessageFormat;

        const sort_value = try tuple.arr[0].deepClone(allocator);
        errdefer sort_value.free(allocator);

        return query_parser.Cursor{
            .sort_value = sort_value,
            .id = try allocator.dupe(u8, tuple.arr[1].str.value()),
        };
    }

    fn generateSubscriptionId(conn: *Connection) !u64 {
        return conn.allocateSubscriptionId();
    }

    fn handleStoreSubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        if (payload != .map) return error.InvalidPayload;
        const namespace = self.getStringFromMap(payload.map, "namespace") orelse return error.MissingNamespace;
        const collection = self.getStringFromMap(payload.map, "collection") orelse return error.MissingCollection;
        const sub_id = try generateSubscriptionId(conn);

        const filter = try query_parser.parseQueryFilter(arena_allocator, self.schema_manager, collection, payload);
        defer filter.deinit(arena_allocator);

        _ = try self.subscription_engine.subscribe(namespace, collection, filter, conn.id, sub_id);
        try conn.addSubscription(sub_id);

        // Snapshot
        var results = try self.storage_engine.selectQuery(arena_allocator, collection, namespace, filter);
        defer results.deinit();

        const sub_key = subscription_mod.SubscriptionGroup.SubscriberKey{
            .connection_id = conn.id,
            .id = sub_id,
        };

        return self.buildQueryResponse(arena_allocator, msg_id, sub_id, &results, sub_key);
    }

    fn handleStoreUnsubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        if (payload != .map) return error.InvalidPayload;
        const sub_id = try self.extractSubId(payload.map);

        try self.subscription_engine.unsubscribe(conn.id, sub_id);

        // Remove from connection tracking
        conn.removeSubscription(sub_id);

        return try buildSuccessResponse(arena_allocator, msg_id);
    }

    fn handleStoreQuery(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        _ = conn;
        if (payload != .map) return error.InvalidPayload;
        const namespace = self.getStringFromMap(payload.map, "namespace") orelse return error.MissingNamespace;
        const collection = self.getStringFromMap(payload.map, "collection") orelse return error.MissingCollection;

        const filter = try query_parser.parseQueryFilter(arena_allocator, self.schema_manager, collection, payload);
        defer filter.deinit(arena_allocator);

        var results = try self.storage_engine.selectQuery(arena_allocator, collection, namespace, filter);
        defer results.deinit();

        return self.buildQueryResponse(arena_allocator, msg_id, null, &results, null);
    }

    fn handleStoreLoadMore(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        if (payload != .map) return error.InvalidPayload;

        const sub_id = try self.extractSubId(payload.map);
        const next_cursor_token = self.getStringFromMap(payload.map, "nextCursor") orelse return error.MissingRequiredFields;

        const requested_cursor = try query_parser.parseCursorToken(arena_allocator, next_cursor_token);
        defer requested_cursor.deinit(arena_allocator);

        const sub_key = subscription_mod.SubscriptionGroup.SubscriberKey{
            .connection_id = conn.id,
            .id = sub_id,
        };

        try self.subscription_engine.setSubscriberCursor(sub_key, requested_cursor);

        var sub_query = (try self.subscription_engine.getSubscriptionQuery(arena_allocator, sub_key)) orelse return error.SubscriptionNotFound;
        defer sub_query.deinit(arena_allocator);

        var results = try self.storage_engine.selectQuery(arena_allocator, sub_query.collection, sub_query.namespace, sub_query.filter);
        defer results.deinit();

        return self.buildQueryResponse(arena_allocator, msg_id, sub_id, &results, sub_key);
    }

    fn buildQueryResponse(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        msg_id: u64,
        sub_id: ?u64,
        results: *storage_mod.ManagedPayload,
        sub_key: ?subscription_mod.SubscriptionGroup.SubscriberKey,
    ) ![]const u8 {
        var response = msgpack.Payload.mapPayload(arena_allocator);
        defer response.free(arena_allocator);

        try response.mapPut("type", try msgpack.Payload.strToPayload("ok", arena_allocator));
        try response.mapPut("id", msgpack.Payload.uintToPayload(msg_id));

        if (sub_id) |sid| {
            try response.mapPut("subId", msgpack.Payload.uintToPayload(sid));
        }

        if (results.value) |val| {
            try response.mapPut("value", val);
            results.value = null; // Transfer ownership to response
        } else {
            try response.mapPut("value", msgpack.Payload{ .arr = &[_]msgpack.Payload{} });
        }

        const has_more = results.next_cursor_arr != null;
        if (sub_id != null) {
            try response.mapPut("hasMore", msgpack.Payload{ .bool = has_more });
        }

        if (results.next_cursor_arr) |cursor_tuple| {
            const encoded_cursor = try encodeCursor(arena_allocator, cursor_tuple);
            defer arena_allocator.free(encoded_cursor);
            try response.mapPut("nextCursor", try msgpack.Payload.strToPayload(encoded_cursor, arena_allocator));

            if (sub_key) |key| {
                const next_cursor = try cursorFromTuplePayload(arena_allocator, cursor_tuple);
                defer next_cursor.deinit(arena_allocator);
                try self.subscription_engine.setSubscriberCursor(key, next_cursor);
            }
        } else {
            try response.mapPut("nextCursor", .nil);
            if (sub_key) |key| {
                try self.subscription_engine.setSubscriberCursor(key, null);
            }
        }

        return try msgpack.encodePayload(arena_allocator, response);
    }

    fn extractSubId(self: *MessageHandler, map: msgpack.Map) !u64 {
        const sub_id_val = self.getPayloadFromMap(map, "subId") orelse return error.MissingSubscriptionId;
        return if (sub_id_val == .uint)
            sub_id_val.uint
        else if (sub_id_val == .int and sub_id_val.int >= 0)
            @intCast(sub_id_val.int)
        else
            error.InvalidSubscriptionId;
    }
};
