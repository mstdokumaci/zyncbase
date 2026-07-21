const std = @import("std");
const Allocator = std.mem.Allocator;
const query_ast = @import("../query/ast.zig");
const query_eval = @import("../query/eval.zig");
const hash_context = @import("../query/hash_context.zig");
const QueryFilter = query_ast.QueryFilter;
const Condition = query_ast.Condition;
const OrClause = query_ast.OrClause;
const typed = @import("../typed/types.zig");
const Record = typed.Record;
const predicate_dag = @import("predicate_dag.zig");
const PredicateDag = predicate_dag.PredicateDag;

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
                hash_context.hashCondition(&ch, c);
                combined +%= ch.final();
            }
            std.hash.autoHash(&hasher, combined);
        }
        hasher.update("\x00"); // Separator
        if (f.predicate.or_clauses) |clauses| {
            std.hash.autoHash(&hasher, clauses.len);
            for (clauses) |clause| {
                var combined: u64 = 0;
                for (clause) |c| {
                    var ch = std.hash.Wyhash.init(0);
                    hash_context.hashCondition(&ch, c);
                    combined +%= ch.final();
                }
                std.hash.autoHash(&hasher, combined);
            }
        }
        hasher.update("\x00"); // Separator
        std.hash.autoHash(&hasher, f.order_by);
        std.hash.autoHash(&hasher, f.limit);
        if (f.after) |a| {
            hash_context.hashValue(&hasher, a.sort_value);
            std.hash.autoHash(&hasher, a.id);
        }
        return hasher.final();
    }

    pub fn eql(_: CanonicalFilterContext, a: QueryFilter, b: QueryFilter) bool {
        if (a.predicate.state != b.predicate.state) return false;
        if (!eqlConditionsSorted(a.predicate.conditions, b.predicate.conditions)) return false;
        if (!eqlOrClauses(a.predicate.or_clauses, b.predicate.or_clauses)) return false;
        if (!std.meta.eql(a.order_by, b.order_by)) return false;
        if (a.limit != b.limit) return false;
        if (a.after == null and b.after == null) return true;
        if (a.after == null or b.after == null) return false;
        const aa = a.after.?;
        const bb = b.after.?;
        return aa.sort_value.eql(bb.sort_value) and std.meta.eql(aa.id, bb.id);
    }
};

fn eqlConditionsSorted(a: ?[]const Condition, b: ?[]const Condition) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const aa = a.?;
    const bb = b.?;
    if (aa.len != bb.len) return false;
    for (aa, 0..) |ca, i| {
        if (!hash_context.eqlCondition(ca, bb[i])) return false;
    }
    return true;
}

fn eqlOrClauses(a: ?[]const OrClause, b: ?[]const OrClause) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const aa = a.?;
    const bb = b.?;
    if (aa.len != bb.len) return false;
    for (aa, 0..) |clause_a, i| {
        if (!eqlConditionsSorted(clause_a, bb[i])) return false;
    }
    return true;
}

