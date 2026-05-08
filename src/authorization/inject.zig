const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const schema = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const reader = @import("../storage_engine/reader.zig");
const TypedValue = @import("../storage_engine/values.zig").TypedValue;
const evaluate_mod = @import("evaluate.zig");
const EvalContext = evaluate_mod.EvalContext;

pub const InjectedClause = struct {
    /// SQL fragment like ` AND "owner_id" = ?`
    sql: []const u8,
    /// Bind values (TypedValue) matching the ? placeholders
    bind_values: []TypedValue,

    pub fn deinit(self: InjectedClause, allocator: Allocator) void {
        for (self.bind_values) |v| v.deinit(allocator);
        allocator.free(self.bind_values);
        allocator.free(self.sql);
    }
};

pub fn cloneBindValues(allocator: Allocator, clause_opt: ?InjectedClause) !?[]TypedValue {
    const clause = clause_opt orelse return null;
    const values = try allocator.alloc(TypedValue, clause.bind_values.len);
    var initialized_count: usize = 0;
    errdefer {
        for (values[0..initialized_count]) |v| v.deinit(allocator);
        allocator.free(values);
    }

    for (clause.bind_values, 0..) |value, i| {
        values[i] = try value.clone(allocator);
        initialized_count += 1;
    }
    return values;
}

pub fn deinitBindValues(allocator: Allocator, values_opt: ?[]TypedValue) void {
    const values = values_opt orelse return;
    for (values) |value| value.deinit(allocator);
    allocator.free(values);
}

const ExprResult = enum { allow, deny, sql };

/// Extract $doc predicates from a Condition and produce SQL WHERE fragments.
/// Reuses reader.appendConditionSql for SQL generation with zero duplication.
pub fn injectDocCondition(
    allocator: Allocator,
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
) !InjectedClause {
    var expr_sql: std.ArrayListUnmanaged(u8) = .empty;
    defer expr_sql.deinit(allocator);

    var values: std.ArrayListUnmanaged(TypedValue) = .empty;
    var values_owned = true;
    errdefer {
        if (values_owned) {
            for (values.items) |v| v.deinit(allocator);
            values.deinit(allocator);
        }
    }

    const result = try appendInjectedExpr(allocator, condition, ctx, table, &expr_sql, &values);

    if (result == .deny) return error.AccessDenied;

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql_buf.deinit(allocator);
    if (result == .sql) {
        try sql_buf.appendSlice(allocator, " AND (");
        try sql_buf.appendSlice(allocator, expr_sql.items);
        try sql_buf.appendSlice(allocator, ")");
    }

    const sql = try sql_buf.toOwnedSlice(allocator);
    errdefer allocator.free(sql);
    const bind_values = try values.toOwnedSlice(allocator);
    values_owned = false;

    return InjectedClause{
        .sql = sql,
        .bind_values = bind_values,
    };
}

fn appendInjectedExpr(
    allocator: Allocator,
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
) anyerror!ExprResult {
    return switch (condition) {
        .boolean => |b| if (b) .allow else .deny,
        .hook => .deny,
        .logical_and => |conds| try appendLogicalExpr(allocator, conds, .logical_and, ctx, table, sql_buf, values),
        .logical_or => |conds| try appendLogicalExpr(allocator, conds, .logical_or, ctx, table, sql_buf, values),
        .comparison => |comp| {
            if (comp.lhs.scope != .doc) {
                return switch (evaluate_mod.evaluateCondition(.{ .comparison = comp }, ctx)) {
                    .allow => .allow,
                    .deny, .needs_injection => .deny,
                };
            }
            try appendComparisonExpr(allocator, comp, ctx, table, sql_buf, values);
            return .sql;
        },
    };
}

fn appendLogicalExpr(
    allocator: Allocator,
    conds: []const types.Condition,
    comptime tag: std.meta.Tag(types.Condition),
    ctx: EvalContext,
    table: *const schema.Table,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
) anyerror!ExprResult {
    var emitted = false;

    for (conds) |cond| {
        var child_sql: std.ArrayListUnmanaged(u8) = .empty;
        defer child_sql.deinit(allocator);

        var child_values: std.ArrayListUnmanaged(TypedValue) = .empty;
        defer {
            for (child_values.items) |v| v.deinit(allocator);
            child_values.deinit(allocator);
        }

        const result = try appendInjectedExpr(allocator, cond, ctx, table, &child_sql, &child_values);
        switch (result) {
            .allow => {
                if (tag == .logical_or) return .allow;
            },
            .deny => {
                if (tag == .logical_and) return .deny;
            },
            .sql => {
                if (!emitted) {
                    try sql_buf.append(allocator, '(');
                    emitted = true;
                } else {
                    try sql_buf.appendSlice(allocator, if (tag == .logical_and) " AND " else " OR ");
                }

                try sql_buf.appendSlice(allocator, child_sql.items);
                try values.appendSlice(allocator, child_values.items);
                child_values.items.len = 0;
            },
        }
    }

    if (!emitted) return if (tag == .logical_and) .allow else .deny;
    try sql_buf.append(allocator, ')');
    return .sql;
}

fn appendComparisonExpr(
    allocator: Allocator,
    comp: types.Comparison,
    ctx: EvalContext,
    table: *const schema.Table,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
) !void {
    const field_index = table.fieldIndex(comp.lhs.field) orelse return error.InvalidFieldName;
    const field_meta = table.fields[field_index];

    const resolved_value = evaluate_mod.resolveRhs(comp.rhs, ctx) orelse return error.InvalidValue;
    defer resolved_value.deinit(allocator);

    const query_op = mapToQueryOp(comp.op);

    const query_cond = query_ast.Condition{
        .field_index = field_index,
        .op = query_op,
        .value = resolved_value.value,
        .field_type = field_meta.storage_type,
        .items_type = field_meta.items_type,
    };
    try reader.appendConditionSql(allocator, sql_buf, values, table, query_cond);
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
