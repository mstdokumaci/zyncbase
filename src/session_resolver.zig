const std = @import("std");
const Allocator = std.mem.Allocator;
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const session_resolution = @import("session_resolution_buffer.zig");
const SessionResolutionBuffer = session_resolution.SessionResolutionBuffer;
const SessionResolutionResult = session_resolution.SessionResolutionResult;
const wire = @import("wire.zig");
const authorization = @import("authorization.zig");

pub const SessionResolver = struct {
    resolution_buffer: *SessionResolutionBuffer,
    memory_strategy: *MemoryStrategy,
    allocator: Allocator,
    drain_buf: std.ArrayListUnmanaged(SessionResolutionResult) = .empty,

    pub fn init(
        self: *SessionResolver,
        allocator: Allocator,
        resolution_buffer: *SessionResolutionBuffer,
        memory_strategy: *MemoryStrategy,
    ) void {
        self.* = .{
            .resolution_buffer = resolution_buffer,
            .memory_strategy = memory_strategy,
            .allocator = allocator,
            .drain_buf = .empty,
        };
    }

    pub fn poll(self: *SessionResolver, cm: *ConnectionManager) void {
        self.resolution_buffer.drainInto(&self.drain_buf, self.allocator) catch |err| {
            std.log.err("SessionResolver drain failed: {}", .{err});
            return;
        };

        if (self.drain_buf.items.len == 0) return;
        defer self.drain_buf.clearRetainingCapacity();

        for (self.drain_buf.items) |result| {
            self.deliverResult(result, cm);
        }
    }

    fn sendStaleScopeError(self: *SessionResolver, conn: *Connection, msg_id: u64) void {
        const arena = self.memory_strategy.acquireArena() catch |arena_err| {
            std.log.err("SessionResolver acquireArena failed: {}", .{arena_err});
            return;
        };
        defer self.memory_strategy.releaseArena(arena);

        const msg = wire.encodeError(arena.allocator(), msg_id, wire.getWireError(error.RequestSuperseded)) catch |encode_err| {
            std.log.err("SessionResolver failed to encode stale-scope error: {}", .{encode_err});
            return;
        };
        conn.ws.send(msg, .binary);
    }

    fn sendError(self: *SessionResolver, conn: *Connection, msg_id: u64, err: anyerror) void {
        const arena = self.memory_strategy.acquireArena() catch |arena_err| {
            std.log.err("SessionResolver acquireArena failed: {}", .{arena_err});
            return;
        };
        defer self.memory_strategy.releaseArena(arena);

        const msg = wire.encodeError(arena.allocator(), msg_id, wire.getWireError(err)) catch |encode_err| {
            std.log.err("SessionResolver failed to encode error response: {}", .{encode_err});
            return;
        };
        conn.ws.send(msg, .binary);
    }

    fn deliverResult(self: *SessionResolver, result: SessionResolutionResult, cm: *ConnectionManager) void {
        const conn = cm.acquireConnection(result.conn_id) catch |err| {
            std.log.debug("Failed to acquire connection {} for session resolution: {}", .{ result.conn_id, err });
            return;
        };
        defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

        if (result.err) |err| {
            if (!conn.isScopeSeqCurrent(result.scope_seq)) {
                self.sendStaleScopeError(conn, result.msg_id);
                return;
            }
            self.sendError(conn, result.msg_id, err);
            return;
        }

        const arena = self.memory_strategy.acquireArena() catch |arena_err| {
            std.log.err("SessionResolver acquireArena failed: {}", .{arena_err});
            return;
        };
        defer self.memory_strategy.releaseArena(arena);

        const pending_namespace = (conn.dupePendingStoreNamespaceIfSeq(arena.allocator(), result.scope_seq) catch |err| {
            self.sendError(conn, result.msg_id, err);
            return;
        }) orelse {
            self.sendStaleScopeError(conn, result.msg_id);
            return;
        };

        const external_user_id = conn.dupeExternalUserId(arena.allocator()) catch |err| {
            self.sendError(conn, result.msg_id, err);
            return;
        };

        authorization.authorizeStoreNamespace(arena.allocator(), cm.message_handler.auth_config, pending_namespace, result.user_doc_id, external_user_id) catch |err| {
            _ = conn.resetStoreScopeIfSeq(result.scope_seq);
            self.sendError(conn, result.msg_id, err);
            return;
        };

        if (!conn.setStoreScopeIfSeq(result.scope_seq, result.namespace_id, result.user_doc_id)) {
            self.sendStaleScopeError(conn, result.msg_id);
            return;
        }

        const msg = wire.encodeSuccess(arena.allocator(), result.msg_id) catch |encode_err| {
            std.log.err("SessionResolver failed to encode success response: {}", .{encode_err});
            return;
        };
        conn.ws.send(msg, .binary);
    }

    pub fn deinit(self: *SessionResolver) void {
        self.drain_buf.deinit(self.allocator);
    }
};
