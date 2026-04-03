const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const storage_mod = @import("storage_engine.zig");
const StorageEngine = storage_mod.StorageEngine;
const ColumnValue = storage_mod.ColumnValue;
const ManagedPayload = storage_mod.ManagedPayload;
const subscription_mod = @import("subscription_engine.zig");
const SubscriptionEngine = subscription_mod.SubscriptionEngine;
const RowChange = subscription_mod.RowChange;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

/// WriteCoordinator orchestrates the write path:
/// 1. Fetching old state for context
/// 2. Performing optimistic merging
/// 3. Materializing full row for storage engine (preventing data loss)
/// 4. Notifying subscribers immediately
pub const WriteCoordinator = struct {
    allocator: Allocator,
    storage_engine: *StorageEngine,
    subscription_engine: *SubscriptionEngine,
    connection_manager: ?*ConnectionManager = null,
    memory_strategy: *MemoryStrategy,

    pub fn init(
        allocator: Allocator,
        storage_engine: *StorageEngine,
        subscription_engine: *SubscriptionEngine,
        memory_strategy: *MemoryStrategy,
    ) !*WriteCoordinator {
        const self = try allocator.create(WriteCoordinator);
        self.* = .{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .subscription_engine = subscription_engine,
            .memory_strategy = memory_strategy,
            .connection_manager = null,
        };
        return self;
    }

    pub fn deinit(self: *WriteCoordinator) void {
        self.allocator.destroy(self);
    }

    pub fn setConnectionManager(self: *WriteCoordinator, cm: *ConnectionManager) void {
        self.connection_manager = cm;
    }

    pub fn coordinateSet(
        self: *WriteCoordinator,
        arena: Allocator,
        namespace: []const u8,
        table: []const u8,
        doc_id: []const u8,
        fields: []const ColumnValue,
    ) !void {
        std.log.debug("coordinateSet: table='{s}', id='{s}'", .{ table, doc_id });

        // 1. Fetch current state (hits metadata cache first, so it's fast/optimistic)
        var managed_old = self.storage_engine.selectDocument(arena, table, doc_id, namespace) catch |err| if (err == error.NotFound)
            ManagedPayload{ .value = null, .allocator = arena }
        else
            return err;
        defer managed_old.deinit();

        const old_row = managed_old.value;

        // 2. Perform optimistic merge to compute new state for notifications
        const new_row = try self.mergeRow(arena, old_row, fields);
        defer new_row.free(arena);

        const old_row_cloned = if (old_row) |o| try o.deepClone(arena) else null;
        errdefer {
            if (old_row_cloned) |o| o.free(arena);
        }
        const new_row_cloned = try new_row.deepClone(arena);
        errdefer new_row_cloned.free(arena);

        const change = RowChange{
            .namespace = namespace,
            .collection = table,
            .operation = if (old_row != null) .update else .insert,
            .old_row = old_row_cloned,
            .new_row = new_row_cloned,
        };
        defer change.deinit(arena);

        try self.broadcastChange(arena, change);
        try self.storage_engine.insertOrReplace(table, doc_id, namespace, fields);
    }

    /// Coordinates a StoreRemove operation.
    pub fn coordinateRemove(
        self: *WriteCoordinator,
        arena: Allocator,
        namespace: []const u8,
        table: []const u8,
        doc_id: []const u8,
        field_to_remove: ?[]const u8,
    ) !void {
        // 1. Fetch current state
        var managed_old = self.storage_engine.selectDocument(arena, table, doc_id, namespace) catch |err| {
            std.log.debug("Optimistic fetch failed for remove: {}", .{err});
            return;
        };
        defer managed_old.deinit();

        const old_row = managed_old.value;

        if (field_to_remove) |field| {
            // Partial removal (field removal). StorageEngine.updateField is safe/non-destructive.
            try self.storage_engine.updateField(table, doc_id, namespace, field, .nil);

            const new_row = if (old_row) |old| try self.removeFieldFromRow(arena, old, field) else null;
            defer {
                if (new_row) |nr| nr.free(arena);
            }

            const old_row_cloned = if (old_row) |o| try o.deepClone(arena) else null;
            errdefer {
                if (old_row_cloned) |o| o.free(arena);
            }
            const new_row_cloned = if (new_row) |nr| try nr.deepClone(arena) else null;
            errdefer {
                if (new_row_cloned) |nr| nr.free(arena);
            }

            const change = RowChange{
                .namespace = namespace,
                .collection = table,
                .operation = .update,
                .old_row = old_row_cloned,
                .new_row = new_row_cloned,
            };
            defer change.deinit(arena);
            try self.broadcastChange(arena, change);
        } else {
            // Full document delete
            const old_row_actual = old_row orelse return;
            const old_row_cloned = try old_row_actual.deepClone(arena);
            errdefer old_row_cloned.free(arena);

            const change = RowChange{
                .namespace = namespace,
                .collection = table,
                .operation = .delete,
                .old_row = old_row_cloned,
                .new_row = null,
            };
            defer change.deinit(arena);

            try self.broadcastChange(arena, change);
            try self.storage_engine.deleteDocument(table, doc_id, namespace);
        }
    }

    fn broadcastChange(self: *WriteCoordinator, arena: Allocator, change: RowChange) !void {
        const matches = try self.subscription_engine.handleRowChange(change, arena);
        if (matches.len == 0) return;

        const cm = self.connection_manager orelse return;

        // 1. Build the common message prefix once.
        // A StoreDelta message has 5 keys: type, namespace, collection, value, and subscription_id.
        // We encode the first 4 pairs and the key of the 5th pair once.
        var common = std.ArrayListUnmanaged(u8).empty;
        defer common.deinit(arena);
        const writer = common.writer(arena);

        // FixMap header for 5 elements (0x80 | 5)
        try writer.writeByte(0x85);

        // Pre-create payloads for keys to avoid redundant arena allocations
        const type_k = try Payload.strToPayload("type", arena);
        defer type_k.free(arena);
        const type_v = try Payload.strToPayload("StoreDelta", arena);
        defer type_v.free(arena);
        const ns_k = try Payload.strToPayload("namespace", arena);
        defer ns_k.free(arena);
        const ns_v = try Payload.strToPayload(change.namespace, arena);
        defer ns_v.free(arena);
        const coll_k = try Payload.strToPayload("collection", arena);
        defer coll_k.free(arena);
        const coll_v = try Payload.strToPayload(change.collection, arena);
        defer coll_v.free(arena);
        const val_k = try Payload.strToPayload("value", arena);
        defer val_k.free(arena);
        const sub_k = try Payload.strToPayload("subscription_id", arena);
        defer sub_k.free(arena);

        // Encode common pairs
        try msgpack.encode(type_k, writer);
        try msgpack.encode(type_v, writer);

        try msgpack.encode(ns_k, writer);
        try msgpack.encode(ns_v, writer);

        try msgpack.encode(coll_k, writer);
        try msgpack.encode(coll_v, writer);

        try msgpack.encode(val_k, writer);
        const value_p = if (change.operation == .delete) .nil else change.new_row orelse .nil;
        try msgpack.encode(value_p, writer);

        // Encode the key for subscription_id; the value is recipient-specific
        try msgpack.encode(sub_k, writer);

        const prefix = common.items;

        // 2. Broadcast to all matching connections
        // Reuse a single buffer for the per-recipient assembly
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(arena);
        for (matches) |match| {
            out.clearRetainingCapacity();
            try out.appendSlice(arena, prefix);
            try msgpack.encode(Payload.uintToPayload(match.subscription_id), out.writer(arena));

            const conn = cm.acquireConnection(match.connection_id) catch |err| {
                std.log.debug("Failed to acquire connection {} for notification: {}", .{ match.connection_id, err });
                continue;
            };
            defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

            conn.ws.send(out.items, .binary);
        }
    }

    pub fn mergeRow(self: *WriteCoordinator, arena: Allocator, old_row: ?Payload, fields: []const ColumnValue) !Payload {
        _ = self;
        var new_map = msgpack.Payload.mapPayload(arena);
        errdefer new_map.free(arena);

        // 1. Copy over old row state
        if (old_row) |old| {
            if (old == .map) {
                var it = old.map.iterator();
                while (it.next()) |entry| {
                    const cloned_val = try entry.value_ptr.*.deepClone(arena);
                    errdefer cloned_val.free(arena);
                    try new_map.mapPut(entry.key_ptr.*.str.value(), cloned_val);
                }
            }
        }

        // 2. Apply new fields
        for (fields) |col| {
            const cloned_val = try col.value.deepClone(arena);
            errdefer cloned_val.free(arena);
            try new_map.mapPut(col.name, cloned_val);
        }

        return new_map;
    }

    fn removeFieldFromRow(self: *WriteCoordinator, arena: Allocator, row: Payload, field: []const u8) !Payload {
        _ = self;
        if (row != .map) return try row.deepClone(arena);

        var new_map = msgpack.Payload.mapPayload(arena);
        errdefer new_map.free(arena);

        var it = row.map.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*.str.value();
            if (std.mem.eql(u8, key, field)) continue;
            const cloned_val = try entry.value_ptr.*.deepClone(arena);
            errdefer cloned_val.free(arena);
            try new_map.mapPut(key, cloned_val);
        }
        return new_map;
    }
};
