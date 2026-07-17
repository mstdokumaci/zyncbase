const std = @import("std");
const Allocator = std.mem.Allocator;
const PresenceWorker = @import("worker.zig").PresenceWorker;
const PresenceOp = @import("worker.zig").PresenceOp;
const authorization_types = @import("../authorization/types.zig");
const authorization_presence = @import("../authorization/presence.zig");
const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const msgpack = @import("../msgpack_utils.zig");
const AuthConfig = authorization_types.AuthConfig;
const Schema = schema_types.Schema;
const DocId = typed_doc_id.DocId;

/// PresenceService is the domain-level facade for presence operations.
/// It owns authorization, patch memory management, and worker dispatch.
/// `enqueue` is private — no external caller can reach PresenceWorker or PresenceOp.
pub const PresenceService = struct {
    allocator: Allocator,
    worker: ?*PresenceWorker,
    auth_config: *const AuthConfig,
    schema: *const Schema,

    /// Presence context built by the handler from Connection state.
    /// Matches the pattern of StoreService.WriteContext / ReadContext.
    pub const Session = struct {
        namespace_id: i64,
        user_doc_id: DocId,
        conn_id: u64,
        external_user_id: []const u8,
        session_claims: *const std.StringHashMapUnmanaged(typed.Value),
        presence_namespace: []const u8,
        /// Arena allocator for auth temporaries (pattern-matching captures).
        arena: Allocator,
    };

    pub fn init(
        allocator: Allocator,
        worker: ?*PresenceWorker,
        auth_config: *const AuthConfig,
        schema: *const Schema,
    ) PresenceService {
        return .{
            .allocator = allocator,
            .worker = worker,
            .auth_config = auth_config,
            .schema = schema,
        };
    }

    pub fn deinit(_: *PresenceService) void {}

    // === Public API — each method owns its full policy chain ===

    /// Authorize user presence write, clone patch onto service allocator, enqueue set_user.
    pub fn setUser(self: *PresenceService, session: Session, patch: msgpack.Payload) !void {
        try self.authorizeWrite(session, &patch);
        const cloned_patch = try patch.deepClone(self.allocator);
        self.enqueue(.{ .set_user = .{
            .namespace_id = session.namespace_id,
            .user_id = session.user_doc_id,
            .patch = cloned_patch,
        } });
    }

    /// Authorize shared presence write, clone patch onto service allocator, enqueue set_shared.
    pub fn setShared(self: *PresenceService, session: Session, patch: msgpack.Payload) !void {
        try self.authorizeSharedWrite(session, &patch);
        const cloned_patch = try patch.deepClone(self.allocator);
        self.enqueue(.{ .set_shared = .{
            .namespace_id = session.namespace_id,
            .patch = cloned_patch,
            .source_conn = session.conn_id,
        } });
    }

    /// Enqueue remove_user. No per-op auth — namespace admission already gatekept presenceRead.
    pub fn removeUser(self: *PresenceService, session: Session) !void {
        self.enqueue(.{ .remove_user = .{
            .namespace_id = session.namespace_id,
            .user_id = session.user_doc_id,
        } });
    }

    /// Enqueue subscribe_user with client-provided sub_id and msg_id.
    pub fn subscribeUser(self: *PresenceService, session: Session, sub_id: u64, msg_id: u64) !void {
        self.enqueue(.{ .subscribe_user = .{
            .namespace_id = session.namespace_id,
            .conn_id = session.conn_id,
            .sub_id = sub_id,
            .msg_id = msg_id,
        } });
    }

    /// Enqueue subscribe_shared with client-provided sub_id and msg_id.
    pub fn subscribeShared(self: *PresenceService, session: Session, sub_id: u64, msg_id: u64) !void {
        self.enqueue(.{ .subscribe_shared = .{
            .namespace_id = session.namespace_id,
            .conn_id = session.conn_id,
            .sub_id = sub_id,
            .msg_id = msg_id,
        } });
    }

    /// Enqueue unsubscribe_user.
    pub fn unsubscribeUser(self: *PresenceService, session: Session) !void {
        self.enqueue(.{ .unsubscribe_user = .{
            .namespace_id = session.namespace_id,
            .conn_id = session.conn_id,
        } });
    }

    /// Enqueue unsubscribe_shared.
    pub fn unsubscribeShared(self: *PresenceService, session: Session) !void {
        self.enqueue(.{ .unsubscribe_shared = .{
            .namespace_id = session.namespace_id,
            .conn_id = session.conn_id,
        } });
    }

    /// Enqueue remove_all_for_connection. Used by teardown and scope reset.
    /// Returns void — called from void contexts; enqueue errors are swallowed internally.
    pub fn removeAllForConnection(self: *PresenceService, namespace_id: i64, user_doc_id: DocId, conn_id: u64) void {
        self.enqueue(.{ .remove_all_for_connection = .{
            .namespace_id = namespace_id,
            .user_id = user_doc_id,
            .conn_id = conn_id,
        } });
    }

    // === Private policies — not accessible from outside ===

    fn authorizeWrite(self: *PresenceService, session: Session, patch: *const msgpack.Payload) !void {
        try authorization_presence.authorizePresenceWrite(
            session.arena,
            self.auth_config,
            session.presence_namespace,
            session.user_doc_id,
            session.external_user_id,
            session.session_claims,
            self.schema.presence_user_fields,
            patch,
        );
    }

    fn authorizeSharedWrite(self: *PresenceService, session: Session, patch: *const msgpack.Payload) !void {
        try authorization_presence.authorizePresenceSharedWrite(
            session.arena,
            self.auth_config,
            session.presence_namespace,
            session.user_doc_id,
            session.external_user_id,
            session.session_claims,
            self.schema.presence_shared_fields,
            patch,
        );
    }

    /// Only path to PresenceWorker. Builds the PresenceOp internally.
    /// Silently drops ops when worker is null (test environments).
    /// Swallows enqueue errors (fire-and-forget system — logged, not propagated).
    fn enqueue(self: *PresenceService, op: PresenceOp.Op) void {
        var temp_op = PresenceOp{ .op = op, .allocator = self.allocator };
        const worker = self.worker orelse {
            temp_op.deinit();
            return;
        };
        worker.enqueue(temp_op) catch |err| {
            std.log.err("Failed to enqueue presence op: {}", .{err});
            temp_op.deinit();
        };
    }
};
