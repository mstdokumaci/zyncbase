const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const subscription_mod = @import("subscription_engine.zig");
const SubscriptionEngine = subscription_mod.SubscriptionEngine;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const SecurityConfig = @import("config_loader.zig").Config.SecurityConfig;
const StoreService = @import("store_service.zig").StoreService;
const wire = @import("wire.zig");

/// Message handler for WebSocket events
/// Manages connection lifecycle, message parsing, routing, and response handling
pub const MessageHandler = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    store_service: *StoreService,
    subscription_engine: *SubscriptionEngine,
    security_config: SecurityConfig,

    /// Initialize message handler with all required components
    pub fn init(
        self: *MessageHandler,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        violation_tracker: *ViolationTracker,
        store_service: *StoreService,
        subscription_engine: *SubscriptionEngine,
        security_config: SecurityConfig,
    ) void {
        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .violation_tracker = violation_tracker,
            .store_service = store_service,
            .subscription_engine = subscription_engine,
            .security_config = security_config,
        };
    }

    /// Clean up message handler resources
    pub fn deinit(_: *MessageHandler) void {}

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
                try self.sendError(ws, null, wire.getWireError(error.RateLimited));
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

            const wire_err = wire.getWireError(err);
            try self.sendError(ws, null, wire_err);
            return;
        };

        // Extract message type and correlation ID
        const msg_info = wire.extractAs(wire.Envelope, arena_allocator, parsed) catch |err| {
            std.log.warn("Failed to extract message info from connection {}: {}", .{ conn_id, err });
            const wire_err2 = wire.getWireError(err);
            try self.sendError(ws, null, wire_err2);
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
        msg_info: wire.Envelope,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        return self.routeMessage(allocator, conn, msg_info, parsed) catch |err| {
            return try wire.encodeError(allocator, msg_info.id, wire.getWireError(err));
        };
    }

    pub fn teardownSession(self: *MessageHandler, conn: *Connection) void {
        conn.mutex.lock();
        defer conn.mutex.unlock();

        for (conn.subscription_ids.items) |sub_id| {
            self.subscription_engine.unsubscribe(conn.id, sub_id);
        }

        conn.resetSessionLocked();
    }

    pub fn routeMessage(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_info: wire.Envelope,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        if (std.mem.eql(u8, msg_info.type, "StoreSetNamespace")) {
            return try self.handleStoreSetNamespace(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreSet")) {
            return try self.handleStoreSet(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreSubscribe")) {
            return try self.handleStoreSubscribe(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreUnsubscribe")) {
            return try self.handleStoreUnsubscribe(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreQuery")) {
            return try self.handleStoreQuery(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreLoadMore")) {
            return try self.handleStoreLoadMore(arena_allocator, conn, msg_info.id, parsed);
        } else if (std.mem.eql(u8, msg_info.type, "StoreRemove")) {
            return try self.handleStoreRemove(arena_allocator, conn, msg_info.id, parsed);
        } else {
            return error.UnknownMessageType;
        }
    }

    pub fn sendError(self: *MessageHandler, ws: *WebSocket, msg_id: ?u64, wire_err: wire.WireError) !void {
        const error_msg = try wire.encodeError(self.allocator, msg_id, wire_err);
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

    fn requireStoreSession(conn: *Connection) !Connection.StoreSession {
        const session = conn.getStoreSession();
        if (session.namespace_id == connection_mod.unset_namespace_id) return error.NamespaceUnauthorized;
        return session;
    }

    fn requireStoreNamespace(conn: *Connection) !i64 {
        return (try requireStoreSession(conn)).namespace_id;
    }

    fn clearStoreSubscriptions(self: *MessageHandler, conn: *Connection) void {
        conn.mutex.lock();
        defer conn.mutex.unlock();

        for (conn.subscription_ids.items) |sub_id| {
            self.subscription_engine.unsubscribe(conn.id, sub_id);
        }
        conn.subscription_ids.clearRetainingCapacity();
    }

    fn handleStoreSetNamespace(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        const req = try wire.extractAs(wire.StoreSetNamespaceRequest, arena_allocator, parsed);

        const namespace_id = try self.store_service.resolveNamespace(req.namespace);

        self.clearStoreSubscriptions(conn);
        conn.setNamespaceId(namespace_id);

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreSet(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        const req = try wire.extractAs(wire.StorePathRequest, arena_allocator, parsed);
        const value = req.value orelse return error.MissingRequiredFields;
        const session = try requireStoreSession(conn);

        try self.store_service.setPath(
            .{
                .namespace_id = session.namespace_id,
                .owner_doc_id = session.user_doc_id,
            },
            req.path,
            value,
        );

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        parsed: msgpack.Payload,
    ) ![]const u8 {
        const req = try wire.extractAs(wire.StorePathRequest, arena_allocator, parsed);
        const namespace_id = try requireStoreNamespace(conn);

        try self.store_service.removePath(namespace_id, req.path);

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreSubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        const req = try wire.extractAs(wire.StoreCollectionRequest, arena_allocator, payload);
        const sub_id = generateSubscriptionId(conn) catch return error.SubscriptionIdGenerationFailed;
        const namespace_id = try requireStoreNamespace(conn);

        var qr = try self.store_service.queryCollection(arena_allocator, namespace_id, req.table_index, payload);
        defer qr.deinit(arena_allocator);

        _ = try self.subscription_engine.subscribe(namespace_id, qr.table_index, qr.filter, conn.id, sub_id);
        try conn.addSubscription(sub_id);

        return try wire.encodeQuery(arena_allocator, .{
            .msg_id = msg_id,
            .sub_id = sub_id,
            .results = &qr.results,
            .table = qr.table,
        });
    }

    fn handleStoreUnsubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        const req = try wire.extractAs(wire.StoreUnsubscribeRequest, arena_allocator, payload);

        self.subscription_engine.unsubscribe(conn.id, req.subId);
        conn.removeSubscription(req.subId);

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreQuery(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        const req = try wire.extractAs(wire.StoreCollectionRequest, arena_allocator, payload);
        const namespace_id = try requireStoreNamespace(conn);

        var qr = try self.store_service.queryCollection(arena_allocator, namespace_id, req.table_index, payload);
        defer qr.deinit(arena_allocator);

        return try wire.encodeQuery(arena_allocator, .{
            .msg_id = msg_id,
            .results = &qr.results,
            .table = qr.table,
        });
    }

    fn handleStoreLoadMore(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        payload: msgpack.Payload,
    ) ![]const u8 {
        const req = try wire.extractAs(wire.StoreLoadMoreRequest, arena_allocator, payload);

        const sub_key = subscription_mod.SubscriptionGroup.SubscriberKey{
            .connection_id = conn.id,
            .id = req.subId,
        };

        var sub_query = (try self.subscription_engine.getSubscriptionQuery(arena_allocator, sub_key)) orelse return error.SubscriptionNotFound;
        defer sub_query.deinit(arena_allocator);

        var page = try self.store_service.queryMore(arena_allocator, sub_query.table_index, sub_query.namespace_id, &sub_query.filter, req.nextCursor);
        defer page.deinit();

        return try wire.encodeQuery(arena_allocator, .{
            .msg_id = msg_id,
            .sub_id = req.subId,
            .results = &page.results,
            .table = page.table,
        });
    }

    fn generateSubscriptionId(conn: *Connection) !u64 {
        return conn.allocateSubscriptionId();
    }
};
