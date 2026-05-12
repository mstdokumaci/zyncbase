const std = @import("std");
const Allocator = std.mem.Allocator;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MatchOp = SubscriptionEngine.MatchOp;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const OwnedRecordChange = @import("change_buffer.zig").OwnedRecordChange;
const RecordChange = @import("subscription_engine.zig").RecordChange;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const wire = @import("wire.zig");
const schema = @import("schema.zig");

pub const NotificationDispatcher = struct {
    change_buffer: *ChangeBuffer,
    subscription_engine: *SubscriptionEngine,
    memory_strategy: *MemoryStrategy,
    schema_manager: *const schema.Schema,
    allocator: Allocator,
    drain_buf: std.ArrayListUnmanaged(OwnedRecordChange) = .empty,

    pub fn init(self: *NotificationDispatcher, allocator: Allocator, change_buffer: *ChangeBuffer, subscription_engine: *SubscriptionEngine, memory_strategy: *MemoryStrategy, sm: *const schema.Schema) !void {
        self.* = .{
            .change_buffer = change_buffer,
            .subscription_engine = subscription_engine,
            .memory_strategy = memory_strategy,
            .schema_manager = sm,
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

    fn dispatchChange(self: *NotificationDispatcher, change: OwnedRecordChange, cm: *ConnectionManager) void {
        const table_metadata = self.schema_manager.getTableByIndex(change.table_index) orelse {
            std.log.err("NotificationDispatcher skipping delta for unknown table index {d}", .{change.table_index});
            return;
        };

        // === Phase 1: Extract record metadata ===
        const record_change = RecordChange{
            .namespace_id = change.namespace_id,
            .table_index = change.table_index,
            .operation = @enumFromInt(@intFromEnum(change.operation)),
            .new_record = change.new_record,
            .old_record = change.old_record,
        };

        const id_val = if (change.new_record orelse change.old_record) |record|
            if (record.values.len > schema.id_field_index) record.values[schema.id_field_index] else null
        else
            null;

        if (id_val == null) {
            std.log.err("NotificationDispatcher skipping delta for namespace {d}, table {d} because record has no id", .{ change.namespace_id, change.table_index });
            return;
        }

        const id_val_actual = id_val.?;

        // === Phase 2: Match subscriptions ===
        const arena = self.memory_strategy.acquireArena() catch |err| {
            std.log.err("NotificationDispatcher acquireArena failed: {}", .{err});
            return;
        };
        defer self.memory_strategy.releaseArena(arena);
        const alloc = arena.allocator();

        const matches = self.subscription_engine.handleRecordChange(record_change, alloc) catch |err| {
            std.log.err("NotificationDispatcher handleRecordChange failed: {}", .{err});
            return;
        };

        if (matches.len == 0) return;

        // === Phase 3: Pre-encode suffix templates (once per change) ===
        // For updates, some subscribers may need "set" while others need "remove"
        // (record left their filter). Pre-encode both and pick per-match.

        var set_suffix: ?[]const u8 = null;
        var remove_suffix: ?[]const u8 = null;

        // Pre-encode set and remove suffixes if any match needs them
        for (matches) |match| {
            if (set_suffix == null and match.op == MatchOp.set_op) {
                const new_record = change.new_record orelse {
                    std.log.err("NotificationDispatcher skipping set delta for namespace {d}, table {d} because new_record is missing", .{ change.namespace_id, change.table_index });
                    return;
                };
                set_suffix = wire.encodeSetDeltaSuffix(
                    alloc,
                    table_metadata.index,
                    id_val_actual,
                    new_record,
                    table_metadata,
                ) catch |err| {
                    std.log.err("NotificationDispatcher failed to encode set suffix for namespace {d}, table {d}: {}", .{ change.namespace_id, change.table_index, err });
                    return;
                };
            }
            if (remove_suffix == null and match.op == MatchOp.remove) {
                remove_suffix = wire.encodeDeleteDeltaSuffix(
                    alloc,
                    table_metadata.index,
                    id_val_actual,
                ) catch |err| {
                    std.log.err("NotificationDispatcher failed to encode remove suffix for namespace {d}, table {d}: {}", .{ change.namespace_id, change.table_index, err });
                    return;
                };
            }
            if (set_suffix != null and remove_suffix != null) break;
        }

        // === Phase 4: Per-subscriber send ===
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(alloc);

        for (matches) |match| {
            out.clearRetainingCapacity();
            const writer = out.writer(alloc);

            // Write constant header (23 bytes)
            out.appendSlice(alloc, &wire.store_delta_header) catch |err| {
                std.log.err("NotificationDispatcher failed to write header: {}", .{err});
                continue;
            };

            // Write subscription_id (variable length: 1-9 bytes)
            msgpack.encode(Payload.uintToPayload(match.subscription_id), writer) catch |err| {
                std.log.err("NotificationDispatcher failed to encode subId {}: {}", .{ match.subscription_id, err });
                continue;
            };

            // Append pre-encoded suffix based on match operation
            const suffix = switch (match.op) {
                MatchOp.set_op => set_suffix orelse continue,
                MatchOp.remove => remove_suffix orelse continue,
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

            conn.trySendDelta(out.items) catch |err| switch (err) {
                error.Dropped => {
                    std.log.warn("Connection {} dropped by uWS, closing", .{match.connection_id});
                    conn.ws.close();
                },
                error.Full => {
                    std.log.warn("Connection {} outbox full (slow client), closing", .{match.connection_id});
                    conn.ws.close();
                },
                else => {
                    std.log.err("Connection {} unexpected send error: {}", .{ match.connection_id, err });
                    conn.ws.close();
                },
            };
        }
    }

    pub fn deinit(self: *NotificationDispatcher) void {
        for (self.drain_buf.items) |*change| change.deinit(self.allocator);
        self.drain_buf.deinit(self.allocator);
    }
};
