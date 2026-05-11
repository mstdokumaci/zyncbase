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

    fn deinit(self: *LowerResult, allocator: Allocator) void {
        switch (self.*) {
            .filter => |*filter| filter.deinit(allocator),
            else => {},
        }
        self.* = .allow;
    }

    fn takeFilter(self: *LowerResult) ?query_ast.FilterPredicate {
        return switch (self.*) {
            .filter => |filter| blk: {
                self.* = .allow;
                break :blk filter;
            },
            else => null,
        };
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
    var result = try lowerCondition(allocator, condition, ctx, table);
    defer result.deinit(allocator);
    switch (result) {
        .allow => return null,
        .deny => return error.AccessDenied,
        .filter => {
            var filter = result.takeFilter() orelse unreachable;
            errdefer filter.deinit(allocator);
            switch (try filter.normalize(allocator)) {
                .match_all => {
                    filter.deinit(allocator);
                    return null;
                },
                .match_none, .conditional => return filter,
            }
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
        var result = try lowerCondition(allocator, condition, ctx, table);
        defer result.deinit(allocator);
        switch (result) {
            .allow => {},
            .deny => return .deny,
            .filter => {
                var filter = result.takeFilter() orelse unreachable;
                defer filter.deinit(allocator);
                try builder.appendAndFilterMove(allocator, &filter);
            },
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
    errdefer if (first_filter) |*filter| filter.deinit(allocator);

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
            .filter => {
                var filter = result.takeFilter() orelse unreachable;
                defer filter.deinit(allocator);
                if (or_builder) |*builder| {
                    try builder.appendOrFilterMove(allocator, &filter);
                } else if (first_filter != null) {
                    var existing = first_filter.?;
                    first_filter = null;
                    defer existing.deinit(allocator);

                    var builder = PredicateBuilder{};
                    errdefer builder.deinit(allocator);
                    try builder.appendOrFilterMove(allocator, &existing);
                    try builder.appendOrFilterMove(allocator, &filter);
                    or_builder = builder;
                } else {
                    first_filter = filter;
                    filter = .{};
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
    var condition = try comparisonToQueryCondition(allocator, comp, ctx, table);
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

    var resolved_value = evaluate_mod.resolveRhs(comp.rhs, ctx) orelse return error.InvalidValue;
    defer resolved_value.deinit(allocator);

    return .{
        .field_index = field_index,
        .op = mapToQueryOp(comp.op),
        .value = try resolved_value.cloneOwned(allocator),
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
    const lhs_type = ValueType.fromField(field);

    if (!operatorAllowedForField(comp.op, lhs_type.storage_type)) return error.UnsupportedOperatorForFieldType;

    switch (comp.rhs) {
        .literal => |value| try validateLiteralValue(comp.op, lhs_type, value),
        .context_var => |ctx_var| try validateContextVarValue(comp.op, lhs_type, ctx_var, table),
    }
}

const ValueType = struct {
    storage_type: schema.FieldType,
    items_type: ?schema.FieldType = null,

    fn scalar(storage_type: schema.FieldType) ValueType {
        return .{ .storage_type = storage_type };
    }

    fn fromField(field: schema.Field) ValueType {
        return .{
            .storage_type = field.storage_type,
            .items_type = field.items_type,
        };
    }

    fn arrayItemsType(self: ValueType) !schema.FieldType {
        if (self.storage_type != .array) return error.InvalidValue;
        return self.items_type orelse error.InvalidValue;
    }

    fn membershipItemsType(self: ValueType) !schema.FieldType {
        return if (self.storage_type == .array) try self.arrayItemsType() else self.storage_type;
    }
};

fn validateLiteralValue(
    op: types.ComparisonOp,
    lhs_type: ValueType,
    value: Value,
) !void {
    if (op == .in_set or op == .not_in_set) {
        if (value != .array) return error.InvalidValue;
        try validateScalarItems(try lhs_type.membershipItemsType(), value.array);
        return;
    }

    if (op == .contains and lhs_type.storage_type == .array) {
        if (value != .scalar) return error.InvalidValue;
        try validateScalarType(try lhs_type.arrayItemsType(), value.scalar);
        return;
    }

    if (lhs_type.storage_type == .array) {
        if (value != .array) return error.InvalidValue;
        try validateScalarItems(try lhs_type.arrayItemsType(), value.array);
        return;
    }

    if (value != .scalar) return error.InvalidValue;
    try validateScalarType(lhs_type.storage_type, value.scalar);
}

fn validateContextVarValue(
    op: types.ComparisonOp,
    lhs_type: ValueType,
    ctx_var: types.ContextVar,
    table: *const schema.Table,
) !void {
    const rhs_type = try resolveContextVarType(ctx_var, table);
    try validateRhsType(op, lhs_type, rhs_type);
}

fn resolveContextVarType(ctx_var: types.ContextVar, table: *const schema.Table) !ValueType {
    return switch (ctx_var.scope) {
        .session => {
            if (std.mem.eql(u8, ctx_var.field, "userId")) {
                return ValueType.scalar(.doc_id);
            } else if (std.mem.eql(u8, ctx_var.field, "externalId")) {
                return ValueType.scalar(.text);
            } else return error.InvalidContextVariable;
        },
        .namespace => ValueType.scalar(.text),
        .path => {
            if (!std.mem.eql(u8, ctx_var.field, "table")) return error.InvalidValue;
            return ValueType.scalar(.text);
        },
        .value => {
            const value_index = table.fieldIndex(ctx_var.field) orelse return error.InvalidFieldName;
            const value_field = table.fields[value_index];
            return ValueType.fromField(value_field);
        },
        .doc => return error.InvalidContextVariable,
    };
}

fn validateRhsType(
    op: types.ComparisonOp,
    lhs_type: ValueType,
    rhs_type: ValueType,
) !void {
    if (op == .in_set or op == .not_in_set) {
        if (rhs_type.storage_type != .array) return error.InvalidValue;
        try validateItemsType(try lhs_type.membershipItemsType(), rhs_type.items_type);
        return;
    }

    if (op == .contains and lhs_type.storage_type == .array) {
        const expected_items_type = try lhs_type.arrayItemsType();
        if (rhs_type.storage_type != expected_items_type) return error.InvalidValue;
        return;
    }

    try validateMatchingValueType(lhs_type, rhs_type);
}

fn validateMatchingValueType(lhs_type: ValueType, rhs_type: ValueType) !void {
    if (lhs_type.storage_type == .array) {
        if (rhs_type.storage_type != .array) return error.InvalidValue;
        try validateItemsType(try lhs_type.arrayItemsType(), rhs_type.items_type);
        return;
    }

    if (rhs_type.storage_type != lhs_type.storage_type) return error.InvalidValue;
}

fn validateItemsType(expected_items_type: schema.FieldType, actual_items_type: ?schema.FieldType) !void {
    if (actual_items_type == null or actual_items_type.? != expected_items_type) return error.InvalidValue;
}

fn validateScalarItems(expected_items_type: schema.FieldType, items: []const typed.ScalarValue) !void {
    for (items) |item| {
        try validateScalarType(expected_items_type, item);
    }
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
        for (self.conditions.items) |*condition| condition.deinit(allocator);
        self.conditions.deinit(allocator);
        for (self.or_conditions.items) |*condition| condition.deinit(allocator);
        self.or_conditions.deinit(allocator);
        self.* = .{};
    }

    fn appendAndFilterMove(
        self: *PredicateBuilder,
        allocator: Allocator,
        filter: *query_ast.FilterPredicate,
    ) !void {
        if (self.or_conditions.items.len > 0 and filter.or_conditions != null and filter.or_conditions.?.len > 0) {
            return error.UnsupportedAuthorizationPredicate;
        }
        try self.appendMovedConditions(allocator, &self.conditions, filter.conditions);
        try self.appendMovedConditions(allocator, &self.or_conditions, filter.or_conditions);
    }

    fn appendOrFilterMove(
        self: *PredicateBuilder,
        allocator: Allocator,
        filter: *query_ast.FilterPredicate,
    ) !void {
        const conds = filter.conditions orelse @as([]const query_ast.Condition, &.{});
        const or_conds = filter.or_conditions orelse @as([]const query_ast.Condition, &.{});
        if (conds.len == 0 and or_conds.len > 0) {
            try self.appendMovedConditions(allocator, &self.or_conditions, filter.or_conditions);
            return;
        }
        if (conds.len == 1 and or_conds.len == 0) {
            try self.appendMovedConditions(allocator, &self.or_conditions, filter.conditions);
            return;
        }
        if (conds.len == 0 and or_conds.len == 0) return;
        return error.UnsupportedAuthorizationPredicate;
    }

    fn appendMovedConditions(
        _: *PredicateBuilder,
        allocator: Allocator,
        list: *std.ArrayListUnmanaged(query_ast.Condition),
        conditions: ?[]query_ast.Condition,
    ) !void {
        const conds = conditions orelse return;
        for (conds) |*condition| {
            var moved = condition.*;
            condition.* = .{
                .field_index = 0,
                .op = .eq,
                .value = null,
                .field_type = .text,
                .items_type = null,
            };
            errdefer moved.deinit(allocator);
            try list.append(allocator, moved);
        }
    }

    fn toOwnedPredicate(self: *PredicateBuilder, allocator: Allocator) !query_ast.FilterPredicate {
        const conditions = if (self.conditions.items.len > 0)
            try self.conditions.toOwnedSlice(allocator)
        else
            null;
        errdefer if (conditions) |conds| {
            for (conds) |*condition| condition.deinit(allocator);
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
