const std = @import("std");
const Allocator = std.mem.Allocator;

/// Unique identifier for a subscription
pub const SubscriptionId = u64;

/// Represents a query filter condition
pub const Condition = struct {
    field: []const u8,
    op: Operator,
    value: Value,

    pub const Operator = enum {
        equals,
        not_equals,
        greater_than,
        less_than,
        greater_or_equal,
        less_or_equal,
        contains,
        starts_with,
        ends_with,
    };

    pub const Value = union(enum) {
        string: []const u8,
        integer: i64,
        float: f64,
        boolean: bool,
        null_value,
    };
};

/// Query filter with AND/OR conditions
pub const QueryFilter = struct {
    conditions: []const Condition,
    or_conditions: ?[]const Condition = null,
};

/// Sort specification for a query
pub const SortSpec = struct {
    field: []const u8,
    order: Order,

    pub const Order = enum {
        asc,
        desc,
    };
};

/// Represents a subscription to a query
pub const Subscription = struct {
    id: SubscriptionId,
    namespace: []const u8,
    collection: []const u8,
    filter: QueryFilter,
    sort: ?SortSpec,
    connection_id: u64,
};

/// Represents a row in the database
pub const Row = struct {
    fields: std.StringHashMap(Condition.Value),

    pub fn init(allocator: Allocator) Row {
        return Row{
            .fields = std.StringHashMap(Condition.Value).init(allocator),
        };
    }

    pub fn deinit(self: *Row) void {
        self.fields.deinit();
    }

    pub fn get(self: *const Row, field: []const u8) ?Condition.Value {
        return self.fields.get(field);
    }

    pub fn put(self: *Row, field: []const u8, value: Condition.Value) !void {
        try self.fields.put(field, value);
    }
};

/// Represents a change to a row
pub const RowChange = struct {
    namespace: []const u8,
    collection: []const u8,
    operation: Operation,
    old_row: ?Row,
    new_row: ?Row,

    pub const Operation = enum {
        insert,
        update,
        delete,
    };
};

/// Manages subscriptions and matches row changes against them
pub const SubscriptionManager = struct {
    subscriptions: std.AutoHashMap(SubscriptionId, Subscription),
    index: std.StringHashMap(std.ArrayList(SubscriptionId)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*SubscriptionManager {
        const self = try allocator.create(SubscriptionManager);
        self.* = SubscriptionManager{
            .subscriptions = std.AutoHashMap(SubscriptionId, Subscription).init(allocator),
            .index = std.StringHashMap(std.ArrayList(SubscriptionId)).init(allocator),
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *SubscriptionManager) void {
        self.subscriptions.deinit();

        // Clean up index - free keys and lists
        var index_iter = self.index.iterator();
        while (index_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.index.deinit();
        self.allocator.destroy(self);
    }

    /// Subscribe to a query
    pub fn subscribe(self: *SubscriptionManager, sub: Subscription) !void {
        // Add to subscriptions map
        try self.subscriptions.put(sub.id, sub);

        // Build index key: namespace:collection
        const key = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}",
            .{ sub.namespace, sub.collection },
        );
        errdefer self.allocator.free(key);

        // Add to index
        const result = try self.index.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(SubscriptionId){};
        } else {
            self.allocator.free(key);
        }
        try result.value_ptr.append(self.allocator, sub.id);
    }

    /// Unsubscribe from a query
    pub fn unsubscribe(self: *SubscriptionManager, id: SubscriptionId) !void {
        // Get subscription to find its index key
        const sub = self.subscriptions.get(id) orelse return error.SubscriptionNotFound;

        // Build index key
        const key = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}",
            .{ sub.namespace, sub.collection },
        );
        defer self.allocator.free(key);

        // Remove from index
        if (self.index.getPtr(key)) |list| {
            for (list.items, 0..) |sub_id, i| {
                if (sub_id == id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }

        // Remove from subscriptions map
        _ = self.subscriptions.remove(id);
    }

    /// Find all subscriptions that match a row change
    pub fn findMatchingSubscriptions(
        self: *SubscriptionManager,
        change: RowChange,
    ) ![]SubscriptionId {
        var matches = std.ArrayList(SubscriptionId){};
        errdefer matches.deinit(self.allocator);

        // Build index key
        const key = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}",
            .{ change.namespace, change.collection },
        );
        defer self.allocator.free(key);

        // Get candidates from index
        const candidates = self.index.get(key) orelse return matches.toOwnedSlice(self.allocator);

        // Evaluate each candidate subscription
        for (candidates.items) |sub_id| {
            const sub = self.subscriptions.get(sub_id) orelse continue;

            // Evaluate filter against changed row
            const matches_filter = switch (change.operation) {
                .insert => blk: {
                    if (change.new_row) |new_row| {
                        break :blk self.evaluateFilter(sub.filter, new_row);
                    }
                    break :blk false;
                },
                .update => blk: {
                    // Check if row matched before or after update
                    const matched_before = if (change.old_row) |old_row|
                        self.evaluateFilter(sub.filter, old_row)
                    else
                        false;

                    const matches_after = if (change.new_row) |new_row|
                        self.evaluateFilter(sub.filter, new_row)
                    else
                        false;

                    // Notify if row entered, left, or changed within filter
                    break :blk matched_before or matches_after;
                },
                .delete => blk: {
                    if (change.old_row) |old_row| {
                        break :blk self.evaluateFilter(sub.filter, old_row);
                    }
                    break :blk false;
                },
            };

            if (matches_filter) {
                // Check if sort order affected
                if (sub.sort) |sort_spec| {
                    const sort_field_changed = self.sortFieldChanged(change, sort_spec.field);
                    if (sort_field_changed) {
                        try matches.append(self.allocator, sub_id);
                        continue;
                    }
                }

                try matches.append(self.allocator, sub_id);
            }
        }

        return matches.toOwnedSlice(self.allocator);
    }

    /// Evaluate a filter against a row
    pub fn evaluateFilter(self: *SubscriptionManager, filter: QueryFilter, row: Row) bool {
        _ = self;

        // Handle empty filter (matches all)
        if (filter.conditions.len == 0 and filter.or_conditions == null) {
            return true;
        }

        // Evaluate OR conditions (any must match)
        if (filter.or_conditions) |or_list| {
            for (or_list) |condition| {
                if (evaluateCondition(condition, row)) {
                    return true;
                }
            }
            return false;
        }

        // Evaluate AND conditions (all must match)
        for (filter.conditions) |condition| {
            if (!evaluateCondition(condition, row)) {
                return false;
            }
        }

        return true;
    }

    /// Check if a sort field changed in a row update
    fn sortFieldChanged(self: *SubscriptionManager, change: RowChange, sort_field: []const u8) bool {
        _ = self;

        if (change.operation != .update) {
            return false;
        }

        const old_row = change.old_row orelse return false;
        const new_row = change.new_row orelse return false;

        const old_value = old_row.get(sort_field);
        const new_value = new_row.get(sort_field);

        // If either is missing, consider it changed
        if (old_value == null and new_value == null) {
            return false;
        }
        if (old_value == null or new_value == null) {
            return true;
        }

        // Compare values
        return !valuesEqual(old_value.?, new_value.?);
    }
};

