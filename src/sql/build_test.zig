const std = @import("std");

const query_ast = @import("../query/ast.zig");
const schema_system = @import("../schema/system.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const schema_types = @import("../schema/types.zig");
const typed = @import("../typed/types.zig");
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

    const from_index = table_metadata.fieldIndex("from") orelse return error.TestExpectedValue;
    const descriptors = [_]query_ast.SortDescriptor{
        .{ .field_index = from_index, .desc = false },
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
    const cursor_values = [_]typed.Value{
        .{ .scalar = .{ .text = "a" } },
        .{ .scalar = .{ .doc_id = 1 } },
    };

    var buf = buf_mod.SqlBuf.init();
    defer buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(typed.Value) = .empty;
    defer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }

    try build.appendSelectFromTableSql(allocator, &buf, table_metadata);
    try buf.appendSlice(allocator, " WHERE ");
    try build.appendNamespaceFilterSql(allocator, &buf);
    try buf.appendSlice(allocator, " AND ");
    try build.appendCursorPredicateSql(allocator, &buf, table_metadata, &descriptors, &cursor_values, &values);
    try build.appendOrderBySql(allocator, &buf, table_metadata, &descriptors);

    // "from" is optional (makeField default), so it uses null-safe forms; id is required.
    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\" FROM \"select\" WHERE \"namespace_id\" = ? AND ((? IS NOT NULL AND (\"from\" IS NULL OR \"from\" > ?)) OR (\"from\" IS ? AND \"id\" > ?)) ORDER BY \"from\" ASC NULLS LAST, \"id\" ASC",
        buf.items(),
    );
}

test "appendCursorPredicateSql emits null-safe forms for optional fields" {
    const allocator = std.testing.allocator;
    // makeField produces required fields; override requiredness for the optional case.
    var optional_field = schema_helpers.makeField("note", .text);
    optional_field.required = false;
    const fields = [_]schema_types.Field{
        schema_helpers.makeField("title", .text),
        optional_field,
    };
    const table = schema_helpers.makeTable("docs", &fields);
    var tables = [_]schema_types.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("docs") orelse return error.TestExpectedValue;

    const title_index = table_metadata.fieldIndex("title") orelse return error.TestExpectedValue;
    const note_index = table_metadata.fieldIndex("note") orelse return error.TestExpectedValue;
    const descriptors = [_]query_ast.SortDescriptor{
        .{ .field_index = title_index, .desc = true },
        .{ .field_index = note_index, .desc = false },
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
    const cursor_values = [_]typed.Value{
        .{ .scalar = .{ .text = "t" } },
        .nil,
        .{ .scalar = .{ .doc_id = 1 } },
    };

    var buf = buf_mod.SqlBuf.init();
    defer buf.deinit(allocator);
    var values: std.ArrayListUnmanaged(typed.Value) = .empty;
    defer {
        for (values.items) |v| v.deinit(allocator);
        values.deinit(allocator);
    }
    try build.appendCursorPredicateSql(allocator, &buf, table_metadata, &descriptors, &cursor_values, &values);

    // 3 branches: optional desc (2 binds) + prefix/optional (3) + prefix/prefix/required id (3).
    // Branch and bind counts stay stable regardless of cursor null values.
    try std.testing.expectEqual(@as(usize, 8), values.items.len);
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
