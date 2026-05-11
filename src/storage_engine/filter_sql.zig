const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const typed = @import("../typed.zig");

const Value = typed.Value;

pub const RenderedPredicate = struct {
    sql: ?[]const u8,
    values: ?[]Value,

    pub fn deinit(self: *RenderedPredicate, allocator: Allocator) void {
        if (self.values) |values| {
            deinitValueSlice(allocator, values);
        }
        if (self.sql) |sql| {
            allocator.free(sql);
        }
        self.* = .{ .sql = null, .values = null };
    }

    pub fn sqlSlice(self: *const RenderedPredicate) ?[]const u8 {
        return self.sql;
    }

    pub fn takeSql(self: *RenderedPredicate) ?[]const u8 {
        const sql = self.sql;
        self.sql = null;
        return sql;
    }

    pub fn takeValues(self: *RenderedPredicate) ?[]Value {
        const values = self.values;
        self.values = null;
        return values;
    }
};

pub fn deinitValueSlice(allocator: Allocator, values: []Value) void {
    for (values) |value| value.deinit(allocator);
    allocator.free(values);
}

pub fn appendClonedValue(
    allocator: Allocator,
    values: *std.ArrayListUnmanaged(Value),
    value: Value,
) !void {
    const cloned = try value.clone(allocator);
    errdefer cloned.deinit(allocator);
    try values.append(allocator, cloned);
}

pub fn appendOwnedValue(
    allocator: Allocator,
    values: *std.ArrayListUnmanaged(Value),
    value: Value,
) !void {
    errdefer value.deinit(allocator);
    try values.append(allocator, value);
}

pub fn renderAndClause(
    allocator: Allocator,
    table_metadata: *const schema.Table,
    predicate: ?*const query_ast.FilterPredicate,
) !?RenderedPredicate {
    const pred = predicate orelse return null;
    if (pred.isAlwaysTrue()) return null;

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql_buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (values.items) |value| value.deinit(allocator);
        values.deinit(allocator);
    }

    try sql_buf.appendSlice(allocator, " AND (");
    try appendFilterPredicateSql(allocator, &sql_buf, &values, table_metadata, pred);
    try sql_buf.append(allocator, ')');

    const sql_owned = try sql_buf.toOwnedSlice(allocator);
    errdefer allocator.free(sql_owned);

    const values_owned = try values.toOwnedSlice(allocator);
    return .{
        .sql = sql_owned,
        .values = values_owned,
    };
}

pub fn appendFilterPredicateSql(
    allocator: Allocator,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(Value),
    table_metadata: *const schema.Table,
    predicate: *const query_ast.FilterPredicate,
) !void {
    if (predicate.isAlwaysTrue()) {
        try sql_buf.append(allocator, '1');
        return;
    }
    if (predicate.isAlwaysFalse()) {
        try sql_buf.append(allocator, '0');
        return;
    }

    var emitted = false;

    const conds = predicate.conditions orelse @as([]const query_ast.Condition, &.{});
    for (conds, 0..) |cond, i| {
        if (emitted or i > 0) try sql_buf.appendSlice(allocator, " AND ");
        try appendConditionSql(allocator, sql_buf, values, table_metadata, &cond);
        emitted = true;
    }

    const or_conds = predicate.or_conditions orelse @as([]const query_ast.Condition, &.{});
    if (or_conds.len > 0) {
        if (emitted) try sql_buf.appendSlice(allocator, " AND ");
        try sql_buf.append(allocator, '(');
        for (or_conds, 0..) |cond, i| {
            if (i > 0) try sql_buf.appendSlice(allocator, " OR ");
            try appendConditionSql(allocator, sql_buf, values, table_metadata, &cond);
        }
        try sql_buf.append(allocator, ')');
    }
}

pub fn appendConditionSql(
    allocator: Allocator,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(Value),
    table_metadata: *const schema.Table,
    cond: *const query_ast.Condition,
) !void {
    if (cond.field_index >= table_metadata.fields.len) return error.InvalidConditionFormat;
    const sql_field_quoted = table_metadata.fields[cond.field_index].name_quoted;
    try sql_buf.appendSlice(allocator, sql_field_quoted);

    switch (cond.op) {
        .eq => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " = ?");
            try appendClonedValue(allocator, values, val);
        },
        .ne => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " != ?");
            try appendClonedValue(allocator, values, val);
        },
        .gt => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " > ?");
            try appendClonedValue(allocator, values, val);
        },
        .lt => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " < ?");
            try appendClonedValue(allocator, values, val);
        },
        .gte => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " >= ?");
            try appendClonedValue(allocator, values, val);
        },
        .lte => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " <= ?");
            try appendClonedValue(allocator, values, val);
        },
        .contains => {
            const val = cond.value orelse return error.MissingConditionValue;
            if (cond.field_type == .array) {
                try sql_buf.appendSlice(allocator, " IS NOT NULL AND EXISTS (SELECT 1 FROM json_each(");
                try sql_buf.appendSlice(allocator, sql_field_quoted);
                try sql_buf.appendSlice(allocator, ") WHERE json_each.value = ?)");
                try appendClonedValue(allocator, values, val);
                return;
            }

            if (val != .scalar or val.scalar != .text) {
                return error.InvalidConditionValue;
            }
            try sql_buf.appendSlice(allocator, " LIKE '%' || ? || '%' ESCAPE '\\'");
            const escaped = try escapeLikePattern(allocator, val.scalar.text);
            try appendOwnedValue(allocator, values, Value{ .scalar = .{ .text = escaped } });
        },
        .startsWith => {
            const val = cond.value orelse return error.MissingConditionValue;
            if (val != .scalar or val.scalar != .text) {
                return error.InvalidConditionValue;
            }
            try sql_buf.appendSlice(allocator, " LIKE ? || '%' ESCAPE '\\'");
            const escaped = try escapeLikePattern(allocator, val.scalar.text);
            try appendOwnedValue(allocator, values, Value{ .scalar = .{ .text = escaped } });
        },
        .endsWith => {
            const val = cond.value orelse return error.MissingConditionValue;
            if (val != .scalar or val.scalar != .text) {
                return error.InvalidConditionValue;
            }
            try sql_buf.appendSlice(allocator, " LIKE '%' || ? ESCAPE '\\'");
            const escaped = try escapeLikePattern(allocator, val.scalar.text);
            try appendOwnedValue(allocator, values, Value{ .scalar = .{ .text = escaped } });
        },
        .in, .notIn => {
            const is_not = cond.op == .notIn;
            try sql_buf.appendSlice(allocator, if (is_not) " NOT IN (" else " IN (");
            if (cond.value) |val| {
                if (val == .array) {
                    for (val.array, 0..) |v, i| {
                        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
                        try sql_buf.append(allocator, '?');
                        try appendOwnedValue(allocator, values, Value{ .scalar = try v.clone(allocator) });
                    }
                } else {
                    try sql_buf.append(allocator, '?');
                    try appendClonedValue(allocator, values, val);
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
