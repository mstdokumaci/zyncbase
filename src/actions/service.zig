const std = @import("std");

const authorization_actions = @import("../authorization/actions.zig");
const auth_types = @import("../authorization/types.zig");
const connection_manager_mod = @import("../connection/manager.zig");
const msgpack = @import("../msgpack_utils.zig");
const schema_constraints = @import("../schema/constraints.zig");
const schema_types = @import("../schema/types.zig");
const typed_codec = @import("../typed/codec.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const uws_timer = @import("../uws_timer.zig");
const wire_encode = @import("../wire/encode.zig");
const wire_errors = @import("../wire/errors.zig");
const c = @import("../uwebsockets_wrapper.zig").c;

const Allocator = std.mem.Allocator;
const ConnectionManager = connection_manager_mod.ConnectionManager;
const Payload = msgpack.Payload;
const ActionField = schema_types.ActionField;
const ActionScope = schema_types.ActionScope;
const Schema = schema_types.Schema;

/// Default server-owned deadline for synchronous action replies (wire-protocol.md).
pub const default_timeout_ms: u64 = 10_000;
/// Client `timeoutMs` may only shorten the deadline; values above this clamp.
const max_pending_per_connection: usize = 256;
const sweep_interval_ms: u32 = 500;

pub const CallOutcome = enum {
    /// Async action admitted to the forward path; caller already got `ok`.
    accepted,
    /// Sync action forwarded; caller response is deferred to `resolveReply`.
    pending,
};

/// Verified per-connection session facts needed to route and authorize actions.
/// The caller (message handler) resolves these from `Connection` state.
pub const SessionContext = struct {
    conn_id: u64,
    user_doc_id: typed_doc_id.DocId,
    external_user_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value) = null,
    store_namespace: ?[]const u8 = null,
    store_namespace_id: i64 = -1,
    presence_namespace: ?[]const u8 = null,
    presence_namespace_id: i64 = -1,
};

pub const RegistryKey = struct {
    scope: ActionScope,
    namespace_id: i64,
    action_id: u32,
};

const Bucket = struct {
    workers: std.ArrayListUnmanaged(u64) = .empty,
    next: usize = 0,
};

const PendingCall = struct {
    caller_conn_id: u64,
    worker_conn_id: u64,
    req_id: u64,
    action_id: u32,
    scope: ActionScope,
    deadline_ns: i96,
};

const ScopeInfo = struct {
    namespace: []const u8,
    namespace_id: i64,
};

