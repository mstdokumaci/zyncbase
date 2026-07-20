const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const schema_types = @import("../schema/types.zig");
const query_ast = @import("../query/ast.zig");
const typed = @import("../typed/types.zig");
const evaluate_mod = @import("evaluate.zig");

const EvalContext = evaluate_mod.EvalContext;
const Value = typed.Value;

pub const DocPredicateError = error{
    InvalidFieldName,
    InvalidValue,
    InvalidContextVariable,
    UnsupportedAuthorizationPredicate,
    UnsupportedOperatorForFieldType,
} || Allocator.Error;

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
    or_clauses: usize = 0,

    fn isEmpty(self: Shape) bool {
        return self.conditions == 0 and self.or_clauses == 0;
    }
};

pub fn validateDocPredicate(condition: types.Condition, table: *const schema_types.Table) !void {
    _ = try validateShape(condition, table);
}

pub fn buildDocPredicate(
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema_types.Table,
) !?query_ast.FilterPredicate {
    const allocator = ctx.allocator;
    var result = try lowerCondition(condition, ctx, table);
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

pub fn authorizeWriteCondition(
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema_types.Table,
    is_create: bool,
) !?query_ast.FilterPredicate {
    if (is_create) {
        if (!evaluate_mod.evaluateConditionWithDoc(condition, ctx)) {
            return error.AccessDenied;
        }
    }
    return try buildDocPredicate(condition, ctx, table);
}

fn lowerCondition(
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema_types.Table,
) DocPredicateError!LowerResult {
    return switch (condition) {
        .boolean => |b| if (b) .allow else .deny,
        .logical_and => |conds| try lowerAnd(conds, ctx, table),
        .logical_or => |conds| try lowerOr(conds, ctx, table),
        .comparison => |comp| {
            if (comp.lhs.scope != .doc) {
                return switch (evaluate_mod.evaluateCondition(.{ .comparison = comp }, ctx)) {
                    .allow => .allow,
                    .deny, .needs_doc_predicate => .deny,
                };
            }
            return .{ .filter = try comparisonToFilter(comp, ctx, table) };
        },
    };
}

fn lowerAnd(
    conds: []const types.Condition,
    ctx: EvalContext,
    table: *const schema_types.Table,
) DocPredicateError!LowerResult {
    const allocator = ctx.allocator;
    var builder = PredicateBuilder{};
    errdefer builder.deinit(allocator);

    for (conds) |condition| {
        var result = try lowerCondition(condition, ctx, table);
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
    conds: []const types.Condition,
    ctx: EvalContext,
    table: *const schema_types.Table,
) DocPredicateError!LowerResult {
    const allocator = ctx.allocator;
    var first_filter: ?query_ast.FilterPredicate = null;
    errdefer if (first_filter) |*filter| filter.deinit(allocator);

    var or_builder: ?PredicateBuilder = null;
    errdefer if (or_builder) |*builder| builder.deinit(allocator);

    for (conds) |condition| {
        var result = try lowerCondition(condition, ctx, table);
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
    comp: types.Comparison,
    ctx: EvalContext,
    table: *const schema_types.Table,
) DocPredicateError!query_ast.FilterPredicate {
    const allocator = ctx.allocator;
    var condition = try comparisonToQueryCondition(comp, ctx, table);
    errdefer condition.deinit(allocator);

    const conditions = try allocator.alloc(query_ast.Condition, 1);
    conditions[0] = condition;
    return .{ .conditions = conditions };
}

fn comparisonToQueryCondition(
    comp: types.Comparison,
    ctx: EvalContext,
    table: *const schema_types.Table,
) DocPredicateError!query_ast.Condition {
    const allocator = ctx.allocator;
    const field_index = table.fieldIndex(comp.lhs.field) orelse return error.InvalidFieldName;
    const field_meta = table.fields[field_index];

    const value: ?typed.Value = if (comp.rhs) |rhs| blk: {
        var rhs_value = evaluate_mod.resolveOperand(rhs, ctx) orelse return error.InvalidValue;
        defer rhs_value.deinit(allocator);
        break :blk try rhs_value.intoOwned(allocator);
    } else null;

    return .{
        .field_index = field_index,
        .op = comp.op,
        .value = value,
        .field_type = field_meta.storage_type,
        .items_type = field_meta.items_type,
    };
}

fn validateShape(condition: types.Condition, table: *const schema_types.Table) DocPredicateError!Shape {
    return switch (condition) {
        .boolean => .{},
        .logical_and => |conds| validateAndShape(conds, table),
        .logical_or => |conds| validateOrShape(conds, table),
        .comparison => |comp| {
            if (comp.lhs.scope != .doc) return .{};
            try validateDocComparison(comp, table);
            return .{ .conditions = 1 };
        },
    };
}

fn validateAndShape(conds: []const types.Condition, table: *const schema_types.Table) DocPredicateError!Shape {
    var out = Shape{};
    for (conds) |condition| {
        const child = try validateShape(condition, table);
        out.conditions += child.conditions;
        out.or_clauses += child.or_clauses;
    }
    return out;
}

fn validateOrShape(conds: []const types.Condition, table: *const schema_types.Table) DocPredicateError!Shape {
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

    if (or_terms > 0) return .{ .or_clauses = or_terms };
    return first orelse Shape{};
}

fn shapeAsOrTermCount(shape: Shape) DocPredicateError!usize {
    if (shape.or_clauses > 0 and shape.conditions == 0) return shape.or_clauses;
    if (shape.conditions == 1 and shape.or_clauses == 0) return 1;
    return error.UnsupportedAuthorizationPredicate;
}

fn validateDocComparison(comp: types.Comparison, table: *const schema_types.Table) DocPredicateError!void {
    const field_index = table.fieldIndex(comp.lhs.field) orelse return error.InvalidFieldName;
    const field = table.fields[field_index];
    const lhs_type = ValueType.fromField(field);

    _ = try query_ast.operatorExpectsValueShape(comp.op, lhs_type.storage_type);

    // Nullary operators have no RHS; nothing further to validate.
    if (comp.op.isNullary()) return;

    switch (comp.rhs orelse return error.UnsupportedAuthorizationPredicate) {
        .literal => |value| try validateLiteralValue(comp.op, lhs_type, value),
        .context_var => |ctx_var| try validateContextVarValue(comp.op, lhs_type, ctx_var, table),
    }
}

const ValueType = struct {
    storage_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType = null,

    fn scalar(storage_type: schema_types.FieldType) ValueType {
        return .{ .storage_type = storage_type };
    }

    fn fromField(field: schema_types.Field) ValueType {
        return .{
            .storage_type = field.storage_type,
            .items_type = field.items_type,
        };
    }

    fn arrayItemsType(self: ValueType) !schema_types.FieldType {
        if (self.storage_type != .array) return error.InvalidValue;
        return self.items_type orelse error.InvalidValue;
    }

    fn membershipItemsType(self: ValueType) !schema_types.FieldType {
        return if (self.storage_type == .array) try self.arrayItemsType() else self.storage_type;
    }
};

fn validateLiteralValue(
    op: query_ast.Operator,
    lhs_type: ValueType,
    value: Value,
) DocPredicateError!void {
    const shape = try query_ast.operatorExpectsValueShape(op, lhs_type.storage_type);

    switch (shape) {
        .nullary => unreachable, // nullary ops have no literal RHS
        .scalar_text, .contains_text => {
            if (value != .scalar or value.scalar != .text) return error.InvalidValue;
        },
        .scalar => {
            if (value != .scalar) return error.InvalidValue;
            try validateScalarType(lhs_type.storage_type, value.scalar);
        },
        .array_membership => {
            if (value != .array) return error.InvalidValue;
            try validateScalarItems(try lhs_type.membershipItemsType(), value.array);
        },
        .array_field => {
            if (value != .array) return error.InvalidValue;
            try validateScalarItems(try lhs_type.arrayItemsType(), value.array);
        },
        .contains_element => {
            if (value != .scalar) return error.InvalidValue;
            try validateScalarType(try lhs_type.arrayItemsType(), value.scalar);
        },
    }
}

fn validateContextVarValue(
    op: query_ast.Operator,
    lhs_type: ValueType,
    ctx_var: types.ContextVar,
    table: *const schema_types.Table,
) DocPredicateError!void {
    const rhs_type = try resolveContextVarType(ctx_var, table);
    try validateRhsType(op, lhs_type, rhs_type);
}

fn resolveContextVarType(ctx_var: types.ContextVar, table: *const schema_types.Table) DocPredicateError!ValueType {
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
    op: query_ast.Operator,
    lhs_type: ValueType,
    rhs_type: ValueType,
) DocPredicateError!void {
    if (op == .in or op == .notIn) {
        if (rhs_type.storage_type != .array) return error.InvalidValue;
        try validateItemsType(try lhs_type.membershipItemsType(), rhs_type.items_type);
        return;
    }

    if (op == .contains and lhs_type.storage_type == .array) {
        const expected_items_type = try lhs_type.arrayItemsType();
        if (rhs_type.storage_type != expected_items_type) return error.InvalidValue;
        return;
    }

    if (op == .startsWith or op == .endsWith) {
        if (rhs_type.storage_type != .text) return error.InvalidValue;
        return;
    }

    try validateMatchingValueType(lhs_type, rhs_type);
}

fn validateMatchingValueType(lhs_type: ValueType, rhs_type: ValueType) DocPredicateError!void {
    if (lhs_type.storage_type == .array) {
        if (rhs_type.storage_type != .array) return error.InvalidValue;
        try validateItemsType(try lhs_type.arrayItemsType(), rhs_type.items_type);
        return;
    }

    if (rhs_type.storage_type != lhs_type.storage_type) return error.InvalidValue;
}

fn validateItemsType(expected_items_type: schema_types.FieldType, actual_items_type: ?schema_types.FieldType) DocPredicateError!void {
    if (actual_items_type == null or actual_items_type.? != expected_items_type) return error.InvalidValue;
}

fn validateScalarItems(expected_items_type: schema_types.FieldType, items: []const typed.ScalarValue) DocPredicateError!void {
    for (items) |item| {
        try validateScalarType(expected_items_type, item);
    }
}

fn validateScalarType(field_type: schema_types.FieldType, scalar: typed.ScalarValue) DocPredicateError!void {
    switch (field_type) {
        .text => if (scalar != .text) return error.InvalidValue,
        .integer => if (scalar != .integer) return error.InvalidValue,
        .real => if (scalar != .real) return error.InvalidValue,
        .boolean => if (scalar != .boolean) return error.InvalidValue,
        .doc_id => if (scalar != .doc_id) return error.InvalidValue,
        .array => return error.InvalidValue,
    }
}

const PredicateBuilder = struct {
    conditions: std.ArrayListUnmanaged(query_ast.Condition) = .empty,
    or_clauses: std.ArrayListUnmanaged(query_ast.OrClause) = .empty,

    fn isEmpty(self: PredicateBuilder) bool {
        return self.conditions.items.len == 0 and self.or_clauses.items.len == 0;
    }

    fn deinit(self: *PredicateBuilder, allocator: Allocator) void {
        for (self.conditions.items) |*condition| condition.deinit(allocator);
        self.conditions.deinit(allocator);
        for (self.or_clauses.items) |clause| {
            for (clause) |*condition| condition.deinit(allocator);
            allocator.free(clause);
        }
        self.or_clauses.deinit(allocator);
        self.* = .{};
    }

    fn appendAndFilterMove(
        self: *PredicateBuilder,
        allocator: Allocator,
        filter: *query_ast.FilterPredicate,
    ) !void {
        try self.appendMovedConditions(allocator, &self.conditions, filter.conditions);
        try self.moveOrClauses(allocator, filter);
    }

    fn appendOrFilterMove(
        self: *PredicateBuilder,
        allocator: Allocator,
        filter: *query_ast.FilterPredicate,
    ) !void {
        // Each filter being ORed becomes a single OrClause.
        // AND conditions: each becomes a single-condition OrClause.
        // OR clauses: each appended as-is.
        if (filter.conditions) |mutable_conds| {
            for (mutable_conds) |*cond| {
                const moved = cond.*;
                cond.* = .{ .field_index = 0, .op = .eq, .value = null, .field_type = .text, .items_type = null };
                const single = try allocator.alloc(query_ast.Condition, 1);
                single[0] = moved;
                try self.or_clauses.append(allocator, single);
            }
            allocator.free(mutable_conds);
            filter.conditions = null;
        }

        try self.moveOrClauses(allocator, filter);
    }

    fn moveOrClauses(self: *PredicateBuilder, allocator: Allocator, filter: *query_ast.FilterPredicate) !void {
        const clauses = filter.or_clauses orelse return;
        for (clauses) |clause| {
            var moved = try allocator.alloc(query_ast.Condition, clause.len);
            for (clause, 0..) |*c, i| {
                moved[i] = c.*;
                c.* = .{ .field_index = 0, .op = .eq, .value = null, .field_type = .text, .items_type = null };
            }
            try self.or_clauses.append(allocator, moved);
        }
        allocator.free(clauses);
        filter.or_clauses = null;
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
        allocator.free(conds);
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

        const or_clauses = if (self.or_clauses.items.len > 0)
            try self.or_clauses.toOwnedSlice(allocator)
        else
            null;

        return .{
            .conditions = conditions,
            .or_clauses = or_clauses,
        };
    }
};
