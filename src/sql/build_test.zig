const std = @import("std");
const schema_types = @import("../schema/types.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const buf_mod = @import("buf.zig");
const build = @import("build.zig");

test "appendProjectedColumnsSql projects all fields with proper quoting" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_types.Field{schema_helpers.makeField("from", .text)};
    const table = schema_helpers.makeTable("select", &fields);
    var tables = [_]schema_types.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("select") orelse return error.TestExpectedValue;

    var buf = buf_mod.SqlBuf.init();
    defer buf.deinit(allocator);
    try build.appendProjectedColumnsSql(allocator, &buf, table_metadata);
    try std.testing.expectEqualStrings(
        "\"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\"",
        buf.items(),
    );
}

test "appendSelectFromTableSql builds SELECT ... FROM with quoted identifiers" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_types.Field{schema_helpers.makeField("from", .text)};
    const table = schema_helpers.makeTable("select", &fields);
    var tables = [_]schema_types.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("select") orelse return error.TestExpectedValue;

    var buf = buf_mod.SqlBuf.init();
    defer buf.deinit(allocator);
    try build.appendSelectFromTableSql(allocator, &buf, table_metadata);
    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\" FROM \"select\"",
        buf.items(),
    );
}

test "append helpers compose into a complete SELECT query" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_types.Field{schema_helpers.makeField("from", .text)};
    const table = schema_helpers.makeTable("select", &fields);
    var tables = [_]schema_types.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("select") orelse return error.TestExpectedValue;

    var buf = buf_mod.SqlBuf.init();
    defer buf.deinit(allocator);
    try build.appendSelectFromTableSql(allocator, &buf, table_metadata);
    try buf.appendSlice(allocator, " WHERE ");
    try build.appendNamespaceFilterSql(allocator, &buf);
    try buf.appendSlice(allocator, " AND ");
    try build.appendCursorPredicateSql(allocator, &buf, "\"from\"", false, false);
    try build.appendOrderBySql(allocator, &buf, "\"from\"", false);

    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\" FROM \"select\" WHERE \"namespace_id\" = ? AND (\"from\", \"id\") > (?, ?) ORDER BY \"from\" ASC, \"id\" ASC",
        buf.items(),
    );
}

test "buildSelectDocumentSql builds no-guard SELECT document query" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_types.Field{schema_helpers.makeField("title", .text)};
    const table = schema_helpers.makeTable("docs", &fields);
    var tables = [_]schema_types.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("docs") orelse return error.TestExpectedValue;

    const select_from_sql = try build.buildSelectFromSql(allocator, table_metadata);
    defer allocator.free(select_from_sql);
    const sql = try build.buildSelectDocumentSql(allocator, select_from_sql);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"title\", \"created_at\", \"updated_at\" FROM \"docs\" WHERE \"id\"=? AND \"namespace_id\"=?",
        sql,
    );
}

test "buildSelectAllIdsSql builds simple id projection" {
    const allocator = std.testing.allocator;
    const sql = try build.buildSelectAllIdsSql(allocator, "\"test_table\"");
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "SELECT \"id\" FROM \"test_table\"",
        sql,
    );
}

test "buildDeleteDocumentSqlPrefix builds delete prefix" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_types.Field{schema_helpers.makeField("title", .text)};
    const table = schema_helpers.makeTable("docs", &fields);
    var tables = [_]schema_types.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("docs") orelse return error.TestExpectedValue;

    const prefix = try build.buildDeleteDocumentSqlPrefix(allocator, table_metadata);
    defer allocator.free(prefix);
    try std.testing.expectEqualStrings(
        "DELETE FROM \"docs\" WHERE \"id\"=? AND \"namespace_id\"=?",
        prefix,
    );
}

test "buildDeleteDocumentSqlSuffix builds returning clause" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_types.Field{schema_helpers.makeField("title", .text)};
    const table = schema_helpers.makeTable("docs", &fields);
    var tables = [_]schema_types.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("docs") orelse return error.TestExpectedValue;

    const suffix = try build.buildDeleteDocumentSqlSuffix(allocator, table_metadata);
    defer allocator.free(suffix);
    try std.testing.expectEqualStrings(
        " RETURNING \"id\", \"namespace_id\", \"owner_id\", \"title\", \"created_at\", \"updated_at\"",
        suffix,
    );
}
