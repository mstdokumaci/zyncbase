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

        const encoder = struct {
            fn writeStr(w: anytype, s: []const u8) !void {
                if (s.len <= 31) {
                    try w.writeByte(0xa0 | @as(u8, @intCast(s.len)));
                } else if (s.len <= 0xff) {
                    try w.writeByte(0xd9);
                    try w.writeByte(@as(u8, @intCast(s.len)));
                } else if (s.len <= 0xffff) {
                    try w.writeByte(0xda);
                    try w.writeInt(u16, @as(u16, @intCast(s.len)), .big);
                } else {
                    try w.writeByte(0xdb);
                    try w.writeInt(u32, @as(u32, @intCast(s.len)), .big);
                }
                try w.writeAll(s);
            }
        };

        var out = std.ArrayListUnmanaged(u8).empty;
        for (matches) |match| {
            out.clearRetainingCapacity();
            const writer = out.writer(alloc);

            const id_payload = blk: {
                const row = if (change.new_row) |new_row|
                    new_row
                else if (change.old_row) |old_row|
                    old_row
                else
                    break :blk null;

                break :blk (row.mapGet("id") catch null) orelse null;
            };

            if (id_payload == null) {
                std.log.err("NotificationDispatcher skipping delta for {s}:{s} because row has no id", .{ change.namespace, change.collection });
                continue;
            }

            const id_payload_value = id_payload.?;
            const is_delete = change.operation == .delete;

            const encode_res = blk: {
                // {
                //   "type": "StoreDelta",
                //   "subId": <u64>,
                //   "ops": [
                //     {
                //       "op": "set" | "remove",
                //       "path": [collection, id],
                //       "value": <row> // only for set
                //     }
                //   ]
                // }
                writer.writeByte(0x83) catch break :blk false;

                encoder.writeStr(writer, "type") catch break :blk false;
                encoder.writeStr(writer, "StoreDelta") catch break :blk false;

                encoder.writeStr(writer, "subId") catch break :blk false;
                msgpack.encode(Payload.uintToPayload(match.subscription_id), writer) catch break :blk false;

                encoder.writeStr(writer, "ops") catch break :blk false;
                writer.writeByte(0x91) catch break :blk false; // array(1)

                writer.writeByte(if (is_delete) 0x82 else 0x83) catch break :blk false; // map(2|3)

                encoder.writeStr(writer, "op") catch break :blk false;
                encoder.writeStr(writer, if (is_delete) "remove" else "set") catch break :blk false;

                encoder.writeStr(writer, "path") catch break :blk false;
                writer.writeByte(0x92) catch break :blk false; // array(2)
                encoder.writeStr(writer, change.collection) catch break :blk false;
                msgpack.encode(id_payload_value, writer) catch break :blk false;

                if (!is_delete) {
                    encoder.writeStr(writer, "value") catch break :blk false;
                    msgpack.encode(change.new_row orelse Payload.nil, writer) catch break :blk false;
                }

                break :blk true;
            };

            if (!encode_res) {
                std.log.err("NotificationDispatcher delta encoding failed for {s}:{s}", .{ change.namespace, change.collection });
                continue;
            }

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
