const std = @import("std");
const Allocator = std.mem.Allocator;
const query_parser = @import("query_parser.zig");
const QueryFilter = query_parser.QueryFilter;
const Condition = query_parser.Condition;
const types = @import("storage_engine/types.zig");
const TypedRow = types.TypedRow;
const TypedValue = types.TypedValue;
const schema_manager = @import("schema_manager.zig");

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
    /// The full record after the change. Null only for delete.
    new_row: ?TypedRow,
    /// The full record before the change. Null only for insert.
    old_row: ?TypedRow,

    pub fn deinit(self: *const RowChange, allocator: Allocator) void {
        if (self.new_row) |r| r.deinit(allocator);
        if (self.old_row) |r| r.deinit(allocator);
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

    pub fn handleRowChange(self: *SubscriptionEngine, change: RowChange, table_metadata: *const schema_manager.TableMetadata, allocator: Allocator) ![]Match {
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
            const matched_before = if (change.old_row) |old| try evaluateFilter(group.filter, old, table_metadata) else false;
            const matches_after = if (change.new_row) |new| try evaluateFilter(group.filter, new, table_metadata) else false;

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

    fn typedValueLessThan(_: void, a: TypedValue, b: TypedValue) bool {
        if (@as(std.meta.Tag(TypedValue), a) != @as(std.meta.Tag(TypedValue), b)) {
            return @intFromEnum(a) < @intFromEnum(b);
        }
        return switch (a) {
            .nil => false,
            .scalar => |sa| sa.order(b.scalar) == .lt,
            .array => |arr_a| blk: {
                const arr_b = b.array;
                const min_len = @min(arr_a.len, arr_b.len);
                for (0..min_len) |i| {
                    const ord = arr_a[i].order(arr_b[i]);
                    if (ord == .lt) break :blk true;
                    if (ord == .gt) break :blk false;
                }
                break :blk arr_a.len < arr_b.len;
            },
        };
    }

    fn conditionLessThan(_: void, a: Condition, b: Condition) bool {
        const f = std.mem.order(u8, a.field, b.field);
        if (f != .eq) return f == .lt;
        const o = std.math.order(@intFromEnum(a.op), @intFromEnum(b.op));
        if (o != .eq) return o == .lt;
        const va = a.value orelse return b.value != null;
        const vb = b.value orelse return false;
        return typedValueLessThan({}, va, vb);
    }

    fn appendTypedValueKey(
        allocator: Allocator,
        list: *std.ArrayListUnmanaged(u8),
        value: TypedValue,
    ) !void {
        const writer = list.writer(allocator);
        switch (value) {
            .nil => try list.append(allocator, 'n'),
            .scalar => |s| switch (s) {
                .integer => |iv| try writer.print("i:{}", .{iv}),
                .real => |rv| try writer.print("f:{}", .{rv}),
                .text => |tv| {
                    try writer.print("t:{}:", .{tv.len});
                    try list.appendSlice(allocator, tv);
                },
                .boolean => |bv| try writer.print("b:{}", .{@intFromBool(bv)}),
            },
            .array => |arr| {
                try writer.writeAll("a:[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try list.append(allocator, ',');
                    try appendTypedValueKey(allocator, list, TypedValue{ .scalar = item });
                }
                try list.append(allocator, ']');
            },
        }
    }

    fn appendSortedConditions(
        allocator: Allocator,
        list: *std.ArrayListUnmanaged(u8),
        conditions: ?[]const Condition,
        prefix: ?[]const u8,
    ) !void {
        const conds = conditions orelse return;
        if (conds.len == 0) return;

        if (prefix) |p| try list.appendSlice(allocator, p);

        const max_inline = 16;
        var inline_buf: [max_inline]Condition = undefined;
        var heap_buf: ?[]Condition = null;
        defer if (heap_buf) |buf| allocator.free(buf);

        const sorted = if (conds.len <= max_inline)
            inline_buf[0..conds.len]
        else blk: {
            const buf = try allocator.alloc(Condition, conds.len);
            heap_buf = buf;
            break :blk buf;
        };
        @memcpy(sorted, conds);

        std.sort.pdq(Condition, sorted, {}, conditionLessThan);

        const writer = list.writer(allocator);
        for (sorted) |c| {
            try writer.writeAll("(");
            try writer.writeAll(c.field);
            try writer.writeAll(":");
            try writer.writeAll(@tagName(c.op));
            try writer.writeAll(":");
            if (c.value) |v| {
                try appendTypedValueKey(allocator, list, v);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(")");
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
        {
            const ob = filter.order_by;
            const s = try std.fmt.allocPrint(allocator, ":O:{}:{}", .{ ob.field_index, ob.desc });
            defer allocator.free(s);
            try list.appendSlice(allocator, s);
        }

        return try list.toOwnedSlice(allocator);
    }

    /// Evaluates a row against a filter AST.
    pub fn evaluateFilter(filter: QueryFilter, row: TypedRow, table_metadata: *const schema_manager.TableMetadata) !bool {
        // 1. Evaluate AND conditions (all must match)
        if (filter.conditions) |conds| {
            for (conds) |cond| {
                if (!try evaluateCondition(cond, row, table_metadata)) return false;
            }
        }

        // 2. Evaluate OR conditions (any must match)
        if (filter.or_conditions) |or_conds| {
            if (or_conds.len > 0) {
                var matched_any = false;
                for (or_conds) |cond| {
                    if (try evaluateCondition(cond, row, table_metadata)) {
                        matched_any = true;
                        break;
                    }
                }
                if (!matched_any) return false;
            }
        }

        return true;
    }

    fn evaluateCondition(cond: Condition, row: TypedRow, table_metadata: *const schema_manager.TableMetadata) !bool {
        const val = blk: {
            if (cond.field_index != Condition.invalid_field_index and cond.field_index < row.values.len) {
                break :blk row.values[cond.field_index];
            }
            const idx = table_metadata.field_index_map.get(cond.field) orelse return cond.op == .isNull;
            break :blk row.values[idx];
        };

        return switch (cond.op) {
            .eq => typedValuesEqual(val, cond.value orelse return false),
            .ne => !typedValuesEqual(val, cond.value orelse return true),
            .gt => compareTypedValues(val, cond.value orelse return false) == .gt,
            .gte => blk: {
                const res = compareTypedValues(val, cond.value orelse return false);
                break :blk res == .gt or res == .eq;
            },
            .lt => compareTypedValues(val, cond.value orelse return false) == .lt,
            .lte => blk: {
                const res = compareTypedValues(val, cond.value orelse return false);
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

    fn typedValuesEqual(a: TypedValue, b: TypedValue) bool {
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

    fn compareTypedValues(a: TypedValue, b: TypedValue) std.math.Order {
        if (@as(std.meta.Tag(TypedValue), a) != @as(std.meta.Tag(TypedValue), b)) return .lt;

        return switch (a) {
            .scalar => |sa| sa.order(b.scalar),
            else => .eq, // Unsortable
        };
    }
};
