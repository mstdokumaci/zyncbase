const std = @import("std");
const Allocator = std.mem.Allocator;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const OwnedRowChange = @import("change_buffer.zig").OwnedRowChange;
const RowChange = @import("subscription_engine.zig").RowChange;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const protocol = @import("protocol.zig");

pub const NotificationDispatcher = struct {
    change_buffer: *ChangeBuffer,
    subscription_engine: *SubscriptionEngine,
    memory_strategy: *MemoryStrategy,
    allocator: Allocator,
    drain_buf: std.ArrayListUnmanaged(OwnedRowChange) = .empty,

    pub fn init(self: *NotificationDispatcher, allocator: Allocator, change_buffer: *ChangeBuffer, subscription_engine: *SubscriptionEngine, memory_strategy: *MemoryStrategy) !void {
        self.* = .{
            .change_buffer = change_buffer,
            .subscription_engine = subscription_engine,
            .memory_strategy = memory_strategy,
            .allocator = allocator,
            .drain_buf = .empty,
        };
    }

    pub fn poll(self: *NotificationDispatcher, cm: *ConnectionManager) void {
        self.change_buffer.drainInto(&self.drain_buf, self.allocator) catch |err| {
            std.log.err("NotificationDispatcher drain failed: {}", .{err});
            return;
        };

        if (self.drain_buf.items.len == 0) return;
        defer {
            for (self.drain_buf.items) |*change| change.deinit(self.allocator);
            self.drain_buf.clearRetainingCapacity();
        }

        for (self.drain_buf.items) |change| {
            self.dispatchChange(change, cm);
        }
    }

    fn dispatchChange(self: *NotificationDispatcher, change: OwnedRowChange, cm: *ConnectionManager) void {
        const row_change = RowChange{
            .namespace = change.namespace,
            .collection = change.collection,
            .operation = @enumFromInt(@intFromEnum(change.operation)),
            .new_row = change.new_row,
            .old_row = change.old_row,
        };

        const id_payload = if (change.new_row orelse change.old_row) |row|
            (row.mapGet("id") catch null)
        else
            null;

        if (id_payload == null) {
            std.log.err("NotificationDispatcher skipping delta for {s}:{s} because row has no id", .{ change.namespace, change.collection });
            return;
        }

        const id_payload_value = id_payload.?;
        const is_delete = change.operation == .delete;

        const arena = self.memory_strategy.acquireArena() catch |err| {
            std.log.err("NotificationDispatcher acquireArena failed: {}", .{err});
            return;
        };
        defer self.memory_strategy.releaseArena(arena);
        const alloc = arena.allocator();

        const matches = self.subscription_engine.handleRowChange(row_change, alloc) catch |err| {
            std.log.err("NotificationDispatcher handleRowChange failed: {}", .{err});
            return;
        };

        if (matches.len == 0) return;

        const suffix = protocol.encodeDeltaSuffix(
            alloc,
            change.collection,
            id_payload_value,
            is_delete,
            change.new_row,
        ) catch |err| {
            std.log.err("NotificationDispatcher failed to encode delta suffix for {s}:{s}: {}", .{ change.namespace, change.collection, err });
            return;
        };

        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(alloc);

        for (matches) |match| {
            out.clearRetainingCapacity();
            const writer = out.writer(alloc);

            out.appendSlice(alloc, &protocol.store_delta_header) catch |err| {
                std.log.err("NotificationDispatcher failed to write header: {}", .{err});
                continue;
            };

            msgpack.encode(Payload.uintToPayload(match.subscription_id), writer) catch |err| {
                std.log.err("NotificationDispatcher failed to encode subId {}: {}", .{ match.subscription_id, err });
                continue;
            };

            out.appendSlice(alloc, suffix) catch |err| {
                std.log.err("NotificationDispatcher failed to append suffix: {}", .{err});
                continue;
            };

            const conn = cm.acquireConnection(match.connection_id) catch |err| {
                std.log.debug("Failed to acquire connection {} for notification: {}", .{ match.connection_id, err });
                continue;
            };
            defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

            conn.ws.send(out.items, .binary);
        }
    }

    pub fn deinit(self: *NotificationDispatcher) void {
        for (self.drain_buf.items) |*change| change.deinit(self.allocator);
        self.drain_buf.deinit(self.allocator);
    }
};
