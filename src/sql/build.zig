const std = @import("std");

const query_ast = @import("../query/ast.zig");
const system = @import("../schema/system.zig");
const types = @import("../schema/types.zig");
const typed = @import("../typed/types.zig");
const SqlBuf = @import("buf.zig").SqlBuf;
const SqlList = @import("buf.zig").SqlList;

const Allocator = std.mem.Allocator;

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

/// Appends the multi-key lexicographic cursor disjunction and appends the bound
/// value clones to `values` in matching positional order. Fragment generation
/// and bind generation live in one loop to prevent positional drift.
///
/// For canonical keys k0..kn, branch i requires equality on k0..k(i-1) and an
/// after-comparison on ki. Optional (non-required) keys use null-safe forms:
/// prefix equality is `column IS ?` and the comparison branch becomes
/// `(? IS NOT NULL AND (column IS NULL OR column <op> ?))`.
pub fn appendCursorPredicateSql(
    allocator: Allocator,
    buf: *SqlBuf,
    table: *const types.Table,
    descriptors: []const query_ast.SortDescriptor,
    cursor_values: []const typed.Value,
    values: *std.ArrayListUnmanaged(typed.Value),
) !void {
    std.debug.assert(descriptors.len == cursor_values.len);
    if (descriptors.len == 0) return;

    try buf.appendSlice(allocator, "(");
    for (descriptors, 0..) |d, i| {
        if (i > 0) try buf.appendSlice(allocator, " OR ");
        try buf.appendSlice(allocator, "(");

        // Prefix equality on k0..k(i-1)
        for (descriptors[0..i], 0..) |p, j| {
            const pf = table.fields[p.field_index];
            try buf.appendSlice(allocator, pf.name_quoted);
            // repeated prefix binds are O(n²), bounded by max_sort_clauses+1;
            // numbered params/CTEs only if profiling shows bind cost matters.
            try buf.appendSlice(allocator, if (pf.required) " = ? AND " else " IS ? AND ");
            try appendBoundValueClone(allocator, values, cursor_values[j]);
        }

        const f = table.fields[d.field_index];
        const op = if (d.desc) " < ?" else " > ?";
        if (f.required) {
            try buf.appendSlice(allocator, f.name_quoted);
            try buf.appendSlice(allocator, op);
            try appendBoundValueClone(allocator, values, cursor_values[i]);
        } else {
            try buf.appendSlice(allocator, "? IS NOT NULL AND (");
            try buf.appendSlice(allocator, f.name_quoted);
            try buf.appendSlice(allocator, " IS NULL OR ");
            try buf.appendSlice(allocator, f.name_quoted);
            try buf.appendSlice(allocator, op);
            try buf.appendSlice(allocator, ")");
            try appendBoundValueClone(allocator, values, cursor_values[i]); // null guard
            try appendBoundValueClone(allocator, values, cursor_values[i]); // comparison
        }

        try buf.appendSlice(allocator, ")");
    }
    try buf.appendSlice(allocator, ")");
}

fn appendBoundValueClone(
    allocator: Allocator,
    values: *std.ArrayListUnmanaged(typed.Value),
    value: typed.Value,
) !void {
    const copy = try value.clone(allocator);
    errdefer copy.deinit(allocator);
    try values.append(allocator, copy);
}

/// Appends ` ORDER BY <col> <dir> [NULLS LAST], ...` for every canonical clause.
pub fn appendOrderBySql(
    allocator: Allocator,
    buf: *SqlBuf,
    table: *const types.Table,
    descriptors: []const query_ast.SortDescriptor,
) !void {
    try buf.appendSlice(allocator, " ORDER BY ");
    var list = SqlList.init(buf, ", ");
    for (descriptors) |d| {
        const f = table.fields[d.field_index];
        try list.maybeSep(allocator);
        try buf.appendSlice(allocator, f.name_quoted);
        try buf.appendSlice(allocator, if (d.desc) " DESC" else " ASC");
        if (!f.required) try buf.appendSlice(allocator, " NULLS LAST");
    }
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

/// Builds `SELECT MAX("created_at") FROM "<table>"`.
pub fn buildSelectMaxCreatedAtSql(allocator: Allocator, table_name_quoted: []const u8) ![]const u8 {
    var buf = SqlBuf.init();
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "SELECT MAX(");
    try buf.appendSlice(allocator, system.quoted_created_at);
    try buf.appendSlice(allocator, ") FROM ");
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
