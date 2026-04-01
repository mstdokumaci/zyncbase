const std = @import("std");
const Allocator = std.mem.Allocator;
const query_parser = @import("query_parser.zig");
const QueryFilter = query_parser.QueryFilter;
const Condition = query_parser.Condition;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;

/// Unique identifier for a subscription as seen by the client
pub const SubscriptionId = u64;

/// Internal representation of a group of subscribers sharing the same Filter AST
pub const SubscriptionGroup = struct {
    id: u64,
    namespace: []const u8,
    collection: []const u8,
    filter: QueryFilter,
    /// Set of (connection_id, client_subscription_id)
    subscribers: std.AutoHashMapUnmanaged(SubscriberKey, void) = .empty,

    pub const SubscriberKey = struct {
        connection_id: u64,
        id: SubscriptionId,
    };

    pub fn deinit(self: *SubscriptionGroup, allocator: Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.collection);
        self.filter.deinit(allocator);
        self.subscribers.deinit(allocator);
    }
};

/// Represents a change to a row, emitted by the storage engine or handler
pub const RowChange = struct {
    namespace: []const u8,
    collection: []const u8,
    operation: enum { insert, update, delete },
    /// The full record (map payload) after the change. Null only for delete.
    new_row: ?Payload,
    /// The full record before the change. Null only for insert.
    old_row: ?Payload,

    pub fn deinit(self: *const RowChange, allocator: Allocator) void {
        if (self.new_row) |r| r.free(allocator);
        if (self.old_row) |r| r.free(allocator);
    }
};

