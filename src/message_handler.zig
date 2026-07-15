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
const PresenceManager = @import("presence/manager.zig").PresenceManager;
const PresenceOp = @import("presence/worker.zig").PresenceOp;
const PresenceWorker = @import("presence/worker.zig").PresenceWorker;
const wire_errors = @import("wire/errors.zig");
const wire_decode = @import("wire/decode.zig");
const wire_encode = @import("wire/encode.zig");
const authorization_types = @import("authorization/types.zig");
const authorization_evaluate = @import("authorization/evaluate.zig");
const schema_types = @import("schema/types.zig");
const typed_doc_id = @import("typed/doc_id.zig");
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
    auth_config: *const authorization_types.AuthConfig,
    schema: *const schema_types.Schema,
    jwt_validator: ?*JwtValidator,
    session_claims_mapping: *const std.StringHashMapUnmanaged([]const u8),

    /// Pointer to the presence worker thread. Set by the server
    /// after both MessageHandler and PresenceWorker are initialized.
    presence_worker: ?*PresenceWorker = null,

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
        auth_config: *const authorization_types.AuthConfig,
        schema: *const schema_types.Schema,
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
            .presence_worker = null,
        };
    }

    pub fn setPresenceWorker(
        self: *MessageHandler,
        worker: *PresenceWorker,
    ) void {
        self.presence_worker = worker;
    }

    fn enqueuePresenceOp(self: *MessageHandler, op: PresenceOp.Op) void {
        var temp_op = PresenceOp{ .op = op, .allocator = self.allocator };
        const presence = self.presence_worker orelse {
            temp_op.deinit();
            return;
        };
        presence.enqueue(temp_op) catch |err| {
            std.log.err("Failed to enqueue presence op: {}", .{err});
            temp_op.deinit();
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

        // 1. Enforce rate limiting (integer token bucket)
        if (self.security_config.max_messages_per_second > 0) {
            const is_rate_limited = blk: {
                const now_us = std.time.microTimestamp();
                const rate: u64 = self.security_config.max_messages_per_second;
                const burst_capacity: u64 = rate * 2_000_000;

                if (conn.last_request_time == null) {
                    conn.request_tokens = burst_capacity;
                    conn.last_request_time = now_us;
                } else {
                    const elapsed_us: u64 = @intCast(@max(0, now_us - conn.last_request_time.?));
                    const capped_elapsed_us = @min(elapsed_us, 2_000_000);
                    const tokens_to_add = capped_elapsed_us * rate;
                    conn.request_tokens = @min(burst_capacity, conn.request_tokens + tokens_to_add);
                    conn.last_request_time = now_us;
                }

                if (conn.request_tokens < 1_000_000) break :blk true;
                conn.request_tokens -= 1_000_000;
                break :blk false;
            };

            if (is_rate_limited) {
                std.log.warn("Rate limit exceeded for connection {}: tokens={d:.2} (limit={d}/s, burst={d})", .{
                    conn_id,
                    @as(f64, @floatFromInt(conn.request_tokens)) / 1_000_000.0,
                    self.security_config.max_messages_per_second,
                    self.security_config.max_messages_per_second * 2,
                });
                const rate: u64 = self.security_config.max_messages_per_second;
                const ms_until_token: u64 = (1000 + rate - 1) / rate;
                var err = wire_errors.getWireError(error.RateLimited);
                err.retry_after_ms = ms_until_token;
                try self.sendError(self.allocator, conn, null, err);
                return;
            }
        }

        // 2. Extract envelope from raw bytes (zero-alloc)
        const envelope = wire_decode.extractEnvelopeFast(message) catch |err| {
            std.log.warn("Failed to extract envelope from connection {}: {}", .{ conn_id, err });
            if (isSecurityError(err)) {
                if (try self.violation_tracker.recordViolation(conn_id)) {
                    std.log.warn("Closing connection {} due to repeated security violations", .{conn_id});
                    ws.close();
                    return;
                }
            }
            try self.sendError(self.allocator, conn, null, wire_errors.getWireError(err));
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
            const response_err = try wire_encode.encodeError(arena_allocator, envelope.id, wire_errors.getWireError(err));
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
        envelope: wire_decode.Envelope,
        message: []const u8,
    ) !?[]const u8 {
        const msg_type = classifyMsgType(envelope.type) orelse return error.UnknownMessageType;
        return handler_table[@intFromEnum(msg_type)](self, arena_allocator, conn, envelope.id, message);
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
            self.enqueuePresenceOp(.{ .remove_all_for_connection = .{
                .namespace_id = presence_ns,
                .user_id = presence_user,
                .conn_id = conn.id,
            } });
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

    pub fn sendError(_: *MessageHandler, allocator: std.mem.Allocator, conn: *Connection, msg_id: ?u64, wire_err: wire_errors.WireError) !void {
        const error_msg = try wire_encode.encodeError(allocator, msg_id, wire_err);
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

    fn extractTableIndex(parsed: msgpack.Payload) !u64 {
        return switch (parsed) {
            .map => |m| if (m.getByString("table_index")) |ti| switch (ti) {
                .uint => |v| v,
                else => return error.InvalidMessageFormat,
            } else return error.MissingRequiredFields,
            else => return error.InvalidMessageFormat,
        };
    }

    fn buildWriteContext(
        session: Connection.StoreSession,
        conn: *Connection,
        namespace: []const u8,
        write_id: ?[16]u8,
    ) StoreService.WriteContext {
        return .{
            .namespace_id = session.namespace_id,
            .namespace = namespace,
            .owner_doc_id = session.user_doc_id,
            .session_user_id = session.user_doc_id,
            .session_external_id = conn.getExternalUserId(),
            .session_claims = conn.getSessionClaimsPtr(),
            .conn_id = if (write_id != null) conn.id else null,
            .write_id = write_id,
        };
    }

    fn rejectNamespaceSwitch(schema: *const schema_types.Schema, conn: *Connection, req_namespace: []const u8) !void {
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
        const req = try wire_decode.extractStoreSetNamespaceFast(message);

        try rejectNamespaceSwitch(self.schema, conn, req.namespace);

        const external_user_id = try conn.dupeExternalUserId(arena_allocator);

        const scope_seq = try self.resetStoreScopeAndClearSubscriptions(conn, req.namespace);
        errdefer _ = conn.resetScopeIfSeq(scope_seq, false);
        if (try self.store_service.tryResolveScopeCached(req.namespace, external_user_id)) |scope| {
            try authorization_evaluate.authorizeNamespace(arena_allocator, self.auth_config, req.namespace, scope.user_doc_id, external_user_id, conn.getSessionClaimsPtr(), false);
            if (conn.setScopeIfSeq(scope_seq, scope.namespace_id, scope.user_doc_id, false)) {
                return try wire_encode.encodeSuccess(arena_allocator, msg_id);
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
        const req = try wire_decode.extractStoreUnsubscribeFast(message);

        self.subscription_engine.unsubscribe(conn.id, req.subId);
        conn.removeSubscription(req.subId);

        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreLoadMore(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = try wire_decode.extractStoreLoadMoreFast(message);

        const sub_key = subscription_mod.SubscriptionGroup.SubscriberKey{
            .connection_id = conn.id,
            .id = req.subId,
        };

        var sub_query = (try self.subscription_engine.getSubscriptionQuery(arena_allocator, sub_key)) orelse return error.SubscriptionNotFound;
        defer sub_query.deinit(arena_allocator);

        const session = try requireStoreSession(conn);
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        try self.store_service.loadMore(.{
            .conn_id = conn.id,
            .msg_id = msg_id,
            .session_user_id = session.user_doc_id,
            .session_external_id = conn.getExternalUserId(),
            .session_claims = conn.getSessionClaimsPtr(),
            .namespace = namespace,
            .namespace_id = session.namespace_id,
            .allocator = self.allocator,
        }, sub_query.table_index, sub_query.namespace_id, sub_query.filter, req.subId, req.nextCursor);
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
        const payloads = try wire_decode.extractStorePathPayloads(message, arena_allocator);
        const value = payloads.value orelse return error.MissingRequiredFields;
        const session = try requireStoreSession(conn);

        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        try self.store_service.setPath(
            buildWriteContext(session, conn, namespace, payloads.write_id),
            payloads.path,
            value,
        );

        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const payloads = try wire_decode.extractStorePathPayloads(message, arena_allocator);
        const session = try requireStoreSession(conn);

        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        try self.store_service.removePath(
            buildWriteContext(session, conn, namespace, payloads.write_id),
            payloads.path,
        );

        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreBatch(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) ![]const u8 {
        const payloads = try wire_decode.extractStoreBatchPayloads(message, arena_allocator);
        const session = try requireStoreSession(conn);
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        try self.store_service.batchWrite(
            buildWriteContext(session, conn, namespace, payloads.write_id),
            payloads.ops,
        );

        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handleStoreSubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        var reader: std.Io.Reader = .fixed(message);
        const parsed = msgpack.decode(arena_allocator, &reader) catch |err| {
            std.log.warn("Failed to parse StoreSubscribe message: {}", .{err});
            return err;
        };

        const table_index = try extractTableIndex(parsed);

        const sub_id = generateSubscriptionId(conn) catch return error.SubscriptionIdGenerationFailed;
        const session = try requireStoreSession(conn);
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        var read_req = try self.store_service.prepareQueryRead(.{
            .conn_id = conn.id,
            .msg_id = msg_id,
            .session_user_id = session.user_doc_id,
            .session_external_id = conn.getExternalUserId(),
            .session_claims = conn.getSessionClaimsPtr(),
            .namespace = namespace,
            .namespace_id = session.namespace_id,
            .allocator = self.allocator,
        }, table_index, parsed, sub_id, .subscribe);
        errdefer read_req.deinit(self.allocator);

        // Register subscription synchronously before async read so notifications are not missed.
        // subscribe() clones the filter internally; read_req retains ownership.
        _ = try self.subscription_engine.subscribe(session.namespace_id, table_index, read_req.filter, conn.id, sub_id);
        errdefer self.subscription_engine.unsubscribe(conn.id, sub_id);
        try conn.addSubscription(sub_id);
        errdefer conn.removeSubscription(sub_id);

        try self.store_service.enqueueRead(read_req);
        return null;
    }

    fn handleStoreQuery(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        var reader: std.Io.Reader = .fixed(message);
        const parsed = msgpack.decode(arena_allocator, &reader) catch |err| {
            std.log.warn("Failed to parse StoreQuery message: {}", .{err});
            return err;
        };

        const table_index = try extractTableIndex(parsed);

        const session = try requireStoreSession(conn);
        const namespace = conn.getStoreNamespace() orelse return error.SessionNotReady;

        try self.store_service.query(.{
            .conn_id = conn.id,
            .msg_id = msg_id,
            .session_user_id = session.user_doc_id,
            .session_external_id = conn.getExternalUserId(),
            .session_claims = conn.getSessionClaimsPtr(),
            .namespace = namespace,
            .namespace_id = session.namespace_id,
            .allocator = self.allocator,
        }, table_index, parsed);
        return null;
    }

    fn handleAuthRefresh(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const token = wire_decode.extractAuthRefreshFast(message) catch {
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

        return try wire_encode.encodeOkWithSession(arena_allocator, msg_id, conn.getSessionClaimsPtr());
    }

    // === Presence message handlers ===

    fn handlePresenceSetNamespace(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire_decode.extractPresenceSetNamespaceFast(message) catch {
            return error.InvalidMessageFormat;
        };

        try rejectNamespaceSwitch(self.schema, conn, req.namespace);

        const external_user_id = try conn.dupeExternalUserId(arena_allocator);
        const scope_seq = try self.resetPresenceScopeAndClearSubscriptions(conn, req.namespace);
        errdefer _ = conn.resetScopeIfSeq(scope_seq, true);

        if (try self.store_service.tryResolveScopeCached(req.namespace, external_user_id)) |scope| {
            try authorization_evaluate.authorizeNamespace(
                arena_allocator,
                self.auth_config,
                req.namespace,
                scope.user_doc_id,
                external_user_id,
                conn.getSessionClaimsPtr(),
                true,
            );
            if (conn.setScopeIfSeq(scope_seq, scope.namespace_id, scope.user_doc_id, true)) {
                return try wire_encode.encodeSuccess(arena_allocator, msg_id);
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
        const req = wire_decode.extractPresenceSetFast(message, arena_allocator) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);

        try authorization_evaluate.authorizePresenceWrite(
            arena_allocator,
            self.auth_config,
            conn.presence_namespace orelse return error.SessionNotReady,
            session.user_doc_id,
            conn.getExternalUserId() orelse return error.SessionNotReady,
            conn.getSessionClaimsPtr(),
            self.schema.presence_user_fields,
            &req.data,
        );

        const cloned_patch = try req.data.deepClone(self.allocator);
        self.enqueuePresenceOp(.{ .set_user = .{
            .namespace_id = session.namespace_id,
            .user_id = session.user_doc_id,
            .patch = cloned_patch,
        } });
        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceSetShared(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire_decode.extractPresenceSetSharedFast(message, arena_allocator) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);

        try authorization_evaluate.authorizePresenceSharedWrite(
            arena_allocator,
            self.auth_config,
            conn.presence_namespace orelse return error.SessionNotReady,
            session.user_doc_id,
            conn.getExternalUserId() orelse return error.SessionNotReady,
            conn.getSessionClaimsPtr(),
            self.schema.presence_shared_fields,
            &req.data,
        );

        const cloned_patch = try req.data.deepClone(self.allocator);
        self.enqueuePresenceOp(.{ .set_shared = .{
            .namespace_id = session.namespace_id,
            .patch = cloned_patch,
            .source_conn = conn.id,
        } });
        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceSubscribe(
        self: *MessageHandler,
        _: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        _ = wire_decode.extractPresenceSubscribeFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        const sub_id = try conn.allocateSubscriptionId();

        self.enqueuePresenceOp(.{ .subscribe_user = .{
            .namespace_id = session.namespace_id,
            .conn_id = conn.id,
            .sub_id = sub_id,
            .msg_id = msg_id,
        } });
        return null;
    }

    fn handlePresenceUnsubscribe(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire_decode.extractPresenceUnsubscribeFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        _ = req;

        self.enqueuePresenceOp(.{ .unsubscribe_user = .{
            .namespace_id = session.namespace_id,
            .conn_id = conn.id,
        } });
        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceSubscribeShared(
        self: *MessageHandler,
        _: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        _ = wire_decode.extractPresenceSubscribeSharedFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        const sub_id = try conn.allocateSubscriptionId();

        self.enqueuePresenceOp(.{ .subscribe_shared = .{
            .namespace_id = session.namespace_id,
            .conn_id = conn.id,
            .sub_id = sub_id,
            .msg_id = msg_id,
        } });
        return null;
    }

    fn handlePresenceUnsubscribeShared(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        const req = wire_decode.extractPresenceUnsubscribeSharedFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);
        _ = req;

        self.enqueuePresenceOp(.{ .unsubscribe_shared = .{
            .namespace_id = session.namespace_id,
            .conn_id = conn.id,
        } });
        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn handlePresenceRemove(
        self: *MessageHandler,
        arena_allocator: std.mem.Allocator,
        conn: *Connection,
        msg_id: u64,
        message: []const u8,
    ) !?[]const u8 {
        _ = wire_decode.extractPresenceRemoveFast(message) catch {
            return error.InvalidMessageFormat;
        };

        const session = try requirePresenceSession(conn);

        self.enqueuePresenceOp(.{ .remove_user = .{
            .namespace_id = session.namespace_id,
            .user_id = session.user_doc_id,
        } });
        return try wire_encode.encodeSuccess(arena_allocator, msg_id);
    }

    fn requirePresenceSession(conn: *Connection) !struct { namespace_id: i64, user_doc_id: typed_doc_id.DocId } {
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

        // Enqueue cleanup of old namespace presence to the dispatcher thread
        if (old_ns != connection_mod.unset_namespace_id) {
            self.enqueuePresenceOp(.{ .remove_all_for_connection = .{
                .namespace_id = old_ns,
                .user_id = old_user,
                .conn_id = conn.id,
            } });
        }

        return scope_seq;
    }

    fn sendServerDisconnectAndClose(self: *MessageHandler, conn: *Connection, code: []const u8, msg: []const u8) !void {
        const disconnect_msg = wire_encode.encodeServerDisconnect(self.allocator, code, msg) catch return;
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

const msg_type_map = std.StaticStringMap(MsgType).initComptime(.{
    .{ "StoreSetNamespace", .store_set_namespace },
    .{ "StoreSet", .store_set },
    .{ "StoreSubscribe", .store_subscribe },
    .{ "StoreUnsubscribe", .store_unsubscribe },
    .{ "StoreQuery", .store_query },
    .{ "StoreLoadMore", .store_load_more },
    .{ "StoreRemove", .store_remove },
    .{ "StoreBatch", .store_batch },
    .{ "AuthRefresh", .auth_refresh },
    .{ "PresenceSetNamespace", .presence_set_namespace },
    .{ "PresenceSet", .presence_set },
    .{ "PresenceSetShared", .presence_set_shared },
    .{ "PresenceSubscribe", .presence_subscribe },
    .{ "PresenceUnsubscribe", .presence_unsubscribe },
    .{ "PresenceSubscribeShared", .presence_subscribe_shared },
    .{ "PresenceUnsubscribeShared", .presence_unsubscribe_shared },
    .{ "PresenceRemove", .presence_remove },
});

fn classifyMsgType(t: []const u8) ?MsgType {
    if (t.len < 8) return null;
    return msg_type_map.get(t);
}

const HandlerFn = *const fn (*MessageHandler, std.mem.Allocator, *Connection, u64, []const u8) anyerror!?[]const u8;

fn wrap(comptime f: anytype) HandlerFn { // zwanzig-disable-line: unused-parameter
    return struct {
        fn call(self: *MessageHandler, arena: std.mem.Allocator, conn: *Connection, id: u64, msg: []const u8) anyerror!?[]const u8 {
            return try f(self, arena, conn, id, msg);
        }
    }.call;
}

const handler_table = [_]HandlerFn{
    wrap(&MessageHandler.handleStoreSetNamespace),
    wrap(&MessageHandler.handleStoreSet),
    wrap(&MessageHandler.handleStoreSubscribe),
    wrap(&MessageHandler.handleStoreUnsubscribe),
    wrap(&MessageHandler.handleStoreQuery),
    wrap(&MessageHandler.handleStoreLoadMore),
    wrap(&MessageHandler.handleStoreRemove),
    wrap(&MessageHandler.handleStoreBatch),
    wrap(&MessageHandler.handleAuthRefresh),
    wrap(&MessageHandler.handlePresenceSetNamespace),
    wrap(&MessageHandler.handlePresenceSet),
    wrap(&MessageHandler.handlePresenceSetShared),
    wrap(&MessageHandler.handlePresenceSubscribe),
    wrap(&MessageHandler.handlePresenceUnsubscribe),
    wrap(&MessageHandler.handlePresenceSubscribeShared),
    wrap(&MessageHandler.handlePresenceUnsubscribeShared),
    wrap(&MessageHandler.handlePresenceRemove),
};
comptime {
    std.debug.assert(handler_table.len == @typeInfo(MsgType).@"enum".fields.len);
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
