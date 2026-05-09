const std = @import("std");
const schema = @import("schema.zig");
const typed = @import("typed.zig");
const Value = typed.Value;
const Cursor = typed.Cursor;

pub const Operator = enum(u8) {
    eq = 0,
    ne = 1,
    gt = 2,
    lt = 3,
    gte = 4,
    lte = 5,
    contains = 6,
    startsWith = 7,
    endsWith = 8,
    in = 9,
    notIn = 10,
    isNull = 11,
    isNotNull = 12,
};

pub const Condition = struct {
    field_index: usize,
    op: Operator,
    value: ?Value,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,

    pub fn deinit(self: Condition, allocator: std.mem.Allocator) void {
        if (self.value) |v| v.deinit(allocator);
    }

    pub fn clone(self: Condition, allocator: std.mem.Allocator) !Condition {
        return .{
            .field_index = self.field_index,
            .op = self.op,
            .value = if (self.value) |v| try v.clone(allocator) else null,
            .field_type = self.field_type,
            .items_type = self.items_type,
        };
    }
};

pub const SortDescriptor = struct {
    field_index: usize,
    desc: bool,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
};

pub const FilterPredicate = struct {
    conditions: ?[]const Condition = null,
    or_conditions: ?[]const Condition = null,

    pub fn isEmpty(self: FilterPredicate) bool {
        const conds_empty = self.conditions == null or self.conditions.?.len == 0;
        const or_empty = self.or_conditions == null or self.or_conditions.?.len == 0;
        return conds_empty and or_empty;
    }

    pub fn deinit(self: FilterPredicate, allocator: std.mem.Allocator) void {
        if (self.conditions) |conds| {
            for (conds) |c| c.deinit(allocator);
            allocator.free(conds);
        }
        if (self.or_conditions) |or_conds| {
            for (or_conds) |c| c.deinit(allocator);
            allocator.free(or_conds);
        }
    }

    pub fn clone(self: FilterPredicate, allocator: std.mem.Allocator) !FilterPredicate {
        return .{
            .conditions = try cloneConditions(allocator, self.conditions),
            .or_conditions = try cloneConditions(allocator, self.or_conditions),
        };
    }
};

pub const QueryFilter = struct {
    predicate: FilterPredicate = .{},
    order_by: SortDescriptor,
    limit: ?u32 = null,
    after: ?Cursor = null,

    pub fn deinit(self: QueryFilter, allocator: std.mem.Allocator) void {
        var mutable = self;
        mutable.predicate.deinit(allocator);
        if (mutable.after) |*a| a.deinit(allocator);
    }

    pub fn clone(self: QueryFilter, allocator: std.mem.Allocator) !QueryFilter {
        var copy = self;
        copy.predicate = try self.predicate.clone(allocator);
        errdefer copy.predicate.deinit(allocator);
        copy.order_by = self.order_by;
        if (self.after) |a| {
            copy.after = try a.clone(allocator);
        }
        return copy;
    }
};

fn cloneConditions(allocator: std.mem.Allocator, conditions: ?[]const Condition) !?[]const Condition {
    const conds = conditions orelse return null;
    const cloned = try allocator.alloc(Condition, conds.len);
    var initialized_count: usize = 0;
    errdefer {
        for (cloned[0..initialized_count]) |c| c.deinit(allocator);
        allocator.free(cloned);
    }
    for (conds, 0..) |condition, i| {
        cloned[i] = try condition.clone(allocator);
        initialized_count += 1;
    }
    return cloned;
}
