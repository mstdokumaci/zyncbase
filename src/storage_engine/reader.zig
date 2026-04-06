const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const query_parser = @import("../query_parser.zig");
const types = @import("types.zig");

const StorageError = types.StorageError;
const TypedValue = types.TypedValue;
const ColumnContext = types.ColumnContext;

// ─── SQL Builders ─────────────────────────────────────────────────────────

pub fn buildSelectDocumentSql(allocator: Allocator, table_metadata: schema_manager.TableMetadata) ![]const u8 {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "SELECT ");
    try types.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    try sql_buf.appendSlice(allocator, " FROM ");
    try sql_buf.appendSlice(allocator, table_metadata.table.name);
    try sql_buf.appendSlice(allocator, " WHERE id=? AND namespace_id=?");
    return sql_buf.toOwnedSlice(allocator);
}

pub fn buildSelectFieldSql(allocator: Allocator, table_name: []const u8, field_name: []const u8, field_ctx: ?schema_manager.Field) ![]const u8 {
    if (field_ctx != null and field_ctx.?.sql_type == .array) {
        return try std.fmt.allocPrint(allocator, "SELECT json({s}) AS {s} FROM {s} WHERE id=? AND namespace_id=?", .{ field_name, field_name, table_name });
    } else {
        return try std.fmt.allocPrint(allocator, "SELECT {s} FROM {s} WHERE id=? AND namespace_id=?", .{ field_name, table_name });
    }
}

pub fn buildSelectCollectionSql(allocator: Allocator, table_metadata: schema_manager.TableMetadata) ![]const u8 {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "SELECT ");
    try types.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    try sql_buf.appendSlice(allocator, " FROM ");
    try sql_buf.appendSlice(allocator, table_metadata.table.name);
    try sql_buf.appendSlice(allocator, " WHERE namespace_id=?");
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

