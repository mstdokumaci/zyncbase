const std = @import("std");
const Allocator = std.mem.Allocator;
const query_parser = @import("query_parser.zig");
const schema_manager = @import("schema_manager.zig");
const QueryFilter = query_parser.QueryFilter;
const Condition = query_parser.Condition;
const CanonicalValue = query_parser.CanonicalValue;
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

            // Shared filter for the group must NOT contain cursor state.
            var group_filter = try filter.clone(self.allocator);
            errdefer group_filter.deinit(self.allocator);
            if (group_filter.after) |after_cursor| {
                after_cursor.deinit(self.allocator);
                group_filter.after = null;
            }

            const group = SubscriptionGroup{
                .id = group_id,
                .namespace = ns_copy,
                .collection = coll_copy,
                .filter = group_filter,
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

    pub const SubscriptionQuery = struct {
        namespace: []const u8,
        collection: []const u8,
        filter: QueryFilter,

        pub fn deinit(self: *SubscriptionQuery, allocator: Allocator) void {
            allocator.free(self.namespace);
            allocator.free(self.collection);
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

        const ns_copy = try allocator.dupe(u8, group.namespace);
        errdefer allocator.free(ns_copy);

        const coll_copy = try allocator.dupe(u8, group.collection);
        errdefer allocator.free(coll_copy);

        var filter_copy = try group.filter.clone(allocator);
        errdefer filter_copy.deinit(allocator);

        return SubscriptionQuery{
            .namespace = ns_copy,
            .collection = coll_copy,
            .filter = filter_copy,
        };
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

    const SortableCondition = struct {
        cond: Condition,
        val_str: []const u8,

        fn lessThan(_: void, a: SortableCondition, b: SortableCondition) bool {
            const f = std.mem.order(u8, a.cond.field, b.cond.field);
            if (f != .eq) return f == .lt;
            const o = std.math.order(@intFromEnum(a.cond.op), @intFromEnum(b.cond.op));
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.val_str, b.val_str) == .lt;
        }
    };

    fn appendSortedConditions(
        allocator: Allocator,
        list: *std.ArrayListUnmanaged(u8),
        conditions: ?[]const Condition,
        prefix: ?[]const u8,
    ) !void {
        const conds = conditions orelse return;
        if (conds.len == 0) return;

        if (prefix) |p| try list.appendSlice(allocator, p);

        var sortable = try allocator.alloc(SortableCondition, conds.len);
        defer allocator.free(sortable);

        var count: usize = 0;
        errdefer {
            for (0..count) |i| allocator.free(@constCast(sortable[i].val_str));
        }

        for (conds) |c| {
            const val_str = try conditionOperandKey(allocator, c);
            sortable[count] = .{ .cond = c, .val_str = val_str };
            count += 1;
        }

        std.sort.pdq(SortableCondition, sortable, {}, SortableCondition.lessThan);

        for (sortable) |sc| {
            const s = try std.fmt.allocPrint(allocator, "({s}:{s}:{s})", .{ sc.cond.field, @tagName(sc.cond.op), sc.val_str });
            defer allocator.free(s);
            try list.appendSlice(allocator, s);
            allocator.free(@constCast(sc.val_str));
        }
    }

    fn toCanonicalFilterKey(allocator: Allocator, ns: []const u8, coll: []const u8, filter: QueryFilter) ![]u8 {
        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        // Manual formatting to avoid complex writer setups with unmanaged
        const base = try std.fmt.allocPrint(allocator, "{s}:{s}:", .{ ns, coll });
        defer allocator.free(base);
        try list.appendSlice(allocator, base);

        try appendSortedConditions(allocator, &list, filter.conditions, null);
        try appendSortedConditions(allocator, &list, filter.or_conditions, ":OR:");

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
        const val = (try row.mapGet(cond.field)) orelse return cond.op == .isNull;

        if (cond.normalized and cond.field_type != null) {
            return evaluateConditionNormalized(cond, val);
        }

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

    fn evaluateConditionNormalized(cond: Condition, val: Payload) bool {
        const ft = cond.field_type orelse return false;
        return switch (cond.op) {
            .eq => payloadEqualsCanonical(ft, val, cond.canonical_value orelse return false),
            .ne => !payloadEqualsCanonical(ft, val, cond.canonical_value orelse return true),
            .gt => payloadCompareCanonical(ft, val, cond.canonical_value orelse return false) == .gt,
            .gte => blk: {
                const ord = payloadCompareCanonical(ft, val, cond.canonical_value orelse return false);
                break :blk ord == .gt or ord == .eq;
            },
            .lt => payloadCompareCanonical(ft, val, cond.canonical_value orelse return false) == .lt,
            .lte => blk: {
                const ord = payloadCompareCanonical(ft, val, cond.canonical_value orelse return false);
                break :blk ord == .lt or ord == .eq;
            },
            .isNull => val == .nil,
            .isNotNull => val != .nil,
            .startsWith => blk: {
                const rhs = cond.canonical_value orelse return false;
                if (rhs != .text or val != .str) break :blk false;
                break :blk std.ascii.startsWithIgnoreCase(val.str.value(), rhs.text);
            },
            .endsWith => blk: {
                const rhs = cond.canonical_value orelse return false;
                if (rhs != .text or val != .str) break :blk false;
                break :blk std.ascii.endsWithIgnoreCase(val.str.value(), rhs.text);
            },
            .contains => blk: {
                const rhs = cond.canonical_value orelse return false;
                if (rhs != .text or val != .str) break :blk false;
                break :blk std.ascii.indexOfIgnoreCase(val.str.value(), rhs.text) != null;
            },
            .in => blk: {
                if (cond.canonical_list) |items| {
                    for (items) |item| {
                        if (payloadEqualsCanonical(ft, val, item)) break :blk true;
                    }
                    break :blk false;
                }
                if (cond.canonical_value) |item| break :blk payloadEqualsCanonical(ft, val, item);
                break :blk false;
            },
            .notIn => blk: {
                if (cond.canonical_list) |items| {
                    for (items) |item| {
                        if (payloadEqualsCanonical(ft, val, item)) break :blk false;
                    }
                    break :blk true;
                }
                if (cond.canonical_value) |item| break :blk !payloadEqualsCanonical(ft, val, item);
                break :blk true;
            },
        };
    }

    fn payloadEqualsCanonical(ft: schema_manager.FieldType, lhs: Payload, rhs: CanonicalValue) bool {
        return switch (ft) {
            .text => lhs == .str and rhs == .text and std.mem.eql(u8, lhs.str.value(), rhs.text),
            .integer => switch (rhs) {
                .integer => |ri| switch (lhs) {
                    .int => |li| li == ri,
                    .uint => |lu| std.math.cast(i64, lu) != null and std.math.cast(i64, lu).? == ri,
                    else => false,
                },
                .nil => lhs == .nil,
                else => false,
            },
            .real => switch (rhs) {
                .real => |rr| switch (lhs) {
                    .float => |lf| lf == rr,
                    .int => |li| @as(f64, @floatFromInt(li)) == rr,
                    .uint => |lu| @as(f64, @floatFromInt(lu)) == rr,
                    else => false,
                },
                .nil => lhs == .nil,
                else => false,
            },
            .boolean => switch (rhs) {
                .boolean => |rb| lhs == .bool and lhs.bool == rb,
                .nil => lhs == .nil,
                else => false,
            },
            .array => false,
        };
    }

    fn payloadCompareCanonical(ft: schema_manager.FieldType, lhs: Payload, rhs: CanonicalValue) std.math.Order {
        return switch (ft) {
            .text => switch (rhs) {
                .text => |rt| if (lhs == .str) std.mem.order(u8, lhs.str.value(), rt) else .lt,
                else => .lt,
            },
            .integer => switch (rhs) {
                .integer => |ri| switch (lhs) {
                    .int => |li| std.math.order(li, ri),
                    .uint => |lu| if (std.math.cast(i64, lu)) |li| std.math.order(li, ri) else .gt,
                    else => .lt,
                },
                else => .lt,
            },
            .real => switch (rhs) {
                .real => |rr| blk: {
                    const lf: f64 = switch (lhs) {
                        .float => |v| v,
                        .int => |v| @floatFromInt(v),
                        .uint => |v| @floatFromInt(v),
                        else => break :blk .lt,
                    };
                    if (lf < rr) break :blk .lt;
                    if (lf > rr) break :blk .gt;
                    break :blk .eq;
                },
                else => .lt,
            },
            else => .lt,
        };
    }

    fn conditionOperandKey(allocator: Allocator, cond: Condition) ![]const u8 {
        if (cond.canonical_list) |items| {
            var rendered = try allocator.alloc([]const u8, items.len);
            var count: usize = 0;
            errdefer {
                while (count > 0) : (count -= 1) allocator.free(@constCast(rendered[count - 1]));
                allocator.free(rendered);
            }
            for (items, 0..) |item, i| {
                rendered[i] = try canonicalValueKey(allocator, item);
                count += 1;
            }
            std.sort.pdq([]const u8, rendered, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
            var list = std.ArrayListUnmanaged(u8).empty;
            errdefer list.deinit(allocator);
            try list.append(allocator, '[');
            for (rendered, 0..) |k, i| {
                if (i > 0) try list.appendSlice(allocator, ",");
                try list.appendSlice(allocator, k);
                allocator.free(@constCast(k));
            }
            allocator.free(rendered);
            try list.append(allocator, ']');
            return list.toOwnedSlice(allocator);
        }
        if (cond.canonical_value) |v| {
            return canonicalValueKey(allocator, v);
        }
        if (cond.value) |v| return msgpack.encodeBase64(allocator, v);
        return allocator.dupe(u8, "null");
    }

    fn canonicalValueKey(allocator: Allocator, v: CanonicalValue) ![]u8 {
        return switch (v) {
            .integer => |i| std.fmt.allocPrint(allocator, "i:{d}", .{i}),
            .real => |r| std.fmt.allocPrint(allocator, "r:{x}", .{@as(u64, @bitCast(r))}),
            .text => |s| std.fmt.allocPrint(allocator, "s:{s}", .{s}),
            .boolean => |b| allocator.dupe(u8, if (b) "b:1" else "b:0"),
            .nil => allocator.dupe(u8, "n"),
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
