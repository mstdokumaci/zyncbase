const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema_manager = @import("../schema_manager.zig");
const query_parser = @import("../query_parser.zig");
const doc_id = @import("../doc_id.zig");
const types = @import("types.zig");
const sql = @import("sql.zig");

const TypedValue = types.TypedValue;
const DocId = types.DocId;

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
    table_metadata: *const schema_manager.TableMetadata,
    namespace_id: i64,
    filter: query_parser.QueryFilter,
) !QueryResult {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(TypedValue) = .empty;
    errdefer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }
    if (filter.order_by.field_index >= table_metadata.fields.len) return error.InvalidSortFormat;
    const sort_field_name = table_metadata.fields[filter.order_by.field_index].name;

    // 1.. SELECT clause
    try sql.appendSelectFromTableSql(allocator, &sql_buf, table_metadata);

    // 2.. WHERE clause
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql.appendNamespaceFilterSql(allocator, &sql_buf);
    try values.append(allocator, TypedValue{ .scalar = .{ .integer = namespace_id } });

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
                try appendConditionSql(allocator, &sql_buf, &values, table_metadata, cond);
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
                try appendConditionSql(allocator, &sql_buf, &values, table_metadata, cond);
            }
            try sql_buf.appendSlice(allocator, ")");
            added_where = true;
        }

        // cursor-based pagination (after)
        if (filter.after) |cursor| {
            if (added_where) try sql_buf.appendSlice(allocator, " AND ");

            // SQLite row-value comparison (requires SQLite 3.15.0+):
            // (sql_field, id) > (?, ?)
            try sql.appendCursorPredicateSql(
                allocator,
                &sql_buf,
                sort_field_name,
                filter.order_by.field_index == schema_manager.id_field_index,
                filter.order_by.desc,
            );

            if (filter.order_by.field_index == schema_manager.id_field_index) {
                try values.append(allocator, TypedValue{ .scalar = .{ .doc_id = cursor.id } });
            } else {
                const sv = try cursor.sort_value.clone(allocator);
                errdefer sv.deinit(allocator);
                try values.append(allocator, sv);
                try values.append(allocator, TypedValue{ .scalar = .{ .doc_id = cursor.id } });
            }
        }

        try sql_buf.appendSlice(allocator, ")");
    }

    // 3.. ORDER BY
    const o = filter.order_by;
    try sql.appendOrderBySql(allocator, &sql_buf, sort_field_name, o.desc);

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

pub fn getCacheKey(allocator: Allocator, table: []const u8, namespace: []const u8, id: DocId) ![]u8 {
    var id_hex_buf: [32]u8 = undefined;
    return try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ table, namespace, doc_id.hexSlice(id, &id_hex_buf) });
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
    table_metadata: *const schema_manager.TableMetadata,
    cond: query_parser.Condition,
) !void {
    if (cond.field_index >= table_metadata.fields.len) return error.InvalidConditionFormat;
    const sql_field = table_metadata.fields[cond.field_index].name;
    try sql.appendColumnIdentifierSql(allocator, sql_buf, sql_field);

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
                try sql.appendColumnIdentifierSql(allocator, sql_buf, sql_field);
                try sql_buf.appendSlice(allocator, ") WHERE json_each.value = ?)");
                try values.append(allocator, try val.clone(allocator));
                return;
            } else {
                if (val != .scalar or val.scalar != .text) {
                    return error.InvalidConditionValue;
                }
                const escaped = try escapeLikePattern(allocator, val.scalar.text);
                errdefer allocator.free(escaped);
                try sql_buf.appendSlice(allocator, " LIKE '%' || ? || '%' ESCAPE '\\'");
                try values.append(allocator, TypedValue{ .scalar = .{ .text = escaped } });
            }
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
    table_metadata: *const schema_manager.TableMetadata,
) !types.TypedRow {
    const col_count: usize = @intCast(sqlite.c.sqlite3_column_count(stmt));
    if (col_count != table_metadata.fields.len) return types.StorageError.ColumnCountMismatch;

    var values = try allocator.alloc(types.TypedValue, col_count);
    var i: usize = 0;
    errdefer {
        for (values[0..i]) |value| value.deinit(allocator);
        allocator.free(values);
    }

    while (i < col_count) : (i += 1) {
        const field = table_metadata.fields[i];
        const val = try types.TypedValue.fromSQLiteColumn(allocator, stmt, @intCast(i), field);
        errdefer val.deinit(allocator);
        values[i] = val;
    }
    return types.TypedRow{
        .values = values,
    };
}

pub fn execSelectDocumentTyped(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    id: DocId,
    namespace_id: i64,
    table_metadata: *const schema_manager.TableMetadata,
) !?types.TypedRow {
    const id_bytes = doc_id.toBytes(id);
    if (sql.bindBlobTransient(stmt, 1, &id_bytes) != sqlite.c.SQLITE_OK) return types.classifyStepError(db);
    if (sqlite.c.sqlite3_bind_int64(stmt, 2, namespace_id) != sqlite.c.SQLITE_OK) return types.classifyStepError(db);

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
    table_metadata: *const schema_manager.TableMetadata,
    requested_limit: ?u32,
    sort_field_index: usize,
) !struct { rows: []types.TypedRow, next_cursor: ?types.TypedCursor } {
    if (sort_field_index >= table_metadata.fields.len) return error.InvalidMessageFormat;

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
            if (limit > 0) {
                const last_row = rows.items[limit - 1];
                const sort_val = last_row.values[sort_field_index];
                const id_val = last_row.values[schema_manager.id_field_index];
                if (id_val != .scalar or id_val.scalar != .doc_id) return error.InvalidMessageFormat;
                next_cursor = types.TypedCursor{
                    .sort_value = try sort_val.clone(allocator),
                    .id = id_val.scalar.doc_id,
                };
            }

            while (rows.items.len > limit) {
                if (rows.pop()) |extra_row| {
                    var row = extra_row;
                    row.deinit(allocator);
                } else unreachable;
            }
        }
    }

    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .next_cursor = next_cursor,
    };
}
