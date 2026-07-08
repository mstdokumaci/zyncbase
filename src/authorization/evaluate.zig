const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const types = @import("types.zig");
const pattern_mod = @import("pattern.zig");
const typed = @import("../typed.zig");
const query_ast = @import("../query_ast.zig");
const schema_mod = @import("../schema.zig");
const Allocator = std.mem.Allocator;
const Value = typed.Value;
const ScalarValue = typed.ScalarValue;

pub const EvalContext = struct {
    allocator: Allocator,
    session_user_id: ?typed.DocId = null,
    session_external_id: ?[]const u8 = null,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value) = null,
    namespace_captures: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    path_table: ?[]const u8 = null,
    value_payload: ?*const msgpack.Payload = null,
    value_table: ?*const schema_mod.Table = null,
    presence_fields: ?[]const schema_mod.PresenceField = null,
    doc_id: ?typed.DocId = null,
    owner_doc_id: ?typed.DocId = null,
};

pub const EvalResult = enum {
    allow,
    deny,
    needs_doc_predicate,
};

/// A resolved authorization operand plus its lifetime.
///
/// `borrowed` is a non-owning view into auth config, session, namespace, or path
/// state. `owned` is allocated while resolving authorization input, currently
/// for `$value.*` fields decoded from the incoming MessagePack payload.
///
/// Owned values must be deinitialized, or moved out with `intoOwned`, using the
/// same allocator that created them.
pub const ResolvedAuthValue = union(enum) {
    borrowed: Value,
    owned: Value,

    pub fn fromBorrowed(value: Value) ResolvedAuthValue {
        return .{ .borrowed = value };
    }

    pub fn fromOwned(value: Value) ResolvedAuthValue {
        return .{ .owned = value };
    }

    /// Returns a non-owning view. The caller must not deinitialize it.
    pub fn valueView(self: ResolvedAuthValue) Value {
        return switch (self) {
            .borrowed => |value| value,
            .owned => |value| value,
        };
    }

    /// Returns an owned value by cloning borrowed input or moving owned input.
    pub fn intoOwned(self: *ResolvedAuthValue, allocator: Allocator) !Value {
        return switch (self.*) {
            .borrowed => |value| try value.clone(allocator),
            .owned => |value| blk: {
                self.* = .{ .borrowed = .nil };
                break :blk value;
            },
        };
    }

    pub fn deinit(self: *ResolvedAuthValue, allocator: Allocator) void {
        switch (self.*) {
            .owned => |value| value.deinit(allocator),
            .borrowed => {},
        }
        self.* = .{ .borrowed = .nil };
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

/// Evaluate a condition with $doc references resolved against a candidate document.
/// The candidate is composed from doc_id, owner_doc_id (injected), and incoming value_payload fields.
/// Returns true if the condition passes, false if it fails or references an absent field.
/// Zero-allocation: resolves $doc.field by looking up the incoming payload directly.
pub fn evaluateConditionWithDoc(condition: types.Condition, ctx: EvalContext) bool {
    return evaluateConditionWithDocInternal(condition, ctx);
}

fn evaluateConditionWithDocInternal(condition: types.Condition, ctx: EvalContext) bool {
    switch (condition) {
        .boolean => |b| return b,
        .logical_and => |conds| {
            for (conds) |cond| {
                if (!evaluateConditionWithDocInternal(cond, ctx)) return false;
            }
            return true;
        },
        .logical_or => |conds| {
            for (conds) |cond| {
                if (evaluateConditionWithDocInternal(cond, ctx)) return true;
            }
            return false;
        },
        .comparison => |comp| return evaluateComparisonWithDoc(comp, ctx),
    }
}

fn evaluateComparisonWithDoc(comp: types.Comparison, ctx: EvalContext) bool {
    var lhs = resolveDocOperand(comp.lhs, ctx) orelse return false;
    defer lhs.deinit(ctx.allocator);

    var rhs = resolveOperand(comp.rhs, ctx) orelse return false;
    defer rhs.deinit(ctx.allocator);

    return compareValues(lhs.valueView(), comp.op, rhs.valueView());
}

fn resolveDocOperand(var_ctx: types.ContextVar, ctx: EvalContext) ?ResolvedAuthValue {
    if (var_ctx.scope != .doc) {
        return resolveContextVar(var_ctx, ctx);
    }

    if (std.mem.eql(u8, var_ctx.field, "id")) {
        return if (ctx.doc_id) |id| ResolvedAuthValue.fromBorrowed(.{ .scalar = .{ .doc_id = id } }) else null;
    }
    if (std.mem.eql(u8, var_ctx.field, "owner_id")) {
        return if (ctx.owner_doc_id) |id| ResolvedAuthValue.fromBorrowed(.{ .scalar = .{ .doc_id = id } }) else null;
    }

    const table = ctx.value_table orelse return null;
    const field_index = table.fieldIndex(var_ctx.field) orelse return null;
    const field_meta = table.fields[field_index];

    if (field_meta.kind == .system) return null;

    return resolveIncomingValueField(var_ctx.field, ctx);
}

pub fn authorizeNamespace(
    allocator: Allocator,
    config: *const types.AuthConfig,
    namespace: []const u8,
    session_user_id: typed.DocId,
    session_external_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
    is_presence: bool,
) !void {
    var match = (try pattern_mod.matchNamespaceRule(allocator, config, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const ctx: EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .session_claims = session_claims,
        .namespace_captures = &match.captures.captures,
    };
    const filter = if (is_presence) match.rule.presence_read else match.rule.store_filter;
    if (!evaluateConditionStrict(filter, ctx)) return error.NamespaceUnauthorized;
}

pub fn authorizePresenceWrite(
    allocator: Allocator,
    config: *const types.AuthConfig,
    namespace: []const u8,
    session_user_id: typed.DocId,
    session_external_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
    presence_fields: []const schema_mod.PresenceField,
    data_payload: *const msgpack.Payload,
) !void {
    var match = (try pattern_mod.matchNamespaceRule(allocator, config, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const ctx: EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .session_claims = session_claims,
        .namespace_captures = &match.captures.captures,
        .value_payload = data_payload,
        .presence_fields = presence_fields,
    };
    if (!evaluateConditionStrict(match.rule.presence_write, ctx)) return error.NamespaceUnauthorized;
}

pub fn authorizePresenceSharedWrite(
    allocator: Allocator,
    config: *const types.AuthConfig,
    namespace: []const u8,
    session_user_id: typed.DocId,
    session_external_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
    presence_fields: []const schema_mod.PresenceField,
    data_payload: *const msgpack.Payload,
) !void {
    var match = (try pattern_mod.matchNamespaceRule(allocator, config, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const ctx: EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .session_claims = session_claims,
        .namespace_captures = &match.captures.captures,
        .value_payload = data_payload,
        .presence_fields = presence_fields,
    };
    if (!evaluateConditionStrict(match.rule.presence_shared_write, ctx)) return error.NamespaceUnauthorized;
}

fn evaluateConditionInternal(condition: types.Condition, ctx: EvalContext, strict: bool) EvalResult {
    switch (condition) {
        .boolean => |b| return if (b) .allow else .deny,
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

    var lhs = resolveContextVar(comp.lhs, ctx) orelse return .deny;
    defer lhs.deinit(ctx.allocator);

    var rhs = resolveOperand(comp.rhs, ctx) orelse return .deny;
    defer rhs.deinit(ctx.allocator);

    return if (compareValues(lhs.valueView(), comp.op, rhs.valueView())) .allow else .deny;
}

fn resolveContextVar(var_ctx: types.ContextVar, ctx: EvalContext) ?ResolvedAuthValue {
    return switch (var_ctx.scope) {
        .session => {
            if (session_field_map.get(var_ctx.field)) |sf| switch (sf) {
                .userId => return if (ctx.session_user_id) |id|
                    ResolvedAuthValue.fromBorrowed(.{ .scalar = .{ .doc_id = id } })
                else
                    null,
                .externalId => return if (ctx.session_external_id) |id|
                    ResolvedAuthValue.fromBorrowed(.{ .scalar = .{ .text = id } })
                else
                    null,
            };
            if (ctx.session_claims) |claims| {
                if (claims.get(var_ctx.field)) |value| {
                    return ResolvedAuthValue.fromBorrowed(value);
                }
            }
            return null;
        },
        .namespace => if (ctx.namespace_captures) |captures| blk: {
            const val = captures.get(var_ctx.field) orelse break :blk null;
            break :blk ResolvedAuthValue.fromBorrowed(.{ .scalar = .{ .text = val } });
        } else null,
        .path => if (std.mem.eql(u8, var_ctx.field, "table"))
            if (ctx.path_table) |t| ResolvedAuthValue.fromBorrowed(.{ .scalar = .{ .text = t } }) else null
        else
            null,
        .value => resolveIncomingValueField(var_ctx.field, ctx),
        .doc => null,
    };
}

pub fn resolveOperand(value: types.Operand, ctx: EvalContext) ?ResolvedAuthValue {
    return switch (value) {
        .literal => |v| ResolvedAuthValue.fromBorrowed(v),
        .context_var => |cv| resolveContextVar(cv, ctx),
    };
}

fn resolveIncomingValueField(field: []const u8, ctx: EvalContext) ?ResolvedAuthValue {
    const payload = ctx.value_payload orelse return null;

    if (payload.* != .arr) return null;
    const pairs = payload.arr;

    if (ctx.presence_fields) |fields| {
        const field_index = for (fields, 0..) |f, idx| {
            if (std.mem.eql(u8, f.name, field)) break idx;
        } else return null;
        const field_type = fields[field_index].declared_type;

        // Wire protocol: duplicate field index in one pair-array → last-wins.
        const pair = findLastValuePair(pairs, field_index) orelse return ResolvedAuthValue.fromBorrowed(.nil);
        const value = typed.valueFromPayload(ctx.allocator, field_type, null, pair.arr[1]) catch return null; // zwanzig-disable-line: swallowed-error
        return ResolvedAuthValue.fromOwned(value);
    }

    const table = ctx.value_table orelse return null;

    const field_index = table.fieldIndex(field) orelse return null;
    const field_meta = table.fields[field_index];

    // Wire protocol: duplicate field index in one pair-array → last-wins.
    const pair = findLastValuePair(pairs, field_index) orelse return ResolvedAuthValue.fromBorrowed(.nil);
    const value = typed.valueFromPayload(ctx.allocator, field_meta.storage_type, field_meta.items_type, pair.arr[1]) catch return null; // zwanzig-disable-line: swallowed-error
    return ResolvedAuthValue.fromOwned(value);
}

/// Scan a pair-array payload in reverse and return the last pair whose
/// first element matches `field_index`.  Returns null if no match is found.
///
/// Wire protocol rule: when a pair-array contains duplicate field indices,
/// the last occurrence wins.  Reverse scanning satisfies this with O(n)
/// worst-case but early exit on the first match.
fn findLastValuePair(pairs: []const msgpack.Payload, field_index: usize) ?msgpack.Payload {
    var i: usize = pairs.len;
    while (i > 0) {
        i -= 1;
        const pair_payload = pairs[i];
        if (pair_payload != .arr or pair_payload.arr.len != 2) continue;
        const idx = msgpack.extractPayloadUsize(pair_payload.arr[0]) orelse continue;
        if (idx == field_index) return pair_payload;
    }
    return null;
}

const ScalarArrayPair = struct { scalar: ScalarValue, array: []const ScalarValue };
const ArrayScalarPair = struct { array: []const ScalarValue, scalar: ScalarValue };

const SessionField = enum { userId, externalId };
const session_field_map = std.StaticStringMap(SessionField).initComptime(.{
    .{ "userId", .userId },
    .{ "externalId", .externalId },
});

inline fn extractScalarArray(lhs: Value, rhs: Value) ?ScalarArrayPair {
    if (lhs != .scalar) return null;
    if (rhs != .array) return null;
    return .{ .scalar = lhs.scalar, .array = rhs.array };
}

inline fn extractArrayScalar(lhs: Value, rhs: Value) ?ArrayScalarPair {
    if (lhs != .array) return null;
    if (rhs != .scalar) return null;
    return .{ .array = lhs.array, .scalar = rhs.scalar };
}

inline fn binarySearchScalar(haystack: []const ScalarValue, needle: ScalarValue) bool {
    return std.sort.binarySearch(ScalarValue, haystack, needle, ScalarValue.order) != null;
}

fn compareValues(lhs: Value, op: query_ast.Operator, rhs: Value) bool {
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
        .in => blk: {
            const pair = extractScalarArray(lhs, rhs) orelse break :blk false;
            break :blk binarySearchScalar(pair.array, pair.scalar);
        },
        .notIn => blk: {
            const pair = extractScalarArray(lhs, rhs) orelse break :blk false;
            break :blk !binarySearchScalar(pair.array, pair.scalar);
        },
        .contains => blk: {
            const pair = extractArrayScalar(lhs, rhs) orelse break :blk false;
            break :blk binarySearchScalar(pair.array, pair.scalar);
        },
        // Auth parser only produces the 9 documented ops above; these query-only
        // ops cannot reach here. unreachable keeps the switch exhaustive.
        else => unreachable,
    };
}
