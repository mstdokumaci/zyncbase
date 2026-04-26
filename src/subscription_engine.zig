const std = @import("std");
const Allocator = std.mem.Allocator;
const query_parser = @import("query_parser.zig");
const QueryFilter = query_parser.QueryFilter;
const Condition = query_parser.Condition;
const types = @import("storage_engine/types.zig");
const TypedRow = types.TypedRow;
const TypedValue = types.TypedValue;

/// Unique identifier for a subscription as seen by the client
pub const SubscriptionId = u64;

/// Internal representation of a group of subscribers sharing the same Filter AST
pub const SubscriptionGroup = struct {
    id: u64,
    namespace_id: i64,
    table_index: usize,
    filter: QueryFilter,
    /// Set of (connection_id, client_subscription_id)
    subscribers: std.AutoHashMapUnmanaged(SubscriberKey, void) = .empty,

    pub const SubscriberKey = struct {
        connection_id: u64,
        id: SubscriptionId,
    };

    pub fn deinit(self: *SubscriptionGroup, allocator: Allocator) void {
        self.filter.deinit(allocator);
        self.subscribers.deinit(allocator);
    }
};

/// Represents a change to a row, emitted by the storage engine or handler
pub const RowChange = struct {
    pub const Operation = enum { insert, update, delete };
    namespace_id: i64,
    table_index: usize,
    operation: Operation,
    /// The full record after the change. Null only for delete.
    new_row: ?TypedRow,
    /// The full record before the change. Null only for insert.
    old_row: ?TypedRow,

    pub fn deinit(self: *const RowChange, allocator: Allocator) void {
        if (self.new_row) |r| r.deinit(allocator);
        if (self.old_row) |r| r.deinit(allocator);
    }
};

pub const CollectionKey = struct {
    namespace_id: i64,
    table_index: usize,
};

pub const CanonicalFilterContext = struct {
    pub fn hash(_: CanonicalFilterContext, f: QueryFilter) u64 {
        var hasher = std.hash.Wyhash.init(0);
        if (f.conditions) |conds| {
            var combined: u64 = 0;
            for (conds) |c| {
                var ch = std.hash.Wyhash.init(0);
                hashCondition(&ch, c);
                combined +%= ch.final();
            }
            std.hash.autoHash(&hasher, combined);
        }
        hasher.update("\x00"); // Separator
        if (f.or_conditions) |conds| {
            var combined: u64 = 0;
            for (conds) |c| {
                var ch = std.hash.Wyhash.init(0);
                hashCondition(&ch, c);
                combined +%= ch.final();
            }
            std.hash.autoHash(&hasher, combined);
        }
        hasher.update("\x00"); // Separator
        std.hash.autoHash(&hasher, f.order_by);
        std.hash.autoHash(&hasher, f.limit);
        if (f.after) |a| {
            hashTypedValue(&hasher, a.sort_value);
            std.hash.autoHash(&hasher, a.id);
        }
        return hasher.final();
    }

    pub fn eql(_: CanonicalFilterContext, a: QueryFilter, b: QueryFilter) bool {
        if (!eqlConditionsAsSets(a.conditions, b.conditions)) return false;
        if (!eqlConditionsAsSets(a.or_conditions, b.or_conditions)) return false;
        if (!std.meta.eql(a.order_by, b.order_by)) return false;
        if (a.limit != b.limit) return false;
        if (a.after == null and b.after == null) return true;
        if (a.after == null or b.after == null) return false;
        const aa = a.after.?;
        const bb = b.after.?;
        return eqlTypedValue(aa.sort_value, bb.sort_value) and std.meta.eql(aa.id, bb.id);
    }

    fn hashCondition(hasher: *std.hash.Wyhash, c: Condition) void {
        std.hash.autoHash(hasher, c.field_index);
        std.hash.autoHash(hasher, c.op);
        if (c.value) |v| hashTypedValue(hasher, v);
        std.hash.autoHash(hasher, c.field_type);
        std.hash.autoHash(hasher, c.items_type);
    }

    fn hashTypedValue(hasher: *std.hash.Wyhash, v: TypedValue) void {
        std.hash.autoHash(hasher, std.meta.activeTag(v));
        switch (v) {
            .scalar => |s| hashScalarValue(hasher, s),
            .array => |arr| {
                for (arr) |item| hashScalarValue(hasher, item);
            },
            .nil => {},
        }
    }

    fn hashScalarValue(hasher: *std.hash.Wyhash, s: types.ScalarValue) void {
        std.hash.autoHash(hasher, std.meta.activeTag(s));
        switch (s) {
            .text => |t| hasher.update(t),
            .doc_id => |id| std.hash.autoHash(hasher, id),
            .integer => |i| std.hash.autoHash(hasher, i),
            .real => |r| std.hash.autoHash(hasher, @as(u64, @bitCast(r))),
            .boolean => |b| std.hash.autoHash(hasher, b),
        }
    }
};

