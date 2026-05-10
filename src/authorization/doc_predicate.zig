const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const schema = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const typed = @import("../typed.zig");
const evaluate_mod = @import("evaluate.zig");

const EvalContext = evaluate_mod.EvalContext;
const Value = typed.Value;

const LowerResult = union(enum) {
    allow,
    deny,
    filter: query_ast.FilterPredicate,

    fn deinit(self: LowerResult, allocator: Allocator) void {
        switch (self) {
            .filter => |filter| filter.deinit(allocator),
            else => {},
        }
    }
};

const Shape = struct {
    conditions: usize = 0,
    or_conditions: usize = 0,

    fn isEmpty(self: Shape) bool {
        return self.conditions == 0 and self.or_conditions == 0;
    }
};

pub fn validateDocPredicate(condition: types.Condition, table: *const schema.Table) !void {
    _ = try validateShape(condition, table);
}

pub fn buildDocPredicate(
    allocator: Allocator,
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
) !?query_ast.FilterPredicate {
    const result = try lowerCondition(allocator, condition, ctx, table);
    switch (result) {
        .allow => return null,
        .deny => return error.AccessDenied,
        .filter => |filter| {
            if (filter.isEmpty()) {
                filter.deinit(allocator);
                return null;
            }
            return filter;
        },
    }
}

fn lowerCondition(
    allocator: Allocator,
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
) anyerror!LowerResult {
    return switch (condition) {
        .boolean => |b| if (b) .allow else .deny,
        .hook => .deny,
        .logical_and => |conds| try lowerAnd(allocator, conds, ctx, table),
        .logical_or => |conds| try lowerOr(allocator, conds, ctx, table),
        .comparison => |comp| {
            if (comp.lhs.scope != .doc) {
                return switch (evaluate_mod.evaluateCondition(.{ .comparison = comp }, ctx)) {
                    .allow => .allow,
                    .deny, .needs_doc_predicate => .deny,
                };
            }
            return .{ .filter = try comparisonToFilter(allocator, comp, ctx, table) };
        },
    };
}

fn lowerAnd(
    allocator: Allocator,
    conds: []const types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
) !LowerResult {
    var builder = PredicateBuilder{};
    errdefer builder.deinit(allocator);

    for (conds) |condition| {
        const result = try lowerCondition(allocator, condition, ctx, table);
        defer result.deinit(allocator);
        switch (result) {
            .allow => {},
            .deny => return .deny,
            .filter => |filter| try builder.appendAndFilter(allocator, filter),
        }
    }

    if (builder.isEmpty()) return .allow;
    return .{ .filter = try builder.toOwnedPredicate(allocator) };
}

fn lowerOr(
    allocator: Allocator,
    conds: []const types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
) !LowerResult {
    var first_filter: ?query_ast.FilterPredicate = null;
    errdefer if (first_filter) |filter| filter.deinit(allocator);

    var or_builder: ?PredicateBuilder = null;
    errdefer if (or_builder) |*builder| builder.deinit(allocator);

    for (conds) |condition| {
        var result = try lowerCondition(allocator, condition, ctx, table);
        defer result.deinit(allocator);
        switch (result) {
            .allow => {
                return .allow;
            },
            .deny => {},
            .filter => |filter| {
                if (or_builder) |*builder| {
                    try builder.appendOrFilter(allocator, filter);
                } else if (first_filter) |existing| {
                    var builder = PredicateBuilder{};
                    errdefer builder.deinit(allocator);
                    try builder.appendOrFilter(allocator, existing);
                    existing.deinit(allocator);
                    first_filter = null;
                    try builder.appendOrFilter(allocator, filter);
                    or_builder = builder;
                } else {
                    first_filter = filter;
                    result = .allow;
                }
            },
        }
    }

    if (or_builder) |*builder| {
        if (builder.isEmpty()) return .deny;
        return .{ .filter = try builder.toOwnedPredicate(allocator) };
    }
    if (first_filter) |filter| {
        first_filter = null;
        return .{ .filter = filter };
    }
    return .deny;
}

fn comparisonToFilter(
    allocator: Allocator,
    comp: types.Comparison,
    ctx: EvalContext,
    table: *const schema.Table,
) !query_ast.FilterPredicate {
    const condition = try comparisonToQueryCondition(allocator, comp, ctx, table);
    errdefer condition.deinit(allocator);

    const conditions = try allocator.alloc(query_ast.Condition, 1);
    conditions[0] = condition;
    return .{ .conditions = conditions };
}

