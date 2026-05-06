const std = @import("std");
const Allocator = std.mem.Allocator;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const session_resolution = @import("session_resolution.zig");
const SessionResolutionBuffer = session_resolution.SessionResolutionBuffer;
const SessionResolutionResult = session_resolution.SessionResolutionResult;
const wire = @import("wire.zig");

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

    fn deliverResult(self: *SessionResolver, result: SessionResolutionResult, cm: *ConnectionManager) void {
        const conn = cm.acquireConnection(result.conn_id) catch |err| {
            std.log.debug("Failed to acquire connection {} for session resolution: {}", .{ result.conn_id, err });
            return;
        };
        defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

        if (result.err) |err| {
            if (!conn.isScopeSeqCurrent(result.scope_seq)) return;
            const arena = self.memory_strategy.acquireArena() catch |arena_err| {
                std.log.err("SessionResolver acquireArena failed: {}", .{arena_err});
                return;
            };
            defer self.memory_strategy.releaseArena(arena);

            const msg = wire.encodeError(arena.allocator(), result.msg_id, wire.getWireError(err)) catch |encode_err| {
                std.log.err("SessionResolver failed to encode error response: {}", .{encode_err});
                return;
            };
            conn.ws.send(msg, .binary);
            return;
        }

        const arena = self.memory_strategy.acquireArena() catch |err| {
            std.log.err("SessionResolver acquireArena failed: {}", .{err});
            return;
        };
        defer self.memory_strategy.releaseArena(arena);

        const msg = wire.encodeSuccess(arena.allocator(), result.msg_id) catch |err| {
            std.log.err("SessionResolver failed to encode success response: {}", .{err});
            return;
        };

        if (!conn.setStoreScopeIfSeq(result.scope_seq, result.namespace_id, result.user_doc_id)) return;
        conn.ws.send(msg, .binary);
    }

    pub fn deinit(self: *SessionResolver) void {
        self.drain_buf.deinit(self.allocator);
    }
};
