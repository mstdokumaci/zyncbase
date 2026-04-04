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
        // 1. Drain (lock-free, fast)
        self.change_buffer.drainInto(&self.drain_buf, self.allocator) catch |err| {
            std.log.err("NotificationDispatcher drain failed: {}", .{err});
            return;
        };
        if (self.drain_buf.items.len == 0) return;
        defer {
            for (self.drain_buf.items) |*change| change.deinit(self.allocator);
            self.drain_buf.clearRetainingCapacity();
        }

        // 2. Dispatch each change
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

        var common = std.ArrayListUnmanaged(u8).empty;
        const writer = common.writer(alloc);

        // FixMap header for 5 elements (0x80 | 5)
        writer.writeByte(0x85) catch return;

        const type_k = Payload.strToPayload("type", alloc) catch return;
        const type_v = Payload.strToPayload("StoreDelta", alloc) catch return;
        const ns_k = Payload.strToPayload("namespace", alloc) catch return;
        const ns_v = Payload.strToPayload(change.namespace, alloc) catch return;
        const coll_k = Payload.strToPayload("collection", alloc) catch return;
        const coll_v = Payload.strToPayload(change.collection, alloc) catch return;
        const val_k = Payload.strToPayload("value", alloc) catch return;
        const sub_k = Payload.strToPayload("subscription_id", alloc) catch return;

        msgpack.encode(type_k, writer) catch return;
        msgpack.encode(type_v, writer) catch return;

        msgpack.encode(ns_k, writer) catch return;
        msgpack.encode(ns_v, writer) catch return;

        msgpack.encode(coll_k, writer) catch return;
        msgpack.encode(coll_v, writer) catch return;

        msgpack.encode(val_k, writer) catch return;
        const value_p = if (change.operation == .delete) .nil else change.new_row orelse .nil;
        msgpack.encode(value_p, writer) catch return;

        msgpack.encode(sub_k, writer) catch return;

        const prefix = common.items;

        var out = std.ArrayListUnmanaged(u8).empty;
        for (matches) |match| {
            out.clearRetainingCapacity();
            out.appendSlice(alloc, prefix) catch continue; // zwanzig-disable-line: swallowed-error
            msgpack.encode(Payload.uintToPayload(match.subscription_id), out.writer(alloc)) catch continue; // zwanzig-disable-line: swallowed-error

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