fn comparisonToQueryCondition(
    allocator: Allocator,
    comp: types.Comparison,
    ctx: EvalContext,
    table: *const schema.Table,
) !query_ast.Condition {
    const field_index = table.fieldIndex(comp.lhs.field) orelse return error.InvalidFieldName;
    const field_meta = table.fields[field_index];

    const resolved_value = evaluate_mod.resolveRhs(comp.rhs, ctx) orelse return error.InvalidValue;
    defer resolved_value.deinit(allocator);

    return .{
        .field_index = field_index,
        .op = mapToQueryOp(comp.op),
        .value = try resolved_value.value.clone(allocator),
        .field_type = field_meta.storage_type,
        .items_type = field_meta.items_type,
    };
}

fn validateShape(condition: types.Condition, table: *const schema.Table) anyerror!Shape {
    return switch (condition) {
        .boolean => .{},
        .hook => error.UnsupportedAuthorizationPredicate,
        .logical_and => |conds| validateAndShape(conds, table),
        .logical_or => |conds| validateOrShape(conds, table),
        .comparison => |comp| {
            if (comp.lhs.scope != .doc) return .{};
            try validateDocComparison(comp, table);
            return .{ .conditions = 1 };
        },
    };
}

fn validateAndShape(conds: []const types.Condition, table: *const schema.Table) !Shape {
    var out = Shape{};
    for (conds) |condition| {
        const child = try validateShape(condition, table);
        if (out.or_conditions > 0 and child.or_conditions > 0) {
            return error.UnsupportedAuthorizationPredicate;
        }
        out.conditions += child.conditions;
        out.or_conditions += child.or_conditions;
    }
    return out;
}

fn validateOrShape(conds: []const types.Condition, table: *const schema.Table) !Shape {
    var first: ?Shape = null;
    var or_terms: usize = 0;

    for (conds) |condition| {
        const child = try validateShape(condition, table);
        if (child.isEmpty()) continue;

        if (first == null and or_terms == 0) {
            first = child;
            continue;
        }

        if (first) |existing| {
            or_terms += try shapeAsOrTermCount(existing);
            first = null;
        }
        or_terms += try shapeAsOrTermCount(child);
    }

    if (or_terms > 0) return .{ .or_conditions = or_terms };
    return first orelse Shape{};
}

fn shapeAsOrTermCount(shape: Shape) !usize {
    if (shape.or_conditions > 0 and shape.conditions == 0) return shape.or_conditions;
    if (shape.conditions == 1 and shape.or_conditions == 0) return 1;
    return error.UnsupportedAuthorizationPredicate;
}

fn validateDocComparison(comp: types.Comparison, table: *const schema.Table) !void {
    const field_index = table.fieldIndex(comp.lhs.field) orelse return error.InvalidFieldName;
    const field = table.fields[field_index];

    if (!operatorAllowedForField(comp.op, field.storage_type)) return error.UnsupportedOperatorForFieldType;

    switch (comp.rhs) {
        .literal => |value| try validateLiteralValue(comp.op, field.storage_type, field.items_type, value),
        .context_var => |ctx_var| try validateContextVarValue(field.storage_type, field.items_type, ctx_var, table),
    }
}

fn validateLiteralValue(
    op: types.ComparisonOp,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
    value: Value,
) !void {
    if (op == .in_set or op == .not_in_set) {
        if (value != .array) return error.InvalidValue;
        for (value.array) |item| {
            try validateScalarType(if (field_type == .array) items_type orelse return error.InvalidValue else field_type, item);
        }
        return;
    }

    if (op == .contains and field_type == .array) {
        if (value != .scalar) return error.InvalidValue;
        try validateScalarType(items_type orelse return error.InvalidValue, value.scalar);
        return;
    }

    if (field_type == .array) {
        if (value != .array) return error.InvalidValue;
        return;
    }

    if (value != .scalar) return error.InvalidValue;
    try validateScalarType(field_type, value.scalar);
}

fn validateContextVarValue(
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
    ctx_var: types.ContextVar,
    table: *const schema.Table,
) !void {
    _ = items_type;
    return switch (ctx_var.scope) {
        .session => {
            if (std.mem.eql(u8, ctx_var.field, "userId")) {
                if (field_type != .doc_id) return error.InvalidValue;
            } else if (std.mem.eql(u8, ctx_var.field, "externalId")) {
                if (field_type != .text) return error.InvalidValue;
            } else return error.InvalidContextVariable;
        },
        .namespace => {
            if (field_type != .text) return error.InvalidValue;
        },
        .path => {
            if (!std.mem.eql(u8, ctx_var.field, "table") or field_type != .text) return error.InvalidValue;
        },
        .value => {
            const value_index = table.fieldIndex(ctx_var.field) orelse return error.InvalidFieldName;
            const value_field = table.fields[value_index];
            if (value_field.storage_type != field_type) return error.InvalidValue;
        },
        .doc => return error.InvalidContextVariable,
    };
}

