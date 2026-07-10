const std = @import("std");
const schema = @import("schema.zig");
const typed = @import("typed.zig");
const Value = typed.Value;
const ScalarValue = typed.ScalarValue;
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

    /// Returns true for operators that take no right-hand side operand.
    pub fn isNullary(self: Operator) bool {
        return switch (self) {
            .isNull, .isNotNull => true,
            else => false,
        };
    }

    /// Evaluate a nullary operator against a resolved LHS value.
    /// Caller must ensure `self.isNullary()` is true.
    pub fn compareNullary(self: Operator, val: Value) bool {
        return switch (self) {
            .isNull => val == .nil,
            .isNotNull => val != .nil,
            else => unreachable,
        };
    }

    /// Evaluate a binary operator given resolved LHS and RHS values.
    /// Returns false for type mismatches rather than erroring.
    pub fn compare(self: Operator, lhs: Value, rhs: Value) bool {
        return switch (self) {
            .eq => lhs.eql(rhs),
            .ne => !lhs.eql(rhs),
            .gt => lhs.order(rhs) == .gt,
            .gte => blk: {
                const ord = lhs.order(rhs);
                break :blk ord == .gt or ord == .eq;
            },
            .lt => lhs.order(rhs) == .lt,
            .lte => blk: {
                const ord = lhs.order(rhs);
                break :blk ord == .lt or ord == .eq;
            },
            .startsWith => blk: {
                if (lhs != .scalar or lhs.scalar != .text) break :blk false;
                if (rhs != .scalar or rhs.scalar != .text) break :blk false;
                break :blk std.ascii.startsWithIgnoreCase(lhs.scalar.text, rhs.scalar.text);
            },
            .endsWith => blk: {
                if (lhs != .scalar or lhs.scalar != .text) break :blk false;
                if (rhs != .scalar or rhs.scalar != .text) break :blk false;
                break :blk std.ascii.endsWithIgnoreCase(lhs.scalar.text, rhs.scalar.text);
            },
            .in => blk: {
                if (lhs != .scalar) break :blk false;
                if (rhs != .array) break :blk false;
                break :blk std.sort.binarySearch(ScalarValue, rhs.array, lhs.scalar, ScalarValue.order) != null;
            },
            .notIn => blk: {
                if (lhs != .scalar) break :blk false;
                if (rhs != .array) break :blk false;
                break :blk std.sort.binarySearch(ScalarValue, rhs.array, lhs.scalar, ScalarValue.order) == null;
            },
            .contains => blk: {
                // array.contains(scalar): binary search
                if (lhs == .array and rhs == .scalar)
                    break :blk std.sort.binarySearch(ScalarValue, lhs.array, rhs.scalar, ScalarValue.order) != null;
                // text.contains(text): case-insensitive substring
                if (lhs == .scalar and lhs.scalar == .text and rhs == .scalar and rhs.scalar == .text)
                    break :blk std.ascii.indexOfIgnoreCase(lhs.scalar.text, rhs.scalar.text) != null;
                break :blk false;
            },
            .isNull, .isNotNull => unreachable, // use compareNullary
        };
    }
};

/// The value shape an operator expects for a given field type.
///
/// This is the single source of truth shared by the query parser (which
/// decodes a raw MessagePack operand into a `Value`) and the authorization
/// predicate validator (which checks the shape of an already-parsed literal
/// `Value`). Deriving both from this predicate guarantees that a condition a
/// client query can send is also one an authorization rule may express, and
/// vice versa — eliminating the divergent op × field-type matrix that
/// previously let a rule validate while the equivalent query failed to parse.
pub const ValueShape = enum {
    /// Operator takes no right-hand side operand (isNull / isNotNull).
    nullary,
    /// A single scalar of the field's storage type (eq / ne / gt / lt / … on a
    /// scalar field).
    scalar,
    /// A `.text` scalar specifically (startsWith / endsWith).
    scalar_text,
    /// An array of scalars of the field's storage type (in / notIn). Array
    /// fields are rejected for membership operators.
    array_membership,
    /// An array of element scalars of the field's items type (eq / ne on an
    /// array field).
    array_field,
    /// `contains` on an array field expects a single element scalar (items_type).
    contains_element,
    /// `contains` on a text field expects a `.text` scalar.
    contains_text,
};

