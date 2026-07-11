/// Pre-builds the no-guard SELECT and DELETE SQL strings for a Table.
/// Lives in schema/ to avoid the circular import that would result from
/// parse.zig importing storage_engine/sql.zig (which imports schema.zig
/// which imports parse.zig).
///
/// Imports only: std, schema/types.zig, schema/system.zig, sql_buf.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const system = @import("system.zig");
const SqlBuf = @import("../sql_buf.zig").SqlBuf;
const SqlList = @import("../sql_buf.zig").SqlList;

/// Appends the standard column projection list to `buf`.
/// Array fields are wrapped in json() to ensure text output from JSONB storage.
fn appendProjectedColumnsSql(allocator: Allocator, buf: *SqlBuf, table: *const types.Table) !void {
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
fn appendSelectFromTableSql(allocator: Allocator, buf: *SqlBuf, table: *const types.Table) !void {
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

/// Builds `SELECT <cols> FROM "<table>" WHERE "id"=? AND "namespace_id"=?`.
/// No guard fragment — this is the cacheable, pure-per-table form.
/// Caller owns the returned slice and must free it.
pub fn buildSelectDocumentSql(allocator: Allocator, table: *const types.Table) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try appendSelectFromTableSql(allocator, &buf, table);
    try appendDocIdNamespaceWhere(allocator, &buf);

    return buf.toOwnedSlice(allocator);
}

/// Builds the WHERE prefix for a delete:
/// `DELETE FROM "<table>" WHERE "id"=? AND "namespace_id"=?`
/// For no-guard: concat(prefix, suffix). For guard: concat(prefix, guard_fragment, suffix).
/// Caller owns the returned slice and must free it.
pub fn buildDeleteDocumentSqlPrefix(allocator: Allocator, table: *const types.Table) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "DELETE FROM ");
    try buf.appendSlice(allocator, table.name_quoted);
    try appendDocIdNamespaceWhere(allocator, &buf);

    return buf.toOwnedSlice(allocator);
}

/// Builds the RETURNING suffix for a guarded delete: ` RETURNING <cols>`.
/// Caller owns the returned slice and must free it.
pub fn buildDeleteDocumentSqlSuffix(allocator: Allocator, table: *const types.Table) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, " RETURNING ");
    try appendProjectedColumnsSql(allocator, &buf, table);

    return buf.toOwnedSlice(allocator);
}