fn eqlTypedValue(a: TypedValue, b: TypedValue) bool {
    const tag = std.meta.activeTag(a);
    if (tag != std.meta.activeTag(b)) return false;
    return switch (a) {
        .scalar => |s| eqlScalarValue(s, b.scalar),
        .array => |arr| blk: {
            if (arr.len != b.array.len) break :blk false;
            for (arr, 0..) |item, i| {
                if (!eqlScalarValue(item, b.array[i])) break :blk false;
            }
            break :blk true;
        },
        .nil => true,
    };
}

fn eqlScalarValue(a: types.ScalarValue, b: types.ScalarValue) bool {
    const tag = std.meta.activeTag(a);
    if (tag != std.meta.activeTag(b)) return false;
    return switch (a) {
        .text => |t| std.mem.eql(u8, t, b.text),
        .real => |r| blk: {
            // Standard Zig 0.15 behavior for f64 comparison
            break :blk r == b.real;
        },
        else => std.meta.eql(a, b),
    };
}

fn eqlConditionsAsSets(a: ?[]const Condition, b: ?[]const Condition) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const aa = a.?;
    const bb = b.?;
    if (aa.len != bb.len) return false;
    var matched = std.bit_set.StaticBitSet(64).initEmpty();
    var count: usize = 0;
    for (aa) |ca| {
        for (bb, 0..) |cb, i| {
            if (i < 64 and !matched.isSet(i) and eqlCondition(ca, cb)) {
                matched.set(i);
                count += 1;
                break;
            }
        }
    }
    return count == aa.len;
}

fn eqlCondition(a: Condition, b: Condition) bool {
    if (a.field_index != b.field_index) return false;
    if (a.op != b.op) return false;
    if (a.field_type != b.field_type) return false;
    if (a.items_type != b.items_type) return false;
    if (a.value == null and b.value == null) return true;
    if (a.value == null or b.value == null) return false;
    return eqlTypedValue(a.value.?, b.value.?);
}