pub const ExecQueryResult = struct {
    data: msgpack.Payload,
    next_cursor_arr: ?msgpack.Payload = null,

    pub fn deinit(self: *ExecQueryResult, allocator: Allocator) void {
        self.data.free(allocator);
        if (self.next_cursor_arr) |*cursor| cursor.free(allocator);
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
    try types.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    try sql_buf.appendSlice(allocator, " FROM ");
    try sql_buf.appendSlice(allocator, table_metadata.table.name);

    // 2.. WHERE clause
    try sql_buf.appendSlice(allocator, " WHERE namespace_id = ?");
    const ns_val = try allocator.dupe(u8, namespace);
    errdefer allocator.free(ns_val);
    try values.append(allocator, TypedValue{ .text = ns_val });

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

            const sort_field = if (filter.order_by) |o| o.field else "id";
            const is_desc = if (filter.order_by) |o| o.desc else false;
            const op = if (is_desc) "<" else ">";

            const sql_field = sort_field;

            // SQLite row-value comparison (requires SQLite 3.15.0+):
            // (sort_field, id) > (?, ?)
            if (std.mem.eql(u8, sort_field, "id")) {
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

            // Find sort field type for correct binding
            var sort_ft: schema_manager.FieldType = .text;
            for (table_metadata.table.fields) |f| {
                if (std.mem.eql(u8, f.name, sql_field)) {
                    sort_ft = f.sql_type;
                    break;
                }
            }
            if (std.mem.eql(u8, sort_field, "id")) sort_ft = .text;
            if (std.mem.eql(u8, sort_field, "namespace_id")) sort_ft = .text;
            if (std.mem.eql(u8, sort_field, "created_at")) sort_ft = .integer;
            if (std.mem.eql(u8, sort_field, "updated_at")) sort_ft = .integer;

            if (std.mem.eql(u8, sort_field, "id")) {
                const ci = try allocator.dupe(u8, cursor.id);
                errdefer allocator.free(ci);
                try values.append(allocator, TypedValue{ .text = ci });
            } else {
                const sv = try TypedValue.fromPayload(allocator, sort_ft, cursor.sort_value);
                errdefer sv.deinit(allocator);
                try values.append(allocator, sv);

                const ci = try allocator.dupe(u8, cursor.id);
                errdefer allocator.free(ci);
                try values.append(allocator, TypedValue{ .text = ci });
            }
        }

        try sql_buf.appendSlice(allocator, ")");
    }

    // 3.. ORDER BY
    try sql_buf.appendSlice(allocator, " ORDER BY ");
    if (filter.order_by) |o| {
        const sql_field = o.field;
        try sql_buf.appendSlice(allocator, sql_field);
        try sql_buf.appendSlice(allocator, if (o.desc) " DESC" else " ASC");
        try sql_buf.appendSlice(allocator, ", id ");
        try sql_buf.appendSlice(allocator, if (o.desc) " DESC" else " ASC");
    } else {
        try sql_buf.appendSlice(allocator, "id ASC");
    }

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

pub fn classifyError(err: anyerror) anyerror {
    // Map SQLite errors to our specific error types
    return switch (err) {
        error.SQLiteConstraint => StorageError.ConstraintViolation,
        error.SQLiteFull => StorageError.DiskFull,
        error.SQLiteCorrupt, error.SQLiteNotADatabase => StorageError.DatabaseCorrupted,
        error.SQLiteBusy, error.SQLiteLocked => StorageError.DatabaseLocked,
        else => err,
    };
}

pub fn classifyStepError(db: *sqlite.Db) anyerror {
    const rc = sqlite.c.sqlite3_errcode(db.db);
    return switch (rc) {
        sqlite.c.SQLITE_CONSTRAINT => StorageError.ConstraintViolation,
        sqlite.c.SQLITE_FULL => StorageError.DiskFull,
        sqlite.c.SQLITE_CORRUPT, sqlite.c.SQLITE_NOTADB => StorageError.DatabaseCorrupted,
        sqlite.c.SQLITE_BUSY, sqlite.c.SQLITE_LOCKED => StorageError.DatabaseLocked,
        else => error.SQLiteError,
    };
}

pub fn logDatabaseError(operation: []const u8, err: anyerror, context: []const u8) void {
    std.log.debug("Database error during {s}: {} - Context: {s}", .{ operation, err, context });
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

pub fn readColumnValue(allocator: Allocator, stmt: sqlite.DynamicStatement, i: c_int, field: ?schema_manager.Field) !msgpack.Payload {
    const col_type = sqlite.c.sqlite3_column_type(stmt.stmt, i);
    if (field != null and field.?.sql_type == .array and col_type == sqlite.c.SQLITE_TEXT) {
        const ptr = sqlite.c.sqlite3_column_text(stmt.stmt, i);
        const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt.stmt, i));
        const s = if (ptr != null) ptr[0..len] else "[]";
        return msgpack.jsonToPayload(s, allocator);
    }
    return switch (col_type) {
        sqlite.c.SQLITE_INTEGER => {
            const val = sqlite.c.sqlite3_column_int64(stmt.stmt, i);
            if (field != null and field.?.sql_type == .boolean) {
                return msgpack.Payload{ .bool = val != 0 };
            }
            return msgpack.Payload.intToPayload(val);
        },
        sqlite.c.SQLITE_FLOAT => msgpack.Payload{ .float = sqlite.c.sqlite3_column_double(stmt.stmt, i) },
        sqlite.c.SQLITE_TEXT => blk: {
            const ptr = sqlite.c.sqlite3_column_text(stmt.stmt, i);
            const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt.stmt, i));
            const s = if (ptr != null) ptr[0..len] else "";
            break :blk try msgpack.Payload.strToPayload(s, allocator);
        },
        else => .nil,
    };
}

pub fn resolveColumnContext(
    stmt: sqlite.DynamicStatement,
    i: c_int,
    table_metadata: schema_manager.TableMetadata,
) ?ColumnContext {
    const col_name_c = sqlite.c.sqlite3_column_name(stmt.stmt, i) orelse {
        std.log.err("sqlite3_column_name returned NULL: OOM or Statement Corrupted", .{});
        return null;
    };
    const col_name = std.mem.span(col_name_c);

    // If the column name cannot be found in our pre-allocated payloads cache,
    // skip it and log an error. This handles schema drift gracefully.
    const key = table_metadata.field_payloads.get(col_name) orelse {
        std.log.err("Schema Cache out of sync: Column '{s}' not found in field_payloads", .{col_name});
        return null;
    };

    return ColumnContext{
        .index = i,
        .name = key.str.value(),
        .field = table_metadata.getField(col_name),
        .key = key,
    };
}

