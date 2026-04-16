const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema_manager = @import("../schema_manager.zig");
const query_parser = @import("../query_parser.zig");
const types = @import("types.zig");
const sql = @import("sql.zig");

const TypedValue = types.TypedValue;

pub fn buildSelectDocumentSql(allocator: Allocator, table_metadata: schema_manager.TableMetadata) ![]const u8 {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "SELECT ");
    try sql.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    try sql_buf.appendSlice(allocator, " FROM ");
    try sql_buf.appendSlice(allocator, table_metadata.table.name);
    try sql_buf.appendSlice(allocator, " WHERE id=? AND namespace_id=?");
    return sql_buf.toOwnedSlice(allocator);
}

pub const QueryResult = struct {
    sql: []const u8,
    values: []TypedValue,

    pub fn deinit(self: QueryResult, allocator: Allocator) void {
        for (self.values) |v| v.deinit(allocator);
        allocator.free(self.values);
        allocator.free(self.sql);
    }
};

pub fn buildSelectQuery(
    allocator: Allocator,
    table_metadata: schema_manager.TableMetadata,
    namespace: []const u8,
    filter: query_parser.QueryFilter,
) !QueryResult {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(TypedValue) = .empty;
    errdefer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }

    // 1.. SELECT clause
    try sql_buf.appendSlice(allocator, "SELECT ");
    try sql.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    try sql_buf.appendSlice(allocator, " FROM ");
    try sql_buf.appendSlice(allocator, table_metadata.table.name);

    // 2.. WHERE clause
    try sql_buf.appendSlice(allocator, " WHERE namespace_id = ?");
    const ns_val = try allocator.dupe(u8, namespace);
    errdefer allocator.free(ns_val);
    try values.append(allocator, TypedValue{ .scalar = .{ .text = ns_val } });

    const conds = filter.conditions orelse @as([]const query_parser.Condition, &.{});
    const or_conds = filter.or_conditions orelse @as([]const query_parser.Condition, &.{});
    const has_conditions = conds.len > 0 or or_conds.len > 0;

    if (has_conditions or filter.after != null) {
        try sql_buf.appendSlice(allocator, " AND (");

        var added_where = false;

        // AND conditions
        if (conds.len > 0) {
            try sql_buf.appendSlice(allocator, "(");
            for (conds, 0..) |cond, i| {
                if (i > 0) try sql_buf.appendSlice(allocator, " AND ");
                try appendConditionSql(allocator, &sql_buf, &values, cond);
            }
            try sql_buf.appendSlice(allocator, ")");
            added_where = true;
        }

        // OR conditions
        if (or_conds.len > 0) {
            if (added_where) try sql_buf.appendSlice(allocator, " OR ");
            try sql_buf.appendSlice(allocator, "(");
            for (or_conds, 0..) |cond, i| {
                if (i > 0) try sql_buf.appendSlice(allocator, " OR ");
                try appendConditionSql(allocator, &sql_buf, &values, cond);
            }
            try sql_buf.appendSlice(allocator, ")");
            added_where = true;
        }

        // cursor-based pagination (after)
        if (filter.after) |cursor| {
            if (added_where) try sql_buf.appendSlice(allocator, " AND ");

            const sql_field = filter.order_by.field;
            const op = if (filter.order_by.desc) "<" else ">";

            // SQLite row-value comparison (requires SQLite 3.15.0+):
            // (sql_field, id) > (?, ?)
            if (std.mem.eql(u8, sql_field, "id")) {
                try sql_buf.appendSlice(allocator, "id ");
                try sql_buf.appendSlice(allocator, op);
                try sql_buf.appendSlice(allocator, " ?");
            } else {
                try sql_buf.appendSlice(allocator, "(");
                try sql_buf.appendSlice(allocator, sql_field);
                try sql_buf.appendSlice(allocator, ", id) ");
                try sql_buf.appendSlice(allocator, op);
                try sql_buf.appendSlice(allocator, " (?, ?)");
            }

            if (std.mem.eql(u8, sql_field, "id")) {
                const ci = try allocator.dupe(u8, cursor.id);
                errdefer allocator.free(ci);
                try values.append(allocator, TypedValue{ .scalar = .{ .text = ci } });
            } else {
                const sv = try cursor.sort_value.clone(allocator);
                errdefer sv.deinit(allocator);
                try values.append(allocator, sv);

                const ci = try allocator.dupe(u8, cursor.id);
                errdefer allocator.free(ci);
                try values.append(allocator, TypedValue{ .scalar = .{ .text = ci } });
            }
        }

        try sql_buf.appendSlice(allocator, ")");
    }

    // 3.. ORDER BY
    try sql_buf.appendSlice(allocator, " ORDER BY ");
    const o = filter.order_by;
    const sql_field = o.field;
    try sql_buf.appendSlice(allocator, sql_field);
    try sql_buf.appendSlice(allocator, if (o.desc) " DESC" else " ASC");
    try sql_buf.appendSlice(allocator, ", id ");
    try sql_buf.appendSlice(allocator, if (o.desc) " DESC" else " ASC");

    // 4.. LIMIT (+1 overfetch for accurate hasMore detection)
    if (filter.limit) |l| {
        const effective_limit: u32 = if (l == std.math.maxInt(u32)) l else l + 1;
        try sql_buf.appendSlice(allocator, " LIMIT ");
        try std.fmt.format(sql_buf.writer(allocator), "{}", .{effective_limit});
    }

    return QueryResult{
        .sql = try sql_buf.toOwnedSlice(allocator),
        .values = try values.toOwnedSlice(allocator),
    };
}