pub const SubscriptionEngine = struct {
    allocator: Allocator align(16),
    /// filter -> GroupId
    groups_by_filter: std.HashMapUnmanaged(QueryFilter, u64, CanonicalFilterContext, 80) = .empty,
    /// group_id -> SubscriptionGroup
    groups: std.AutoHashMapUnmanaged(u64, SubscriptionGroup) = .empty,
    /// collection_key -> ArrayList(GroupId)
    groups_by_collection: std.AutoHashMapUnmanaged(CollectionKey, std.ArrayListUnmanaged(u64)) = .empty,
    /// (conn_id, sub_id) -> group_id
    active_subs: std.AutoHashMapUnmanaged(SubscriptionGroup.SubscriberKey, u64) = .empty,
    next_group_id: u64 = 1,
    mutex: std.Thread.RwLock = .{},

    pub fn init(allocator: Allocator) SubscriptionEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SubscriptionEngine) void {
        self.groups_by_filter.deinit(self.allocator);

        var it_coll = self.groups_by_collection.valueIterator();
        while (it_coll.next()) |entry| {
            entry.deinit(self.allocator);
        }
        self.groups_by_collection.deinit(self.allocator);

        var it_groups = self.groups.valueIterator();
        while (it_groups.next()) |g| {
            g.deinit(self.allocator);
        }
        self.groups.deinit(self.allocator);
        self.active_subs.deinit(self.allocator);
    }

    /// Registers a new subscriber to a query. Returns true if first sub in group.
    pub fn subscribe(
        self: *SubscriptionEngine,
        namespace_id: i64,
        table_index: usize,
        filter: QueryFilter,
        conn_id: u64,
        sub_id: u64,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sub_key = SubscriptionGroup.SubscriberKey{ .connection_id = conn_id, .id = sub_id };

        // Check if subscriber already active
        if (self.active_subs.contains(sub_key)) return error.AlreadySubscribed;

        const coll_key = CollectionKey{ .namespace_id = namespace_id, .table_index = table_index };

        var group_id: u64 = 0;
        var first_sub = false;

        if (self.groups_by_filter.get(filter)) |gid| {
            group_id = gid;
        } else {
            // Create new group
            group_id = self.next_group_id;
            self.next_group_id += 1;
            first_sub = true;

            const cloned_filter = try filter.clone(self.allocator);
            errdefer cloned_filter.deinit(self.allocator);

            var group = SubscriptionGroup{
                .id = group_id,
                .namespace_id = namespace_id,
                .table_index = table_index,
                .filter = cloned_filter,
            };
            try group.subscribers.put(self.allocator, sub_key, {});
            try self.groups.put(self.allocator, group_id, group);
            try self.groups_by_filter.put(self.allocator, cloned_filter, group_id);

            // Index by collection
            const gop = try self.groups_by_collection.getOrPut(self.allocator, coll_key);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayListUnmanaged(u64).empty;
            }
            try gop.value_ptr.append(self.allocator, group_id);
        }

        if (!first_sub) {
            var group = self.groups.getPtr(group_id) orelse unreachable;
            try group.subscribers.put(self.allocator, sub_key, {});
        }

        try self.active_subs.put(self.allocator, sub_key, group_id);
        return first_sub;
    }

    pub fn unsubscribe(self: *SubscriptionEngine, conn_id: u64, sub_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sub_key = SubscriptionGroup.SubscriberKey{ .connection_id = conn_id, .id = sub_id };
        const group_id = self.active_subs.fetchRemove(sub_key) orelse return;

        var group = self.groups.getPtr(group_id.value) orelse unreachable;
        _ = group.subscribers.remove(sub_key);

        if (group.subscribers.count() == 0) {
            // Group empty, cleanup
            _ = self.groups_by_filter.remove(group.filter);
            const coll_key = CollectionKey{ .namespace_id = group.namespace_id, .table_index = group.table_index };
            if (self.groups_by_collection.getPtr(coll_key)) |list| {
                for (list.items, 0..) |gid, i| {
                    if (gid == group_id.value) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
                if (list.items.len == 0) {
                    list.deinit(self.allocator);
                    _ = self.groups_by_collection.remove(coll_key);
                }
            }
            group.deinit(self.allocator);
            _ = self.groups.remove(group_id.value);
            return;
        }
    }

    pub fn unsubscribeConnection(self: *SubscriptionEngine, conn_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.active_subs.iterator();
        var to_remove = std.ArrayList(SubscriptionGroup.SubscriberKey).init(self.allocator);
        defer to_remove.deinit();

        while (it.next()) |entry| {
            if (entry.key_ptr.connection_id == conn_id) {
                to_remove.append(entry.key_ptr.*) catch |err| {
                    std.log.err("Failed to append to to_remove: {}", .{err});
                    continue;
                };
            }
        }

        for (to_remove.items) |key| {
            const group_id = self.active_subs.fetchRemove(key) orelse unreachable;
            var group = self.groups.getPtr(group_id.value) orelse unreachable;
            _ = group.subscribers.remove(key);

            if (group.subscribers.count() == 0) {
                _ = self.groups_by_filter.remove(group.filter);
                const coll_key = CollectionKey{ .namespace_id = group.namespace_id, .table_index = group.table_index };
                if (self.groups_by_collection.getPtr(coll_key)) |list| {
                    for (list.items, 0..) |gid, i| {
                        if (gid == group_id.value) {
                            _ = list.swapRemove(i);
                            break;
                        }
                    }
                    if (list.items.len == 0) {
                        list.deinit(self.allocator);
                        _ = self.groups_by_collection.remove(coll_key);
                    }
                }
                group.deinit(self.allocator);
                _ = self.groups.remove(group_id.value);
            }
        }
    }

    pub fn match(self: *SubscriptionEngine, change: RowChange) ![]const u64 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const coll_key = CollectionKey{ .namespace_id = change.namespace_id, .table_index = change.table_index };
        const group_ids = self.groups_by_collection.get(coll_key) orelse return &[_]u64{};

        var matched = std.ArrayList(u64).init(self.allocator);
        errdefer matched.deinit();

        for (group_ids.items) |gid| {
            const group = self.groups.get(gid) orelse unreachable;
            if (try evaluateFilterForChangeInternal(group.filter, change)) {
                try matched.append(gid);
            }
        }

        return matched.toOwnedSlice();
    }

    pub fn getSubscribers(self: *SubscriptionEngine, group_id: u64) ![]SubscriptionGroup.SubscriberKey {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const group = self.groups.get(group_id) orelse return error.GroupNotFound;
        var subs = std.ArrayList(SubscriptionGroup.SubscriberKey).init(self.allocator);
        errdefer subs.deinit();

        var it = group.subscribers.keyIterator();
        while (it.next()) |k| {
            try subs.append(k.*);
        }

        return subs.toOwnedSlice();
    }

    pub const SubscriptionQuery = struct {
        namespace_id: i64,
        table_index: usize,
        filter: QueryFilter,

        pub fn deinit(self: *SubscriptionQuery, allocator: Allocator) void {
            self.filter.deinit(allocator);
        }
    };

    /// Returns a safe, cloned query context for a subscriber.
    /// Caller owns the returned data and must call `deinit`.
    pub fn getSubscriptionQuery(
        self: *SubscriptionEngine,
        allocator: Allocator,
        sub_key: SubscriptionGroup.SubscriberKey,
    ) !?SubscriptionQuery {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const group_id = self.active_subs.get(sub_key) orelse return null;
        const group = self.groups.get(group_id) orelse return null;

        var filter_copy = try group.filter.clone(allocator);
        errdefer filter_copy.deinit(allocator);

        return SubscriptionQuery{
            .namespace_id = group.namespace_id,
            .table_index = group.table_index,
            .filter = filter_copy,
        };
    }

    /// Finds all subscribers matching a row change. Returns matches through a Result struct.
    pub const MatchOp = enum { set_op, remove };

    pub const Match = struct {
        connection_id: u64,
        subscription_id: SubscriptionId,
        op: MatchOp,
    };

    pub fn handleRowChange(self: *SubscriptionEngine, change: RowChange, allocator: Allocator) ![]Match {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        var matches = std.ArrayListUnmanaged(Match).empty;
        errdefer matches.deinit(allocator);

        const key: CollectionKey = .{
            .namespace_id = change.namespace_id,
            .table_index = change.table_index,
        };

        const group_ids = self.groups_by_collection.get(key) orelse return allocator.alloc(Match, 0);

        for (group_ids.items) |gid| {
            const group = self.groups.get(gid) orelse continue;

            const matched_before = if (change.old_row) |old| try SubscriptionEngine.evaluateFilter(group.filter, old) else false;
            const matches_after = if (change.new_row) |new| try SubscriptionEngine.evaluateFilter(group.filter, new) else false;

            if (matched_before and !matches_after) {
                // Row left the filter: send remove
                var sub_it = group.subscribers.keyIterator();
                while (sub_it.next()) |sub| {
                    try matches.append(allocator, .{
                        .connection_id = sub.connection_id,
                        .subscription_id = sub.id,
                        .op = .remove,
                    });
                }
            } else if (matches_after) {
                // Row now matches the filter: send set.
                // Covers both "row entered the filter" (!matched_before)
                // and "row changed within the filter" (matched_before).
                var sub_it = group.subscribers.keyIterator();
                while (sub_it.next()) |sub| {
                    try matches.append(allocator, .{
                        .connection_id = sub.connection_id,
                        .subscription_id = sub.id,
                        .op = .set_op,
                    });
                }
            }
        }

        return try matches.toOwnedSlice(allocator);
    }

    /// Evaluates a row against a filter AST.
    pub fn evaluateFilter(filter: QueryFilter, row: TypedRow) !bool {
        return evaluateFilterInternal(filter, row);
    }
};

