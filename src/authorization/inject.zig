const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const schema = @import("../schema.zig");
const query_parser = @import("../query_parser.zig");
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

/// Extract $doc predicates from a Condition and produce SQL WHERE fragments.
/// Reuses reader.appendConditionSql for SQL generation — zero duplication.
pub fn injectDocCondition(
    allocator: Allocator,
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
) !InjectedClause {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql_buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(TypedValue) = .empty;
    errdefer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }

    try injectConditionInternal(allocator, condition, ctx, table, &sql_buf, &values);

    return InjectedClause{
        .sql = try sql_buf.toOwnedSlice(allocator),
        .bind_values = try values.toOwnedSlice(allocator),
    };
}

fn injectConditionInternal(
    allocator: Allocator,
    condition: types.Condition,
    ctx: EvalContext,
    table: *const schema.Table,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
) !void {
    switch (condition) {
        .boolean, .hook => {},
        .logical_and => |conds| {
            for (conds) |cond| {
                try injectConditionInternal(allocator, cond, ctx, table, sql_buf, values);
            }
        },
        .logical_or => {}, // OR injection not supported in initial implementation
        .comparison => |comp| {
            if (comp.lhs.scope != .doc) return;
            try injectComparison(allocator, comp, ctx, table, sql_buf, values);
        },
    }
}

fn injectComparison(
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

    const query_op = mapToQueryOp(comp.op);

    var query_cond = query_parser.Condition{
        .field_index = field_index,
        .op = query_op,
        .value = resolved_value,
        .field_type = field_meta.storage_type,
        .items_type = field_meta.items_type,
    };
    defer query_cond.deinit(allocator);

    try sql_buf.appendSlice(allocator, " AND ");
    try reader.appendConditionSql(allocator, sql_buf, values, table, query_cond);
}

fn mapToQueryOp(op: types.ComparisonOp) query_parser.Operator {
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
