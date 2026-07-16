const std = @import("std");
const Allocator = std.mem.Allocator;
const ConnectionManager = @import("manager.zig").ConnectionManager;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const ArenaHandle = @import("../memory_strategy.zig").ArenaHandle;
const typed_doc_id = @import("../typed/doc_id.zig");
const DocId = typed_doc_id.DocId;
const wire_encode = @import("../wire/encode.zig");
const wire_errors = @import("../wire/errors.zig");
const authorization_evaluate = @import("../authorization/evaluate.zig");

pub const SessionResolver = struct {
    connection_manager: *ConnectionManager,
    memory_strategy: *MemoryStrategy,
    allocator: Allocator,

    pub const ResolutionOutcome = struct {
        conn_id: u64,
        data: []const u8,
        arena: ArenaHandle,
    };

    pub fn init(
        self: *SessionResolver,
        allocator: Allocator,
        connection_manager: *ConnectionManager,
        memory_strategy: *MemoryStrategy,
    ) void {
        self.* = .{
            .connection_manager = connection_manager,
            .memory_strategy = memory_strategy,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionResolver) void {
        _ = self;
    }

    pub fn processResolution(
        self: *SessionResolver,
        conn_id: u64,
        msg_id: u64,
        scope_seq: u64,
        namespace_id: i64,
        user_doc_id: DocId,
        resolution_err: ?anyerror,
        is_presence: bool,
    ) ?ResolutionOutcome {
        const conn = self.connection_manager.acquireConnection(conn_id) catch |err| {
            std.log.debug("Failed to acquire connection {} for session resolution: {}", .{ conn_id, err });
            return null;
        };
        defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

        const handle = self.memory_strategy.acquireArenaDeferred() catch |arena_err| {
            std.log.err("SessionResolver acquireArenaDeferred failed: {}", .{arena_err});
            return null;
        };
        // Always release the producer's reference unconditionally.
        // retain() before each return adds exactly one consumer reference.
        // Net: consumer holds refcount=1; entry.deinit() drops it to 0 → arena returned to pool.
        defer handle.release();

        if (resolution_err) |err| {
            const final_err = if (conn.isScopeSeqCurrentFor(scope_seq, is_presence)) err else error.RequestSuperseded;
            const wire_err = wire_errors.getWireError(final_err);
            const msg = wire_encode.encodeError(handle.allocator(), msg_id, wire_err) catch |encode_err| {
                std.log.err("SessionResolver failed to encode error response: {}", .{encode_err});
                return null;
            };
            handle.retain();
            return .{
                .conn_id = conn_id,
                .data = msg,
                .arena = handle,
            };
        }

        const pending_namespace = conn.dupePendingNamespaceIfSeq(handle.allocator(), scope_seq, is_presence) catch |err| {
            const wire_err = wire_errors.getWireError(err);
            const msg = wire_encode.encodeError(handle.allocator(), msg_id, wire_err) catch |encode_err| {
                std.log.err("SessionResolver failed to encode error response: {}", .{encode_err});
                return null;
            };
            handle.retain();
            return .{
                .conn_id = conn_id,
                .data = msg,
                .arena = handle,
            };
        } orelse {
            const wire_err = wire_errors.getWireError(error.RequestSuperseded);
            const msg = wire_encode.encodeError(handle.allocator(), msg_id, wire_err) catch |encode_err| {
                std.log.err("SessionResolver failed to encode stale-scope error: {}", .{encode_err});
                return null;
            };
            handle.retain();
            return .{
                .conn_id = conn_id,
                .data = msg,
                .arena = handle,
            };
        };

        const external_user_id = conn.dupeExternalUserId(handle.allocator()) catch |err| {
            const wire_err = wire_errors.getWireError(err);
            const msg = wire_encode.encodeError(handle.allocator(), msg_id, wire_err) catch |encode_err| {
                std.log.err("SessionResolver failed to encode error response: {}", .{encode_err});
                return null;
            };
            handle.retain();
            return .{
                .conn_id = conn_id,
                .data = msg,
                .arena = handle,
            };
        };

        authorization_evaluate.authorizeNamespace(
            handle.allocator(),
            self.connection_manager.message_handler.auth_config,
            pending_namespace,
            user_doc_id,
            external_user_id,
            conn.getSessionClaimsPtr(),
            is_presence,
        ) catch |err| {
            _ = conn.resetScopeIfSeq(scope_seq, is_presence);
            const wire_err = wire_errors.getWireError(err);
            const msg = wire_encode.encodeError(handle.allocator(), msg_id, wire_err) catch |encode_err| {
                std.log.err("SessionResolver failed to encode error response: {}", .{encode_err});
                return null;
            };
            handle.retain();
            return .{
                .conn_id = conn_id,
                .data = msg,
                .arena = handle,
            };
        };

        if (!conn.setScopeIfSeq(scope_seq, namespace_id, user_doc_id, is_presence)) {
            const wire_err = wire_errors.getWireError(error.RequestSuperseded);
            const msg = wire_encode.encodeError(handle.allocator(), msg_id, wire_err) catch |encode_err| {
                std.log.err("SessionResolver failed to encode stale-scope error: {}", .{encode_err});
                return null;
            };
            handle.retain();
            return .{
                .conn_id = conn_id,
                .data = msg,
                .arena = handle,
            };
        }

        const msg = wire_encode.encodeSuccess(handle.allocator(), msg_id) catch |encode_err| {
            std.log.err("SessionResolver failed to encode success response: {}", .{encode_err});
            return null;
        };
        handle.retain();
        return .{
            .conn_id = conn_id,
            .data = msg,
            .arena = handle,
        };
    }
};