fn evaluateFilterInternal(filter: QueryFilter, row: TypedRow) !bool {
    // 1. Evaluate AND conditions (all must match)
    if (filter.conditions) |conds| {
        for (conds) |cond| {
            if (!try evaluateConditionInternal(cond, row)) return false;
        }
    }

    // 2. Evaluate OR conditions (any must match)
    if (filter.or_conditions) |or_conds| {
        if (or_conds.len > 0) {
            var matched_any = false;
            for (or_conds) |cond| {
                if (try evaluateConditionInternal(cond, row)) {
                    matched_any = true;
                    break;
                }
            }
            if (!matched_any) return false;
        }
    }

    return true;
}

fn evaluateConditionInternal(cond: Condition, row: TypedRow) !bool {
    if (cond.field_index >= row.values.len) return cond.op == .isNull;
    const val = row.values[cond.field_index];

    return switch (cond.op) {
        .eq => typedValuesEqualInternal(val, cond.value orelse return false),
        .ne => !typedValuesEqualInternal(val, cond.value orelse return true),
        .gt => compareTypedValuesInternal(val, cond.value orelse return false) == .gt,
        .gte => blk: {
            const res = compareTypedValuesInternal(val, cond.value orelse return false);
            break :blk res == .gt or res == .eq;
        },
        .lt => compareTypedValuesInternal(val, cond.value orelse return false) == .lt,
        .lte => blk: {
            const res = compareTypedValuesInternal(val, cond.value orelse return false);
            break :blk res == .lt or res == .eq;
        },
        .isNull => val == .nil,
        .isNotNull => val != .nil,
        .startsWith => blk: {
            if (val != .scalar or val.scalar != .text) break :blk false;
            if (cond.value == null or cond.value.? != .scalar or cond.value.?.scalar != .text) break :blk false;
            break :blk std.ascii.startsWithIgnoreCase(val.scalar.text, cond.value.?.scalar.text);
        },
        .endsWith => blk: {
            if (val != .scalar or val.scalar != .text) break :blk false;
            if (cond.value == null or cond.value.? != .scalar or cond.value.?.scalar != .text) break :blk false;
            break :blk std.ascii.endsWithIgnoreCase(val.scalar.text, cond.value.?.scalar.text);
        },
        .contains => blk: {
            if (cond.field_type == .array) {
                if (val != .array) break :blk false;
                if (cond.value == null) break :blk false;
                if (cond.value.? != .scalar) break :blk false;
                break :blk std.sort.binarySearch(types.ScalarValue, val.array, cond.value.?.scalar, types.ScalarValue.order) != null;
            } else {
                if (val != .scalar or val.scalar != .text) break :blk false;
                if (cond.value == null or cond.value.? != .scalar or cond.value.?.scalar != .text) break :blk false;
                break :blk std.ascii.indexOfIgnoreCase(val.scalar.text, cond.value.?.scalar.text) != null;
            }
        },
        .in => blk: {
            if (val != .scalar) break :blk false;
            if (cond.value == null or cond.value.? != .array) break :blk false;
            break :blk std.sort.binarySearch(types.ScalarValue, cond.value.?.array, val.scalar, types.ScalarValue.order) != null;
        },
        .notIn => blk: {
            if (val != .scalar) break :blk true;
            if (cond.value == null or cond.value.? != .array) break :blk false;
            break :blk std.sort.binarySearch(types.ScalarValue, cond.value.?.array, val.scalar, types.ScalarValue.order) == null;
        },
    };
}