/// Event-loop-only worker registry, round-robin router, and sync-call pending table.
/// No mutex: every entry point runs on the uWS event loop (ADR-022).
pub const ActionsService = struct {
    allocator: Allocator,
    io: std.Io,
    schema: *const Schema,
    auth_config: *const auth_types.AuthConfig,
    connection_manager: ?*ConnectionManager = null,
    registry: std.AutoHashMapUnmanaged(RegistryKey, Bucket) = .{},
    pending: std.AutoHashMapUnmanaged(u64, PendingCall) = .{},
    pending_counts: std.AutoHashMapUnmanaged(u64, usize) = .{},
    next_exec_id: u64 = 1,
    sweep_timer: ?*c.struct_us_timer_t = null,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        schema: *const Schema,
        auth_config: *const auth_types.AuthConfig,
    ) ActionsService {
        return .{
            .allocator = allocator,
            .io = io,
            .schema = schema,
            .auth_config = auth_config,
        };
    }

    pub fn setConnectionManager(self: *ActionsService, connection_manager: *ConnectionManager) void {
        self.connection_manager = connection_manager;
    }

    pub fn deinit(self: *ActionsService) void {
        self.stopSweepTimer();
        var it = self.registry.valueIterator();
        while (it.next()) |bucket| bucket.workers.deinit(self.allocator);
        self.registry.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pending_counts.deinit(self.allocator);
    }

    pub fn startSweepTimer(self: *ActionsService, loop: *c.struct_us_loop_t) !void {
        self.sweep_timer = try uws_timer.startTimer(
            ActionsService,
            self,
            loop,
            sweepTimerCallback,
            sweep_interval_ms,
            sweep_interval_ms,
        );
    }

    pub fn stopSweepTimer(self: *ActionsService) void {
        uws_timer.stopTimer(&self.sweep_timer);
    }

    fn sweepTimerCallback(t: ?*c.struct_us_timer_t) callconv(.c) void {
        const timer = t orelse return;
        const self = uws_timer.extractPtr(ActionsService, timer);
        self.sweepDeadlines();
    }

    // === Registration ===

    /// Validate and register every action id atomically: authorization and
    /// readiness gate the whole message before any bucket is mutated.
    pub fn register(self: *ActionsService, ctx: SessionContext, action_ids: []const u64) !void {
        var keys = std.ArrayListUnmanaged(RegistryKey).empty;
        defer keys.deinit(self.allocator);

        for (action_ids) |action_id_raw| {
            if (action_id_raw > std.math.maxInt(u32)) return error.UnknownAction;
            const action_id: u32 = @intCast(action_id_raw);
            const action = self.schema.actionByIndex(action_id) orelse return error.UnknownAction;
            const info = scopeInfo(ctx, action.scope) orelse return error.SessionNotReady;
            try authorization_actions.authorizeActionRegister(
                self.allocator,
                self.auth_config,
                action,
                info.namespace,
                ctx.user_doc_id,
                ctx.external_user_id,
                ctx.session_claims,
            );
            try keys.append(self.allocator, .{
                .scope = action.scope,
                .namespace_id = info.namespace_id,
                .action_id = action_id,
            });
        }

        for (keys.items) |key| {
            const gop = try self.registry.getOrPut(self.allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (std.mem.indexOfScalar(u64, gop.value_ptr.workers.items, ctx.conn_id) == null) {
                try gop.value_ptr.workers.append(self.allocator, ctx.conn_id);
            }
        }
    }

    /// Remove all of a connection's registrations, optionally scoped.
    pub fn unregister(self: *ActionsService, conn_id: u64, scope_filter: ?ActionScope) void {
        var it = self.registry.iterator();
        while (it.next()) |entry| {
            if (scope_filter) |scope| {
                if (entry.key_ptr.scope != scope) continue;
            }
            removeWorker(entry.value_ptr, conn_id);
        }
        self.pruneEmptyBuckets();
    }

    fn pruneEmptyBuckets(self: *ActionsService) void {
        var empty_keys = std.ArrayListUnmanaged(RegistryKey).empty;
        defer empty_keys.deinit(self.allocator);

        var it = self.registry.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.workers.items.len == 0) {
                empty_keys.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }
        for (empty_keys.items) |key| {
            if (self.registry.fetchRemove(key)) |kv| {
                var bucket = kv.value;
                bucket.workers.deinit(self.allocator);
            }
        }
    }

    // === Calls ===

    /// Authorize, validate, and forward one `ActionCall`.
    /// `params` is the decoded pair-array payload from the caller frame.
    pub fn call(
        self: *ActionsService,
        ctx: SessionContext,
        req_id: u64,
        action_id: u64,
        params: *const Payload,
        client_timeout_ms: ?u64,
    ) !CallOutcome {
        if (action_id > std.math.maxInt(u32)) return error.UnknownAction;
        const action = self.schema.actionByIndex(@intCast(action_id)) orelse return error.UnknownAction;
        const info = scopeInfo(ctx, action.scope) orelse return error.SessionNotReady;

        try authorization_actions.authorizeActionInvoke(
            self.allocator,
            self.auth_config,
            action,
            info.namespace,
            ctx.user_doc_id,
            ctx.external_user_id,
            ctx.session_claims,
            params,
        );
        try validatePayload(self.allocator, action.params, params);

        const key = RegistryKey{
            .scope = action.scope,
            .namespace_id = info.namespace_id,
            .action_id = @intCast(action_id),
        };
        const worker_conn_id = self.pickWorker(key) orelse return error.NoActionWorker;

        const exec_id = self.next_exec_id;
        self.next_exec_id +%= 1;

        const forward = try wire_encode.encodeActionForward(
            self.allocator,
            exec_id,
            ctx.user_doc_id,
            action_id,
            params,
        );
        defer self.allocator.free(forward);

        if (!action.isSync()) {
            self.sendTo(worker_conn_id, forward);
            return .accepted;
        }

        const deadline_ms = if (client_timeout_ms) |t| @min(t, default_timeout_ms) else default_timeout_ms;
        try self.addPending(exec_id, .{
            .caller_conn_id = ctx.conn_id,
            .worker_conn_id = worker_conn_id,
            .req_id = req_id,
            .action_id = @intCast(action_id),
            .scope = action.scope,
            .deadline_ns = nowNs(self.io) + @as(i96, deadline_ms) * std.time.ns_per_ms,
        });
        self.sendTo(worker_conn_id, forward);
        return .pending;
    }

    /// Round-robin worker selection. Returns null when no worker is registered.
    pub fn pickWorker(self: *ActionsService, key: RegistryKey) ?u64 {
        const bucket = self.registry.getPtr(key) orelse return null;
        if (bucket.workers.items.len == 0) return null;
        const idx = bucket.next % bucket.workers.items.len;
        bucket.next = (idx + 1) % bucket.workers.items.len;
        return bucket.workers.items[idx];
    }

    fn addPending(self: *ActionsService, exec_id: u64, call_state: PendingCall) !void {
        const count = try self.pending_counts.getOrPut(self.allocator, call_state.caller_conn_id);
        if (!count.found_existing) count.value_ptr.* = 0;
        if (count.value_ptr.* >= max_pending_per_connection) {
            if (!count.found_existing) _ = self.pending_counts.remove(call_state.caller_conn_id);
            return error.RateLimited;
        }
        try self.pending.put(self.allocator, exec_id, call_state);
        count.value_ptr.* += 1;
    }

    fn removePending(self: *ActionsService, exec_id: u64) ?PendingCall {
        const kv = self.pending.fetchRemove(exec_id) orelse return null;
        if (self.pending_counts.getPtr(kv.value.caller_conn_id)) |count| {
            if (count.* > 0) count.* -= 1;
            if (count.* == 0) _ = self.pending_counts.remove(kv.value.caller_conn_id);
        }
        return kv.value;
    }

    // === Replies ===

    /// Resolve a worker reply. Unknown, foreign, or async exec ids are discarded.
    pub fn resolveReply(self: *ActionsService, worker_conn_id: u64, exec_id: u64, ok: bool, payload: *const Payload) void {
        const pending = self.pending.get(exec_id) orelse return;
        if (pending.worker_conn_id != worker_conn_id) return;
        if (pending.deadline_ns <= nowNs(self.io)) {
            _ = self.removePending(exec_id);
            self.sendError(pending.caller_conn_id, pending.req_id, wire_errors.getWireError(error.ActionTimeout));
            return;
        }
        const action = self.schema.actionByIndex(pending.action_id) orelse {
            _ = self.removePending(exec_id);
            return;
        };

        if (ok) {
            const returns = action.returns orelse {
                _ = self.removePending(exec_id);
                return;
            };
            validatePayload(self.allocator, returns, payload) catch {
                _ = self.removePending(exec_id);
                self.sendError(pending.caller_conn_id, pending.req_id, wire_errors.getWireError(error.SchemaValidationFailed));
                return;
            };
            _ = self.removePending(exec_id);
            const bytes = wire_encode.encodeActionOkWithValue(self.allocator, pending.req_id, payload) catch |err| {
                std.log.err("actions: failed to encode sync reply: {}", .{err});
                return;
            };
            defer self.allocator.free(bytes);
            self.sendTo(pending.caller_conn_id, bytes);
            return;
        }

        _ = self.removePending(exec_id);
        const err_pair = errorPair(payload) orelse {
            self.sendError(pending.caller_conn_id, pending.req_id, wire_errors.getWireError(error.InternalError));
            return;
        };
        self.sendErrorStrings(pending.caller_conn_id, pending.req_id, err_pair.code, err_pair.message);
    }

    // === Lifecycle ===

    /// Caller disconnect drops its pending calls; worker disconnect fails the
    /// calls it was processing and removes its registrations.
    pub fn removeAllForConnection(self: *ActionsService, conn_id: u64) void {
        self.unregister(conn_id, null);

        var caller_exec_ids = std.ArrayListUnmanaged(u64).empty;
        defer caller_exec_ids.deinit(self.allocator);
        var worker_exec_ids = std.ArrayListUnmanaged(u64).empty;
        defer worker_exec_ids.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.caller_conn_id == conn_id) {
                caller_exec_ids.append(self.allocator, entry.key_ptr.*) catch return;
            } else if (entry.value_ptr.worker_conn_id == conn_id) {
                worker_exec_ids.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }

        for (caller_exec_ids.items) |exec_id| _ = self.removePending(exec_id);
        for (worker_exec_ids.items) |exec_id| {
            const pending = self.removePending(exec_id) orelse continue;
            self.sendError(pending.caller_conn_id, pending.req_id, wire_errors.getWireError(error.WorkerDisconnected));
        }
    }

    /// Bound-scope namespace change: drop registrations for that scope and
    /// reject the connection's pending calls in that scope.
    pub fn invalidateScope(self: *ActionsService, conn_id: u64, scope: ActionScope) void {
        self.unregister(conn_id, scope);

        var exec_ids = std.ArrayListUnmanaged(u64).empty;
        defer exec_ids.deinit(self.allocator);
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.caller_conn_id == conn_id and entry.value_ptr.scope == scope) {
                exec_ids.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }

        for (exec_ids.items) |exec_id| {
            const pending = self.removePending(exec_id) orelse continue;
            self.sendError(pending.caller_conn_id, pending.req_id, wire_errors.getWireError(error.RequestSuperseded));
        }
    }

    /// Re-evaluate every registration of a refreshed session. Registrations
    /// that no longer pass are removed and their in-flight calls fail.
    pub fn reauthorizeRegistrations(self: *ActionsService, ctx: SessionContext) void {
        var revoked = std.ArrayListUnmanaged(RegistryKey).empty;
        defer revoked.deinit(self.allocator);

        var it = self.registry.iterator();
        while (it.next()) |entry| {
            const bucket = entry.value_ptr;
            if (std.mem.indexOfScalar(u64, bucket.workers.items, ctx.conn_id) == null) continue;
            const action = self.schema.actionByIndex(entry.key_ptr.action_id) orelse {
                revoked.append(self.allocator, entry.key_ptr.*) catch return;
                continue;
            };
            const info = scopeInfo(ctx, action.scope) orelse {
                revoked.append(self.allocator, entry.key_ptr.*) catch return;
                continue;
            };
            authorization_actions.authorizeActionRegister(
                self.allocator,
                self.auth_config,
                action,
                info.namespace,
                ctx.user_doc_id,
                ctx.external_user_id,
                ctx.session_claims,
            ) catch {
                revoked.append(self.allocator, entry.key_ptr.*) catch return;
            };
        }

        for (revoked.items) |key| {
            if (self.registry.getPtr(key)) |bucket| removeWorker(bucket, ctx.conn_id);
            self.failPendingForWorkerAction(ctx.conn_id, key.action_id, wire_errors.getWireError(error.PermissionDenied));
        }
        self.pruneEmptyBuckets();
    }

    fn failPendingForWorkerAction(self: *ActionsService, worker_conn_id: u64, action_id: u32, wire_err: wire_errors.WireError) void {
        var exec_ids = std.ArrayListUnmanaged(u64).empty;
        defer exec_ids.deinit(self.allocator);
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.worker_conn_id == worker_conn_id and entry.value_ptr.action_id == action_id) {
                exec_ids.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }
        for (exec_ids.items) |exec_id| {
            const pending = self.removePending(exec_id) orelse continue;
            self.sendError(pending.caller_conn_id, pending.req_id, wire_err);
        }
    }

    /// Reject sync calls whose deadline expired. The worker may still execute.
    pub fn sweepDeadlines(self: *ActionsService) void {
        self.sweepDeadlinesAt(nowNs(self.io));
    }

    pub fn sweepDeadlinesAt(self: *ActionsService, now_ns: i96) void {
        var expired = std.ArrayListUnmanaged(u64).empty;
        defer expired.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deadline_ns <= now_ns) {
                expired.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }

        for (expired.items) |exec_id| {
            const pending = self.removePending(exec_id) orelse continue;
            self.sendError(pending.caller_conn_id, pending.req_id, wire_errors.getWireError(error.ActionTimeout));
        }
    }

    pub fn pendingCount(self: *ActionsService, conn_id: u64) usize {
        return self.pending_counts.get(conn_id) orelse 0;
    }

    pub fn workerCount(self: *ActionsService, key: RegistryKey) usize {
        const bucket = self.registry.getPtr(key) orelse return 0;
        return bucket.workers.items.len;
    }

    // === Helpers ===

    fn sendTo(self: *ActionsService, conn_id: u64, bytes: []const u8) void {
        const cm = self.connection_manager orelse return;
        cm.sendToConnection(conn_id, bytes);
    }

    fn sendError(self: *ActionsService, conn_id: u64, req_id: u64, wire_err: wire_errors.WireError) void {
        const bytes = wire_encode.encodeError(self.allocator, req_id, wire_err) catch |err| {
            std.log.err("actions: failed to encode error response: {}", .{err});
            return;
        };
        defer self.allocator.free(bytes);
        self.sendTo(conn_id, bytes);
    }

    fn sendErrorStrings(self: *ActionsService, conn_id: u64, req_id: u64, code: []const u8, message: []const u8) void {
        const bytes = wire_encode.encodeErrorWithStrings(self.allocator, req_id, code, message) catch |err| {
            std.log.err("actions: failed to encode worker error response: {}", .{err});
            return;
        };
        defer self.allocator.free(bytes);
        self.sendTo(conn_id, bytes);
    }
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn scopeInfo(ctx: SessionContext, scope: ActionScope) ?ScopeInfo {
    return switch (scope) {
        .store => if (ctx.store_namespace) |namespace|
            .{ .namespace = namespace, .namespace_id = ctx.store_namespace_id }
        else
            null,
        .presence => if (ctx.presence_namespace) |namespace|
            .{ .namespace = namespace, .namespace_id = ctx.presence_namespace_id }
        else
            null,
    };
}

