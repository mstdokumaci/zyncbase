const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const types = @import("types.zig");
const write_command = @import("write_command.zig");
const sql_utils = @import("sql_utils.zig");
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
    try sql_buf.appendSlice(allocator, ", updated_at = excluded.updated_at RETURNING ");
    try sql_utils.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);

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
        values[i] = try types.TypedValue.fromPayload(allocator, field_type, col.value);
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
                try types.TypedValue.validateValue(field_sql_type, value);
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
    values[0] = try types.TypedValue.fromPayload(allocator, field_sql_type, value);

    // Use jsonb(?) placeholder for array fields, ? for others
    const field_placeholder = if (field_sql_type == .array) "jsonb(?)" else "?";

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "INSERT INTO ");
    try sql_buf.appendSlice(allocator, table);
    try sql_buf.appendSlice(allocator, " (id, namespace_id, ");
    try sql_buf.appendSlice(allocator, field);
    try sql_buf.appendSlice(allocator, ", created_at, updated_at) VALUES (?, ?, ");
    try sql_buf.appendSlice(allocator, field_placeholder);
    try sql_buf.appendSlice(allocator, ", ?, ?) ON CONFLICT(id, namespace_id) DO UPDATE SET ");
    try sql_buf.appendSlice(allocator, field);
    try sql_buf.appendSlice(allocator, " = excluded.");
    try sql_buf.appendSlice(allocator, field);
    try sql_buf.appendSlice(allocator, ", updated_at = excluded.updated_at RETURNING ");

    try sql_utils.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);

    const sql = try sql_buf.toOwnedSlice(allocator);
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

pub fn buildInsertFromCommandOp(
    allocator: Allocator,
    sm: *const schema_manager.SchemaManager,
    write: *write_command.DocumentWrite,
) !WriteOp {
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "INSERT INTO ");
    try sql_buf.appendSlice(allocator, write.table);
    try sql_buf.appendSlice(allocator, " (id, namespace_id");
    for (write.columns) |col| {
        try sql_buf.append(allocator, ',');
        try sql_buf.appendSlice(allocator, col.name);
    }
    try sql_buf.appendSlice(allocator, ", created_at, updated_at) VALUES (?, ?");
    for (write.columns) |col| {
        if (col.field_type == .array) {
            try sql_buf.appendSlice(allocator, ", jsonb(?)");
        } else {
            try sql_buf.appendSlice(allocator, ", ?");
        }
    }
    try sql_buf.appendSlice(allocator, ", ?, ?) ON CONFLICT(id, namespace_id) DO UPDATE SET ");
    for (write.columns, 0..) |col, i| {
        if (i > 0) try sql_buf.appendSlice(allocator, ", ");
        try sql_buf.appendSlice(allocator, col.name);
        try sql_buf.appendSlice(allocator, " = excluded.");
        try sql_buf.appendSlice(allocator, col.name);
    }
    try sql_buf.appendSlice(allocator, ", updated_at = excluded.updated_at RETURNING ");
    const table_metadata = sm.getTable(write.table) orelse return error.UnknownTable;
    try sql_utils.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);

    const sql = try sql_buf.toOwnedSlice(allocator);
    errdefer allocator.free(sql);

    const values = try allocator.alloc(TypedValue, write.columns.len);
    var initialized_count: usize = 0;
    errdefer {
        for (values[0..initialized_count]) |v| v.deinit(allocator);
        allocator.free(values);
    }
    for (write.columns, 0..) |*col, i| {
        values[i] = typedValueFromWriteValue(col.value);
        col.value = .nil;
        initialized_count += 1;
    }

    const op = WriteOp{
        .insert = .{
            .table = write.table,
            .id = write.id,
            .namespace = write.namespace,
            .sql = sql,
            .values = values,
            .timestamp = std.time.timestamp(),
            .completion_signal = null,
        },
    };

    for (write.columns) |col| allocator.free(col.name);
    if (write.columns.ptr != write_command.DocumentWrite.empty.columns.ptr) {
        allocator.free(write.columns);
    }
    write.* = .empty;

    return op;
}

pub fn buildUpdateFromCommandOp(
    allocator: Allocator,
    sm: *const schema_manager.SchemaManager,
    write: *write_command.FieldWrite,
) !WriteOp {
    const field_placeholder = if (write.field_type == .array) "jsonb(?)" else "?";

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.appendSlice(allocator, "INSERT INTO ");
    try sql_buf.appendSlice(allocator, write.table);
    try sql_buf.appendSlice(allocator, " (id, namespace_id, ");
    try sql_buf.appendSlice(allocator, write.field);
    try sql_buf.appendSlice(allocator, ", created_at, updated_at) VALUES (?, ?, ");
    try sql_buf.appendSlice(allocator, field_placeholder);
    try sql_buf.appendSlice(allocator, ", ?, ?) ON CONFLICT(id, namespace_id) DO UPDATE SET ");
    try sql_buf.appendSlice(allocator, write.field);
    try sql_buf.appendSlice(allocator, " = excluded.");
    try sql_buf.appendSlice(allocator, write.field);
    try sql_buf.appendSlice(allocator, ", updated_at = excluded.updated_at RETURNING ");

    const table_metadata = sm.getTable(write.table) orelse return error.UnknownTable;
    try sql_utils.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);

    const sql = try sql_buf.toOwnedSlice(allocator);
    errdefer allocator.free(sql);

    const values = try allocator.alloc(TypedValue, 1);
    values[0] = typedValueFromWriteValue(write.value);
    write.value = .nil;
    errdefer {
        values[0].deinit(allocator);
        allocator.free(values);
    }

    const op = WriteOp{
        .update = .{
            .table = write.table,
            .id = write.id,
            .namespace = write.namespace,
            .sql = sql,
            .values = values,
            .timestamp = std.time.timestamp(),
            .completion_signal = null,
        },
    };

    if (write.field.ptr != "".ptr) allocator.free(write.field);
    write.* = .empty;

    return op;
}

fn typedValueFromWriteValue(value: write_command.WriteValue) TypedValue {
    return switch (value) {
        .integer => |v| .{ .integer = v },
        .real => |v| .{ .real = v },
        .text => |v| .{ .text = v },
        .boolean => |v| .{ .boolean = v },
        .array_json => |v| .{ .blob = v },
        .nil => .nil,
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

    const table_metadata = sm.getTable(table) orelse return error.UnknownTable;
    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    try sql_buf.appendSlice(allocator, "DELETE FROM ");
    try sql_buf.appendSlice(allocator, table);
    try sql_buf.appendSlice(allocator, " WHERE id=? AND namespace_id=? RETURNING ");
    try sql_utils.appendProjectedColumnsSql(allocator, &sql_buf, table_metadata);
    const sql = try sql_buf.toOwnedSlice(allocator);
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