fn typedValuesEqualInternal(a: TypedValue, b: TypedValue) bool {
    if (@as(std.meta.Tag(TypedValue), a) != @as(std.meta.Tag(TypedValue), b)) return false;
    return switch (a) {
        .nil => true,
        .scalar => a.scalar.order(b.scalar) == .eq,
        .array => |arr| blk: {
            if (arr.len != b.array.len) break :blk false;
            for (arr, 0..) |item, i| {
                if (item.order(b.array[i]) != .eq) break :blk false;
            }
            break :blk true;
        },
    };
}

fn compareTypedValuesInternal(a: TypedValue, b: TypedValue) std.math.Order {
    if (@as(std.meta.Tag(TypedValue), a) != @as(std.meta.Tag(TypedValue), b)) return .lt;

    return switch (a) {
        .scalar => |sa| sa.order(b.scalar),
        else => .eq, // Unsortable
    };
}

fn evaluateFilterForChangeInternal(filter: QueryFilter, change: RowChange) !bool {
    if (filter.conditions == null and filter.or_conditions == null) return true;

    if (filter.conditions) |conds| {
        for (conds) |c| {
            if (!try evaluateConditionForChangeInternal(c, change)) return false;
        }
        if (filter.or_conditions == null) return true;
    }

    if (filter.or_conditions) |or_conds| {
        for (or_conds) |c| {
            if (try evaluateConditionForChangeInternal(c, change)) return true;
        }
        return false;
    }

    return true;
}

fn evaluateConditionForChangeInternal(c: Condition, change: RowChange) !bool {
    const row = change.new_row orelse return false;
    if (c.field_index >= row.values.len) return false;

    const val = row.values[c.field_index];
    return switch (c.op) {
        .eq => typedValuesEqualInternal(val, c.value orelse return false),
        .ne => !typedValuesEqualInternal(val, c.value orelse return true),
        else => false,
    };
}
