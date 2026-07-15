const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../schema/types.zig");
const system = @import("../schema/system.zig");
const SqlBuf = @import("buf.zig").SqlBuf;
const SqlList = @import("buf.zig").SqlList;

/// Appends the standard column projection list to `buf`.
/// Array fields are wrapped in json() to ensure text output from JSONB storage.
pub fn appendProjectedColumnsSql(allocator: Allocator, buf: *SqlBuf, table: *const types.Table) !void {
    var list = SqlList.init(buf, ", ");
    for (table.fields) |f| {
        if (f.storage_type == .array) {
            try list.maybeSep(allocator);
            try buf.appendSlice(allocator, "json(");
            try buf.appendSlice(allocator, f.name_quoted);
            try buf.appendSlice(allocator, ") AS ");
            try buf.appendSlice(allocator, f.name_quoted);
        } else {
            try list.appendItemSlice(allocator, f.name_quoted);
        }
    }
}

/// Appends `SELECT <cols> FROM "<table>"` to `buf`.
pub fn appendSelectFromTableSql(allocator: Allocator, buf: *SqlBuf, table: *const types.Table) !void {
    try buf.appendSlice(allocator, "SELECT ");
    try appendProjectedColumnsSql(allocator, buf, table);
    try buf.appendSlice(allocator, " FROM ");
    try buf.appendSlice(allocator, table.name_quoted);
}

/// Appends `WHERE "id"=? AND "namespace_id"=?` to `buf`.
fn appendDocIdNamespaceWhere(allocator: Allocator, buf: *SqlBuf) !void {
    try buf.appendSlice(allocator, " WHERE ");
    try buf.appendSlice(allocator, system.quoted_id);
    try buf.appendSlice(allocator, "=? AND ");
    try buf.appendSlice(allocator, system.quoted_namespace_id);
    try buf.appendSlice(allocator, "=?");
}

/// Appends `"namespace_id" = ?` to `buf`.
pub fn appendNamespaceFilterSql(allocator: Allocator, buf: *SqlBuf) !void {
    try buf.appendSlice(allocator, system.quoted_namespace_id);
    try buf.appendSlice(allocator, " = ?");
}

/// Appends a composite cursor predicate: `("sort_field", "id") > (?, ?)`.
pub fn appendCursorPredicateSql(
    allocator: Allocator,
    buf: *SqlBuf,
    sort_field_name_quoted: []const u8,
    sort_field_is_id: bool,
    desc: bool,
) !void {
    const op = if (desc) "<" else ">";

    if (sort_field_is_id) {
        try buf.appendSlice(allocator, system.quoted_id);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, op);
        try buf.appendSlice(allocator, " ?");
        return;
    }

    try buf.append(allocator, '(');
    try buf.appendSlice(allocator, sort_field_name_quoted);
    try buf.appendSlice(allocator, ", ");
    try buf.appendSlice(allocator, system.quoted_id);
    try buf.appendSlice(allocator, ") ");
    try buf.appendSlice(allocator, op);
    try buf.appendSlice(allocator, " (?, ?)");
}

/// Appends ` ORDER BY <sort_field> <dir>, "id" <dir>` to `buf`.
pub fn appendOrderBySql(
    allocator: Allocator,
    buf: *SqlBuf,
    sort_field_name_quoted: []const u8,
    desc: bool,
) !void {
    try buf.appendSlice(allocator, " ORDER BY ");
    try buf.appendSlice(allocator, sort_field_name_quoted);
    try buf.appendSlice(allocator, if (desc) " DESC" else " ASC");
    try buf.appendSlice(allocator, ", ");
    try buf.appendSlice(allocator, system.quoted_id);
    try buf.appendSlice(allocator, if (desc) " DESC" else " ASC");
}

/// Builds `SELECT <cols> FROM "<table>"`. Pre-built once per table.
pub fn buildSelectFromSql(allocator: Allocator, table: *const types.Table) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try appendSelectFromTableSql(allocator, &buf, table);

    return buf.toOwnedSlice(allocator);
}

/// Builds `SELECT <cols> FROM "<table>" WHERE "id"=? AND "namespace_id"=?`.
/// Takes the pre-built `select_from_sql` (see buildSelectFromSql).
pub fn buildSelectDocumentSql(allocator: Allocator, select_from_sql: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{
        select_from_sql,
        " WHERE ",
        system.quoted_id,
        "=? AND ",
        system.quoted_namespace_id,
        "=?",
    });
}

/// Builds `SELECT "id" FROM "<table>"`.
pub fn buildSelectAllIdsSql(allocator: Allocator, table_name_quoted: []const u8) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "SELECT ");
    try buf.appendSlice(allocator, system.quoted_id);
    try buf.appendSlice(allocator, " FROM ");
    try buf.appendSlice(allocator, table_name_quoted);

    return buf.toOwnedSlice(allocator);
}

/// Builds the WHERE prefix for a delete:
/// `DELETE FROM "<table>" WHERE "id"=? AND "namespace_id"=?`
/// For no-guard: concat(prefix, suffix). For guard: concat(prefix, guard_fragment, suffix).
pub fn buildDeleteDocumentSqlPrefix(allocator: Allocator, table: *const types.Table) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "DELETE FROM ");
    try buf.appendSlice(allocator, table.name_quoted);
    try appendDocIdNamespaceWhere(allocator, &buf);

    return buf.toOwnedSlice(allocator);
}

/// Builds the RETURNING suffix for a guarded delete: ` RETURNING <cols>`.
pub fn buildDeleteDocumentSqlSuffix(allocator: Allocator, table: *const types.Table) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, " RETURNING ");
    try appendProjectedColumnsSql(allocator, &buf, table);

    return buf.toOwnedSlice(allocator);
}
