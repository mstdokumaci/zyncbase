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

        // 2. Extract envelope from raw bytes (zero-alloc)
        const envelope = wire.extractEnvelopeFast(message) catch |err| {
            std.log.warn("Failed to extract envelope from connection {}: {}", .{ conn_id, err });
            if (isSecurityError(err)) {
                if (try self.violation_tracker.recordViolation(conn_id)) {
                    std.log.warn("Closing connection {} due to repeated security violations", .{conn_id});
                    ws.close();
                    return;
                }
            }
            try self.sendError(ws, null, wire.getWireError(err));
            return;
        };

        // 3. Acquire arena for response encoding
        const arena = try self.memory_strategy.acquireArena();
        defer self.memory_strategy.releaseArena(arena);
        const arena_allocator = arena.allocator();

        // 4. Route and handle errors
        const response = self.routeMessageFast(arena_allocator, conn, envelope, message) catch |err| {
            if (isSecurityError(err)) {
                if (try self.violation_tracker.recordViolation(conn_id)) {
                    std.log.warn("Closing connection {} due to repeated security violations", .{conn_id});
                    ws.close();
                    return;
                }
            }
            const response_err = try wire.encodeError(arena_allocator, envelope.id, wire.getWireError(err));
            ws.send(response_err, .binary);
            return;
        };

        // 5. Send response
        ws.send(response, .binary);
    }

    pub fn routeMessageFast(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        envelope: wire.Envelope,
        message: []const u8,
    ) ![]const u8 {
        const msg_type = classifyMsgType(envelope.type) orelse return error.UnknownMessageType;
        return switch (msg_type) {
            .store_set_namespace => try self.handleStoreSetNamespace(arena_allocator, conn, envelope.id, message),
            .store_set => try self.handleStoreSet(arena_allocator, conn, envelope.id, message),
            .store_subscribe => try self.handleStoreSubscribe(arena_allocator, conn, envelope.id, message),
            .store_unsubscribe => try self.handleStoreUnsubscribe(arena_allocator, conn, envelope.id, message),
            .store_query => try self.handleStoreQuery(arena_allocator, conn, envelope.id, message),
            .store_load_more => try self.handleStoreLoadMore(arena_allocator, conn, envelope.id, message),
            .store_remove => try self.handleStoreRemove(arena_allocator, conn, envelope.id, message),
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

    pub fn sendError(self: *MessageHandler, ws: *WebSocket, msg_id: ?u64, wire_err: wire.WireError) !void {
        const error_msg = try wire.encodeError(self.allocator, msg_id, wire_err);
        defer self.allocator.free(error_msg);
        ws.send(error_msg, .binary);
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

    // ---- Group A: Scalar-only fast decoders (no Payload tree) ----

    fn handleStoreSetNamespace(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const req = try wire.extractStoreSetNamespaceFast(message);

        const namespace_id = try self.store_service.resolveNamespace(req.namespace);

        self.clearStoreSubscriptions(conn);
        conn.setNamespaceId(namespace_id);

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreUnsubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const req = try wire.extractStoreUnsubscribeFast(message);

        self.subscription_engine.unsubscribe(conn.id, req.subId);
        conn.removeSubscription(req.subId);

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreLoadMore(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const req = try wire.extractStoreLoadMoreFast(message);

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

    // ---- Group B: Payload-dependent handlers (keep Payload tree) ----

    fn handleStoreSet(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const payloads = try wire.extractStorePathPayloads(message, arena_allocator);
        const value = payloads.value orelse return error.MissingRequiredFields;
        const session = try requireStoreSession(conn);

        try self.store_service.setPath(
            .{
                .namespace_id = session.namespace_id,
                .owner_doc_id = session.user_doc_id,
            },
            payloads.path,
            value,
        );

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const payloads = try wire.extractStorePathPayloads(message, arena_allocator);
        const namespace_id = try requireStoreNamespace(conn);

        try self.store_service.removePath(namespace_id, payloads.path);

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreSubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const table_index = try wire.extractStoreTableIndexFast(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = msgpack.decode(arena_allocator, &reader) catch |err| {
            std.log.warn("Failed to parse StoreSubscribe message: {}", .{err});
            return err;
        };

        const sub_id = generateSubscriptionId(conn) catch return error.SubscriptionIdGenerationFailed;
        const namespace_id = try requireStoreNamespace(conn);

        var qr = try self.store_service.queryCollection(arena_allocator, namespace_id, msgpack.Payload.uintToPayload(table_index), parsed);
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

    fn handleStoreQuery(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const table_index = try wire.extractStoreTableIndexFast(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = msgpack.decode(arena_allocator, &reader) catch |err| {
            std.log.warn("Failed to parse StoreQuery message: {}", .{err});
            return err;
        };

        const namespace_id = try requireStoreNamespace(conn);

        var qr = try self.store_service.queryCollection(arena_allocator, namespace_id, msgpack.Payload.uintToPayload(table_index), parsed);
        defer qr.deinit(arena_allocator);

        return try wire.encodeQuery(arena_allocator, .{
            .msg_id = msg_id,
            .results = &qr.results,
            .table = qr.table,
        });
    }

    fn generateSubscriptionId(conn: *Connection) !u64 {
        return conn.allocateSubscriptionId();
    }
};

const MsgType = enum {
    store_set_namespace,
    store_set,
    store_subscribe,
    store_unsubscribe,
    store_query,
    store_load_more,
    store_remove,
};

fn classifyMsgType(t: []const u8) ?MsgType {
    if (t.len < 8) return null;
    return switch (t[5]) {
        'S' => {
            if (std.mem.eql(u8, t, "StoreSetNamespace")) return .store_set_namespace;
            if (std.mem.eql(u8, t, "StoreSubscribe")) return .store_subscribe;
            if (std.mem.eql(u8, t, "StoreSet")) return .store_set;
            return null;
        },
        'R' => if (std.mem.eql(u8, t, "StoreRemove")) return .store_remove else null,
        'Q' => if (std.mem.eql(u8, t, "StoreQuery")) return .store_query else null,
        'U' => if (std.mem.eql(u8, t, "StoreUnsubscribe")) return .store_unsubscribe else null,
        'L' => if (std.mem.eql(u8, t, "StoreLoadMore")) return .store_load_more else null,
        else => null,
    };
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
