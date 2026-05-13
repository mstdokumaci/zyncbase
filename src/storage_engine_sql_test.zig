const std = @import("std");
const schema = @import("schema.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const sql = @import("storage_engine/sql.zig");
const filter_sql = @import("storage_engine/filter_sql.zig");
const query_ast = @import("query_ast.zig");
const ColumnValue = @import("storage_engine.zig").ColumnValue;

test "storage SQL builders quote identifiers" {
    const allocator = std.testing.allocator;
    const fields = [_]schema.Field{schema_helpers.makeField("from", .text)};
    const table = schema_helpers.makeTable("select", &fields);
    var tables = [_]schema.Table{table};
    var sm = try schema.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer sm.deinit();
    const table_metadata = sm.getTable("select") orelse return error.TestExpectedValue;

    const columns = [_]ColumnValue{
        .{ .index = schema.first_user_field_index, .value = undefined },
    };

    const insert_sql = try sql.buildInsertOrReplaceSql(allocator, table_metadata, &columns, null);
    defer allocator.free(insert_sql);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "INSERT INTO \"select\" (\"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"from\" = excluded.\"from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"select\".\"namespace_id\" = excluded.\"namespace_id\"") != null);

    const delete_sql = try sql.buildDeleteDocumentSql(allocator, table_metadata, null);
    defer allocator.free(delete_sql);
    try std.testing.expect(std.mem.indexOf(u8, delete_sql, "DELETE FROM \"select\" WHERE \"id\"=? AND \"namespace_id\"=? RETURNING ") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_sql, "\"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\"") != null);
}

test "storage SELECT SQL helpers quote and compose identifiers" {
    const allocator = std.testing.allocator;
    const fields = [_]schema.Field{schema_helpers.makeField("from", .text)};
    const table = schema_helpers.makeTable("select", &fields);
    var tables = [_]schema.Table{table};
    var sm = try schema.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer sm.deinit();
    const table_metadata = sm.getTable("select") orelse return error.TestExpectedValue;

    const select_document_sql = try sql.buildSelectDocumentSql(allocator, table_metadata, null);
    defer allocator.free(select_document_sql);
    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\" FROM \"select\" WHERE \"id\"=? AND \"namespace_id\"=?",
        select_document_sql,
    );

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);
    try sql.appendSelectFromTableSql(allocator, &sql_buf, table_metadata);
    try sql_buf.appendSlice(allocator, " WHERE ");
    try sql.appendNamespaceFilterSql(allocator, &sql_buf);
    try sql_buf.appendSlice(allocator, " AND ");
    try sql.appendCursorPredicateSql(allocator, &sql_buf, "\"from\"", false, false);
    try sql.appendOrderBySql(allocator, &sql_buf, "\"from\"", false);

    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\" FROM \"select\" WHERE \"namespace_id\" = ? AND (\"from\", \"id\") > (?, ?) ORDER BY \"from\" ASC, \"id\" ASC",
        sql_buf.items,
    );
}

test "filter SQL render cleans up all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, renderFilterSqlForAllocationTest, .{});
}

fn renderFilterSqlForAllocationTest(allocator: std.mem.Allocator) !void {
    const fields = [_]schema.Field{schema_helpers.makeField("name", .text)};
    const table = schema_helpers.makeTable("people", &fields);
    var tables = [_]schema.Table{table};
    var sm = try schema.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer sm.deinit();
    const table_metadata = sm.getTable("people") orelse return error.TestExpectedValue;
    const name_index = table_metadata.fieldIndex("name") orelse return error.TestExpectedValue;

    const conds = try allocator.alloc(query_ast.Condition, 2);
    for (conds) |*cond| {
        cond.* = .{
            .field_index = 0,
            .op = .eq,
            .value = null,
            .field_type = .text,
            .items_type = null,
        };
    }
    var predicate = query_ast.FilterPredicate{ .conditions = conds };
    var predicate_owned = true;
    errdefer if (predicate_owned) predicate.deinit(allocator);

    const eq_text = try allocator.dupe(u8, "ada");
    conds[0] = .{
        .field_index = name_index,
        .op = .eq,
        .value = .{ .scalar = .{ .text = eq_text } },
        .field_type = .text,
        .items_type = null,
    };

    const prefix_text = try allocator.dupe(u8, "a_%");
    conds[1] = .{
        .field_index = name_index,
        .op = .startsWith,
        .value = .{ .scalar = .{ .text = prefix_text } },
        .field_type = .text,
        .items_type = null,
    };

    var rendered = (try filter_sql.renderAndClause(allocator, table_metadata, &predicate)) orelse return error.TestExpectedValue;
    defer rendered.deinit(allocator);
    defer predicate.deinit(allocator);
    predicate_owned = false;

    try std.testing.expect(rendered.sqlSlice() != null);
    const rendered_values = rendered.values orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 2), rendered_values.len);
}
