const std = @import("std");
const Allocator = std.mem.Allocator;
const schema_types = @import("../schema/types.zig");
const query_ast = @import("../query/ast.zig");
const typed = @import("../typed/types.zig");
const SqlBuf = @import("../sql/buf.zig").SqlBuf;
const SqlList = @import("../sql/buf.zig").SqlList;

const Value = typed.Value;

pub const RenderedPredicate = struct {
    sql: ?[]const u8,
    values: ?[]Value,

    pub fn deinit(self: *RenderedPredicate, allocator: Allocator) void {
        if (self.values) |values| {
            typed.deinitValueSlice(allocator, values);
        }
        if (self.sql) |sql| {
            allocator.free(sql);
        }
        self.* = .{ .sql = null, .values = null };
    }

    pub fn sqlSlice(self: *const RenderedPredicate) ?[]const u8 {
        return self.sql;
    }

    pub fn takeValues(self: *RenderedPredicate) ?[]Value {
        const values = self.values;
        self.values = null;
        return values;
    }
};

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
    table_metadata: *const schema_types.Table,
    predicate: ?*const query_ast.FilterPredicate,
) !?RenderedPredicate {
    const pred = predicate orelse return null;
    if (pred.isAlwaysTrue()) return null;

    var buf = SqlBuf.init();
    errdefer buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (values.items) |value| value.deinit(allocator);
        values.deinit(allocator);
    }

    try buf.appendSlice(allocator, " AND (");
    try appendFilterPredicateSql(allocator, &buf, &values, table_metadata, pred);
    try buf.append(allocator, ')');

    const sql_owned = try buf.toOwnedSlice(allocator);
    errdefer allocator.free(sql_owned);

    const values_owned = try values.toOwnedSlice(allocator);
    return .{
        .sql = sql_owned,
        .values = values_owned,
    };
}

pub fn appendFilterPredicateSql(
    allocator: Allocator,
    buf: *SqlBuf,
    values: *std.ArrayListUnmanaged(Value),
    table_metadata: *const schema_types.Table,
    predicate: *const query_ast.FilterPredicate,
) !void {
    if (predicate.isAlwaysTrue()) {
        try buf.append(allocator, '1');
        return;
    }
    if (predicate.isAlwaysFalse()) {
        try buf.append(allocator, '0');
        return;
    }

    const conds = predicate.conditions orelse @as([]const query_ast.Condition, &.{});
    var and_list = SqlList.init(buf, " AND ");
    for (conds) |*cond| {
        try appendConditionSql(allocator, &and_list, values, table_metadata, cond);
    }

    const clauses = predicate.or_clauses orelse @as([]const query_ast.OrClause, &.{});
    for (clauses) |clause| {
        if (clause.len == 0) continue;
        try and_list.maybeSep(allocator);
        try buf.append(allocator, '(');
        var or_list = SqlList.init(buf, " OR ");
        for (clause) |*cond| {
            try appendConditionSql(allocator, &or_list, values, table_metadata, cond);
        }
        try buf.append(allocator, ')');
    }
}

pub fn appendConditionSql(
    allocator: Allocator,
    list: *SqlList,
    values: *std.ArrayListUnmanaged(Value),
    table_metadata: *const schema_types.Table,
    cond: *const query_ast.Condition,
) !void {
    try list.maybeSep(allocator);
    const buf = list.buf;
    if (cond.field_index >= table_metadata.fields.len) return error.InvalidConditionFormat;
    const sql_field_quoted = table_metadata.fields[cond.field_index].name_quoted;
    try buf.appendSlice(allocator, sql_field_quoted);

    switch (cond.op) {
        .eq, .ne, .gt, .lt, .gte, .lte => {
            const val = try requireValue(cond);
            try buf.appendSlice(allocator, cmpOpSql(cond.op));
            try appendClonedValue(allocator, values, val);
        },
        .contains => {
            const val = try requireValue(cond);
            if (cond.field_type == .array) {
                try appendArrayContainsSql(allocator, buf, values, sql_field_quoted, val);
                return;
            }
            try appendLikePredicate(allocator, buf, values, val, "'%' || ? || '%'");
        },
        .startsWith, .endsWith => {
            const val = try requireValue(cond);
            const pattern: []const u8 = if (cond.op == .startsWith)
                "? || '%'"
            else
                "'%' || ?";
            try appendLikePredicate(allocator, buf, values, val, pattern);
        },
        .in, .notIn => {
            try appendInPredicate(allocator, buf, values, cond);
        },
        .isNull => {
            try buf.appendSlice(allocator, " IS NULL");
        },
        .isNotNull => {
            try buf.appendSlice(allocator, " IS NOT NULL");
        },
    }
}

fn requireValue(cond: *const query_ast.Condition) !Value {
    return cond.value orelse return error.MissingConditionValue;
}

fn cmpOpSql(op: query_ast.Operator) []const u8 {
    return switch (op) {
        .eq => " = ?",
        .ne => " != ?",
        .gt => " > ?",
        .lt => " < ?",
        .gte => " >= ?",
        .lte => " <= ?",
        else => unreachable,
    };
}

fn appendLikePredicate(
    allocator: Allocator,
    buf: *SqlBuf,
    values: *std.ArrayListUnmanaged(Value),
    val: Value,
    pattern: []const u8,
) !void {
    if (val != .scalar or val.scalar != .text) {
        return error.InvalidConditionValue;
    }
    try buf.appendSlice(allocator, " LIKE ");
    try buf.appendSlice(allocator, pattern);
    try buf.appendSlice(allocator, " ESCAPE '\\'");
    const escaped = try escapeLikePattern(allocator, val.scalar.text);
    try appendOwnedValue(allocator, values, Value{ .scalar = .{ .text = escaped } });
}

fn appendArrayContainsSql(
    allocator: Allocator,
    buf: *SqlBuf,
    values: *std.ArrayListUnmanaged(Value),
    sql_field_quoted: []const u8,
    val: Value,
) !void {
    try buf.appendSlice(allocator, " IS NOT NULL AND EXISTS (SELECT 1 FROM json_each(");
    try buf.appendSlice(allocator, sql_field_quoted);
    try buf.appendSlice(allocator, ") WHERE json_each.value = ?)");
    try appendClonedValue(allocator, values, val);
}

fn appendInPredicate(
    allocator: Allocator,
    buf: *SqlBuf,
    values: *std.ArrayListUnmanaged(Value),
    cond: *const query_ast.Condition,
) !void {
    const is_not = cond.op == .notIn;
    try buf.appendSlice(allocator, if (is_not) " NOT IN (" else " IN (");
    if (cond.value) |val| {
        if (val == .array) {
            var in_list = SqlList.init(buf, ", ");
            for (val.array) |v| {
                try in_list.maybeSep(allocator);
                try buf.append(allocator, '?');
                try appendOwnedValue(allocator, values, Value{ .scalar = try v.clone(allocator) });
            }
        } else {
            try buf.append(allocator, '?');
            try appendClonedValue(allocator, values, val);
        }
    }
    try buf.append(allocator, ')');
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
