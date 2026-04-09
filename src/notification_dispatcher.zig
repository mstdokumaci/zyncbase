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

/// The 23-byte constant prefix for all StoreDelta messages.
/// fixmap(3) + "type" + "StoreDelta" + "subId"
const store_delta_header: [23]u8 = .{
    0x83, // fixmap(3)
    0xa4, 't', 'y', 'p', 'e', // fixstr(4) "type"
    0xaa, 'S', 't', 'o', 'r', 'e', 'D', 'e', 'l', 't', 'a', // fixstr(10) "StoreDelta"
    0xa5, 's', 'u', 'b', 'I', 'd', // fixstr(5) "subId"
};

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
        // === Phase 1: Extract row metadata ===
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

        // === Phase 2: Match subscriptions ===
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

        // === Phase 3: Pre-encode suffix template (once per change) ===
        // This encodes: "ops": [{"op": "set"/"remove", "path": [collection, id], "value": <row>}]
        // The expensive part (msgpack.encode(new_row)) happens exactly once here.
        const suffix = encodeDeltaSuffix(
            alloc,
            change.collection,
            id_payload_value,
            is_delete,
            change.new_row,
        ) catch |err| {
            std.log.err("NotificationDispatcher failed to encode delta suffix for {s}:{s}: {}", .{ change.namespace, change.collection, err });
            return;
        };

        // === Phase 4: Per-subscriber send ===
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(alloc);

        for (matches) |match| {
            out.clearRetainingCapacity();
            const writer = out.writer(alloc);

            // Write constant header (23 bytes)
            out.appendSlice(alloc, &store_delta_header) catch |err| {
                std.log.err("NotificationDispatcher failed to write header: {}", .{err});
                continue;
            };

            // Write subscription_id (variable length: 1-9 bytes)
            msgpack.encode(Payload.uintToPayload(match.subscription_id), writer) catch |err| {
                std.log.err("NotificationDispatcher failed to encode subId {}: {}", .{ match.subscription_id, err });
                continue;
            };

            // Append pre-encoded suffix
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

/// Encodes the suffix of a StoreDelta message (everything after subId).
/// This includes: "ops", the operation array, path, and optional value.
/// Caller owns the returned slice (allocated from the arena).
pub fn encodeDeltaSuffix(
    allocator: Allocator,
    collection: []const u8,
    id_payload: Payload,
    is_delete: bool,
    new_row: ?Payload,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    // "ops": [{
    try msgpack.writeMsgPackStr(writer, "ops");
    try writer.writeByte(0x91); // fixarray(1)

    // {"op": "set"/"remove", "path": [collection, id], "value": <row>}
    // map size is 2 for delete (no "value"), 3 for set
    try writer.writeByte(if (is_delete) 0x82 else 0x83);

    // "op": "set" or "remove"
    try msgpack.writeMsgPackStr(writer, "op");
    try msgpack.writeMsgPackStr(writer, if (is_delete) "remove" else "set");

    // "path": [collection, id]
    try msgpack.writeMsgPackStr(writer, "path");
    try writer.writeByte(0x92); // fixarray(2)
    try msgpack.writeMsgPackStr(writer, collection);
    try msgpack.encode(id_payload, writer);

    // "value": <row> (only for set operations)
    if (!is_delete) {
        try msgpack.writeMsgPackStr(writer, "value");
        try msgpack.encode(new_row orelse Payload.nil, writer);
    }

    return list.toOwnedSlice(allocator);
}