pub fn getCacheKey(allocator: Allocator, table: []const u8, namespace: []const u8, id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ table, namespace, id });
}

pub fn escapeLikePattern(allocator: Allocator, input: []const u8) ![]const u8 {
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

pub fn appendConditionSql(
    allocator: Allocator,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
    cond: query_parser.Condition,
) !void {
    const sql_field = cond.field;
    try sql_buf.appendSlice(allocator, sql_field);

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
            const raw_str = val.scalar.text;
            const escaped = try escapeLikePattern(allocator, raw_str);
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
                        try sql_buf.appendSlice(allocator, "?");
                        try values.append(allocator, TypedValue{ .scalar = try v.clone(allocator) });
                    }
                } else {
                    try sql_buf.appendSlice(allocator, "?");
                    try values.append(allocator, try val.clone(allocator));
                }
            }
            try sql_buf.appendSlice(allocator, ")");
        },
        .isNull => {
            try sql_buf.appendSlice(allocator, " IS NULL");
        },
        .isNotNull => {
            try sql_buf.appendSlice(allocator, " IS NOT NULL");
        },
    }
}

pub fn decodeTypedRow(
    allocator: Allocator,
    stmt: *sqlite.c.sqlite3_stmt,
    table_metadata: schema_manager.TableMetadata,
) !types.TypedRow {
    const col_count: usize = @intCast(sqlite.c.sqlite3_column_count(stmt));
    var fields = try allocator.alloc(types.FieldEntry, col_count);
    var i: usize = 0;
    errdefer {
        for (fields[0..i]) |f| f.deinit(allocator);
        allocator.free(fields);
    }

    while (i < col_count) : (i += 1) {
        const col_name_c = sqlite.c.sqlite3_column_name(stmt, @intCast(i)) orelse return error.InternalError;
        const col_name = std.mem.span(col_name_c);
        const field = table_metadata.getField(col_name);

        const val = try types.TypedValue.fromSQLiteColumn(allocator, stmt, @intCast(i), field);
        errdefer val.deinit(allocator);

        fields[i] = types.FieldEntry{
            .name = try allocator.dupe(u8, col_name),
            .value = val,
        };
    }
    return types.TypedRow{ .fields = fields };
}

pub fn execSelectDocumentTyped(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    id: []const u8,
    namespace: []const u8,
    table_metadata: schema_manager.TableMetadata,
) !?types.TypedRow {
    if (sql.bindTextTransient(stmt, 1, id) != sqlite.c.SQLITE_OK) return types.classifyStepError(db);
    if (sql.bindTextTransient(stmt, 2, namespace) != sqlite.c.SQLITE_OK) return types.classifyStepError(db);

    const rc = sqlite.c.sqlite3_step(stmt);
    if (rc == sqlite.c.SQLITE_DONE) return null;
    if (rc != sqlite.c.SQLITE_ROW) return types.classifyStepError(db);

    return try decodeTypedRow(allocator, stmt, table_metadata);
}

pub fn execQueryTyped(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    values: []const TypedValue,
    table_metadata: schema_manager.TableMetadata,
    requested_limit: ?u32,
    sort_field: []const u8,
) !struct { rows: []types.TypedRow, next_cursor: ?types.TypedCursor } {
    for (values, 0..) |v, i| {
        try v.bindSQLite(db, stmt, @intCast(i + 1), allocator);
    }

    var rows: std.ArrayListUnmanaged(types.TypedRow) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    while (true) {
        const rc = sqlite.c.sqlite3_step(stmt);
        if (rc == sqlite.c.SQLITE_DONE) break;
        if (rc != sqlite.c.SQLITE_ROW) return types.classifyStepError(db);

        try rows.append(allocator, try decodeTypedRow(allocator, stmt, table_metadata));
    }

    var next_cursor: ?types.TypedCursor = null;
    if (requested_limit) |limit_u32| {
        const limit: usize = @intCast(limit_u32);
        if (rows.items.len > limit) {
            const last_row = rows.items[limit - 1];
            const sort_val = last_row.getField(sort_field) orelse return error.InvalidMessageFormat;
            const id_val = last_row.getField("id") orelse return error.InvalidMessageFormat;
            next_cursor = types.TypedCursor{
                .sort_value = try sort_val.clone(allocator),
                .id = try allocator.dupe(u8, id_val.scalar.text),
            };

            var i: usize = limit;
            while (i < rows.items.len) : (i += 1) {
                rows.items[i].deinit(allocator);
            }
            rows.items.len = limit;
        }
    }

    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .next_cursor = next_cursor,
    };
}
