const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema = @import("../schema.zig");
const query_parser = @import("../query_parser.zig");
const query_ast = @import("../query_ast.zig");
const typed = @import("../typed.zig");
const sql = @import("sql.zig");
const sql_build = @import("../sql/build.zig");
const filter_sql = @import("filter_sql.zig");
const SqlBuf = @import("../sql/buf.zig").SqlBuf;

const DocId = typed.DocId;
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

pub fn buildSelectQuery(
    allocator: Allocator,
    table_metadata: *const schema.Table,
    namespace_id: i64,
    filter: *const query_ast.QueryFilter,
    guard_predicate: ?*const query_ast.FilterPredicate,
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

    // 1.. SELECT clause
    try sql_build.appendSelectFromTableSql(allocator, &buf, table_metadata);

    // 2.. WHERE clause
    try buf.appendSlice(allocator, " WHERE ");
    try sql_build.appendNamespaceFilterSql(allocator, &buf);
    try values.append(allocator, Value{ .scalar = .{ .integer = namespace_id } });

    try appendWhereConditions(allocator, &buf, &values, table_metadata, filter, sort_field_name_quoted);
    try appendGuardPredicate(allocator, &buf, &values, table_metadata, guard_predicate);

    // 3.. ORDER BY
    try sql_build.appendOrderBySql(allocator, &buf, sort_field_name_quoted, filter.order_by.desc);

    // 4.. LIMIT (+1 overfetch for accurate hasMore detection)
    if (filter.limit) |l| {
        const effective_limit: u32 = if (l == std.math.maxInt(u32)) l else l + 1;
        try buf.appendSlice(allocator, " LIMIT ");
        try std.fmt.format(buf.writer(allocator), "{}", .{effective_limit});
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
    table_metadata: *const schema.Table,
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
            filter.order_by.field_index == schema.id_field_index,
            filter.order_by.desc,
        );

        if (filter.order_by.field_index == schema.id_field_index) {
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

fn appendGuardPredicate(
    allocator: Allocator,
    buf: *SqlBuf,
    values: *std.ArrayListUnmanaged(Value),
    table_metadata: *const schema.Table,
    guard_predicate: ?*const query_ast.FilterPredicate,
) !void {
    const predicate = guard_predicate orelse return;
    if (predicate.isEmpty()) return;
    try buf.appendSlice(allocator, " AND (");
    try filter_sql.appendFilterPredicateSql(allocator, buf, values, table_metadata, predicate);
    try buf.append(allocator, ')');
}

pub fn execSelectDocument(
    allocator: Allocator,
    db: *sqlite.Db,
    stmt: *sqlite.c.sqlite3_stmt,
    id: DocId,
    namespace_id: i64,
    table_metadata: *const schema.Table,
    guard_values: ?[]const Value,
    json_buf: *std.ArrayListUnmanaged(u8),
) !?Record {
    try sql.bindDocIdNamespace(stmt, db, 1, id, namespace_id);

    var bind_idx: c_int = 3;
    if (guard_values) |vals| {
        for (vals) |val| {
            try sql.bindValue(val, db, stmt, bind_idx, allocator, json_buf);
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
    table_metadata: *const schema.Table,
    requested_limit: ?u32,
    sort_field_index: usize,
    json_buf: *std.ArrayListUnmanaged(u8),
) !struct { records: []Record, next_cursor_str: ?[]const u8 } {
    if (sort_field_index >= table_metadata.fields.len) return error.InvalidMessageFormat;

    for (values, 0..) |v, i| {
        try sql.bindValue(v, db, stmt, @intCast(i + 1), allocator, json_buf);
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
            const id_val = last_record.values[schema.id_field_index];
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
