const std = @import("std");
const Allocator = std.mem.Allocator;
const connection = @import("connection.zig");
const ConnectionManager = connection.ConnectionManager;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const write_outcome = @import("write_outcome_buffer.zig");
const WriteOutcomeBuffer = write_outcome.WriteOutcomeBuffer;
const WriteOutcomeResult = write_outcome.WriteOutcomeResult;
const wire = @import("wire.zig");

pub const WriteOutcomeDispatcher = struct {
    outcome_buffer: *WriteOutcomeBuffer,
    memory_strategy: *MemoryStrategy,
    allocator: Allocator,
    drain_buf: std.ArrayListUnmanaged(WriteOutcomeResult) = .empty,

    pub fn init(
        self: *WriteOutcomeDispatcher,
        allocator: Allocator,
        outcome_buffer: *WriteOutcomeBuffer,
        memory_strategy: *MemoryStrategy,
    ) void {
        self.* = .{
            .outcome_buffer = outcome_buffer,
            .memory_strategy = memory_strategy,
            .allocator = allocator,
            .drain_buf = .empty,
        };
    }

    pub fn poll(self: *WriteOutcomeDispatcher, cm: *ConnectionManager) void {
        self.outcome_buffer.drainInto(&self.drain_buf, self.allocator) catch |err| {
            std.log.err("WriteOutcomeDispatcher drain failed: {}", .{err});
            return;
        };

        if (self.drain_buf.items.len == 0) return;
        defer self.drain_buf.clearRetainingCapacity();

        for (self.drain_buf.items) |result| {
            self.deliverResult(result, cm);
        }
    }

    fn deliverResult(self: *WriteOutcomeDispatcher, result: WriteOutcomeResult, cm: *ConnectionManager) void {
        const arena = self.memory_strategy.acquireArena() catch |arena_err| {
            std.log.err("WriteOutcomeDispatcher acquireArena failed: {}", .{arena_err});
            return;
        };
        defer self.memory_strategy.releaseArena(arena);

        const msg = if (result.err) |err| blk: {
            const wire_err = wire.getWireError(err);
            break :blk wire.encodeWriteError(arena.allocator(), result.write_id, wire_err, result.batch_index) catch |encode_err| {
                std.log.err("WriteOutcomeDispatcher failed to encode WriteError: {}", .{encode_err});
                return;
            };
        } else blk: {
            break :blk wire.encodeWriteCommitted(arena.allocator(), result.write_id) catch |encode_err| {
                std.log.err("WriteOutcomeDispatcher failed to encode WriteCommitted: {}", .{encode_err});
                return;
            };
        };

        cm.sendToConnection(result.conn_id, msg);
    }

    pub fn deinit(self: *WriteOutcomeDispatcher) void {
        self.drain_buf.deinit(self.allocator);
    }
};
