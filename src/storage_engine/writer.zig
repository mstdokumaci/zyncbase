const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const types = @import("types.zig");
const reader = @import("reader.zig");
const TypedValue = types.TypedValue;
const WriteOp = types.WriteOp;
const ColumnValue = types.ColumnValue;

pub fn buildInsertOrReplaceOp(
    allocator: Allocator,
    sm: *const schema_manager.SchemaManager,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    columns: []const ColumnValue,
) !WriteOp {
    try sm.validateColumns(table, columns);

    // Look up table schema to determine which columns are array fields
    const table_metadata = sm.getTable(table) orelse return error.UnknownTable;

    // Build SQL: INSERT OR REPLACE INTO <table> (id, namespace_id, col1, .., created_at, updated_at)
    // VALUES (?, ?, .., COALESCE((SELECT created_at FROM <table> WHERE id=? AND namespace_id=?), ?), ?)
    // Array columns use jsonb(?) instead of ? as the placeholder.
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "INSERT INTO ");
    try sql_buf.appendSlice(allocator, table);
    try sql_buf.appendSlice(allocator, " (id, namespace_id");
    for (columns) |col| {
        try sql_buf.append(allocator, ',');
        try sql_buf.appendSlice(allocator, col.name);
    }
    try sql_buf.appendSlice(allocator, ", created_at, updated_at) VALUES (?, ?");
    for (columns) |col| {
        // Find the field schema to check if it's an array type
        var is_array = false;
        for (table_metadata.table.fields) |f| {
            if (std.mem.eql(u8, f.name, col.name)) {
                is_array = f.sql_type == .array;
                break;
            }
        }
        if (is_array) {
            try sql_buf.appendSlice(allocator, ", jsonb(?)");
        } else {
            try sql_buf.appendSlice(allocator, ", ?");
        }
    }
    // created_at and updated_at placeholders
    try sql_buf.appendSlice(allocator, ", ?, ?) ON CONFLICT(id, namespace_id) DO UPDATE SET ");

    // Update each column provided
    for (columns, 0..) |col, i| {
        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
        try sql_buf.appendSlice(allocator, col.name);
        try sql_buf.appendSlice(allocator, " = excluded.");
        try sql_buf.appendSlice(allocator, col.name);
    }
    // Always update updated_at
    try sql_buf.appendSlice(allocator, ", updated_at = excluded.updated_at");

    const sql = try sql_buf.toOwnedSlice(allocator);
    errdefer allocator.free(sql);

    const values = try allocator.alloc(TypedValue, columns.len);
    var initialized_count: usize = 0;
    errdefer {
        for (values[0..initialized_count]) |v| v.deinit(allocator);
        allocator.free(values);
    }
    for (columns, 0..) |col, i| {
        // Find the field schema to check its type
        var field_type: schema_manager.FieldType = .text;
        for (table_metadata.table.fields) |f| {
            if (std.mem.eql(u8, f.name, col.name)) {
                field_type = f.sql_type;
                break;
            }
        }
        values[i] = try reader.payloadToTypedValue(allocator, field_type, col.value);
        initialized_count += 1;
    }

    const now = std.time.timestamp();
    const id_owned = try allocator.dupe(u8, id);
    errdefer allocator.free(id_owned);
    const ns_owned = try allocator.dupe(u8, namespace);
    errdefer allocator.free(ns_owned);
    const table_owned = try allocator.dupe(u8, table);
    errdefer allocator.free(table_owned);

    return WriteOp{
        .insert = .{
            .table = table_owned,
            .id = id_owned,
            .namespace = ns_owned,
            .sql = sql,
            .values = values,
            .timestamp = now,
            .completion_signal = null,
        },
    };
}

pub fn buildUpdateFieldOp(
    allocator: Allocator,
    sm: *const schema_manager.SchemaManager,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    field: []const u8,
    value: msgpack.Payload,
) !WriteOp {
    try sm.validateField(table, field);

    // Look up the field's sql_type to determine if it's an array field and validate type
    const table_metadata = sm.getTable(table) orelse return error.UnknownTable;
    var field_sql_type: schema_manager.FieldType = .text;
    for (table_metadata.table.fields) |f| {
        if (std.mem.eql(u8, f.name, field)) {
            field_sql_type = f.sql_type;
            if (value != .nil) {
                try reader.validateValueType(field_sql_type, value);
            }
            break;
        }
    }

    const values = try allocator.alloc(TypedValue, 1);
    values[0] = .nil;
    errdefer {
        values[0].deinit(allocator);
        allocator.free(values);
    }
    values[0] = try reader.payloadToTypedValue(allocator, field_sql_type, value);

    // Use jsonb(?) placeholder for array fields, ? for others
    const field_placeholder = if (field_sql_type == .array) "jsonb(?)" else "?";

    const sql = try std.fmt.allocPrint(allocator,
        \\INSERT INTO {s} (id, namespace_id, {s}, created_at, updated_at)
        \\VALUES (?, ?, {s}, ?, ?)
        \\ON CONFLICT(id, namespace_id) DO UPDATE SET
        \\  {s} = excluded.{s},
        \\  updated_at = excluded.updated_at
    , .{ table, field, field_placeholder, field, field });
    errdefer allocator.free(sql);

    const id_owned = try allocator.dupe(u8, id);
    errdefer allocator.free(id_owned);
    const ns_owned = try allocator.dupe(u8, namespace);
    errdefer allocator.free(ns_owned);
    const table_owned = try allocator.dupe(u8, table);
    errdefer allocator.free(table_owned);

    const now = std.time.timestamp();
    return WriteOp{
        .update = .{
            .table = table_owned,
            .id = id_owned,
            .namespace = ns_owned,
            .sql = sql,
            .values = values,
            .timestamp = now,
            .completion_signal = null,
        },
    };
}

pub fn buildDeleteDocumentOp(
    allocator: Allocator,
    sm: *const schema_manager.SchemaManager,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
) !WriteOp {
    try sm.validateTable(table);

    const sql = try std.fmt.allocPrint(allocator, "DELETE FROM {s} WHERE id=? AND namespace_id=?", .{table});
    errdefer allocator.free(sql);

    const id_owned = try allocator.dupe(u8, id);
    errdefer allocator.free(id_owned);
    const ns_owned = try allocator.dupe(u8, namespace);
    errdefer allocator.free(ns_owned);
    const table_owned = try allocator.dupe(u8, table);
    errdefer allocator.free(table_owned);

    return WriteOp{
        .delete = .{
            .table = table_owned,
            .id = id_owned,
            .namespace = ns_owned,
            .sql = sql,
            .completion_signal = null,
        },
    };
}