fn removeWorker(bucket: *Bucket, conn_id: u64) void {
    var i: usize = 0;
    while (i < bucket.workers.items.len) {
        if (bucket.workers.items[i] == conn_id) {
            _ = bucket.workers.swapRemove(i);
        } else {
            i += 1;
        }
    }
    if (bucket.workers.items.len == 0) bucket.next = 0;
}

const ErrorPair = struct {
    code: []const u8,
    message: []const u8,
};

fn errorPair(payload: *const Payload) ?ErrorPair {
    if (payload.* != .arr or payload.arr.len != 2) return null;
    if (payload.arr[0] != .str or payload.arr[1] != .str) return null;
    return .{ .code = payload.arr[0].str.value(), .message = payload.arr[1].str.value() };
}

/// Validate a params/returns pair-array against flattened action fields.
/// Every field flagged `required` must be present and non-nil.
pub fn validatePayload(allocator: Allocator, fields: []const ActionField, payload: *const Payload) !void {
    if (payload.* != .arr) return error.SchemaValidationFailed;

    const seen = try allocator.alloc(bool, fields.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (payload.arr) |pair| {
        if (pair != .arr or pair.arr.len != 2) return error.SchemaValidationFailed;
        const field_index = msgpack.extractPayloadUsize(pair.arr[0]) orelse return error.SchemaValidationFailed;
        if (field_index >= fields.len) return error.SchemaValidationFailed;

        const field = fields[field_index];
        const value = pair.arr[1];
        if (value == .nil) {
            if (field.required) return error.SchemaValidationFailed;
            seen[field_index] = true;
            continue;
        }
        try validateField(allocator, field, value);
        seen[field_index] = true;
    }

    for (fields, seen) |field, was_seen| {
        if (field.required and !was_seen) return error.SchemaValidationFailed;
    }
}

fn validateField(allocator: Allocator, field: ActionField, value: Payload) !void {
    try typed_codec.validateValue(field.declared_type, value);
    if (field.declared_type == .array) {
        const items_type = field.items_type orelse return error.TypeMismatch;
        for (value.arr) |item| {
            // Actions reject nested arrays/objects as array elements.
            if (item == .arr or item == .map) return error.InvalidArrayElement;
            try typed_codec.validateValue(items_type, item);
        }
    }
    if (field.constraints) |constraints| {
        try schema_constraints.validate(constraints, field.declared_type, value, allocator);
    }
}