/// Evaluate a single condition against a row
fn evaluateCondition(condition: Condition, row: Row) bool {
    const field_value = row.get(condition.field) orelse return false;

    return switch (condition.op) {
        .equals => valuesEqual(field_value, condition.value),
        .not_equals => !valuesEqual(field_value, condition.value),
        .greater_than => compareValues(field_value, condition.value) > 0,
        .less_than => compareValues(field_value, condition.value) < 0,
        .greater_or_equal => compareValues(field_value, condition.value) >= 0,
        .less_or_equal => compareValues(field_value, condition.value) <= 0,
        .contains => blk: {
            if (field_value == .string and condition.value == .string) {
                break :blk std.mem.indexOf(u8, field_value.string, condition.value.string) != null;
            }
            break :blk false;
        },
        .starts_with => blk: {
            if (field_value == .string and condition.value == .string) {
                break :blk std.mem.startsWith(u8, field_value.string, condition.value.string);
            }
            break :blk false;
        },
        .ends_with => blk: {
            if (field_value == .string and condition.value == .string) {
                break :blk std.mem.endsWith(u8, field_value.string, condition.value.string);
            }
            break :blk false;
        },
    };
}

/// Compare two values for equality
fn valuesEqual(a: Condition.Value, b: Condition.Value) bool {
    if (@as(std.meta.Tag(Condition.Value), a) != @as(std.meta.Tag(Condition.Value), b)) {
        return false;
    }

    return switch (a) {
        .string => |s| std.mem.eql(u8, s, b.string),
        .integer => |i| i == b.integer,
        .float => |f| f == b.float,
        .boolean => |bool_val| bool_val == b.boolean,
        .null_value => true,
    };
}

/// Compare two values for ordering
fn compareValues(a: Condition.Value, b: Condition.Value) i8 {
    if (@as(std.meta.Tag(Condition.Value), a) != @as(std.meta.Tag(Condition.Value), b)) {
        return 0; // Can't compare different types
    }

    return switch (a) {
        .string => |s| blk: {
            const cmp = std.mem.order(u8, s, b.string);
            break :blk switch (cmp) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        },
        .integer => |i| blk: {
            if (i < b.integer) break :blk -1;
            if (i > b.integer) break :blk 1;
            break :blk 0;
        },
        .float => |f| blk: {
            if (f < b.float) break :blk -1;
            if (f > b.float) break :blk 1;
            break :blk 0;
        },
        .boolean => |bool_val| blk: {
            if (!bool_val and b.boolean) break :blk -1;
            if (bool_val and !b.boolean) break :blk 1;
            break :blk 0;
        },
        .null_value => 0,
    };
}
