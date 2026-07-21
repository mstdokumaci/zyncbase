const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema_types = @import("../schema/types.zig");
const schema_system = @import("../schema/system.zig");
const query_parser = @import("../query/parser.zig");
const query_ast = @import("../query/ast.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const sql = @import("sql.zig");
const sql_build = @import("../sql/build.zig");
const filter_sql = @import("filter_sql.zig");
const SqlBuf = @import("../sql/buf.zig").SqlBuf;

const DocId = typed_doc_id.DocId;
const Cursor = typed.Cursor;
const Record = typed.Record;
const Value = typed.Value;

pub const QueryResult = struct {
    sql: []const u8,
    values: []Value,

    pub fn deinit(self: QueryResult, allocator: Allocator) void {
        for (self.values) |v| v.deinit(allocator);
        allocator.free(self.values);
        allocator.free(self.sql);
    }
};

/// Builds only the bind values for a select query, without the SQL string.
/// Used on the cache-hit path where the SQL template is already cached.
/// The values array length doubles as param_count for cache collision safety.
pub fn buildSelectValues(
    allocator: Allocator,
    table_metadata: *const schema_types.Table,
    namespace_id: i64,
    filter: *const query_ast.QueryFilter,
) ![]Value {
    var values: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }
    if (filter.order_by.field_index >= table_metadata.fields.len) return error.InvalidSortFormat;

    // namespace_id
    try values.append(allocator, Value{ .scalar = .{ .integer = namespace_id } });

    // filter predicate conditions
    if (!filter.predicate.isEmpty()) {
        try filter_sql.appendFilterValues(allocator, &values, table_metadata, &filter.predicate);
    }

    // cursor-based pagination (after)
    if (filter.after) |cursor| {
        if (filter.order_by.field_index == schema_system.id_field_index) {
            try values.append(allocator, Value{ .scalar = .{ .doc_id = cursor.id } });
        } else {
            const sv = try cursor.sort_value.clone(allocator);
            errdefer sv.deinit(allocator);
            try values.append(allocator, sv);
            try values.append(allocator, Value{ .scalar = .{ .doc_id = cursor.id } });
        }
    }

    // limit
    if (filter.limit) |l| {
        const effective_limit: u32 = if (l == std.math.maxInt(u32)) l else l + 1;
        try values.append(allocator, Value{ .scalar = .{ .integer = @intCast(effective_limit) } });
    }

    return try values.toOwnedSlice(allocator);
}

/// Builds only the SQL template for a select query, without the bind values.
/// Used on the cache-miss path to prepare a new statement.
pub fn buildSelectSql(
    allocator: Allocator,
    table_metadata: *const schema_types.Table,
    filter: *const query_ast.QueryFilter,
) ![]u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);
    if (filter.order_by.field_index >= table_metadata.fields.len) return error.InvalidSortFormat;
    const sort_field_name_quoted = table_metadata.fields[filter.order_by.field_index].name_quoted;

    // 1.. SELECT clause (pre-built)
    try buf.appendSlice(allocator, table_metadata.select_from_sql);

    // 2.. WHERE clause
    try buf.appendSlice(allocator, " WHERE ");
    try sql_build.appendNamespaceFilterSql(allocator, &buf);
    try appendWhereConditionsSql(allocator, &buf, table_metadata, filter, sort_field_name_quoted);

    // 3.. ORDER BY
    try sql_build.appendOrderBySql(allocator, &buf, sort_field_name_quoted, filter.order_by.desc);

    // 4.. LIMIT
    if (filter.limit != null) {
        try buf.appendSlice(allocator, " LIMIT ?");
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn buildSelectQuery(
    allocator: Allocator,
    table_metadata: *const schema_types.Table,
    namespace_id: i64,
    filter: *const query_ast.QueryFilter,
) !QueryResult {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }
    if (filter.order_by.field_index >= table_metadata.fields.len) return error.InvalidSortFormat;
    const sort_field_name_quoted = table_metadata.fields[filter.order_by.field_index].name_quoted;

    // 1.. SELECT clause (pre-built, no field iteration per query)
    try buf.appendSlice(allocator, table_metadata.select_from_sql);

    // 2.. WHERE clause
    try buf.appendSlice(allocator, " WHERE ");
    try sql_build.appendNamespaceFilterSql(allocator, &buf);
    try values.append(allocator, Value{ .scalar = .{ .integer = namespace_id } });

    try appendWhereConditions(allocator, &buf, &values, table_metadata, filter, sort_field_name_quoted);

    // 3.. ORDER BY
    try sql_build.appendOrderBySql(allocator, &buf, sort_field_name_quoted, filter.order_by.desc);

    // 4.. LIMIT (+1 overfetch for accurate hasMore detection)
    if (filter.limit) |l| {
        const effective_limit: u32 = if (l == std.math.maxInt(u32)) l else l + 1;
        try buf.appendSlice(allocator, " LIMIT ?");
        try values.append(allocator, Value{ .scalar = .{ .integer = @intCast(effective_limit) } });
    }

    const sql_owned = try buf.toOwnedSlice(allocator);
    errdefer allocator.free(sql_owned);

    const values_owned = try values.toOwnedSlice(allocator);
    return QueryResult{
        .sql = sql_owned,
        .values = values_owned,
    };
}

