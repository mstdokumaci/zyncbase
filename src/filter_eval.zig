const std = @import("std");
const query_ast = @import("query_ast.zig");
const typed = @import("typed.zig");

const Condition = query_ast.Condition;
const FilterPredicate = query_ast.FilterPredicate;
const Record = typed.Record;
const ScalarValue = typed.ScalarValue;
const Value = typed.Value;

pub fn evaluatePredicate(predicate: *const FilterPredicate, record: *const Record) !bool {
    switch (predicate.state) {
        .match_all => return true,
        .match_none => return false,
        .conditional => {},
    }

    if (predicate.conditions) |conds| {
        for (conds) |condition| {
            if (!try evaluateCondition(&condition, record)) return false;
        }
    }

    if (predicate.or_conditions) |or_conds| {
        if (or_conds.len == 0) return true;
        for (or_conds) |condition| {
            if (try evaluateCondition(&condition, record)) return true;
        }
        return false;
    }

    return true;
}

pub fn evaluateCondition(cond: *const Condition, record: *const Record) !bool {
    if (cond.field_index >= record.values.len) return cond.op == .isNull;
    const val = record.values[cond.field_index];

    return switch (cond.op) {
        .eq, .ne, .gt, .lt, .gte, .lte => try evalComparison(cond.op, val, cond.value),
        .isNull => val == .nil,
        .isNotNull => val != .nil,
        .startsWith => evalTextMatchBool(val, cond.value, std.ascii.startsWithIgnoreCase),
        .endsWith => evalTextMatchBool(val, cond.value, std.ascii.endsWithIgnoreCase),
        .contains => blk: {
            if (cond.field_type == .array) break :blk evalArrayContains(val, cond.value);
            break :blk evalTextMatchIndex(val, cond.value) != null;
        },
        .in => evalIn(val, cond.value),
        .notIn => !evalIn(val, cond.value),
    };
}

fn evalComparison(op: query_ast.Operator, val: Value, maybe_target: ?Value) !bool {
    const target = maybe_target orelse return switch (op) {
        .eq => false,
        .ne => true,
        .gt, .lt, .gte, .lte => false,
        else => unreachable,
    };
    return switch (op) {
        .eq => val.eql(target),
        .ne => !val.eql(target),
        .gt => val.order(target) == .gt,
        .lt => val.order(target) == .lt,
        .gte => blk: {
            const res = val.order(target);
            break :blk res == .gt or res == .eq;
        },
        .lte => blk: {
            const res = val.order(target);
            break :blk res == .lt or res == .eq;
        },
        else => unreachable,
    };
}

fn evalTextMatchBool(
    val: Value,
    maybe_target: ?Value,
    comptime match_fn: fn ([]const u8, []const u8) bool,
) bool {
    if (val != .scalar or val.scalar != .text) return false;
    const target = maybe_target orelse return false;
    if (target != .scalar or target.scalar != .text) return false;
    return match_fn(val.scalar.text, target.scalar.text);
}

fn evalTextMatchIndex(val: Value, maybe_target: ?Value) ?usize {
    if (val != .scalar or val.scalar != .text) return null;
    const target = maybe_target orelse return null;
    if (target != .scalar or target.scalar != .text) return null;
    return std.ascii.indexOfIgnoreCase(val.scalar.text, target.scalar.text);
}

fn evalArrayContains(val: Value, maybe_target: ?Value) bool {
    if (val != .array) return false;
    const target = maybe_target orelse return false;
    if (target != .scalar) return false;
    return std.sort.binarySearch(ScalarValue, val.array, target.scalar, ScalarValue.order) != null;
}

fn evalIn(val: Value, maybe_target: ?Value) bool {
    if (val != .scalar) return false;
    const target = maybe_target orelse return false;
    if (target != .array) return false;
    return std.sort.binarySearch(ScalarValue, target.array, val.scalar, ScalarValue.order) != null;
}
