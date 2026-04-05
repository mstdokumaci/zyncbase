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

        const msg_fixmap_5: []const u8 = "\x85"; // FixMap w/ 5 elements
        const msg_key_type: []const u8 = "\xa4type";
        const msg_val_store_delta: []const u8 = "\xaaStoreDelta";
        const msg_key_namespace: []const u8 = "\xa9namespace";
        const msg_key_collection: []const u8 = "\xacollection";
        const msg_key_value: []const u8 = "\xa5value";
        const msg_key_sub_id: []const u8 = "\xa5subId";

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

        const encode_res = blk: {
            writer.writeAll(msg_fixmap_5) catch break :blk false;
            writer.writeAll(msg_key_type) catch break :blk false;
            writer.writeAll(msg_val_store_delta) catch break :blk false;
            writer.writeAll(msg_key_namespace) catch break :blk false;
            encoder.writeStr(writer, change.namespace) catch break :blk false;
            writer.writeAll(msg_key_collection) catch break :blk false;
            encoder.writeStr(writer, change.collection) catch break :blk false;
            writer.writeAll(msg_key_value) catch break :blk false;

            const val_p = if (change.operation == .delete) Payload.nil else change.new_row orelse Payload.nil;
            msgpack.encode(val_p, writer) catch break :blk false;

            writer.writeAll(msg_key_sub_id) catch break :blk false;
            break :blk true;
        };

        if (!encode_res) {
            std.log.err("NotificationDispatcher prefix encoding failed for {s}:{s}", .{ change.namespace, change.collection });
            return;
        }

        const prefix = common.items;
        var out = std.ArrayListUnmanaged(u8).empty;
        for (matches) |match| {
            out.clearRetainingCapacity();
            out.appendSlice(alloc, prefix) catch |err| {
                std.log.err("NotificationDispatcher match append content failed: {}", .{err});
                continue;
            };
            msgpack.encode(Payload.uintToPayload(match.subscription_id), out.writer(alloc)) catch |err| {
                std.log.err("NotificationDispatcher match encode sub_id failed: {}", .{err});
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
