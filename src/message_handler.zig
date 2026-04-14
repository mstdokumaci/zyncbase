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
const SchemaManager = @import("schema_manager.zig").SchemaManager;
const StoreService = @import("store_service.zig").StoreService;
const protocol = @import("protocol.zig");

/// Message handler for WebSocket events
/// Manages connection lifecycle, message parsing, routing, and response handling
pub const MessageHandler = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    storage_engine: *StorageEngine,
    store_service: *StoreService,
    subscription_engine: *SubscriptionEngine,
    schema_manager: *const SchemaManager,
    security_config: SecurityConfig,

    /// Initialize message handler with all required components
    pub fn init(
        self: *MessageHandler,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        violation_tracker: *ViolationTracker,
        storage_engine: *StorageEngine,
        store_service: *StoreService,
        subscription_engine: *SubscriptionEngine,
        schema_manager: *const SchemaManager,
        security_config: SecurityConfig,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .violation_tracker = violation_tracker,
            .storage_engine = storage_engine,
            .store_service = store_service,
            .subscription_engine = subscription_engine,
            .schema_manager = schema_manager,
            .security_config = security_config,
        };
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
                try self.sendError(ws, protocol.err_code_rate_limited, protocol.err_msg_too_many_requests, null);
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

            try self.sendError(ws, protocol.err_code_invalid_message, protocol.err_msg_failed_to_parse, null);
            return;
        };

        // Extract message type and correlation ID
        const msg_info = protocol.extractAs(protocol.Envelope, arena_allocator, parsed) catch |err| {
            std.log.warn("Failed to extract message info from connection {}: {}", .{ conn_id, err });
            try self.sendError(ws, protocol.err_code_invalid_message_format, protocol.err_msg_missing_type_or_id, null);
            return;
        };

        // Route request and handle errors to produce a wire response
        const response = try self.routeRequest(arena_allocator, conn, msg_info, parsed);

        // Send response (Outside lock to avoid blocking on backpressure)
        ws.send(response, .binary);
    }

    pub fn routeRequest(
        self: *MessageHandler,
        allocator: std.mem.Allocator,
        conn: *Connection,
        msg_info: protocol.Envelope,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        return self.routeMessage(allocator, conn, msg_info, parsed) catch |err| {
            const code = protocol.mapErrorToCode(err);
            const message = protocol.mapErrorToMessage(err);
            return try protocol.buildErrorResponse(allocator, msg_info.id, code, message);
        };
    }

    pub fn teardownSession(self: *MessageHandler, conn: *Connection) void {
        conn.mutex.lock();
        defer conn.mutex.unlock();

        for (conn.subscription_ids.items) |sub_id| {
            self.subscription_engine.unsubscribe(conn.id, sub_id) catch |err| {
                std.log.debug("Failed to unsubscribe {} for connection {}: {}", .{ sub_id, conn.id, err });
            };
        }

        conn.resetSession();
    }

    pub fn routeMessage(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_info: protocol.Envelope,
        parsed: msgpack.Payload,
    ) ![]const u8 {
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

    pub fn sendError(self: *MessageHandler, ws: *WebSocket, code: []const u8, message: []const u8, msg_id: ?u64) !void {
        var list = std.ArrayListUnmanaged(u8).empty;
        defer list.deinit(self.allocator);
        const writer = list.writer(self.allocator);

        try writer.writeByte(if (msg_id != null) 0x84 else 0x83);
        try list.appendSlice(self.allocator, &protocol.error_type_header);
        try list.appendSlice(self.allocator, code);

        try list.appendSlice(self.allocator, protocol.message_key);
        try list.appendSlice(self.allocator, message);

        if (msg_id) |id| {
            try list.appendSlice(self.allocator, protocol.id_key);
            try writer.writeByte(0xcf);
            try writer.writeInt(u64, id, .big);
        }

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

    fn handleStoreSet(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn_id: u64,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        _ = conn_id;
        const req = try protocol.extractAs(protocol.StorePathRequest, arena_allocator, parsed);
        if (req.path.len < 2) return error.InvalidPath;
        const value = req.value orelse return error.MissingRequiredFields;

        try self.store_service.set(
            req.path[0],
            req.path[1],
            req.namespace,
            req.path.len,
            if (req.path.len == 3) req.path[2] else null,
            value,
        );

        return try protocol.buildSuccessResponse(arena_allocator, msg_id);
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        const req = try protocol.extractAs(protocol.StorePathRequest, arena_allocator, parsed);
        if (req.path.len < 2) return error.InvalidPath;

        try self.store_service.remove(
            req.path[0],
            req.path[1],
            req.namespace,
            req.path.len,
            if (req.path.len == 3) req.path[2] else null,
        );

        return try protocol.buildSuccessResponse(arena_allocator, msg_id);
    }

    fn handleStoreSubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        const req = try protocol.extractAs(protocol.StoreCollectionRequest, arena_allocator, payload);
        const sub_id = try generateSubscriptionId(conn);

        var qr = try self.store_service.query(arena_allocator, req.collection, req.namespace, payload);
        defer qr.deinit(arena_allocator);

        _ = try self.subscription_engine.subscribe(req.namespace, req.collection, qr.filter, conn.id, sub_id);
        try conn.addSubscription(sub_id);

        return try protocol.buildQueryResponse(arena_allocator, msg_id, sub_id, &qr.results);
    }

    fn handleStoreUnsubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        const req = try protocol.extractAs(protocol.StoreUnsubscribeRequest, arena_allocator, payload);

        try self.subscription_engine.unsubscribe(conn.id, req.subId);
        conn.removeSubscription(req.subId);

        return try protocol.buildSuccessResponse(arena_allocator, msg_id);
    }

    fn handleStoreQuery(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        _ = conn;
        const req = try protocol.extractAs(protocol.StoreCollectionRequest, arena_allocator, payload);

        var qr = try self.store_service.query(arena_allocator, req.collection, req.namespace, payload);
        defer qr.deinit(arena_allocator);

        return try protocol.buildQueryResponse(arena_allocator, msg_id, null, &qr.results);
    }

    fn handleStoreLoadMore(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        const req = try protocol.extractAs(protocol.StoreLoadMoreRequest, arena_allocator, payload);

        const sub_key = subscription_mod.SubscriptionGroup.SubscriberKey{
            .connection_id = conn.id,
            .id = req.subId,
        };

        var sub_query = (try self.subscription_engine.getSubscriptionQuery(arena_allocator, sub_key)) orelse return error.SubscriptionNotFound;
        defer sub_query.deinit(arena_allocator);

        var results = try self.store_service.queryWithCursor(arena_allocator, sub_query.collection, sub_query.namespace, &sub_query.filter, req.nextCursor);
        defer results.deinit();

        return try protocol.buildQueryResponse(arena_allocator, msg_id, req.subId, &results);
    }

    fn generateSubscriptionId(conn: *Connection) !u64 {
        return conn.allocateSubscriptionId();
    }
};
