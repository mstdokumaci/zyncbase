const std = @import("std");
const schema_types = @import("../schema/types.zig");
const typed = @import("../typed/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
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

/// Returns the value shape `op` expects for `field_type`, or
/// `UnsupportedOperatorForFieldType` when the combination is not permitted.
pub fn operatorExpectsValueShape(
    op: Operator,
    field_type: schema_types.FieldType,
) error{UnsupportedOperatorForFieldType}!ValueShape {
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
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,

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
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
};

pub const PredicateState = enum(u8) {
    conditional,
    match_all,
    match_none,
};

pub const OrClause = []Condition;

pub const FilterPredicate = struct {
    state: PredicateState = .conditional,
    conditions: ?[]Condition = null,
    or_clauses: ?[]OrClause = null,

    pub fn isEmpty(self: FilterPredicate) bool {
        return self.isAlwaysTrue();
    }

    pub fn hasClauses(self: FilterPredicate) bool {
        const has_conds = self.conditions != null and self.conditions.?.len > 0;
        const has_or = self.or_clauses != null and self.or_clauses.?.len > 0;
        return has_conds or has_or;
    }

    pub fn isAlwaysTrue(self: FilterPredicate) bool {
        return self.state == .match_all or (self.state == .conditional and !self.hasClauses());
    }

    pub fn isAlwaysFalse(self: FilterPredicate) bool {
        return self.state == .match_none;
    }

    pub fn deinit(self: *FilterPredicate, allocator: std.mem.Allocator) void {
        self.freeMemory(allocator);
        self.* = .{};
    }

    pub fn freeMemory(self: *const FilterPredicate, allocator: std.mem.Allocator) void {
        if (self.conditions) |conds| {
            for (conds) |*c| c.deinit(allocator);
            allocator.free(conds);
        }
        if (self.or_clauses) |clauses| {
            for (clauses) |clause| {
                for (clause) |*c| c.deinit(allocator);
                allocator.free(clause);
            }
            allocator.free(clauses);
        }
    }

    pub fn clone(self: FilterPredicate, allocator: std.mem.Allocator) !FilterPredicate {
        var cloned = FilterPredicate{
            .state = self.state,
            .conditions = try cloneConditions(allocator, self.conditions),
            .or_clauses = null,
        };
        errdefer cloned.deinit(allocator);
        cloned.or_clauses = try cloneOrClauses(allocator, self.or_clauses);
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

        if (self.or_clauses) |clauses| {
            // If any clause has a trivially true condition, the entire clause
            // is true → remove it from the AND (it's a no-op).
            var clause_keep_count: usize = 0;
            for (clauses) |clause| {
                var clause_has_true = false;
                for (clause) |c| {
                    if (c.isTriviallyTrue()) {
                        clause_has_true = true;
                        break;
                    }
                }
                if (!clause_has_true) clause_keep_count += 1;
            }

            if (clause_keep_count < clauses.len) {
                // Some clauses were trivially true — compact.
                if (clause_keep_count == 0) {
                    // All clauses were trivially true → remove or_clauses entirely.
                    for (clauses) |clause| {
                        for (clause) |*c| c.deinit(allocator);
                        allocator.free(clause);
                    }
                    allocator.free(clauses);
                    self.or_clauses = null;
                    self.state = if (self.hasClauses()) .conditional else .match_all;
                    return self.state;
                }
                // Compact: keep only non-trivially-true clauses.
                const compacted = try allocator.alloc(OrClause, clause_keep_count);
                var out: usize = 0;
                for (clauses) |clause| {
                    var clause_has_true = false;
                    for (clause) |c| {
                        if (c.isTriviallyTrue()) {
                            clause_has_true = true;
                            break;
                        }
                    }
                    if (clause_has_true) {
                        for (clause) |*c| c.deinit(allocator);
                        allocator.free(clause);
                    } else {
                        compacted[out] = clause;
                        out += 1;
                    }
                }
                allocator.free(clauses);
                self.or_clauses = compacted;
            }

            // Now process each surviving clause: remove trivially false conditions.
            // If a clause becomes empty (all false) → entire predicate is match_none.
            var clause_idx: usize = 0;
            while (clause_idx < self.or_clauses.?.len) {
                const clause = self.or_clauses.?[clause_idx];
                var keep: usize = 0;
                for (clause) |c| {
                    if (!c.isTriviallyFalse()) keep += 1;
                }
                if (keep == 0) {
                    // All conditions in this clause are false → clause is false → entire predicate is match_none.
                    self.clearClauses(allocator);
                    self.state = .match_none;
                    return self.state;
                }
                if (keep < clause.len) {
                    // Compact this clause.
                    const compacted = try allocator.alloc(Condition, keep);
                    var out: usize = 0;
                    for (clause) |*c| {
                        if (c.isTriviallyFalse()) {
                            c.deinit(allocator);
                        } else {
                            compacted[out] = c.*;
                            out += 1;
                        }
                    }
                    allocator.free(clause);
                    self.or_clauses.?[clause_idx] = compacted;
                }
                clause_idx += 1;
            }
        }

        // Sort conditions for deterministic order (required for structural hash)
        if (self.conditions) |conds| {
            std.mem.sort(Condition, conds, {}, conditionLessThan);
        }
        if (self.or_clauses) |clauses| {
            for (clauses) |clause| {
                std.mem.sort(Condition, clause, {}, conditionLessThan);
            }
            // Sort or_clauses by their first condition for deterministic clause order
            std.mem.sort(OrClause, clauses, {}, orClauseLessThan);
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
        if (self.or_clauses) |clauses| {
            for (clauses) |clause| {
                for (clause) |*c| c.deinit(allocator);
                allocator.free(clause);
            }
            allocator.free(clauses);
            self.or_clauses = null;
        }
    }

    /// Merges `guard` into `self` in-place: self ∧ guard.
    /// Guard conditions are appended to self.conditions.
    /// Guard or_clauses are appended to self.or_clauses.
    /// Guard state is respected: match_all = no-op, match_none = self becomes match_none.
    /// Takes ownership of guard's memory on success.
    pub fn mergeInPlace(
        self: *FilterPredicate,
        allocator: std.mem.Allocator,
        guard: *FilterPredicate,
    ) !void {
        if (guard.state == .match_all) {
            guard.deinit(allocator);
            return;
        }
        if (guard.state == .match_none) {
            guard.deinit(allocator);
            self.deinit(allocator);
            self.state = .match_none;
            return;
        }

        // Move guard's conditions into self
        if (guard.conditions) |guard_conds| {
            if (self.conditions) |self_conds| {
                // Concatenate: allocate new combined slice
                const combined = try allocator.alloc(Condition, self_conds.len + guard_conds.len);
                for (self_conds, 0..) |c, i| combined[i] = c;
                for (guard_conds, 0..) |c, i| combined[self_conds.len + i] = c;
                allocator.free(self_conds);
                allocator.free(guard_conds);
                self.conditions = combined;
                guard.conditions = null;
            } else {
                self.conditions = guard_conds;
                guard.conditions = null;
            }
        }

        // Move guard's or_clauses into self
        if (guard.or_clauses) |guard_clauses| {
            if (self.or_clauses) |self_clauses| {
                // Concatenate: allocate new combined slice
                const combined = try allocator.alloc(OrClause, self_clauses.len + guard_clauses.len);
                for (self_clauses, 0..) |c, i| combined[i] = c;
                for (guard_clauses, 0..) |c, i| combined[self_clauses.len + i] = c;
                allocator.free(self_clauses);
                allocator.free(guard_clauses);
                self.or_clauses = combined;
                guard.or_clauses = null;
            } else {
                self.or_clauses = guard_clauses;
                guard.or_clauses = null;
            }
        }

        _ = try self.normalize(allocator);
    }
};

pub const QueryFilter = struct {
    predicate: FilterPredicate = .{},
    order_by: SortDescriptor,
    limit: ?u32 = null,
    after: ?Cursor = null,
    structural_hash: u64 = 0,

    pub fn deinit(self: *QueryFilter, allocator: std.mem.Allocator) void {
        self.predicate.deinit(allocator);
        if (self.after) |*a| a.deinit(allocator);
        self.after = null;
    }

    pub fn clone(self: QueryFilter, allocator: std.mem.Allocator) !QueryFilter {
        var copy = self; // copies structural_hash by value
        copy.predicate = try self.predicate.clone(allocator);
        errdefer copy.predicate.deinit(allocator);
        copy.order_by = self.order_by;
        if (self.after) |a| {
            copy.after = try a.clone(allocator);
        }
        return copy;
    }
};

fn cloneOrClauses(allocator: std.mem.Allocator, clauses: ?[]const OrClause) !?[]OrClause {
    const cls = clauses orelse return null;
    const cloned = try allocator.alloc(OrClause, cls.len);
    var initialized_count: usize = 0;
    errdefer {
        for (cloned[0..initialized_count]) |clause| {
            for (clause) |*c| c.deinit(allocator);
            allocator.free(clause);
        }
        allocator.free(cloned);
    }
    for (cls, 0..) |clause, i| {
        const conds = clause;
        const cloned_conds = try allocator.alloc(Condition, conds.len);
        var cond_count: usize = 0;
        errdefer {
            for (cloned_conds[0..cond_count]) |*c| c.deinit(allocator);
            allocator.free(cloned_conds);
        }
        for (conds, 0..) |condition, j| {
            cloned_conds[j] = try condition.clone(allocator);
            cond_count += 1;
        }
        cloned[i] = cloned_conds;
        initialized_count += 1;
    }
    return cloned;
}

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

fn conditionLessThan(_: void, a: Condition, b: Condition) bool {
    if (a.field_index != b.field_index) return a.field_index < b.field_index;
    if (a.op != b.op) return @intFromEnum(a.op) < @intFromEnum(b.op);
    if (a.field_type != b.field_type) return @intFromEnum(a.field_type) < @intFromEnum(b.field_type);
    // items_type comparison: null < non-null, both null = equal
    const a_items = a.items_type;
    const b_items = b.items_type;
    if (a_items != null and b_items != null) {
        if (a_items.? != b_items.?) return @intFromEnum(a_items.?) < @intFromEnum(b_items.?);
    } else if (a_items == null and b_items != null) {
        return true; // null < non-null
    } else if (a_items != null and b_items == null) {
        return false; // non-null > null
    }
    // both null or equal — continue to value comparison
    return conditionValueLessThan(a.value, b.value);
}

fn orClauseLessThan(_: void, a: OrClause, b: OrClause) bool {
    if (a.len == 0 and b.len == 0) return false;
    if (a.len == 0) return true;
    if (b.len == 0) return false;
    return conditionLessThan({}, a[0], b[0]);
}

fn conditionValueLessThan(a: ?Value, b: ?Value) bool {
    if (a == null and b == null) return false;
    if (a == null) return true;
    if (b == null) return false;
    const av = a.?;
    const bv = b.?;
    if (@intFromEnum(std.meta.activeTag(av)) != @intFromEnum(std.meta.activeTag(bv)))
        return @intFromEnum(std.meta.activeTag(av)) < @intFromEnum(std.meta.activeTag(bv));
    return switch (av) {
        .scalar => |as| switch (as) {
            .text => |at| if (bv.scalar == .text) std.mem.lessThan(u8, at, bv.scalar.text) else false,
            .integer => |ai| if (bv.scalar == .integer) ai < bv.scalar.integer else false,
            .real => |ar| if (bv.scalar == .real) ar < bv.scalar.real else false,
            .boolean => |ab| if (bv.scalar == .boolean) @intFromBool(ab) < @intFromBool(bv.scalar.boolean) else false,
            .doc_id => |ad| if (bv.scalar == .doc_id) std.mem.lessThan(u8, &typed_doc_id.toBytes(ad), &typed_doc_id.toBytes(bv.scalar.doc_id)) else false,
        },
        .array => |aa| blk: {
            const ba = bv.array;
            const min_len = @min(aa.len, ba.len);
            for (0..min_len) |i| {
                if (ScalarValue.order(aa[i], ba[i]) == .lt) break :blk true;
                if (ScalarValue.order(aa[i], ba[i]) == .gt) break :blk false;
            }
            break :blk aa.len < ba.len;
        },
        .nil => false,
    };
}