/// Returns the value shape `op` expects for `field_type` / `items_type`, or
/// `UnsupportedOperatorForFieldType` when the combination is not permitted.
pub fn operatorExpectsValueShape(
    op: Operator,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
) error{UnsupportedOperatorForFieldType}!ValueShape {
    _ = items_type;
    switch (op) {
        .isNull, .isNotNull => return .nullary,
        .startsWith, .endsWith => {
            if (field_type != .text) return error.UnsupportedOperatorForFieldType;
            return .scalar_text;
        },
        .contains => switch (field_type) {
            .text => return .contains_text,
            .array => return .contains_element,
            else => return error.UnsupportedOperatorForFieldType,
        },
        .in, .notIn => {
            if (field_type == .array) return error.UnsupportedOperatorForFieldType;
            return .array_membership;
        },
        .gt, .gte, .lt, .lte => {
            if (field_type == .array) return error.UnsupportedOperatorForFieldType;
            return .scalar;
        },
        .eq, .ne => {
            if (field_type == .array) return .array_field;
            return .scalar;
        },
    }
}

pub const Condition = struct {
    field_index: usize,
    op: Operator,
    value: ?Value,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,

    pub fn deinit(self: *Condition, allocator: std.mem.Allocator) void {
        if (self.value) |v| v.deinit(allocator);
        self.* = .{
            .field_index = 0,
            .op = .eq,
            .value = null,
            .field_type = .text,
            .items_type = null,
        };
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

    pub fn isTriviallyFalse(self: Condition) bool {
        if (self.op == .in) {
            if (self.value != null and self.value.? == .array and self.value.?.array.len == 0) {
                return true;
            }
        }
        return false;
    }

    pub fn isTriviallyTrue(self: Condition) bool {
        if (self.op == .notIn) {
            if (self.value != null and self.value.? == .array and self.value.?.array.len == 0) {
                return true;
            }
        }
        return false;
    }
};

pub const SortDescriptor = struct {
    field_index: usize,
    desc: bool,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
};

pub const PredicateState = enum(u8) {
    conditional,
    match_all,
    match_none,
};

pub const FilterPredicate = struct {
    state: PredicateState = .conditional,
    conditions: ?[]Condition = null,
    or_conditions: ?[]Condition = null,

    pub fn isEmpty(self: FilterPredicate) bool {
        return self.isAlwaysTrue();
    }

    pub fn hasClauses(self: FilterPredicate) bool {
        const has_conds = self.conditions != null and self.conditions.?.len > 0;
        const has_or = self.or_conditions != null and self.or_conditions.?.len > 0;
        return has_conds or has_or;
    }

    pub fn isAlwaysTrue(self: FilterPredicate) bool {
        return self.state == .match_all or (self.state == .conditional and !self.hasClauses());
    }

    pub fn isAlwaysFalse(self: FilterPredicate) bool {
        return self.state == .match_none;
    }

    pub fn deinit(self: *FilterPredicate, allocator: std.mem.Allocator) void {
        if (self.conditions) |conds| {
            for (conds) |*c| c.deinit(allocator);
            allocator.free(conds);
        }
        if (self.or_conditions) |or_conds| {
            for (or_conds) |*c| c.deinit(allocator);
            allocator.free(or_conds);
        }
        self.* = .{};
    }

    pub fn clone(self: FilterPredicate, allocator: std.mem.Allocator) !FilterPredicate {
        var cloned = FilterPredicate{
            .state = self.state,
            .conditions = try cloneConditions(allocator, self.conditions),
            .or_conditions = null,
        };
        errdefer cloned.deinit(allocator);
        cloned.or_conditions = try cloneConditions(allocator, self.or_conditions);
        return cloned;
    }

    pub fn normalize(self: *FilterPredicate, allocator: std.mem.Allocator) !PredicateState {
        if (self.state == .match_all or self.state == .match_none) {
            self.clearClauses(allocator);
            return self.state;
        }
        if (self.conditions) |conds| {
            for (conds) |c| {
                if (c.isTriviallyFalse()) {
                    self.clearClauses(allocator);
                    self.state = .match_none;
                    return self.state;
                }
            }
            self.conditions = try compactTrivialTrueConditions(allocator, conds);
        }

        if (self.or_conditions) |or_conds| {
            for (or_conds) |c| {
                if (c.isTriviallyTrue()) {
                    for (or_conds) |*or_c| or_c.deinit(allocator);
                    allocator.free(or_conds);
                    self.or_conditions = null;
                    self.state = if (self.hasClauses()) .conditional else .match_all;
                    return self.state;
                }
            }

            var keep_count: usize = 0;
            for (or_conds) |c| {
                if (!c.isTriviallyFalse()) keep_count += 1;
            }

            if (keep_count == 0) {
                self.clearClauses(allocator);
                self.state = .match_none;
                return self.state;
            }

            self.or_conditions = try compactTrivialFalseConditions(allocator, or_conds, keep_count);
        }

        self.state = if (self.hasClauses()) .conditional else .match_all;
        return self.state;
    }

    fn clearClauses(self: *FilterPredicate, allocator: std.mem.Allocator) void {
        if (self.conditions) |conds| {
            for (conds) |*c| c.deinit(allocator);
            allocator.free(conds);
            self.conditions = null;
        }
        if (self.or_conditions) |or_conds| {
            for (or_conds) |*c| c.deinit(allocator);
            allocator.free(or_conds);
            self.or_conditions = null;
        }
    }
};

pub const QueryFilter = struct {
    predicate: FilterPredicate = .{},
    order_by: SortDescriptor,
    limit: ?u32 = null,
    after: ?Cursor = null,

    pub fn deinit(self: *QueryFilter, allocator: std.mem.Allocator) void {
        self.predicate.deinit(allocator);
        if (self.after) |*a| a.deinit(allocator);
        self.after = null;
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

fn cloneConditions(allocator: std.mem.Allocator, conditions: ?[]const Condition) !?[]Condition {
    const conds = conditions orelse return null;
    const cloned = try allocator.alloc(Condition, conds.len);
    var initialized_count: usize = 0;
    errdefer {
        for (cloned[0..initialized_count]) |*c| c.deinit(allocator);
        allocator.free(cloned);
    }
    for (conds, 0..) |condition, i| {
        cloned[i] = try condition.clone(allocator);
        initialized_count += 1;
    }
    return cloned;
}

fn compactTrivialTrueConditions(allocator: std.mem.Allocator, conds: []Condition) !?[]Condition {
    var keep_count: usize = 0;
    for (conds) |c| {
        if (!c.isTriviallyTrue()) keep_count += 1;
    }
    if (keep_count == conds.len) return conds;
    if (keep_count == 0) {
        for (conds) |*c| c.deinit(allocator);
        allocator.free(conds);
        return null;
    }

    const compacted = try allocator.alloc(Condition, keep_count);
    var out: usize = 0;
    for (conds) |*c| {
        if (c.isTriviallyTrue()) {
            c.deinit(allocator);
            continue;
        }
        compacted[out] = c.*;
        out += 1;
    }
    allocator.free(conds);
    return compacted;
}

fn compactTrivialFalseConditions(
    allocator: std.mem.Allocator,
    conds: []Condition,
    keep_count: usize,
) ![]Condition {
    if (keep_count == conds.len) return conds;

    const compacted = try allocator.alloc(Condition, keep_count);
    var out: usize = 0;
    for (conds) |*c| {
        if (c.isTriviallyFalse()) {
            c.deinit(allocator);
            continue;
        }
        compacted[out] = c.*;
        out += 1;
    }
    allocator.free(conds);
    return compacted;
}
