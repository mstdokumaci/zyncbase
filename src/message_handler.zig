const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const ViolationTracker = @import("connection/violations.zig").ConnectionViolationTracker;
const subscription_mod = @import("subscription_engine.zig");
const SubscriptionEngine = subscription_mod.SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const connection_mod = @import("connection/state.zig");
const Connection = connection_mod.Connection;
const SecurityConfig = @import("config_loader.zig").Config.SecurityConfig;
const StoreService = @import("store_service.zig").StoreService;
const PresenceManager = @import("presence.zig").PresenceManager;
const wire = @import("wire.zig");
const authorization = @import("authorization.zig");
const schema_mod = @import("schema.zig");
const typed = @import("typed.zig");
const query_ast = @import("query_ast.zig");
const query_parser = @import("query_parser.zig");
const read_buffer = @import("storage_engine/read_buffer.zig");
const JwtValidator = @import("jwt_validator.zig").JwtValidator;

/// Message handler for WebSocket events
/// Manages connection lifecycle, message parsing, routing, and response handling
pub const MessageHandler = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    store_service: *StoreService,
    presence_manager: *PresenceManager,
    subscription_engine: *SubscriptionEngine,
    security_config: SecurityConfig,
    auth_config: *const authorization.AuthConfig,
    schema: *const schema_mod.Schema,
    jwt_validator: ?*JwtValidator,
    session_claims_mapping: *const std.StringHashMapUnmanaged([]const u8),

    /// Initialize message handler with all required components
    pub fn init(
        self: *MessageHandler,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        violation_tracker: *ViolationTracker,
        store_service: *StoreService,
        presence_manager: *PresenceManager,
        subscription_engine: *SubscriptionEngine,
        security_config: SecurityConfig,
        auth_config: *const authorization.AuthConfig,
        schema: *const schema_mod.Schema,
        jwt_validator: ?*JwtValidator,
        session_claims_mapping: *const std.StringHashMapUnmanaged([]const u8),
    ) void {
        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .violation_tracker = violation_tracker,
            .store_service = store_service,
            .presence_manager = presence_manager,
            .subscription_engine = subscription_engine,
            .security_config = security_config,
            .auth_config = auth_config,
            .schema = schema,
            .jwt_validator = jwt_validator,
            .session_claims_mapping = session_claims_mapping,
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

        // 1. Enforce rate limiting
        if (self.security_config.max_messages_per_second > 0) {
            const is_rate_limited = blk: {
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
                    const elapsed_f: f64 = @floatFromInt(@max(0, elapsed_us));
                    const tokens_to_add: f64 = elapsed_f * (rate_limit / 1_000_000.0);

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
                const rate_limit: f64 = @floatFromInt(self.security_config.max_messages_per_second);
                const ms_until_token: u64 = @intFromFloat(@ceil((1.0 - conn.request_tokens) / rate_limit * 1000.0));
                var err = wire.getWireError(error.RateLimited);
                err.retry_after_ms = ms_until_token;
                try self.sendError(self.allocator, conn, null, err);
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
            try self.sendError(self.allocator, conn, null, wire.getWireError(err));
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
            conn.send(response_err) catch {
                std.log.warn("Connection {}: dropped while sending error response, closing", .{conn_id});
                ws.close();
            };
            return;
        };

        // 5. Send immediate response when the route completed synchronously.
        if (response) |payload| {
            conn.send(payload) catch {
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
            .auth_refresh => try self.handleAuthRefresh(arena_allocator, conn, envelope.id, message),
            .presence_set_namespace => try self.handlePresenceSetNamespace(arena_allocator, conn, envelope.id, message),
            .presence_set => try self.handlePresenceSet(arena_allocator, conn, envelope.id, message),
            .presence_set_shared => try self.handlePresenceSetShared(arena_allocator, conn, envelope.id, message),
            .presence_subscribe => try self.handlePresenceSubscribe(arena_allocator, conn, envelope.id, message),
            .presence_unsubscribe => try self.handlePresenceUnsubscribe(arena_allocator, conn, envelope.id, message),
            .presence_subscribe_shared => try self.handlePresenceSubscribeShared(arena_allocator, conn, envelope.id, message),
            .presence_unsubscribe_shared => try self.handlePresenceUnsubscribeShared(arena_allocator, conn, envelope.id, message),
            .presence_remove => try self.handlePresenceRemove(arena_allocator, conn, envelope.id, message),
        };
    }

    pub fn teardownSession(self: *MessageHandler, conn: *Connection) void {
        self.violation_tracker.clearViolations(conn.id);

        // Capture presence state before resetSessionLocked clears it
        const presence_ns = conn.presence_namespace_id;
        const presence_user = conn.user_doc_id;

        const detached = conn.detachSubscriptionsLocked();
        conn.resetSessionLocked();
        self.unsubscribeDetached(conn, detached);

        if (presence_ns != connection_mod.unset_namespace_id) {
            self.presence_manager.removeAllForConnection(presence_ns, presence_user, conn.id) catch |err| {
                std.log.err("Failed to clean up presence on disconnect: {}", .{err});
            };
        }
    }

    fn resetStoreScopeAndClearSubscriptions(self: *MessageHandler, conn: *Connection, namespace: []const u8) !u64 {
        const namespace_owned = try conn.allocator.dupe(u8, namespace);
        var transferred = false;
        errdefer if (!transferred) conn.allocator.free(namespace_owned);

        const detached = conn.detachSubscriptionsLocked();
        conn.beginStoreScopeResolutionLocked(namespace_owned);
        transferred = true;
        const scope_seq = conn.scope_seq;
        self.unsubscribeDetached(conn, detached);
        return scope_seq;
    }

    fn unsubscribeDetached(self: *MessageHandler, conn: *Connection, detached: Connection.DetachedSubscriptions) void {
        defer detached.deinit(conn.allocator);
        if (detached.ids.len > 0) {
            self.subscription_engine.unsubscribeMany(conn.id, detached.ids);
        }
    }

    pub fn sendError(_: *MessageHandler, allocator: std.mem.Allocator, conn: *Connection, msg_id: ?u64, wire_err: wire.WireError) !void {
        const error_msg = try wire.encodeError(allocator, msg_id, wire_err);
        defer allocator.free(error_msg);
        conn.send(error_msg) catch {
            std.log.warn("Connection {}: dropped while sending error, closing", .{conn.id});
            conn.ws.close();
        };
    }

    fn requireStoreSession(conn: *Connection) !Connection.StoreSession {
        const session = conn.getStoreSession();
        if (!session.ready or session.namespace_id == connection_mod.unset_namespace_id) return error.SessionNotReady;
        return session;
    }

    fn rejectNamespaceSwitch(schema: *const schema_mod.Schema, conn: *Connection, req_namespace: []const u8) !void {
        if (schema.table("users")) |users_table| {
            if (users_table.namespaced) {
                if (conn.getStoreNamespace() orelse
                    conn.pending_store_namespace orelse
                    conn.getPresenceNamespace() orelse
                    conn.pending_presence_namespace) |current|
                {
                    if (!std.mem.eql(u8, current, req_namespace)) {
                        return error.NamespaceSwitchRejected;
                    }
                }
            }
        }
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

        try rejectNamespaceSwitch(self.schema, conn, req.namespace);

        const external_user_id = try conn.dupeExternalUserId(arena_allocator);

        const scope_seq = try self.resetStoreScopeAndClearSubscriptions(conn, req.namespace);
        errdefer _ = conn.resetStoreScopeIfSeq(scope_seq);
        if (try self.store_service.tryResolveScopeCached(req.namespace, external_user_id)) |scope| {
            try authorization.authorizeStoreNamespace(arena_allocator, self.auth_config, req.namespace, scope.user_doc_id, external_user_id, conn.getSessionClaimsPtr());
            if (conn.setStoreScopeIfSeq(scope_seq, scope.namespace_id, scope.user_doc_id)) {
                return try wire.encodeSuccess(arena_allocator, msg_id);
            }
            return error.RequestSuperseded;
        }

        try self.store_service.enqueueResolveScope(conn.id, msg_id, scope_seq, req.namespace, external_user_id, false);
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
    ) !?[]const u8 {
        const req = try wire.extractStoreLoadMoreFast(message);

        const sub_key = subscription_mod.SubscriptionGroup.SubscriberKey{
            .connection_id = conn.id,
            .id = req.subId,
        };

        var sub_query = (try self.subscription_engine.getSubscriptionQuery(arena_allocator, sub_key)) orelse return error.SubscriptionNotFound;
        defer sub_query.deinit(arena_allocator);

        const table = self.schema.tableByIndex(sub_query.table_index) orelse return error.UnknownTable;
        const session = try requireStoreSession(conn);
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        const read_auth = try authorization.authorizeStoreRead(arena_allocator, .{
            .config = self.auth_config,
            .table = table,
            .session_user_id = session.user_doc_id,
            .session_external_id = conn.getExternalUserId(),
            .session_claims = conn.getSessionClaimsPtr(),
            .namespace = namespace,
        });

        var filter_clone = try sub_query.filter.clone(self.allocator);
        errdefer filter_clone.deinit(self.allocator);

        const cursor = try query_parser.decodeCursorToken(self.allocator, req.nextCursor, filter_clone.order_by.field_type, filter_clone.order_by.items_type);
        if (filter_clone.after) |*old| old.deinit(self.allocator);
        filter_clone.after = cursor;

        const auth_clone: ?query_ast.FilterPredicate = if (read_auth) |p| try p.clone(self.allocator) else null;
        errdefer if (auth_clone != null) @constCast(&auth_clone).*.?.deinit(self.allocator);

        const request = read_buffer.ReadRequest{
            .conn_id = conn.id,
            .msg_id = msg_id,
            .kind = .load_more,
            .table_index = sub_query.table_index,
            .namespace_id = sub_query.namespace_id,
            .filter = filter_clone,
            .auth_predicate = auth_clone,
            .sub_id = req.subId,
            .allocator = self.allocator,
        };

        try self.store_service.storage_engine.enqueueRead(request);
        return null;
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

        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        // Parse write acknowledgment metadata
        const write_ack = try parseWriteAck(payloads.confirm, payloads.write_id);

        try self.store_service.setPath(
            .{
                .namespace_id = session.namespace_id,
                .namespace = namespace,
                .owner_doc_id = session.user_doc_id,
                .session_user_id = session.user_doc_id,
                .session_external_id = conn.getExternalUserId(),
                .session_claims = conn.getSessionClaimsPtr(),
                .conn_id = if (write_ack != null) conn.id else null,
                .write_id = if (write_ack) |ack| ack.write_id else null,
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

        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        // Parse write acknowledgment metadata
        const write_ack = try parseWriteAck(payloads.confirm, payloads.write_id);

        try self.store_service.removePath(
            .{
                .namespace_id = session.namespace_id,
                .namespace = namespace,
                .owner_doc_id = session.user_doc_id,
                .session_user_id = session.user_doc_id,
                .session_external_id = conn.getExternalUserId(),
                .session_claims = conn.getSessionClaimsPtr(),
                .conn_id = if (write_ack != null) conn.id else null,
                .write_id = if (write_ack) |ack| ack.write_id else null,
            },
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
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        // Parse write acknowledgment metadata
        const write_ack = try parseWriteAck(payloads.confirm, payloads.write_id);

        try self.store_service.batchWrite(
            .{
                .namespace_id = session.namespace_id,
                .namespace = namespace,
                .owner_doc_id = session.user_doc_id,
                .session_user_id = session.user_doc_id,
                .session_external_id = conn.getExternalUserId(),
                .session_claims = conn.getSessionClaimsPtr(),
                .conn_id = if (write_ack != null) conn.id else null,
                .write_id = if (write_ack) |ack| ack.write_id else null,
            },
            payloads.ops,
        );

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreSubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const table_index = try wire.extractStoreTableIndexFast(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = msgpack.decode(arena_allocator, &reader) catch |err| {
            std.log.warn("Failed to parse StoreSubscribe message: {}", .{err});
            return err;
        };

        const sub_id = generateSubscriptionId(conn) catch return error.SubscriptionIdGenerationFailed;
        const session = try requireStoreSession(conn);
        const namespace_id = session.namespace_id;
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        const table = self.schema.tableByIndex(table_index) orelse return error.UnknownTable;

        const read_auth = try authorization.authorizeStoreRead(arena_allocator, .{
            .config = self.auth_config,
            .table = table,
            .session_user_id = session.user_doc_id,
            .session_external_id = conn.getExternalUserId(),
            .session_claims = conn.getSessionClaimsPtr(),
            .namespace = namespace,
        });

        const filter = try query_parser.parseQueryFilter(self.allocator, self.schema, table_index, parsed);
        errdefer @constCast(&filter).deinit(self.allocator);

        // Register subscription synchronously before async read so notifications are not missed
        _ = try self.subscription_engine.subscribe(namespace_id, table_index, filter, conn.id, sub_id);
        errdefer self.subscription_engine.unsubscribe(conn.id, sub_id);
        try conn.addSubscription(sub_id);
        errdefer conn.removeSubscription(sub_id);

        const auth_clone: ?query_ast.FilterPredicate = if (read_auth) |p| try p.clone(self.allocator) else null;
        errdefer if (auth_clone != null) @constCast(&auth_clone).*.?.deinit(self.allocator);

        const request = read_buffer.ReadRequest{
            .conn_id = conn.id,
            .msg_id = msg_id,
            .kind = .subscribe,
            .table_index = table_index,
            .namespace_id = namespace_id,
            .filter = filter,
            .auth_predicate = auth_clone,
            .sub_id = sub_id,
            .allocator = self.allocator,
        };

        try self.store_service.storage_engine.enqueueRead(request);
        return null;
    }

    fn handleStoreQuery(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const table_index = try wire.extractStoreTableIndexFast(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = msgpack.decode(arena_allocator, &reader) catch |err| {
            std.log.warn("Failed to parse StoreQuery message: {}", .{err});
            return err;
        };

        const session = try requireStoreSession(conn);
        const namespace_id = session.namespace_id;
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        const table = self.schema.tableByIndex(table_index) orelse return error.UnknownTable;

        const read_auth = try authorization.authorizeStoreRead(arena_allocator, .{
            .config = self.auth_config,
            .table = table,
            .session_user_id = session.user_doc_id,
            .session_external_id = conn.getExternalUserId(),
            .session_claims = conn.getSessionClaimsPtr(),
            .namespace = namespace,
        });

        const filter = try query_parser.parseQueryFilter(self.allocator, self.schema, table_index, parsed);
        errdefer @constCast(&filter).deinit(self.allocator);

        const auth_clone: ?query_ast.FilterPredicate = if (read_auth) |p| try p.clone(self.allocator) else null;
        errdefer if (auth_clone != null) @constCast(&auth_clone).*.?.deinit(self.allocator);

        const request = read_buffer.ReadRequest{
            .conn_id = conn.id,
            .msg_id = msg_id,
            .kind = .query,
            .table_index = table_index,
            .namespace_id = namespace_id,
            .filter = filter,
            .auth_predicate = auth_clone,
            .allocator = self.allocator,
        };

        try self.store_service.storage_engine.enqueueRead(request);
        return null;
    }

    fn handleAuthRefresh(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const token = wire.extractAuthRefreshFast(message) catch {
            try self.sendServerDisconnectAndClose(conn, "AUTH_FAILED", "Invalid AuthRefresh message");
            return null;
        };

        const validator = self.jwt_validator orelse {
            try self.sendServerDisconnectAndClose(conn, "AUTH_FAILED", "JWT validation not configured");
            return null;
        };

        var validated = validator.validateWithClaims(conn.allocator, token, self.session_claims_mapping.*) catch {
            try self.sendServerDisconnectAndClose(conn, "AUTH_FAILED", "JWT validation failed");
            return null;
        };

        const sess = conn.session orelse {
            validated.deinit(conn.allocator);
            try self.sendServerDisconnectAndClose(conn, "AUTH_FAILED", "No active session");
            return null;
        };

        if (!std.mem.eql(u8, validated.subject, sess.external_id)) {
            validated.deinit(conn.allocator);
            try self.sendServerDisconnectAndClose(conn, "AUTH_FAILED", "Subject mismatch");
            return null;
        }

        const claims = validated.claims;
        const expires_at = validated.expires_at;
        validated.claims = .{};
        validated.deinit(conn.allocator);
        conn.updateSessionClaims(claims, expires_at);

        return try wire.encodeOkWithSession(arena_allocator, msg_id, conn.getSessionClaimsPtr());
    }

    // === Presence message handlers ===

    fn handlePresenceSetNamespace(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire.extractPresenceSetNamespaceFast(message) catch {
            return error.InvalidMessageFormat;
        };

        try rejectNamespaceSwitch(self.schema, conn, req.namespace);

        const external_user_id = try conn.dupeExternalUserId(arena_allocator);
        const scope_seq = try self.resetPresenceScopeAndClearSubscriptions(conn, req.namespace);
        errdefer _ = conn.resetPresenceScopeIfSeq(scope_seq);

        if (try self.store_service.tryResolveScopeCached(req.namespace, external_user_id)) |scope| {
            try authorization.authorizePresenceNamespace(
                arena_allocator,
                self.auth_config,
                req.namespace,
                scope.user_doc_id,
                external_user_id,
                conn.getSessionClaimsPtr(),
            );
            if (conn.setPresenceScopeIfSeq(scope_seq, scope.namespace_id, scope.user_doc_id)) {
                return try wire.encodeSuccess(arena_allocator, msg_id);
            }
            return error.RequestSuperseded;
        }

        try self.store_service.enqueueResolveScope(conn.id, msg_id, scope_seq, req.namespace, external_user_id, true);
        return null;
    }

    fn handlePresenceSet(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire.extractPresenceSetFast(message, arena_allocator) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);

        try authorization.authorizePresenceWrite(
            arena_allocator,
            self.auth_config,
            conn.presence_namespace orelse return error.SessionNotReady,
            session.user_doc_id,
            conn.getExternalUserId() orelse return error.SessionNotReady,
            conn.getSessionClaimsPtr(),
            self.schema.presence_user_fields,
            &req.data,
        );

        try self.presence_manager.setUser(session.namespace_id, session.user_doc_id, req.data);
        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceSetShared(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire.extractPresenceSetSharedFast(message, arena_allocator) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);

        try authorization.authorizePresenceSharedWrite(
            arena_allocator,
            self.auth_config,
            conn.presence_namespace orelse return error.SessionNotReady,
            session.user_doc_id,
            conn.getExternalUserId() orelse return error.SessionNotReady,
            conn.getSessionClaimsPtr(),
            self.schema.presence_shared_fields,
            &req.data,
        );

        try self.presence_manager.setShared(session.namespace_id, req.data, conn.id);
        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceSubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        _ = wire.extractPresenceSubscribeFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        const sub_id = try conn.allocateSubscriptionId();

        var snapshot = try self.presence_manager.onSubscribeUser(session.namespace_id, conn.id, sub_id);
        defer snapshot.deinit(self.presence_manager.allocator);

        return try wire.encodePresenceUserSnapshot(arena_allocator, msg_id, sub_id, snapshot.users.items);
    }

    fn handlePresenceUnsubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire.extractPresenceUnsubscribeFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        self.presence_manager.onUnsubscribeUser(session.namespace_id, conn.id);
        _ = req; // sub_id not tracked separately for presence

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceSubscribeShared(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        _ = wire.extractPresenceSubscribeSharedFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        const sub_id = try conn.allocateSubscriptionId();

        var shared = try self.presence_manager.onSubscribeShared(session.namespace_id, conn.id, sub_id);
        defer if (shared) |*s| s.deinit(self.presence_manager.allocator);

        return try wire.encodePresenceSharedSnapshot(arena_allocator, msg_id, sub_id, if (shared) |*s| s else null);
    }

    fn handlePresenceUnsubscribeShared(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire.extractPresenceUnsubscribeSharedFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        self.presence_manager.onUnsubscribeShared(session.namespace_id, conn.id);
        _ = req; // sub_id not tracked separately for presence

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        _ = wire.extractPresenceRemoveFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        try self.presence_manager.removeUser(session.namespace_id, session.user_doc_id);

        return try wire.encodeSuccess(arena_allocator, msg_id);
    }

    fn requirePresenceSession(conn: *Connection) !struct { namespace_id: i64, user_doc_id: typed.DocId } {
        if (!conn.presence_ready) return error.SessionNotReady;
        if (conn.presence_namespace_id == connection_mod.unset_namespace_id) return error.SessionNotReady;
        return .{
            .namespace_id = conn.presence_namespace_id,
            .user_doc_id = conn.user_doc_id,
        };
    }

    fn resetPresenceScopeAndClearSubscriptions(self: *MessageHandler, conn: *Connection, namespace: []const u8) !u64 {
        const namespace_owned = try conn.allocator.dupe(u8, namespace);
        var transferred = false;
        errdefer if (!transferred) conn.allocator.free(namespace_owned);

        // Capture old presence state before beginPresenceScopeResolutionLocked resets it
        const old_ns = conn.presence_namespace_id;
        const old_user = conn.user_doc_id;

        conn.beginPresenceScopeResolutionLocked(namespace_owned);
        transferred = true;
        const scope_seq = conn.presence_scope_seq;

        // Unsubscribe from old namespace before switching to the new one
        if (old_ns != connection_mod.unset_namespace_id) {
            self.presence_manager.onUnsubscribeUser(old_ns, conn.id);
            self.presence_manager.onUnsubscribeShared(old_ns, conn.id);
            self.presence_manager.removeUser(old_ns, old_user) catch |err| {
                std.log.err("Failed to remove user presence from old namespace during switch: {}", .{err});
            };
        }

        return scope_seq;
    }

    fn sendServerDisconnectAndClose(self: *MessageHandler, conn: *Connection, code: []const u8, msg: []const u8) !void {
        const disconnect_msg = wire.encodeServerDisconnect(self.allocator, code, msg) catch return;
        defer self.allocator.free(disconnect_msg);
        conn.send(disconnect_msg) catch |err| {
            std.log.warn("Failed to send ServerDisconnect to connection {}: {}", .{ conn.id, err });
        };
        conn.ws.close();
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
    auth_refresh,
    presence_set_namespace,
    presence_set,
    presence_set_shared,
    presence_subscribe,
    presence_unsubscribe,
    presence_subscribe_shared,
    presence_unsubscribe_shared,
    presence_remove,
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
        'n' => {
            // Presence messages: "Presence..." has 'n' at index 5
            if (std.mem.eql(u8, t, "PresenceSetNamespace")) return .presence_set_namespace;
            if (std.mem.eql(u8, t, "PresenceSetShared")) return .presence_set_shared;
            if (std.mem.eql(u8, t, "PresenceSet")) return .presence_set;
            if (std.mem.eql(u8, t, "PresenceSubscribeShared")) return .presence_subscribe_shared;
            if (std.mem.eql(u8, t, "PresenceSubscribe")) return .presence_subscribe;
            if (std.mem.eql(u8, t, "PresenceUnsubscribeShared")) return .presence_unsubscribe_shared;
            if (std.mem.eql(u8, t, "PresenceUnsubscribe")) return .presence_unsubscribe;
            if (std.mem.eql(u8, t, "PresenceRemove")) return .presence_remove;
            return null;
        },
        else => if (std.mem.eql(u8, t, "AuthRefresh")) return .auth_refresh else null,
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

fn parseWriteAck(confirm_str: ?[]const u8, write_id_str: ?[]const u8) !?struct { write_id: [16]u8 } {
    const confirm_val = confirm_str orelse {
        // No confirm field — a writeId without confirm is a client bug.
        if (write_id_str != null) return error.InvalidWriteAck;
        return null;
    };
    if (!std.mem.eql(u8, confirm_val, "committed")) {
        // "accepted" (or any other value) with a writeId is a client bug: the
        // writeId would never be resolved, causing a silent hang on the client.
        // Reject early so the client gets an immediate error instead.
        if (write_id_str != null) return error.InvalidWriteAck;
        return null;
    }
    // confirm == "committed": writeId is required and must be valid.
    const wid_str = write_id_str orelse return error.InvalidWriteAck;
    if (wid_str.len != 32) return error.InvalidWriteAck;
    var write_id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&write_id, wid_str) catch return error.InvalidWriteAck;
    return .{ .write_id = write_id };
}
