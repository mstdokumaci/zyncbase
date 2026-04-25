const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const sql = @import("storage_engine/sql.zig");
const types = @import("storage_engine/types.zig");

test "storage SQL builders quote identifiers" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_manager.Field{
        .{
            .name = "from",
            .sql_type = .text,
            .items_type = null,
            .required = false,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
    };
    const table = schema_manager.Table{
        .name = "select",
        .fields = @constCast(&fields),
    };
    var table_metadata = try schema_manager.TableMetadata.init(allocator, &table, 0);
    defer table_metadata.deinit(allocator);

    const columns = [_]types.ColumnValue{
        .{ .index = schema_manager.first_user_field_index, .value = undefined },
    };

    const insert_sql = try sql.buildInsertOrReplaceSql(allocator, &table_metadata, &columns);
    defer allocator.free(insert_sql);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "INSERT INTO \"select\" (\"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"from\" = excluded.\"from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"select\".\"namespace_id\" = excluded.\"namespace_id\"") != null);

    const delete_sql = try sql.buildDeleteDocumentSql(allocator, &table_metadata);
    defer allocator.free(delete_sql);
    try std.testing.expect(std.mem.indexOf(u8, delete_sql, "DELETE FROM \"select\" WHERE \"id\"=? AND \"namespace_id\"=? RETURNING ") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_sql, "\"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\"") != null);
}

test "storage SELECT SQL helpers quote and compose identifiers" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_manager.Field{
        .{
            .name = "from",
            .sql_type = .text,
            .items_type = null,
            .required = false,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
    };
    const table = schema_manager.Table{
        .name = "select",
        .fields = @constCast(&fields),
    };
    var table_metadata = try schema_manager.TableMetadata.init(allocator, &table, 0);
    defer table_metadata.deinit(allocator);

    const select_document_sql = try sql.buildSelectDocumentSql(allocator, &table_metadata);
    defer allocator.free(select_document_sql);
    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\" FROM \"select\" WHERE \"id\"=? AND \"namespace_id\"=?",
        select_document_sql,
    );

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    try sql.appendSelectFromTableSql(allocator, &sql_buf, &table_metadata);
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql.appendNamespaceFilterSql(allocator, &sql_buf);
    try sql_buf.appendSlice(allocator, " AND ");
    try sql.appendCursorPredicateSql(allocator, &sql_buf, "from", false, false);
    try sql.appendOrderBySql(allocator, &sql_buf, "from", false);

    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\" FROM \"select\" WHERE \"namespace_id\" = ? AND (\"from\", \"id\") > (?, ?) ORDER BY \"from\" ASC, \"id\" ASC",
        sql_buf.items,
    );
}