pub const SubscriptionEngine = struct {
    allocator: Allocator align(16),
    /// filter -> GroupId
    groups_by_filter: std.HashMapUnmanaged(QueryFilter, u64, CanonicalFilterContext, 80) = .empty,
    /// group_id -> SubscriptionGroup
    groups: std.AutoHashMapUnmanaged(u64, SubscriptionGroup) = .empty,
    /// collection_key -> ArrayList(GroupId)
    groups_by_collection: std.AutoHashMapUnmanaged(CollectionKey, std.ArrayListUnmanaged(u64)) = .empty,
    /// collection_key -> condition-prefix trie used for change matching
    dags_by_collection: std.AutoHashMapUnmanaged(CollectionKey, PredicateDag) = .empty,
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

        var it_dags = self.dags_by_collection.valueIterator();
        while (it_dags.next()) |dag| {
            dag.deinit();
        }
        self.dags_by_collection.deinit(self.allocator);

        var it_groups = self.groups.valueIterator();
        while (it_groups.next()) |g| {
            g.deinit(self.allocator);
        }
        self.groups.deinit(self.allocator);
        self.active_subs.deinit(self.allocator);
    }

    const GroupCreationResult = struct {
        group_id: u64,
        first_sub: bool,
    };

    /// Creates a new subscription group, clones the filter, and inserts into all indexes.
    /// Caller (subscribe) is responsible for registering the subscriber in active_subs.
    fn createSubscriptionGroup(
        self: *SubscriptionEngine,
        namespace_id: i64,
        table_index: usize,
        filter: QueryFilter,
        sub_key: SubscriptionGroup.SubscriberKey,
    ) !GroupCreationResult {
        const group_id = self.next_group_id;
        self.next_group_id += 1;

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

        const coll_key = CollectionKey{ .namespace_id = namespace_id, .table_index = table_index };
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
        errdefer self.removeGroupFromCollectionIndex(coll_key, group_id);

        // Insert into the per-collection condition-prefix trie.
        const grp_for_dag = self.groups.getPtr(group_id) orelse return error.GroupNotFound;
        const dag_gop = try self.dags_by_collection.getOrPut(self.allocator, coll_key);
        if (!dag_gop.found_existing) {
            dag_gop.value_ptr.* = PredicateDag.init(self.allocator);
        }
        errdefer {
            if (self.dags_by_collection.getPtr(coll_key)) |dag| {
                dag.removeGroup(group_id, &grp_for_dag.filter);
                if (dag.isEmpty()) {
                    dag.deinit();
                    _ = self.dags_by_collection.remove(coll_key);
                }
            }
        }
        _ = try dag_gop.value_ptr.insertGroup(group_id, &grp_for_dag.filter);

        return .{ .group_id = group_id, .first_sub = true };
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
        var subscriber_in_group = false;

        if (self.groups_by_filter.get(filter)) |gid| {
            group_id = gid;
        } else {
            const result = try self.createSubscriptionGroup(
                namespace_id,
                table_index,
                filter,
                sub_key,
            );
            group_id = result.group_id;
            first_sub = result.first_sub;
            subscriber_in_group = true;
        }

        if (!first_sub) {
            var group = self.groups.getPtr(group_id) orelse return error.GroupNotFound;
            try group.subscribers.put(self.allocator, sub_key, {});
            subscriber_in_group = true;
        }

        errdefer if (subscriber_in_group) {
            if (self.groups.getPtr(group_id)) |grp| {
                _ = grp.subscribers.remove(sub_key);
                if (first_sub and grp.subscribers.count() == 0) {
                    self.destroyGroupLocked(coll_key, group_id, grp);
                }
            }
        };

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

    fn removeGroupFromDag(self: *SubscriptionEngine, coll_key: CollectionKey, group_id: u64, filter: *const QueryFilter) void {
        if (self.dags_by_collection.getPtr(coll_key)) |dag| {
            dag.removeGroup(group_id, filter);
            if (dag.isEmpty()) {
                dag.deinit();
                _ = self.dags_by_collection.remove(coll_key);
            }
        }
    }

    /// Tears down a group with zero subscribers from all indexes. Consumes `group`.
    fn destroyGroupLocked(
        self: *SubscriptionEngine,
        coll_key: CollectionKey,
        group_id: u64,
        group: *SubscriptionGroup,
    ) void {
        _ = self.groups_by_filter.remove(group.filter);
        self.removeGroupFromDag(coll_key, group_id, &group.filter);
        self.removeGroupFromCollectionIndex(coll_key, group_id);
        group.deinit(self.allocator);
        _ = self.groups.remove(group_id);
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
            const coll_key = CollectionKey{ .namespace_id = group.namespace_id, .table_index = group.table_index };
            self.destroyGroupLocked(coll_key, group_id.value, group);
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

        const dag = self.dags_by_collection.getPtr(key) orelse return allocator.alloc(Match, 0);

        var matched_before_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer matched_before_ids.deinit(allocator);
        var matched_after_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer matched_after_ids.deinit(allocator);

        if (change.old_record) |old| {
            try dag.collectMatches(&old, &matched_before_ids, allocator);
            try self.filterResidualMatches(&matched_before_ids, &old, allocator);
        }
        if (change.new_record) |new| {
            try dag.collectMatches(&new, &matched_after_ids, allocator);
            try self.filterResidualMatches(&matched_after_ids, &new, allocator);
        }

        // Union of candidate group ids (AND path + residual OR passed).
        var candidate_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer candidate_ids.deinit(allocator);
        var before_it = matched_before_ids.keyIterator();
        while (before_it.next()) |gid| try candidate_ids.put(allocator, gid.*, {});
        var after_it = matched_after_ids.keyIterator();
        while (after_it.next()) |gid| try candidate_ids.put(allocator, gid.*, {});

        var cand_it = candidate_ids.keyIterator();
        while (cand_it.next()) |gid_ptr| {
            const gid = gid_ptr.*;
            const group = self.groups.get(gid) orelse continue;

            const matched_before = matched_before_ids.contains(gid);
            const matches_after = matched_after_ids.contains(gid);

            if (matched_before and !matches_after) {
                var sub_it = group.subscribers.keyIterator();
                while (sub_it.next()) |sub| {
                    try matches.append(allocator, .{
                        .connection_id = sub.connection_id,
                        .subscription_id = sub.id,
                        .op = .remove,
                    });
                }
            } else if (matches_after) {
                // Record entered the filter or changed within it.
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

    /// Drop trie candidates whose residual OR clauses fail (AND path already proven).
    fn filterResidualMatches(
        self: *const SubscriptionEngine,
        candidates: *std.AutoHashMapUnmanaged(u64, void),
        record: *const Record,
        allocator: Allocator,
    ) !void {
        var to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer to_remove.deinit(allocator);

        var it = candidates.keyIterator();
        while (it.next()) |gid_ptr| {
            const gid = gid_ptr.*;
            const group = self.groups.get(gid) orelse {
                try to_remove.append(allocator, gid);
                continue;
            };
            if (!try predicate_dag.residualMatches(&group.filter.predicate, record)) {
                try to_remove.append(allocator, gid);
            }
        }
        for (to_remove.items) |gid| {
            _ = candidates.remove(gid);
        }
    }

    /// Evaluates a record against a filter AST.
    pub fn evaluateFilter(filter: *const QueryFilter, record: *const Record) !bool {
        return query_eval.evaluatePredicate(&filter.predicate, record);
    }
};