fn validateScalarType(field_type: schema.FieldType, scalar: typed.ScalarValue) !void {
    switch (field_type) {
        .text => if (scalar != .text) return error.InvalidValue,
        .integer => if (scalar != .integer) return error.InvalidValue,
        .real => if (scalar != .real) return error.InvalidValue,
        .boolean => if (scalar != .boolean) return error.InvalidValue,
        .doc_id => if (scalar != .doc_id) return error.InvalidValue,
        .array => return error.InvalidValue,
    }
}

fn operatorAllowedForField(op: types.ComparisonOp, field_type: schema.FieldType) bool {
    return switch (op) {
        .eq, .ne => true,
        .gt, .gte, .lt, .lte => field_type != .array,
        .contains => field_type == .text or field_type == .array,
        .in_set, .not_in_set => true,
    };
}

fn mapToQueryOp(op: types.ComparisonOp) query_ast.Operator {
    return switch (op) {
        .eq => .eq,
        .ne => .ne,
        .gt => .gt,
        .gte => .gte,
        .lt => .lt,
        .lte => .lte,
        .in_set => .in,
        .not_in_set => .notIn,
        .contains => .contains,
    };
}

const PredicateBuilder = struct {
    conditions: std.ArrayListUnmanaged(query_ast.Condition) = .empty,
    or_conditions: std.ArrayListUnmanaged(query_ast.Condition) = .empty,

    fn isEmpty(self: PredicateBuilder) bool {
        return self.conditions.items.len == 0 and self.or_conditions.items.len == 0;
    }

    fn deinit(self: *PredicateBuilder, allocator: Allocator) void {
        for (self.conditions.items) |condition| condition.deinit(allocator);
        self.conditions.deinit(allocator);
        for (self.or_conditions.items) |condition| condition.deinit(allocator);
        self.or_conditions.deinit(allocator);
    }

    fn appendAndFilter(
        self: *PredicateBuilder,
        allocator: Allocator,
        filter: query_ast.FilterPredicate,
    ) !void {
        if (self.or_conditions.items.len > 0 and filter.or_conditions != null and filter.or_conditions.?.len > 0) {
            return error.UnsupportedAuthorizationPredicate;
        }
        try self.appendClonedConditions(allocator, &self.conditions, filter.conditions);
        try self.appendClonedConditions(allocator, &self.or_conditions, filter.or_conditions);
    }

    fn appendOrFilter(
        self: *PredicateBuilder,
        allocator: Allocator,
        filter: query_ast.FilterPredicate,
    ) !void {
        const conds = filter.conditions orelse @as([]const query_ast.Condition, &.{});
        const or_conds = filter.or_conditions orelse @as([]const query_ast.Condition, &.{});
        if (conds.len == 0 and or_conds.len > 0) {
            try self.appendClonedConditions(allocator, &self.or_conditions, or_conds);
            return;
        }
        if (conds.len == 1 and or_conds.len == 0) {
            try self.appendClonedConditions(allocator, &self.or_conditions, conds);
            return;
        }
        if (conds.len == 0 and or_conds.len == 0) return;
        return error.UnsupportedAuthorizationPredicate;
    }

    fn appendClonedConditions(
        _: *PredicateBuilder,
        allocator: Allocator,
        list: *std.ArrayListUnmanaged(query_ast.Condition),
        conditions: ?[]const query_ast.Condition,
    ) !void {
        const conds = conditions orelse return;
        for (conds) |condition| {
            const cloned = try condition.clone(allocator);
            errdefer cloned.deinit(allocator);
            try list.append(allocator, cloned);
        }
    }

    fn toOwnedPredicate(self: *PredicateBuilder, allocator: Allocator) !query_ast.FilterPredicate {
        const conditions = if (self.conditions.items.len > 0)
            try self.conditions.toOwnedSlice(allocator)
        else
            null;
        errdefer if (conditions) |conds| {
            for (conds) |condition| condition.deinit(allocator);
            allocator.free(conds);
        };

        const or_conditions = if (self.or_conditions.items.len > 0)
            try self.or_conditions.toOwnedSlice(allocator)
        else
            null;

        return .{
            .conditions = conditions,
            .or_conditions = or_conditions,
        };
    }
};