pub const SubscriptionEngine = struct {
    allocator: Allocator align(16),
    /// Canonical filter string -> GroupId
    groups_by_filter: std.StringHashMapUnmanaged(u64) = .empty,
    /// group_id -> SubscriptionGroup
    groups: std.AutoHashMapUnmanaged(u64, SubscriptionGroup) = .empty,
    /// collection_key (ns:coll) -> ArrayList(GroupId)
    groups_by_collection: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u64)) = .empty,
    /// (conn_id, sub_id) -> group_id
    active_subs: std.AutoHashMapUnmanaged(SubscriptionGroup.SubscriberKey, u64) = .empty,

    next_group_id: u64 = 1,
    mutex: std.Thread.RwLock = .{},

    pub fn init(allocator: Allocator) SubscriptionEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SubscriptionEngine) void {
        var it_filter = self.groups_by_filter.iterator();
        while (it_filter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }

        var it_coll = self.groups_by_collection.iterator();
        while (it_coll.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }

        var it_groups = self.groups.valueIterator();
        while (it_groups.next()) |g| {
            g.deinit(self.allocator);
        }

        self.groups_by_filter.deinit(self.allocator);
        self.groups_by_collection.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.active_subs.deinit(self.allocator);
    }

    /// Registers a new subscriber to a query. Returns true if first sub in group.
    pub fn subscribe(
        self: *SubscriptionEngine,
        namespace: []const u8,
        collection: []const u8,
        filter: QueryFilter,
        conn_id: u64,
        sub_id: u64,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const filter_key = try toCanonicalFilterKey(self.allocator, namespace, collection, filter);
        defer self.allocator.free(filter_key);

        var group_id: u64 = 0;
        var first_in_group = false;

        if (self.groups_by_filter.get(filter_key)) |id| {
            group_id = id;
        } else {
            // Create new group
            group_id = self.next_group_id;
            self.next_group_id += 1;
            first_in_group = true;

            const ns_copy = try self.allocator.dupe(u8, namespace);
            errdefer self.allocator.free(ns_copy);
            const coll_copy = try self.allocator.dupe(u8, collection);
            errdefer self.allocator.free(coll_copy);
            const filter_copy = try filter.clone(self.allocator);
            errdefer filter_copy.deinit(self.allocator);

            const group = SubscriptionGroup{
                .id = group_id,
                .namespace = ns_copy,
                .collection = coll_copy,
                .filter = filter_copy,
            };
            try self.groups.put(self.allocator, group_id, group);
            try self.groups_by_filter.put(self.allocator, try self.allocator.dupe(u8, filter_key), group_id);

            // Index by collection
            const coll_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ namespace, collection });
            errdefer self.allocator.free(coll_key);

            const result = try self.groups_by_collection.getOrPut(self.allocator, coll_key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayListUnmanaged(u64).empty;
            } else {
                self.allocator.free(coll_key);
            }
            try result.value_ptr.append(self.allocator, group_id);
        }

        const sub_key = SubscriptionGroup.SubscriberKey{ .connection_id = conn_id, .id = sub_id };
        const group_ptr = self.groups.getPtr(group_id) orelse return error.InternalError;
        try group_ptr.subscribers.put(self.allocator, sub_key, {});
        try self.active_subs.put(self.allocator, sub_key, group_id);

        return first_in_group;
    }

    pub fn unsubscribe(self: *SubscriptionEngine, conn_id: u64, sub_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sub_key = SubscriptionGroup.SubscriberKey{ .connection_id = conn_id, .id = sub_id };
        const group_id = self.active_subs.get(sub_key) orelse return error.SubscriptionNotFound;

        const group_ptr = self.groups.getPtr(group_id) orelse return;
        _ = group_ptr.subscribers.remove(sub_key);
        _ = self.active_subs.remove(sub_key);

        if (group_ptr.subscribers.count() == 0) {
            // Group became empty - remove it
            const filter_key = try toCanonicalFilterKey(self.allocator, group_ptr.namespace, group_ptr.collection, group_ptr.filter);
            defer self.allocator.free(filter_key);

            if (self.groups_by_filter.fetchRemove(filter_key)) |entry| {
                self.allocator.free(entry.key);
            }

            // Remove from groups_by_collection
            const coll_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ group_ptr.namespace, group_ptr.collection });
            defer self.allocator.free(coll_key);

            if (self.groups_by_collection.getPtr(coll_key)) |list| {
                for (list.items, 0..) |id, i| {
                    if (id == group_id) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
                if (list.items.len == 0) {
                    if (self.groups_by_collection.fetchRemove(coll_key)) |entry| {
                        self.allocator.free(entry.key);
                        var l = entry.value;
                        l.deinit(self.allocator);
                    }
                }
            }

            // Delete group
            if (self.groups.fetchRemove(group_id)) |entry| {
                var g = entry.value;
                g.deinit(self.allocator);
            }
        }
    }

    /// Finds all subscribers matching a row change. Returns matches through a Result struct.
    pub const Match = struct {
        connection_id: u64,
        subscription_id: SubscriptionId,
    };

    pub fn handleRowChange(self: *SubscriptionEngine, change: RowChange, allocator: Allocator) ![]Match {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        var matches = std.ArrayListUnmanaged(Match).empty;
        errdefer matches.deinit(allocator);

        // Build key: namespace:collection
        var key_buf: [256]u8 = undefined;
        var heap_key: ?[]u8 = null;
        defer if (heap_key) |k| allocator.free(k);

        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ change.namespace, change.collection }) catch blk: {
            heap_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ change.namespace, change.collection });
            break :blk heap_key.?;
        };

        const group_ids = self.groups_by_collection.get(key) orelse return allocator.alloc(Match, 0);

        for (group_ids.items) |gid| {
            const group = self.groups.get(gid) orelse continue;

            // ADR-023: Notify if row entered, left, or changed within filter
            const matched_before = if (change.old_row) |old| try evaluateFilter(group.filter, old) else false;
            const matches_after = if (change.new_row) |new| try evaluateFilter(group.filter, new) else false;

            if (matched_before or matches_after) {
                // All subscribers in this group match
                var sub_it = group.subscribers.keyIterator();
                while (sub_it.next()) |sub| {
                    try matches.append(allocator, .{
                        .connection_id = sub.connection_id,
                        .subscription_id = sub.id,
                    });
                }
            }
        }

        return try matches.toOwnedSlice(allocator);
    }

    fn toCanonicalFilterKey(allocator: Allocator, ns: []const u8, coll: []const u8, filter: QueryFilter) ![]u8 {
        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        // Manual formatting to avoid complex writer setups with unmanaged
        const base = try std.fmt.allocPrint(allocator, "{s}:{s}:", .{ ns, coll });
        defer allocator.free(base);
        try list.appendSlice(allocator, base);

        if (filter.conditions) |conds| {
            for (conds) |c| {
                const val_str = if (c.value) |v| try msgpack.payloadToCanonicalString(v, allocator) else try allocator.dupe(u8, "null");
                defer allocator.free(val_str);
                const s = try std.fmt.allocPrint(allocator, "({s}:{s}:{s})", .{ c.field, @tagName(c.op), val_str });
                defer allocator.free(s);
                try list.appendSlice(allocator, s);
            }
        }
        if (filter.or_conditions) |or_conds| {
            try list.appendSlice(allocator, ":OR:");
            for (or_conds) |c| {
                const val_str = if (c.value) |v| try msgpack.payloadToCanonicalString(v, allocator) else try allocator.dupe(u8, "null");
                defer allocator.free(val_str);
                const s = try std.fmt.allocPrint(allocator, "({s}:{s}:{s})", .{ c.field, @tagName(c.op), val_str });
                defer allocator.free(s);
                try list.appendSlice(allocator, s);
            }
        }
        if (filter.limit) |l| {
            const s = try std.fmt.allocPrint(allocator, ":L:{}", .{l});
            defer allocator.free(s);
            try list.appendSlice(allocator, s);
        }
        if (filter.order_by) |ob| {
            const s = try std.fmt.allocPrint(allocator, ":O:{s}:{}", .{ ob.field, ob.desc });
            defer allocator.free(s);
            try list.appendSlice(allocator, s);
        }

        return try list.toOwnedSlice(allocator);
    }

    /// Evaluates a row (msgpack map) against a filter AST.
    pub fn evaluateFilter(filter: QueryFilter, row: Payload) !bool {
        if (row != .map) return false;

        // 1. Evaluate AND conditions (all must match)
        if (filter.conditions) |conds| {
            for (conds) |cond| {
                if (!try evaluateCondition(cond, row)) return false;
            }
        }

        // 2. Evaluate OR conditions (any must match)
        if (filter.or_conditions) |or_conds| {
            if (or_conds.len > 0) {
                var matched_any = false;
                for (or_conds) |cond| {
                    if (try evaluateCondition(cond, row)) {
                        matched_any = true;
                        break;
                    }
                }
                if (!matched_any) return false;
            }
        }

        return true;
    }

    fn evaluateCondition(cond: Condition, row: Payload) !bool {
        const val = (try row.mapGet(cond.field)) orelse {
            // Check for potential nested field that was not flattened in current row
            // (Only happens for partially updated rows during event prop)
            return cond.op == .isNull;
        };

        return switch (cond.op) {
            .eq => payloadsEqual(val, cond.value orelse return false),
            .ne => !payloadsEqual(val, cond.value orelse return true),
            .gt => comparePayloads(val, cond.value orelse return false) == .gt,
            .gte => blk: {
                const res = comparePayloads(val, cond.value orelse return false);
                break :blk res == .gt or res == .eq;
            },
            .lt => comparePayloads(val, cond.value orelse return false) == .lt,
            .lte => blk: {
                const res = comparePayloads(val, cond.value orelse return false);
                break :blk res == .lt or res == .eq;
            },
            .isNull => val == .nil,
            .isNotNull => val != .nil,
            .startsWith => blk: {
                if (val != .str or cond.value == null or cond.value.? != .str) break :blk false;
                break :blk std.ascii.startsWithIgnoreCase(val.str.value(), cond.value.?.str.value());
            },
            .endsWith => blk: {
                if (val != .str or cond.value == null or cond.value.? != .str) break :blk false;
                break :blk std.ascii.endsWithIgnoreCase(val.str.value(), cond.value.?.str.value());
            },
            .contains => blk: {
                if (val != .str or cond.value == null or cond.value.? != .str) break :blk false;
                break :blk std.ascii.indexOfIgnoreCase(val.str.value(), cond.value.?.str.value()) != null;
            },
            .in => blk: {
                if (cond.value == null or cond.value.? != .arr) break :blk false;
                for (cond.value.?.arr) |item| {
                    if (payloadsEqual(val, item)) break :blk true;
                }
                break :blk false;
            },
            .notIn => blk: {
                if (cond.value == null or cond.value.? != .arr) break :blk true;
                for (cond.value.?.arr) |item| {
                    if (payloadsEqual(val, item)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn payloadsEqual(a: Payload, b: Payload) bool {
        if (@as(std.meta.Tag(Payload), a) != @as(std.meta.Tag(Payload), b)) return false;
        return switch (a) {
            .nil => true,
            .bool => a.bool == b.bool,
            .int => a.int == b.int,
            .uint => a.uint == b.uint,
            .float => a.float == b.float,
            .str => std.mem.eql(u8, a.str.value(), b.str.value()),
            .bin => std.mem.eql(u8, a.bin.value(), b.bin.value()),
            .arr => blk: {
                if (a.arr.len != b.arr.len) break :blk false;
                for (a.arr, 0..) |item, i| {
                    if (!payloadsEqual(item, b.arr[i])) break :blk false;
                }
                break :blk true;
            },
            .map => false, // Map equality is complex and not needed for basic op codes
            .ext => false,
            .timestamp => false, // Not handled yet
        };
    }

    fn comparePayloads(a: Payload, b: Payload) std.math.Order {
        // Only same-type comparison for now to match selectQuery/SQLite
        if (@as(std.meta.Tag(Payload), a) != @as(std.meta.Tag(Payload), b)) return .lt; // Should ideally be error.TypeMismatch

        return switch (a) {
            .int => std.math.order(a.int, b.int),
            .uint => std.math.order(a.uint, b.uint),
            .float => blk: {
                if (a.float < b.float) break :blk .lt;
                if (a.float > b.float) break :blk .gt;
                break :blk .eq;
            },
            .str => std.mem.order(u8, a.str.value(), b.str.value()),
            .bin => std.mem.order(u8, a.bin.value(), b.bin.value()),
            else => .eq, // Unsortable types
        };
    }
};
