const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema = @import("../schema.zig");
const query_parser = @import("../query_parser.zig");
const query_ast = @import("../query_ast.zig");
const typed = @import("../typed.zig");
const errors = @import("errors.zig");
const sql = @import("sql.zig");
const filter_sql = @import("filter_sql.zig");
const storage_cache = @import("cache.zig");

const StorageError = errors.StorageError;
const DocId = typed.DocId;
const MetadataCacheKey = storage_cache.MetadataCacheKey;
const TypedCursor = typed.TypedCursor;
const TypedRecord = typed.TypedRecord;
const TypedValue = typed.TypedValue;

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
    table_metadata: *const schema.Table,
    namespace_id: i64,
    filter: query_ast.QueryFilter,
    guard_predicate: ?query_ast.FilterPredicate,
) !QueryResult {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(TypedValue) = .empty;
    errdefer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }
    if (filter.order_by.field_index >= table_metadata.fields.len) return error.InvalidSortFormat;
    const sort_field_name_quoted = table_metadata.fields[filter.order_by.field_index].name_quoted;

    // 1.. SELECT clause
    try sql.appendSelectFromTableSql(allocator, &sql_buf, table_metadata);

    // 2.. WHERE clause
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql.appendNamespaceFilterSql(allocator, &sql_buf);
    try values.append(allocator, TypedValue{ .scalar = .{ .integer = namespace_id } });

    const has_conditions = !filter.predicate.isEmpty();

    if (has_conditions or filter.after != null) {
        try sql_buf.appendSlice(allocator, " AND (");

        var added_where = false;

        if (has_conditions) {
            try filter_sql.appendFilterPredicateSql(allocator, &sql_buf, &values, table_metadata, filter.predicate);
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
                sort_field_name_quoted,
                filter.order_by.field_index == schema.id_field_index,
                filter.order_by.desc,
            );

            if (filter.order_by.field_index == schema.id_field_index) {
                try values.append(allocator, TypedValue{ .scalar = .{ .doc_id = cursor.id } });
            } else {
                {
                    const sv = try cursor.sort_value.clone(allocator);
                    errdefer sv.deinit(allocator);
                    try values.append(allocator, sv);
                }
                try values.append(allocator, TypedValue{ .scalar = .{ .doc_id = cursor.id } });
            }
        }

        try sql_buf.appendSlice(allocator, ")");
    }

    if (guard_predicate) |predicate| {
        if (!predicate.isEmpty()) {
            try sql_buf.appendSlice(allocator, " AND (");
            try filter_sql.appendFilterPredicateSql(allocator, &sql_buf, &values, table_metadata, predicate);
            try sql_buf.append(allocator, ')');
        }
    }

    // 3.. ORDER BY
    const o = filter.order_by;
    try sql.appendOrderBySql(allocator, &sql_buf, sort_field_name_quoted, o.desc);

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

pub fn getCacheKey(table_metadata: *const schema.Table, namespace_id: i64, id: DocId) MetadataCacheKey {
    const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema.global_namespace_id;
    return MetadataCacheKey{
        .namespace_id = effective_namespace_id,
        .table_index = table_metadata.index,
        .id = id,
    };
}

pub fn decodeTypedRecord(
    allocator: Allocator,
    stmt: *sqlite.c.sqlite3_stmt,
    table_metadata: *const schema.Table,
) !TypedRecord {
    const col_count: usize = @intCast(sqlite.c.sqlite3_column_count(stmt));
    if (col_count != table_metadata.fields.len) return StorageError.ColumnCountMismatch;

    var values = try allocator.alloc(TypedValue, col_count);
    var i: usize = 0;
    errdefer {
        for (values[0..i]) |value| value.deinit(allocator);
        allocator.free(values);
    }

    while (i < col_count) : (i += 1) {
        const field = table_metadata.fields[i];
        const val = try sql.typedValueFromColumn(allocator, stmt, @intCast(i), field);
        errdefer val.deinit(allocator);
        values[i] = val;
    }
    return TypedRecord{
        .values = values,
    };
}

pub fn execSelectDocumentTyped(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    id: DocId,
    namespace_id: i64,
    table_metadata: *const schema.Table,
    guard_values: ?[]const TypedValue,
) !?TypedRecord {
    const id_bytes = typed.docIdToBytes(id);
    if (sql.bindBlobTransient(stmt, 1, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);
    if (sqlite.c.sqlite3_bind_int64(stmt, 2, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(db);

    var bind_idx: c_int = 3;
    if (guard_values) |vals| {
        for (vals) |val| {
            try sql.bindTypedValue(val, db, stmt, bind_idx, allocator);
            bind_idx += 1;
        }
    }

    const rc = sqlite.c.sqlite3_step(stmt);
    if (rc == sqlite.c.SQLITE_DONE) return null;
    if (rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(db);

    return try decodeTypedRecord(allocator, stmt, table_metadata);
}

pub fn execQueryTyped(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    values: []const TypedValue,
    table_metadata: *const schema.Table,
    requested_limit: ?u32,
    sort_field_index: usize,
) !struct { records: []TypedRecord, next_cursor_str: ?[]const u8 } {
    if (sort_field_index >= table_metadata.fields.len) return error.InvalidMessageFormat;

    for (values, 0..) |v, i| {
        try sql.bindTypedValue(v, db, stmt, @intCast(i + 1), allocator);
    }

    var records_list: std.ArrayListUnmanaged(TypedRecord) = .empty;
    errdefer {
        for (records_list.items) |r| r.deinit(allocator);
        records_list.deinit(allocator);
    }

    while (true) {
        const rc = sqlite.c.sqlite3_step(stmt);
        if (rc == sqlite.c.SQLITE_DONE) break;
        if (rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(db);

        try records_list.append(allocator, try decodeTypedRecord(allocator, stmt, table_metadata));
    }

    const has_more = if (requested_limit) |limit_u32| blk: {
        const limit: usize = @intCast(limit_u32);
        break :blk records_list.items.len > limit;
    } else false;

    if (requested_limit) |limit_u32| {
        const limit: usize = @intCast(limit_u32);
        while (records_list.items.len > limit) {
            if (records_list.pop()) |extra_record| {
                var record = extra_record;
                record.deinit(allocator);
            } else unreachable;
        }
    }

    const owned_records = try records_list.toOwnedSlice(allocator);
    errdefer {
        for (owned_records) |r| r.deinit(allocator);
        allocator.free(owned_records);
    }

    var next_cursor_str: ?[]const u8 = null;
    if (has_more) {
        const limit: usize = @intCast(requested_limit.?);
        if (limit > 0) {
            const last_record = owned_records[limit - 1];
            const sort_val = last_record.values[sort_field_index];
            const id_val = last_record.values[schema.id_field_index];
            if (id_val != .scalar or id_val.scalar != .doc_id) return error.InvalidMessageFormat;

            const cursor = TypedCursor{
                .sort_value = sort_val,
                .id = id_val.scalar.doc_id,
            };
            next_cursor_str = try query_parser.encodeCursorToken(allocator, cursor);
        }
    }

    return .{
        .records = owned_records,
        .next_cursor_str = next_cursor_str,
    };
}