pub fn resolveAllColumnContexts(
    allocator: Allocator,
    stmt: sqlite.DynamicStatement,
    table_metadata: schema_manager.TableMetadata,
) ![]ColumnContext {
    const col_count: usize = @intCast(sqlite.c.sqlite3_column_count(stmt.stmt));
    var contexts_list: std.ArrayListUnmanaged(ColumnContext) = .empty;
    defer contexts_list.deinit(allocator);
    try contexts_list.ensureTotalCapacity(allocator, col_count);

    var i: c_int = 0;
    while (i < @as(c_int, @intCast(col_count))) : (i += 1) {
        if (resolveColumnContext(stmt, i, table_metadata)) |ctx| {
            try contexts_list.append(allocator, ctx);
        }
    }
    return try contexts_list.toOwnedSlice(allocator);
}

pub fn appendConditionSql(
    allocator: Allocator,
    sql_buf: *std.ArrayListUnmanaged(u8),
    values: *std.ArrayListUnmanaged(TypedValue),
    table_metadata: schema_manager.TableMetadata,
    cond: query_parser.Condition,
) !void {
    const sql_field = cond.field;

    const field = table_metadata.getField(sql_field);
    var ft: schema_manager.FieldType = if (field) |f| f.sql_type else .text;

    if (std.mem.eql(u8, cond.field, "id")) ft = .text;
    if (std.mem.eql(u8, cond.field, "namespace_id")) ft = .text;
    if (std.mem.eql(u8, cond.field, "created_at")) ft = .integer;
    if (std.mem.eql(u8, cond.field, "updated_at")) ft = .integer;

    try sql_buf.appendSlice(allocator, sql_field);

    switch (cond.op) {
        .eq => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " = ?");
            const tv = try TypedValue.fromPayload(allocator, ft, val);
            errdefer tv.deinit(allocator);
            try values.append(allocator, tv);
        },
        .ne => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " != ?");
            const tv = try TypedValue.fromPayload(allocator, ft, val);
            errdefer tv.deinit(allocator);
            try values.append(allocator, tv);
        },
        .gt => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " > ?");
            const tv = try TypedValue.fromPayload(allocator, ft, val);
            errdefer tv.deinit(allocator);
            try values.append(allocator, tv);
        },
        .lt => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " < ?");
            const tv = try TypedValue.fromPayload(allocator, ft, val);
            errdefer tv.deinit(allocator);
            try values.append(allocator, tv);
        },
        .gte => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " >= ?");
            const tv = try TypedValue.fromPayload(allocator, ft, val);
            errdefer tv.deinit(allocator);
            try values.append(allocator, tv);
        },
        .lte => {
            const val = cond.value orelse return error.MissingConditionValue;
            try sql_buf.appendSlice(allocator, " <= ?");
            const tv = try TypedValue.fromPayload(allocator, ft, val);
            errdefer tv.deinit(allocator);
            try values.append(allocator, tv);
        },
        .contains => {
            const val = cond.value orelse return error.MissingConditionValue;
            const raw_str = switch (val) {
                .str => |s| s.value(),
                else => return error.TypeMismatch,
            };
            const escaped = try escapeLikePattern(allocator, raw_str);
            errdefer allocator.free(escaped);
            try sql_buf.appendSlice(allocator, " LIKE '%' || ? || '%' ESCAPE '\\'");
            try values.append(allocator, TypedValue{ .text = escaped });
        },
        .startsWith => {
            const val = cond.value orelse return error.MissingConditionValue;
            const raw_str = switch (val) {
                .str => |s| s.value(),
                else => return error.TypeMismatch,
            };
            const escaped = try escapeLikePattern(allocator, raw_str);
            errdefer allocator.free(escaped);
            try sql_buf.appendSlice(allocator, " LIKE ? || '%' ESCAPE '\\'");
            try values.append(allocator, TypedValue{ .text = escaped });
        },
        .endsWith => {
            const val = cond.value orelse return error.MissingConditionValue;
            const raw_str = switch (val) {
                .str => |s| s.value(),
                else => return error.TypeMismatch,
            };
            const escaped = try escapeLikePattern(allocator, raw_str);
            errdefer allocator.free(escaped);
            try sql_buf.appendSlice(allocator, " LIKE '%' || ? ESCAPE '\\'");
            try values.append(allocator, TypedValue{ .text = escaped });
        },
        .isNull => try sql_buf.appendSlice(allocator, " IS NULL"),
        .isNotNull => try sql_buf.appendSlice(allocator, " IS NOT NULL"),
        .in, .notIn => {
            const is_not = cond.op == .notIn;
            try sql_buf.appendSlice(allocator, if (is_not) " NOT IN (" else " IN (");
            if (cond.value) |val| {
                if (val == .arr) {
                    for (val.arr, 0..) |v, i| {
                        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
                        try sql_buf.appendSlice(allocator, "?");
                        const tv = try TypedValue.fromPayload(allocator, ft, v);
                        errdefer tv.deinit(allocator);
                        try values.append(allocator, tv);
                    }
                } else {
                    try sql_buf.appendSlice(allocator, "?");
                    const tv = try TypedValue.fromPayload(allocator, ft, val);
                    errdefer tv.deinit(allocator);
                    try values.append(allocator, tv);
                }
            }
            try sql_buf.appendSlice(allocator, ")");
        },
    }
}