fn appendWhereConditions(
    allocator: Allocator,
    buf: *SqlBuf,
    values: *std.ArrayListUnmanaged(Value),
    table_metadata: *const schema_types.Table,
    filter: *const query_ast.QueryFilter,
    sort_field_name_quoted: []const u8,
) !void {
    const has_conditions = !filter.predicate.isEmpty();
    if (!has_conditions and filter.after == null) return;

    try buf.appendSlice(allocator, " AND (");

    var added_where = false;

    if (has_conditions) {
        try filter_sql.appendFilterPredicateSql(allocator, buf, values, table_metadata, &filter.predicate);
        added_where = true;
    }

    // cursor-based pagination (after)
    if (filter.after) |cursor| {
        if (added_where) try buf.appendSlice(allocator, " AND ");

        try sql_build.appendCursorPredicateSql(
            allocator,
            buf,
            sort_field_name_quoted,
            filter.order_by.field_index == schema_system.id_field_index,
            filter.order_by.desc,
        );

        if (filter.order_by.field_index == schema_system.id_field_index) {
            try values.append(allocator, Value{ .scalar = .{ .doc_id = cursor.id } });
        } else {
            {
                const sv = try cursor.sort_value.clone(allocator);
                errdefer sv.deinit(allocator);
                try values.append(allocator, sv);
            }
            try values.append(allocator, Value{ .scalar = .{ .doc_id = cursor.id } });
        }
    }

    try buf.appendSlice(allocator, ")");
}

/// SQL-only variant of appendWhereConditions — emits `?` placeholders without values.
fn appendWhereConditionsSql(
    allocator: Allocator,
    buf: *SqlBuf,
    table_metadata: *const schema_types.Table,
    filter: *const query_ast.QueryFilter,
    sort_field_name_quoted: []const u8,
) !void {
    const has_conditions = !filter.predicate.isEmpty();
    if (!has_conditions and filter.after == null) return;

    try buf.appendSlice(allocator, " AND (");

    var added_where = false;

    if (has_conditions) {
        try filter_sql.appendFilterPredicateSqlPlaceholders(allocator, buf, table_metadata, &filter.predicate);
        added_where = true;
    }

    // cursor-based pagination (after)
    if (filter.after) |cursor| {
        _ = cursor;
        if (added_where) try buf.appendSlice(allocator, " AND ");

        try sql_build.appendCursorPredicateSql(
            allocator,
            buf,
            sort_field_name_quoted,
            filter.order_by.field_index == schema_system.id_field_index,
            filter.order_by.desc,
        );
    }

    try buf.appendSlice(allocator, ")");
}

pub fn execSelectDocument(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    id: DocId,
    namespace_id: i64,
    table_metadata: *const schema_types.Table,
    guard_values: ?[]const Value,
    json_buf: *sql.JsonBuf,
) !?Record {
    try sql.bindDocIdNamespace(stmt, db, 1, id, namespace_id);

    var bind_idx: c_int = 3;
    if (guard_values) |vals| {
        for (vals) |val| {
            try sql.bindValue(val, db, stmt, bind_idx, json_buf);
            bind_idx += 1;
        }
    }

    return try sql.fetchRecord(allocator, db, stmt, table_metadata);
}

pub fn execQuery(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    values: []const Value,
    table_metadata: *const schema_types.Table,
    requested_limit: ?u32,
    sort_field_index: usize,
    json_buf: *sql.JsonBuf,
) !struct { records: []Record, next_cursor_str: ?[]const u8 } {
    if (sort_field_index >= table_metadata.fields.len) return error.InvalidMessageFormat;

    for (values, 0..) |v, i| {
        try sql.bindValue(v, db, stmt, @intCast(i + 1), json_buf);
    }

    var records_list: std.ArrayListUnmanaged(Record) = .empty;
    errdefer {
        for (records_list.items) |r| r.deinit(allocator);
        records_list.deinit(allocator);
    }

    while (true) {
        if (try sql.fetchRecord(allocator, db, stmt, table_metadata)) |rec| {
            try records_list.append(allocator, rec);
        } else {
            break;
        }
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
            const id_val = last_record.values[schema_system.id_field_index];
            if (id_val != .scalar or id_val.scalar != .doc_id) return error.InvalidMessageFormat;

            const cursor = Cursor{
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
