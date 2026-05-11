const std = @import("std");
const Allocator = std.mem.Allocator;
const query_ast = @import("query_ast.zig");
const filter_eval = @import("filter_eval.zig");
const QueryFilter = query_ast.QueryFilter;
const Condition = query_ast.Condition;
const typed = @import("typed.zig");
const Record = typed.Record;
const Value = typed.Value;

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

/// Represents a change to a record, emitted by the storage engine or handler
pub const RecordChange = struct {
    pub const Operation = enum { insert, update, delete };
    namespace_id: i64,
    table_index: usize,
    operation: Operation,
    /// The full record after the change. Null only for delete.
    new_record: ?Record,
    /// The full record before the change. Null only for insert.
    old_record: ?Record,

    pub fn deinit(self: *const RecordChange, allocator: Allocator) void {
        if (self.new_record) |r| r.deinit(allocator);
        if (self.old_record) |r| r.deinit(allocator);
    }
};

pub const CollectionKey = struct {
    namespace_id: i64,
    table_index: usize,
};

pub const CanonicalFilterContext = struct {
    pub fn hash(_: CanonicalFilterContext, f: QueryFilter) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, f.predicate.state);
        hasher.update("\x00"); // Separator
        if (f.predicate.conditions) |conds| {
            var combined: u64 = 0;
            for (conds) |c| {
                var ch = std.hash.Wyhash.init(0);
                hashCondition(&ch, c);
                combined +%= ch.final();
            }
            std.hash.autoHash(&hasher, combined);
        }
        hasher.update("\x00"); // Separator
        if (f.predicate.or_conditions) |conds| {
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
            hashValue(&hasher, a.sort_value);
            std.hash.autoHash(&hasher, a.id);
        }
        return hasher.final();
    }

    pub fn eql(_: CanonicalFilterContext, a: QueryFilter, b: QueryFilter) bool {
        if (a.predicate.state != b.predicate.state) return false;
        if (!eqlConditionsAsSets(a.predicate.conditions, b.predicate.conditions)) return false;
        if (!eqlConditionsAsSets(a.predicate.or_conditions, b.predicate.or_conditions)) return false;
        if (!std.meta.eql(a.order_by, b.order_by)) return false;
        if (a.limit != b.limit) return false;
        if (a.after == null and b.after == null) return true;
        if (a.after == null or b.after == null) return false;
        const aa = a.after.?;
        const bb = b.after.?;
        return eqlValue(aa.sort_value, bb.sort_value) and std.meta.eql(aa.id, bb.id);
    }

    fn hashCondition(hasher: *std.hash.Wyhash, c: Condition) void {
        std.hash.autoHash(hasher, c.field_index);
        std.hash.autoHash(hasher, c.op);
        if (c.value) |v| hashValue(hasher, v);
        std.hash.autoHash(hasher, c.field_type);
        std.hash.autoHash(hasher, c.items_type);
    }

    fn hashValue(hasher: *std.hash.Wyhash, v: Value) void {
        std.hash.autoHash(hasher, std.meta.activeTag(v));
        switch (v) {
            .scalar => |s| hashScalarValue(hasher, s),
            .array => |arr| {
                for (arr) |item| hashScalarValue(hasher, item);
            },
            .nil => {},
        }
    }

    fn hashScalarValue(hasher: *std.hash.Wyhash, s: typed.ScalarValue) void {
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

fn eqlValue(a: Value, b: Value) bool {
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

fn eqlScalarValue(a: typed.ScalarValue, b: typed.ScalarValue) bool {
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
    return eqlValue(a.value.?, b.value.?);
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

            var cloned_filter = try filter.clone(self.allocator);
            var cloned_filter_owned = true;
            errdefer if (cloned_filter_owned) cloned_filter.deinit(self.allocator);

            var group = SubscriptionGroup{
                .id = group_id,
                .namespace_id = namespace_id,
                .table_index = table_index,
                .filter = cloned_filter,
            };
            cloned_filter_owned = false;
            var group_owned = true;
            errdefer if (group_owned) group.deinit(self.allocator);

            try group.subscribers.put(self.allocator, sub_key, {});
            try self.groups.put(self.allocator, group_id, group);
            group_owned = false;
            errdefer {
                if (self.groups.getPtr(group_id)) |inserted_group| inserted_group.deinit(self.allocator);
                _ = self.groups.remove(group_id);
            }

            try self.groups_by_filter.put(self.allocator, cloned_filter, group_id);
            errdefer {
                _ = self.groups_by_filter.remove(cloned_filter);
            }

            // Index by collection
            const gop = try self.groups_by_collection.getOrPut(self.allocator, coll_key);
            var collection_created = false;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayListUnmanaged(u64).empty;
                collection_created = true;
            }
            errdefer if (collection_created) {
                if (self.groups_by_collection.getPtr(coll_key)) |list| list.deinit(self.allocator);
                _ = self.groups_by_collection.remove(coll_key);
            };
            try gop.value_ptr.append(self.allocator, group_id);
            errdefer {
                self.removeGroupFromCollectionIndex(coll_key, group_id);
            }
        }

        if (!first_sub) {
            var group = self.groups.getPtr(group_id) orelse unreachable;
            try group.subscribers.put(self.allocator, sub_key, {});
            errdefer _ = group.subscribers.remove(sub_key);
        }

        try self.active_subs.put(self.allocator, sub_key, group_id);
        return first_sub;
    }

    fn removeGroupFromCollectionIndex(self: *SubscriptionEngine, coll_key: CollectionKey, group_id: u64) void {
        if (self.groups_by_collection.getPtr(coll_key)) |list| {
            for (list.items, 0..) |gid, i| {
                if (gid == group_id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                _ = self.groups_by_collection.remove(coll_key);
            }
        }
    }

    pub fn unsubscribe(self: *SubscriptionEngine, conn_id: u64, sub_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.removeSubscriberLocked(.{ .connection_id = conn_id, .id = sub_id });
    }

    pub fn unsubscribeMany(self: *SubscriptionEngine, conn_id: u64, sub_ids: []const u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (sub_ids) |sub_id| {
            self.removeSubscriberLocked(.{ .connection_id = conn_id, .id = sub_id });
        }
    }

    fn removeSubscriberLocked(self: *SubscriptionEngine, sub_key: SubscriptionGroup.SubscriberKey) void {
        const group_id = self.active_subs.fetchRemove(sub_key) orelse return;

        var group = self.groups.getPtr(group_id.value) orelse unreachable;
        _ = group.subscribers.remove(sub_key);

        if (group.subscribers.count() == 0) {
            _ = self.groups_by_filter.remove(group.filter);
            const coll_key = CollectionKey{ .namespace_id = group.namespace_id, .table_index = group.table_index };
            self.removeGroupFromCollectionIndex(coll_key, group_id.value);
            group.deinit(self.allocator);
            _ = self.groups.remove(group_id.value);
        }
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

    /// Finds all subscribers matching a record change. Returns matches through a Result struct.
    pub const MatchOp = enum { set_op, remove };

    pub const Match = struct {
        connection_id: u64,
        subscription_id: SubscriptionId,
        op: MatchOp,
    };

    pub fn handleRecordChange(self: *SubscriptionEngine, change: RecordChange, allocator: Allocator) ![]Match {
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

            const matched_before = if (change.old_record) |old| try SubscriptionEngine.evaluateFilter(&group.filter, &old) else false;
            const matches_after = if (change.new_record) |new| try SubscriptionEngine.evaluateFilter(&group.filter, &new) else false;

            if (matched_before and !matches_after) {
                // Record left the filter: send remove
                var sub_it = group.subscribers.keyIterator();
                while (sub_it.next()) |sub| {
                    try matches.append(allocator, .{
                        .connection_id = sub.connection_id,
                        .subscription_id = sub.id,
                        .op = .remove,
                    });
                }
            } else if (matches_after) {
                // Record now matches the filter: send set.
                // Covers both "record entered the filter" (!matched_before)
                // and "record changed within the filter" (matched_before).
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

    /// Evaluates a record against a filter AST.
    pub fn evaluateFilter(filter: *const QueryFilter, record: *const Record) !bool {
        return filter_eval.evaluatePredicate(&filter.predicate, record);
    }
};