pub fn decodeRow(
    allocator: Allocator,
    stmt: sqlite.DynamicStatement,
    table_metadata: schema_manager.TableMetadata,
) !msgpack.Payload {
    const col_contexts = try resolveAllColumnContexts(allocator, stmt, table_metadata);
    defer allocator.free(col_contexts);

    var map = msgpack.Payload.mapPayload(allocator);
    errdefer map.free(allocator);

    for (col_contexts) |ctx| {
        const val = try readColumnValue(allocator, stmt, ctx.index, ctx.field);
        try map.mapPut(ctx.name, val);
    }
    return map;
}

pub fn execSelectDocument(
    allocator: Allocator,
    reader: *sqlite.Db,
    sql: []const u8,
    id: []const u8,
    namespace: []const u8,
    table_metadata: schema_manager.TableMetadata,
) !?msgpack.Payload {
    var stmt = reader.prepareDynamic(sql) catch |err| return classifyError(err);
    defer stmt.deinit();

    const id_z = try allocator.dupeZ(u8, id);
    defer allocator.free(id_z);
    const ns_z = try allocator.dupeZ(u8, namespace);
    defer allocator.free(ns_z);

    if (types.zyncbase_sqlite3_bind_text_transient(stmt.stmt, 1, id_z.ptr, @intCast(id.len)) != sqlite.c.SQLITE_OK) return classifyStepError(reader);
    if (types.zyncbase_sqlite3_bind_text_transient(stmt.stmt, 2, ns_z.ptr, @intCast(namespace.len)) != sqlite.c.SQLITE_OK) return classifyStepError(reader);

    const rc = sqlite.c.sqlite3_step(stmt.stmt);
    if (rc == sqlite.c.SQLITE_DONE) return null;
    if (rc != sqlite.c.SQLITE_ROW) return classifyStepError(reader);

    return try decodeRow(allocator, stmt, table_metadata);
}

pub fn execSelectScalar(
    allocator: Allocator,
    reader: *sqlite.Db,
    sql: []const u8,
    id: []const u8,
    namespace: []const u8,
    field_ctx: ?schema_manager.Field,
) !?msgpack.Payload {
    var stmt = reader.prepareDynamic(sql) catch |err| return classifyError(err);
    defer stmt.deinit();

    const id_z = try allocator.dupeZ(u8, id);
    defer allocator.free(id_z);
    const ns_z = try allocator.dupeZ(u8, namespace);
    defer allocator.free(ns_z);

    if (types.zyncbase_sqlite3_bind_text_transient(stmt.stmt, 1, id_z.ptr, @intCast(id.len)) != sqlite.c.SQLITE_OK) return classifyStepError(reader);
    if (types.zyncbase_sqlite3_bind_text_transient(stmt.stmt, 2, ns_z.ptr, @intCast(namespace.len)) != sqlite.c.SQLITE_OK) return classifyStepError(reader);

    const rc = sqlite.c.sqlite3_step(stmt.stmt);
    if (rc == sqlite.c.SQLITE_DONE) return null;
    if (rc != sqlite.c.SQLITE_ROW) return classifyStepError(reader);

    return try readColumnValue(allocator, stmt, 0, field_ctx);
}

