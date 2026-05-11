const std = @import("std");
const query_ast = @import("query_ast.zig");
const typed = @import("typed.zig");

const Condition = query_ast.Condition;
const FilterPredicate = query_ast.FilterPredicate;
const Record = typed.Record;
const ScalarValue = typed.ScalarValue;

pub fn evaluatePredicate(predicate: FilterPredicate, record: Record) !bool {
    switch (predicate.state) {
        .match_all => return true,
        .match_none => return false,
        .conditional => {},
    }

    if (predicate.conditions) |conds| {
        for (conds) |condition| {
            if (!try evaluateCondition(condition, record)) return false;
        }
    }

    if (predicate.or_conditions) |or_conds| {
        if (or_conds.len == 0) return true;
        for (or_conds) |condition| {
            if (try evaluateCondition(condition, record)) return true;
        }
        return false;
    }

    return true;
}

pub fn evaluateCondition(cond: Condition, record: Record) !bool {
    if (cond.field_index >= record.values.len) return cond.op == .isNull;
    const val = record.values[cond.field_index];

    return switch (cond.op) {
        .eq => val.eql(cond.value orelse return false),
        .ne => !val.eql(cond.value orelse return true),
        .gt => val.order(cond.value orelse return false) == .gt,
        .gte => blk: {
            const res = val.order(cond.value orelse return false);
            break :blk res == .gt or res == .eq;
        },
        .lt => val.order(cond.value orelse return false) == .lt,
        .lte => blk: {
            const res = val.order(cond.value orelse return false);
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
                break :blk std.sort.binarySearch(ScalarValue, val.array, cond.value.?.scalar, ScalarValue.order) != null;
            }
            if (val != .scalar or val.scalar != .text) break :blk false;
            if (cond.value == null or cond.value.? != .scalar or cond.value.?.scalar != .text) break :blk false;
            break :blk std.ascii.indexOfIgnoreCase(val.scalar.text, cond.value.?.scalar.text) != null;
        },
        .in => blk: {
            if (val != .scalar) break :blk false;
            if (cond.value == null or cond.value.? != .array) break :blk false;
            break :blk std.sort.binarySearch(ScalarValue, cond.value.?.array, val.scalar, ScalarValue.order) != null;
        },
        .notIn => blk: {
            if (val != .scalar) break :blk true;
            if (cond.value == null or cond.value.? != .array) break :blk false;
            break :blk std.sort.binarySearch(ScalarValue, cond.value.?.array, val.scalar, ScalarValue.order) == null;
        },
    };
}
