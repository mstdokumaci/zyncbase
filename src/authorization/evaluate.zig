const std = @import("std");
const msgpack = @import("msgpack");
const types = @import("types.zig");
const TypedValue = @import("../storage_engine/values.zig").TypedValue;
const ScalarValue = @import("../storage_engine/values.zig").ScalarValue;
const doc_id = @import("../doc_id.zig");

pub const EvalContext = struct {
    allocator: std.mem.Allocator,
    session_user_id: ?doc_id.DocId = null,
    session_external_id: ?[]const u8 = null,
    namespace_captures: ?*const std.StringHashMap([]const u8) = null,
    path_table: ?[]const u8 = null,
    value_payload: ?*const msgpack.Payload = null,
    value_table: ?*const @import("../schema.zig").Table = null,
};

pub const EvalResult = enum {
    allow,
    deny,
    needs_injection,
};

/// Evaluate a condition in RAM.
/// Returns .allow / .deny for fully resolvable conditions.
/// Returns .needs_injection if the condition references $doc variables.
pub fn evaluateCondition(condition: types.Condition, ctx: EvalContext) EvalResult {
    return evaluateConditionInternal(condition, ctx, false);
}

/// Strict evaluation — $doc references cause .deny (for commands where $doc is forbidden).
pub fn evaluateConditionStrict(condition: types.Condition, ctx: EvalContext) bool {
    return evaluateConditionInternal(condition, ctx, true) == .allow;
}

fn evaluateConditionInternal(condition: types.Condition, ctx: EvalContext, strict: bool) EvalResult {
    switch (condition) {
        .boolean => |b| return if (b) .allow else .deny,
        .hook => return if (strict) .deny else .needs_injection,
        .logical_and => |conds| {
            for (conds) |cond| {
                const result = evaluateConditionInternal(cond, ctx, strict);
                if (result == .deny) return .deny;
                if (result == .needs_injection and !strict) return .needs_injection;
            }
            return .allow;
        },
        .logical_or => |conds| {
            var has_injection = false;
            for (conds) |cond| {
                const result = evaluateConditionInternal(cond, ctx, strict);
                if (result == .allow) return .allow;
                if (result == .needs_injection) has_injection = true;
            }
            return if (has_injection and !strict) .needs_injection else .deny;
        },
        .comparison => |comp| return evaluateComparison(comp, ctx, strict),
    }
}

fn evaluateComparison(comp: types.Comparison, ctx: EvalContext, strict: bool) EvalResult {
    if (comp.lhs.scope == .doc) {
        return if (strict) .deny else .needs_injection;
    }

    const lhs_opt = resolveLhs(comp.lhs, ctx);
    const rhs_opt = resolveRhs(comp.rhs, ctx);

    const lhs_val = lhs_opt orelse return .deny;
    const rhs_val = rhs_opt orelse return .deny;

    return if (compareValues(lhs_val, comp.op, rhs_val)) .allow else .deny;
}

fn resolveLhs(var_ctx: types.ContextVar, ctx: EvalContext) ?TypedValue {
    return switch (var_ctx.scope) {
        .session => if (std.mem.eql(u8, var_ctx.field, "userId"))
            if (ctx.session_user_id) |id| TypedValue{ .scalar = .{ .doc_id = id } } else null
        else if (std.mem.eql(u8, var_ctx.field, "externalId"))
            if (ctx.session_external_id) |id| TypedValue{ .scalar = .{ .text = id } } else null
        else
            null,
        .namespace => if (ctx.namespace_captures) |captures| blk: {
            const val = captures.get(var_ctx.field) orelse break :blk null;
            break :blk TypedValue{ .scalar = .{ .text = val } };
        } else null,
        .path => if (std.mem.eql(u8, var_ctx.field, "table"))
            if (ctx.path_table) |t| TypedValue{ .scalar = .{ .text = t } } else null
        else
            null,
        .value => resolveValueField(var_ctx.field, ctx),
        .doc => null,
    };
}

pub fn resolveRhs(value: types.Value, ctx: EvalContext) ?TypedValue {
    return switch (value) {
        .string => |s| TypedValue{ .scalar = .{ .text = s } },
        .integer => |i| TypedValue{ .scalar = .{ .integer = i } },
        .real => |r| TypedValue{ .scalar = .{ .real = r } },
        .boolean => |b| TypedValue{ .scalar = .{ .boolean = b } },
        .context_var => |cv| resolveLhs(cv, ctx),
        .string_array => |arr| blk: {
            const scalars = ctx.allocator.alloc(ScalarValue, arr.len) catch break :blk null;
            for (arr, 0..) |s, i| scalars[i] = .{ .text = s };
            break :blk TypedValue{ .array = scalars };
        },
        .integer_array => |arr| blk: {
            const scalars = ctx.allocator.alloc(ScalarValue, arr.len) catch break :blk null;
            for (arr, 0..) |n, i| scalars[i] = .{ .integer = n };
            break :blk TypedValue{ .array = scalars };
        },
    };
}

fn resolveValueField(field: []const u8, ctx: EvalContext) ?TypedValue {
    const payload = ctx.value_payload orelse return null;
    const table = ctx.value_table orelse return null;

    const field_index = table.fieldIndex(field) orelse return null;
    const field_meta = table.fields[field_index];

    if (payload.* != .map) return null;
    const map = payload.map;

    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const matched = switch (key) {
            .uint => key.uint == field_index,
            .int => key.int == field_index,
            .str => std.mem.eql(u8, key.str.value(), field),
            else => false,
        };
        if (matched) {
            return @import("../storage_engine.zig").typedValueFromPayload(ctx.allocator, field_meta.storage_type, field_meta.items_type, entry.value_ptr.*) catch null; // zwanzig-disable-line: swallowed-error
        }
    }

    return null;
}

fn compareValues(lhs: TypedValue, op: types.ComparisonOp, rhs: TypedValue) bool {
    return switch (op) {
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
        .in_set => blk: {
            if (rhs != .array) break :blk false;
            break :blk std.sort.binarySearch(ScalarValue, rhs.array, lhs.scalar, ScalarValue.order) != null;
        },
        .not_in_set => blk: {
            if (rhs != .array) break :blk true;
            break :blk std.sort.binarySearch(ScalarValue, rhs.array, lhs.scalar, ScalarValue.order) == null;
        },
        .contains => blk: {
            if (lhs != .array) break :blk false;
            break :blk std.sort.binarySearch(ScalarValue, lhs.array, rhs.scalar, ScalarValue.order) != null;
        },
    };
}