pub fn execSelectCollection(
    allocator: Allocator,
    reader: *sqlite.Db,
    sql: []const u8,
    namespace: []const u8,
    table_metadata: schema_manager.TableMetadata,
) !msgpack.Payload {
    var stmt = reader.prepareDynamic(sql) catch |err| return classifyError(err);
    defer stmt.deinit();

    const ns_z = try allocator.dupeZ(u8, namespace);
    defer allocator.free(ns_z);

    if (types.zyncbase_sqlite3_bind_text_transient(stmt.stmt, 1, ns_z.ptr, @intCast(namespace.len)) != sqlite.c.SQLITE_OK) return classifyStepError(reader);

    var arr: std.ArrayListUnmanaged(msgpack.Payload) = .empty;
    errdefer {
        for (arr.items) |item| item.free(allocator);
        arr.deinit(allocator);
    }

    const col_contexts = try resolveAllColumnContexts(allocator, stmt, table_metadata);
    defer allocator.free(col_contexts);

    while (true) {
        const rc = sqlite.c.sqlite3_step(stmt.stmt);
        if (rc == sqlite.c.SQLITE_DONE) break;
        if (rc != sqlite.c.SQLITE_ROW) return classifyStepError(reader);

        var map = msgpack.Payload.mapPayload(allocator);
        errdefer map.free(allocator);

        for (col_contexts) |ctx| {
            const val = try readColumnValue(allocator, stmt, ctx.index, ctx.field);
            try map.mapPut(ctx.name, val);
        }
        try arr.append(allocator, map);
    }

    return msgpack.Payload{ .arr = try arr.toOwnedSlice(allocator) };
}

fn extractCursorTupleFromRow(
    allocator: Allocator,
    row: msgpack.Payload,
    sort_field: []const u8,
) !msgpack.Payload {
    if (row != .map) return error.InvalidMessageFormat;

    const sort_val = (try row.mapGet(sort_field)) orelse return error.InvalidMessageFormat;
    const id_val = (try row.mapGet("id")) orelse return error.InvalidMessageFormat;

    const sort_clone = try sort_val.deepClone(allocator);
    errdefer sort_clone.free(allocator);

    const id_clone = try id_val.deepClone(allocator);
    errdefer id_clone.free(allocator);

    const tuple_items = try allocator.alloc(msgpack.Payload, 2);
    errdefer allocator.free(tuple_items);

    tuple_items[0] = sort_clone;
    tuple_items[1] = id_clone;

    return msgpack.Payload{ .arr = tuple_items };
}

pub fn execQuery(
    allocator: Allocator,
    db: *sqlite.Db,
    sql: []const u8,
    values: []const TypedValue,
    table_metadata: schema_manager.TableMetadata,
    requested_limit: ?u32,
    sort_field: []const u8,
) !ExecQueryResult {
    var stmt = db.prepareDynamic(sql) catch |err| {
        return classifyError(err);
    };
    defer stmt.deinit();

    for (values, 0..) |v, i| {
        try v.bindSQLite(stmt, @intCast(i + 1));
    }

    var arr: std.ArrayListUnmanaged(msgpack.Payload) = .empty;
    errdefer {
        for (arr.items) |item| item.free(allocator);
        arr.deinit(allocator);
    }

    var next_cursor_arr: ?msgpack.Payload = null;
    errdefer if (next_cursor_arr) |*cursor| cursor.free(allocator);

    const col_contexts = try resolveAllColumnContexts(allocator, stmt, table_metadata);
    defer allocator.free(col_contexts);

    while (true) {
        const rc = sqlite.c.sqlite3_step(stmt.stmt);
        if (rc == sqlite.c.SQLITE_DONE) break;
        if (rc != sqlite.c.SQLITE_ROW) return classifyStepError(db);

        var map = msgpack.Payload.mapPayload(allocator);
        errdefer map.free(allocator);

        for (col_contexts, 0..) |ctx, i| {
            const val = try readColumnValue(allocator, stmt, @intCast(i), ctx.field);
            try map.mapPut(ctx.name, val);
        }
        try arr.append(allocator, map);
    }

    if (requested_limit) |limit_u32| {
        const limit: usize = @intCast(limit_u32);

        if (arr.items.len > limit) {
            next_cursor_arr = try extractCursorTupleFromRow(allocator, arr.items[limit - 1], sort_field);

            var i: usize = limit;
            while (i < arr.items.len) : (i += 1) {
                arr.items[i].free(allocator);
            }
            arr.items.len = limit;
        }
    }

    return ExecQueryResult{
        .data = msgpack.Payload{ .arr = try arr.toOwnedSlice(allocator) },
        .next_cursor_arr = next_cursor_arr,
    };
}
