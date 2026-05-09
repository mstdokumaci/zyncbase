const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const storage_values = @import("values.zig");

const TypedValue = storage_values.TypedValue;

pub const RenderedPredicate = struct {
    sql: []const u8,
    values: []TypedValue,

    pub fn deinit(self: RenderedPredicate, allocator: Allocator) void {
        for (self.values) |value| value.deinit(allocator);
        allocator.free(self.values);
        allocator.free(self.sql);
    }

    pub fn deinitSql(self: RenderedPredicate, allocator: Allocator) void {
        allocator.free(self.sql);
    }

    pub fn deinitValues(self: RenderedPredicate, allocator: Allocator) void {
        for (self.values) |value| value.deinit(allocator);
        allocator.free(self.values);
    }
};

pub fn renderAndClause(
    allocator: Allocator,
    table_metadata: *const schema.Table,
    predicate: ?query_ast.FilterPredicate,
) !?RenderedPredicate {
    const pred = predicate orelse return null;
    if (pred.isEmpty()) return null;

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql_buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(TypedValue) = .empty;
    errdefer {
        for (values.items) |value| value.deinit(allocator);
        values.deinit(allocator);
    }

    try sql_buf.appendSlice(allocator, " AND (");
    try appendFilterPredicateSql(allocator, &sql_buf, &values, table_metadata, pred);
    try sql_buf.append(allocator, ')');

    return .{
        .sql = try sql_buf.toOwnedSlice(allocator),
        .values = try values.toOwnedSlice(allocator),
    };
}

pub fn appendFilterPredicateSql(
    allocator: Allocator,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
    table_metadata: *const schema.Table,
    predicate: query_ast.FilterPredicate,
) !void {
    var emitted = false;

    const conds = predicate.conditions orelse @as([]const query_ast.Condition, &.{});
    for (conds, 0..) |cond, i| {
        if (emitted or i > 0) try sql_buf.appendSlice(allocator, " AND ");
        try appendConditionSql(allocator, sql_buf, values, table_metadata, cond);
        emitted = true;
    }

    const or_conds = predicate.or_conditions orelse @as([]const query_ast.Condition, &.{});
    if (or_conds.len > 0) {
        if (emitted) try sql_buf.appendSlice(allocator, " AND ");
        try sql_buf.append(allocator, '(');
        for (or_conds, 0..) |cond, i| {
            if (i > 0) try sql_buf.appendSlice(allocator, " OR ");
            try appendConditionSql(allocator, sql_buf, values, table_metadata, cond);
        }
        try sql_buf.append(allocator, ')');
    }
}

pub fn appendConditionSql(
    allocator: Allocator,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
    table_metadata: *const schema.Table,
    cond: query_ast.Condition,
) !void {
    if (cond.field_index >= table_metadata.fields.len) return error.InvalidConditionFormat;
    const sql_field_quoted = table_metadata.fields[cond.field_index].name_quoted;
    try sql_buf.appendSlice(allocator, sql_field_quoted);

    switch (cond.op) {
        .eq => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " = ?");
            try values.append(allocator, try val.clone(allocator));
        },
        .ne => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " != ?");
            try values.append(allocator, try val.clone(allocator));
        },
        .gt => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " > ?");
            try values.append(allocator, try val.clone(allocator));
        },
        .lt => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " < ?");
            try values.append(allocator, try val.clone(allocator));
        },
        .gte => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " >= ?");
            try values.append(allocator, try val.clone(allocator));
        },
        .lte => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " <= ?");
            try values.append(allocator, try val.clone(allocator));
        },
        .contains => {
            const val = cond.value orelse return error.MissingConditionValue;
            if (cond.field_type == .array) {
                try sql_buf.appendSlice(allocator, " IS NOT NULL AND EXISTS (SELECT 1 FROM json_each(");
                try sql_buf.appendSlice(allocator, sql_field_quoted);
                try sql_buf.appendSlice(allocator, ") WHERE json_each.value = ?)");
                try values.append(allocator, try val.clone(allocator));
                return;
            }

            if (val != .scalar or val.scalar != .text) {
                return error.InvalidConditionValue;
            }
            const escaped = try escapeLikePattern(allocator, val.scalar.text);
            errdefer allocator.free(escaped);
            try sql_buf.appendSlice(allocator, " LIKE '%' || ? || '%' ESCAPE '\\'");
            try values.append(allocator, TypedValue{ .scalar = .{ .text = escaped } });
        },
        .startsWith => {
            const val = cond.value orelse return error.MissingConditionValue;
            const raw_str = val.scalar.text;
            const escaped = try escapeLikePattern(allocator, raw_str);
            errdefer allocator.free(escaped);
            try sql_buf.appendSlice(allocator, " LIKE ? || '%' ESCAPE '\\'");
            try values.append(allocator, TypedValue{ .scalar = .{ .text = escaped } });
        },
        .endsWith => {
            const val = cond.value orelse return error.MissingConditionValue;
            const raw_str = val.scalar.text;
            const escaped = try escapeLikePattern(allocator, raw_str);
            errdefer allocator.free(escaped);
            try sql_buf.appendSlice(allocator, " LIKE '%' || ? ESCAPE '\\'");
            try values.append(allocator, TypedValue{ .scalar = .{ .text = escaped } });
        },
        .in, .notIn => {
            const is_not = cond.op == .notIn;
            try sql_buf.appendSlice(allocator, if (is_not) " NOT IN (" else " IN (");
            if (cond.value) |val| {
                if (val == .array) {
                    for (val.array, 0..) |v, i| {
                        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
                        try sql_buf.append(allocator, '?');
                        try values.append(allocator, TypedValue{ .scalar = try v.clone(allocator) });
                    }
                } else {
                    try sql_buf.append(allocator, '?');
                    try values.append(allocator, try val.clone(allocator));
                }
            }
            try sql_buf.append(allocator, ')');
        },
        .isNull => {
            try sql_buf.appendSlice(allocator, " IS NULL");
        },
        .isNotNull => {
            try sql_buf.appendSlice(allocator, " IS NOT NULL");
        },
    }
}

fn escapeLikePattern(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (c == '%' or c == '_' or c == '\\') {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}
