const std = @import("std");
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
const authorization = @import("authorization.zig");
const schema = @import("schema.zig");
const query_ast = @import("query_ast.zig");

/// Message handler for WebSocket events
/// Manages connection lifecycle, message parsing, routing, and response handling
pub const MessageHandler = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    store_service: *StoreService,
    subscription_engine: *SubscriptionEngine,
    security_config: SecurityConfig,
    auth_config: *const authorization.AuthConfig,
    schema_manager: *const schema.Schema,

    /// Initialize message handler with all required components
    pub fn init(
        self: *MessageHandler,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        violation_tracker: *ViolationTracker,
        store_service: *StoreService,
        subscription_engine: *SubscriptionEngine,
        security_config: SecurityConfig,
        auth_config: *const authorization.AuthConfig,
        schema_manager: *const schema.Schema,
    ) void {
        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .violation_tracker = violation_tracker,
            .store_service = store_service,
            .subscription_engine = subscription_engine,
            .security_config = security_config,
            .auth_config = auth_config,
            .schema_manager = schema_manager,
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
                try self.sendError(conn, null, wire.getWireError(error.RateLimited));
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
            try self.sendError(conn, null, wire.getWireError(err));
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
            conn.sendDirect(response_err) catch {
                std.log.warn("Connection {}: dropped while sending error response, closing", .{conn_id});
                ws.close();
            };
            return;
        };

        // 5. Send immediate response when the route completed synchronously.
        if (response) |payload| {
            conn.sendDirect(payload) catch {
                std.log.warn("Connection {}: dropped while sending response, closing", .{conn_id});
                ws.close();
            };
        }
    }

    pub fn routeMessageFast(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        envelope: wire.Envelope,
        message: []const u8,
    ) !?[]const u8 {
        const msg_type = classifyMsgType(envelope.type) orelse return error.UnknownMessageType;
        return switch (msg_type) {
            .store_set_namespace => try self.handleStoreSetNamespace(arena_allocator, conn, envelope.id, message),
            .store_set => try self.handleStoreSet(arena_allocator, conn, envelope.id, message),
            .store_subscribe => try self.handleStoreSubscribe(arena_allocator, conn, envelope.id, message),
            .store_unsubscribe => try self.handleStoreUnsubscribe(arena_allocator, conn, envelope.id, message),
            .store_query => try self.handleStoreQuery(arena_allocator, conn, envelope.id, message),
            .store_load_more => try self.handleStoreLoadMore(arena_allocator, conn, envelope.id, message),
            .store_remove => try self.handleStoreRemove(arena_allocator, conn, envelope.id, message),
            .store_batch => try self.handleStoreBatch(arena_allocator, conn, envelope.id, message),
        };
    }

    pub fn teardownSession(self: *MessageHandler, conn: *Connection) void {
        self.violation_tracker.clearViolations(conn.id);

        conn.mutex.lock();
        const detached = conn.detachSubscriptionsLocked();
        conn.resetSessionLocked();
        conn.mutex.unlock();
        self.unsubscribeDetached(conn, detached);
    }

    fn resetStoreScopeAndClearSubscriptions(self: *MessageHandler, conn: *Connection, namespace: []const u8) !u64 {
        const namespace_owned = try conn.allocator.dupe(u8, namespace);
        var transferred = false;
        errdefer if (!transferred) conn.allocator.free(namespace_owned);

        conn.mutex.lock();
        const detached = conn.detachSubscriptionsLocked();
        conn.beginStoreScopeResolutionLocked(namespace_owned);
        transferred = true;
        const scope_seq = conn.scope_seq;
        conn.mutex.unlock();
        self.unsubscribeDetached(conn, detached);
        return scope_seq;
    }

    fn unsubscribeDetached(self: *MessageHandler, conn: *Connection, detached: Connection.DetachedSubscriptions) void {
        defer detached.deinit(conn.allocator);
        if (detached.ids.len > 0) {
            self.subscription_engine.unsubscribeMany(conn.id, detached.ids);
        }
    }

    pub fn sendError(self: *MessageHandler, conn: *Connection, msg_id: ?u64, wire_err: wire.WireError) !void {
        const error_msg = try wire.encodeError(self.allocator, msg_id, wire_err);
        defer self.allocator.free(error_msg);
        conn.sendDirect(error_msg) catch {
            std.log.warn("Connection {}: dropped while sending error, closing", .{conn.id});
            conn.ws.close();
        };
    }

    /// Send an error to a raw WebSocket that has no Connection object yet
    /// (e.g. rejected non-binary frames before the connection is looked up).
    pub fn sendErrorRaw(self: *MessageHandler, ws: *WebSocket, msg_id: ?u64, wire_err: wire.WireError) !void {
        const error_msg = try wire.encodeError(self.allocator, msg_id, wire_err);
        defer self.allocator.free(error_msg);
        switch (ws.send(error_msg, .binary)) {
            .success, .backpressure => {},
            .dropped => ws.close(),
        }
    }

    fn requireStoreSession(conn: *Connection) !Connection.StoreSession {
        const session = conn.getStoreSession();
        if (!session.ready or session.namespace_id == connection_mod.unset_namespace_id) return error.SessionNotReady;
        return session;
    }

    fn requireStoreNamespace(conn: *Connection) !i64 {
        return (try requireStoreSession(conn)).namespace_id;
    }

    const StoreAuthScope = struct {
        session: Connection.StoreSession,
        namespace: []const u8,
        external_user_id: []const u8,
        namespace_match: authorization.AuthConfig.NamespaceRuleMatch,

        fn deinit(self: *StoreAuthScope, allocator: std.mem.Allocator) void {
            self.namespace_match.deinit(allocator);
            allocator.free(self.external_user_id);
            allocator.free(self.namespace);
        }

        fn evalContext(
            self: *const StoreAuthScope,
            allocator: std.mem.Allocator,
            table: ?*const schema.Table,
            value: ?*const msgpack.Payload,
        ) authorization.EvalContext {
            return .{
                .allocator = allocator,
                .session_user_id = self.session.user_doc_id,
                .session_external_id = self.external_user_id,
                .namespace_captures = &self.namespace_match.captures.captures,
                .path_table = if (table) |t| t.name else null,
                .value_payload = value,
                .value_table = table,
            };
        }
    };

    fn makeStoreAuthScope(
        self: *MessageHandler,
        allocator: std.mem.Allocator,
        conn: *Connection,
        session: Connection.StoreSession,
    ) !StoreAuthScope {
        const namespace = (try conn.dupeStoreNamespace(allocator)) orelse return error.SessionNotReady;
        errdefer allocator.free(namespace);

        const external_user_id = try conn.dupeExternalUserId(allocator);
        errdefer allocator.free(external_user_id);

        const namespace_match = (try self.auth_config.namespaceRuleFor(allocator, namespace)) orelse return error.NamespaceUnauthorized;

        return .{
            .session = session,
            .namespace = namespace,
            .external_user_id = external_user_id,
            .namespace_match = namespace_match,
        };
    }

    // ---- Group A: Scalar-only fast decoders (no Payload tree) ----

    fn handleStoreSetNamespace(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = try wire.extractStoreSetNamespaceFast(message);
        const external_user_id = try conn.dupeExternalUserId(arena_allocator);

        const scope_seq = try self.resetStoreScopeAndClearSubscriptions(conn, req.namespace);
        errdefer _ = conn.resetStoreScopeIfSeq(scope_seq);
        if (try self.store_service.tryResolveScopeCached(req.namespace, external_user_id)) |scope| {
            try authorization.authorizeStoreNamespace(arena_allocator, self.auth_config, req.namespace, scope.user_doc_id, external_user_id);
            if (conn.setStoreScopeIfSeq(scope_seq, scope.namespace_id, scope.user_doc_id)) {
                return try wire.encodeSuccess(arena_allocator, msg_id);
            }
            return error.RequestSuperseded;
        }

        try self.store_service.enqueueResolveScope(conn.id, msg_id, scope_seq, req.namespace, external_user_id);
        return null;
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

        const table = self.schema_manager.getTableByIndex(sub_query.table_index) orelse return error.UnknownTable;
        var read_auth = try self.evaluateStoreReadAuth(arena_allocator, conn, table);
        const read_auth_ptr = if (read_auth) |*predicate| predicate else null;

        var page = try self.store_service.queryMore(arena_allocator, sub_query.table_index, sub_query.namespace_id, &sub_query.filter, req.nextCursor, read_auth_ptr);
        defer page.deinit(arena_allocator);

        return try wire.encodeQuery(arena_allocator, .{
            .msg_id = msg_id,
            .sub_id = req.subId,
            .results = &page.results,
            .table = page.table,
            .next_cursor = page.next_cursor_str,
        });
    }

    // ---- Group B: Payload-dependent handlers (keep Payload tree) ----

    fn extractTableIndexFromPath(path: msgpack.Payload) !usize {
        if (path != .arr or path.arr.len == 0) return error.InvalidMessageFormat;
        return msgpack.extractPayloadUint(path.arr[0]) orelse return error.InvalidMessageFormat;
    }

    fn evaluateStoreWriteAuth(
        self: *MessageHandler,
        arena: std.mem.Allocator,
        conn: *Connection,
        table: *const schema.Table,
        value: ?*const msgpack.Payload,
    ) !?query_ast.FilterPredicate {
        const session = try requireStoreSession(conn);
        const store_rule = self.auth_config.storeRuleFor(table.name) orelse return error.AccessDenied;
        var auth_scope = try self.makeStoreAuthScope(arena, conn, session);
        defer auth_scope.deinit(arena);

        const eval_ctx = auth_scope.evalContext(arena, table, value);
        return try authorization.buildDocPredicate(store_rule.write, eval_ctx, table);
    }

    fn evaluateStoreReadAuth(
        self: *MessageHandler,
        arena: std.mem.Allocator,
        conn: *Connection,
        table: *const schema.Table,
    ) !?query_ast.FilterPredicate {
        const session = try requireStoreSession(conn);
        const store_rule = self.auth_config.storeRuleFor(table.name) orelse return error.AccessDenied;
        var auth_scope = try self.makeStoreAuthScope(arena, conn, session);
        defer auth_scope.deinit(arena);

        const eval_ctx = auth_scope.evalContext(arena, table, null);
        return try authorization.buildDocPredicate(store_rule.read, eval_ctx, table);
    }

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

        const table_index = try extractTableIndexFromPath(payloads.path);
        const table = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        var auth_predicate = try self.evaluateStoreWriteAuth(arena_allocator, conn, table, &value);
        const auth_predicate_ptr = if (auth_predicate) |*predicate| predicate else null;

        try self.store_service.setPath(
            .{
                .namespace_id = session.namespace_id,
                .owner_doc_id = session.user_doc_id,
                .auth_predicate = auth_predicate_ptr,
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
        const session = try requireStoreSession(conn);

        const table_index = try extractTableIndexFromPath(payloads.path);
        const table = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        var auth_predicate = try self.evaluateStoreWriteAuth(arena_allocator, conn, table, null);
        const auth_predicate_ptr = if (auth_predicate) |*predicate| predicate else null;

        try self.store_service.removePath(
            .{ .namespace_id = session.namespace_id, .owner_doc_id = session.user_doc_id, .auth_predicate = auth_predicate_ptr },
            payloads.path,
        );

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreBatch(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const payloads = try wire.extractStoreBatchPayloads(message, arena_allocator);
        const session = try requireStoreSession(conn);
        var auth_scope = try self.makeStoreAuthScope(arena_allocator, conn, session);
        defer auth_scope.deinit(arena_allocator);

        var auth_predicates: ?[]?query_ast.FilterPredicate = null;
        if (payloads.ops == .arr and payloads.ops.arr.len > 0) {
            const predicates = try arena_allocator.alloc(?query_ast.FilterPredicate, payloads.ops.arr.len);
            @memset(predicates, null);
            auth_predicates = predicates;

            for (payloads.ops.arr, 0..) |op_payload, i| {
                if (op_payload != .arr or op_payload.arr.len < 2) continue;
                const path = op_payload.arr[1];
                const table_index = try extractTableIndexFromPath(path);
                const table = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;

                const store_rule = self.auth_config.storeRuleFor(table.name) orelse return error.AccessDenied;
                const value_ptr = if (op_payload.arr.len >= 3) &op_payload.arr[2] else null;
                const eval_ctx = auth_scope.evalContext(arena_allocator, table, value_ptr);
                predicates[i] = try authorization.buildDocPredicate(store_rule.write, eval_ctx, table);
            }
        }

        try self.store_service.batchWrite(
            .{ .namespace_id = session.namespace_id, .owner_doc_id = session.user_doc_id },
            payloads.ops,
            auth_predicates,
        );

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

        const table = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        var read_auth = try self.evaluateStoreReadAuth(arena_allocator, conn, table);
        const read_auth_ptr = if (read_auth) |*predicate| predicate else null;

        var qr = try self.store_service.queryCollection(arena_allocator, namespace_id, msgpack.Payload.uintToPayload(table_index), parsed, read_auth_ptr);
        defer qr.deinit(arena_allocator);

        _ = try self.subscription_engine.subscribe(namespace_id, qr.table_index, qr.filter, conn.id, sub_id);
        try conn.addSubscription(sub_id);

        return try wire.encodeQuery(arena_allocator, .{
            .msg_id = msg_id,
            .sub_id = sub_id,
            .results = &qr.results,
            .table = qr.table,
            .next_cursor = qr.next_cursor_str,
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

        const table = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        var read_auth = try self.evaluateStoreReadAuth(arena_allocator, conn, table);
        const read_auth_ptr = if (read_auth) |*predicate| predicate else null;

        var qr = try self.store_service.queryCollection(arena_allocator, namespace_id, msgpack.Payload.uintToPayload(table_index), parsed, read_auth_ptr);
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
    store_batch,
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
        'B' => if (std.mem.eql(u8, t, "StoreBatch")) return .store_batch else null,
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
