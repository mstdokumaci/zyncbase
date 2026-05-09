const std = @import("std");
const msgpack = @import("msgpack");
const types = @import("types.zig");
const typed = @import("../typed.zig");
const TypedValue = typed.TypedValue;
const ScalarValue = typed.ScalarValue;

pub const EvalContext = struct {
    allocator: std.mem.Allocator,
    session_user_id: ?typed.DocId = null,
    session_external_id: ?[]const u8 = null,
    namespace_captures: ?*const std.StringHashMap([]const u8) = null,
    path_table: ?[]const u8 = null,
    value_payload: ?*const msgpack.Payload = null,
    value_table: ?*const @import("../schema.zig").Table = null,
};

pub const EvalResult = enum {
    allow,
    deny,
    needs_doc_predicate,
};

pub const ResolvedValue = struct {
    value: TypedValue,
    owned: bool = false,

    pub fn deinit(self: ResolvedValue, allocator: std.mem.Allocator) void {
        if (self.owned) self.value.deinit(allocator);
    }
};

/// Evaluate a condition in RAM.
/// Returns .allow / .deny for fully resolvable conditions.
/// Returns .needs_doc_predicate if the condition references $doc variables.
pub fn evaluateCondition(condition: types.Condition, ctx: EvalContext) EvalResult {
    return evaluateConditionInternal(condition, ctx, false);
}

/// Strict evaluation — $doc references cause .deny (for commands where $doc is forbidden).
pub fn evaluateConditionStrict(condition: types.Condition, ctx: EvalContext) bool {
    return evaluateConditionInternal(condition, ctx, true) == .allow;
}

pub fn authorizeStoreNamespace(
    allocator: std.mem.Allocator,
    config: *const types.AuthConfig,
    namespace: []const u8,
    session_user_id: typed.DocId,
    session_external_id: []const u8,
) !void {
    var match = (try config.namespaceRuleFor(allocator, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const ctx: EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .namespace_captures = &match.captures.captures,
    };
    if (!evaluateConditionStrict(match.rule.store_filter, ctx)) return error.NamespaceUnauthorized;
}

fn evaluateConditionInternal(condition: types.Condition, ctx: EvalContext, strict: bool) EvalResult {
    switch (condition) {
        .boolean => |b| return if (b) .allow else .deny,
        .hook => return .deny,
        .logical_and => |conds| {
            var has_injection = false;
            for (conds) |cond| {
                const result = evaluateConditionInternal(cond, ctx, strict);
                if (result == .deny) return .deny;
                if (result == .needs_doc_predicate) has_injection = true;
            }
            return if (has_injection and !strict) .needs_doc_predicate else .allow;
        },
        .logical_or => |conds| {
            var has_injection = false;
            for (conds) |cond| {
                const result = evaluateConditionInternal(cond, ctx, strict);
                if (result == .allow) return .allow;
                if (result == .needs_doc_predicate) has_injection = true;
            }
            return if (has_injection and !strict) .needs_doc_predicate else .deny;
        },
        .comparison => |comp| return evaluateComparison(comp, ctx, strict),
    }
}

fn evaluateComparison(comp: types.Comparison, ctx: EvalContext, strict: bool) EvalResult {
    if (comp.lhs.scope == .doc) {
        return if (strict) .deny else .needs_doc_predicate;
    }

    var lhs = resolveLhs(comp.lhs, ctx) orelse return .deny;
    defer lhs.deinit(ctx.allocator);

    var rhs = resolveRhs(comp.rhs, ctx) orelse return .deny;
    defer rhs.deinit(ctx.allocator);

    return if (compareValues(lhs.value, comp.op, rhs.value)) .allow else .deny;
}

fn borrowed(value: TypedValue) ResolvedValue {
    return .{ .value = value, .owned = false };
}

fn owned(value: TypedValue) ResolvedValue {
    return .{ .value = value, .owned = true };
}

fn resolveLhs(var_ctx: types.ContextVar, ctx: EvalContext) ?ResolvedValue {
    return switch (var_ctx.scope) {
        .session => if (std.mem.eql(u8, var_ctx.field, "userId"))
            if (ctx.session_user_id) |id| borrowed(.{ .scalar = .{ .doc_id = id } }) else null
        else if (std.mem.eql(u8, var_ctx.field, "externalId"))
            if (ctx.session_external_id) |id| borrowed(.{ .scalar = .{ .text = id } }) else null
        else
            null,
        .namespace => if (ctx.namespace_captures) |captures| blk: {
            const val = captures.get(var_ctx.field) orelse break :blk null;
            break :blk borrowed(.{ .scalar = .{ .text = val } });
        } else null,
        .path => if (std.mem.eql(u8, var_ctx.field, "table"))
            if (ctx.path_table) |t| borrowed(.{ .scalar = .{ .text = t } }) else null
        else
            null,
        .value => resolveValueField(var_ctx.field, ctx),
        .doc => null,
    };
}

pub fn resolveRhs(value: types.Value, ctx: EvalContext) ?ResolvedValue {
    return switch (value) {
        .literal => |v| borrowed(v),
        .context_var => |cv| resolveLhs(cv, ctx),
    };
}

fn resolveValueField(field: []const u8, ctx: EvalContext) ?ResolvedValue {
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
            const value = typed.valueFromPayload(ctx.allocator, field_meta.storage_type, field_meta.items_type, entry.value_ptr.*) catch return null; // zwanzig-disable-line: swallowed-error
            return owned(value);
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
            if (lhs != .scalar) break :blk false;
            if (rhs != .array) break :blk false;
            break :blk std.sort.binarySearch(ScalarValue, rhs.array, lhs.scalar, ScalarValue.order) != null;
        },
        .not_in_set => blk: {
            if (lhs != .scalar) break :blk false;
            if (rhs != .array) break :blk false;
            break :blk std.sort.binarySearch(ScalarValue, rhs.array, lhs.scalar, ScalarValue.order) == null;
        },
        .contains => blk: {
            if (lhs != .array) break :blk false;
            if (rhs != .scalar) break :blk false;
            break :blk std.sort.binarySearch(ScalarValue, lhs.array, rhs.scalar, ScalarValue.order) != null;
        },
    };
}
