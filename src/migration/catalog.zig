//! SQLite catalog introspection and comparison with the physical layout a
//! schema table implies (STRICT flag, columns, foreign keys, managed indexes).

const std = @import("std");

const sqlite = @import("sqlite");

const schema_system = @import("../schema/system.zig");
const schema_types = @import("../schema/types.zig");
const sql_buf = @import("../sql/buf.zig");
const ddl = @import("../sql/ddl.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const Table = schema_types.Table;

/// True when `index_name` falls inside ZyncBase's reserved managed namespaces
/// for this table (`idx__<table>__...` / `uidx__<table>__...`).
pub fn isReservedManagedIndexName(index_name: []const u8, table_name: []const u8) bool {
    return hasManagedPrefix(index_name, table_name, "idx__") or
        hasManagedPrefix(index_name, table_name, "uidx__");
}

fn hasManagedPrefix(index_name: []const u8, table_name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, index_name, prefix)) return false;
    const rest = index_name[prefix.len..];
    if (!std.mem.startsWith(u8, rest, table_name)) return false;
    return rest.len > table_name.len + 2 and std.mem.eql(u8, rest[table_name.len .. table_name.len + 2], "__");
}

/// Reads every row of `stmt` into an arena-owned slice.
fn collectRows(comptime T: type, arena: Allocator, stmt: anytype, values: anytype) ![]T {
    var rows = std.ArrayListUnmanaged(T).empty;
    var iter = try stmt.iteratorAlloc(T, arena, values);
    while (try iter.nextAlloc(arena, .{})) |row| try rows.append(arena, row);
    return rows.toOwnedSlice(arena);
}

pub fn tableExists(db: *sqlite.Db, name: []const u8) !bool {
    const exists = try db.oneDynamic(
        i64,
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?)",
        .{},
        .{name},
    );
    return (exists orelse 0) != 0;
}

/// Names of every table that is not SQLite-internal or a `_zync_` system table.
/// Allocated in `arena`.
pub fn listUserTables(arena: Allocator, db: *sqlite.Db) ![]const []const u8 {
    var stmt = try db.prepareDynamic(
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE '\\_zync\\_%' ESCAPE '\\' ORDER BY name",
    );
    defer stmt.deinit();
    return collectRows([]const u8, arena, &stmt, .{});
}

/// Reserved-prefix managed index names currently attached to `table_name`.
/// Allocated in `arena`.
pub fn listManagedIndexNames(arena: Allocator, db: *sqlite.Db, table_name: []const u8) ![]const []const u8 {
    var stmt = try db.prepareDynamic("SELECT name FROM pragma_index_list(?)");
    defer stmt.deinit();
    const all_names = try collectRows([]const u8, arena, &stmt, .{table_name});
    var managed = std.ArrayListUnmanaged([]const u8).empty;
    for (all_names) |name| {
        if (isReservedManagedIndexName(name, table_name)) try managed.append(arena, name);
    }
    return managed.toOwnedSlice(arena);
}

pub const ExpectedColumn = struct {
    name: []const u8,
    sql_type: []const u8,
    not_null: bool,
    primary_key: bool,
};

/// Every physical column `table` implies, in DDL order.
pub fn expectedColumns(arena: Allocator, table: *const Table) ![]const ExpectedColumn {
    var columns = std.ArrayListUnmanaged(ExpectedColumn).empty;
    for (schema_system.leading_system_fields, 0..) |field, i| {
        try columns.append(arena, .{
            .name = field.name,
            .sql_type = field.storage_type.toSqlType(),
            .not_null = field.required,
            .primary_key = i == 0,
        });
    }
    if (table.is_users_table) {
        try columns.append(arena, .{ .name = schema_system.external_id_column, .sql_type = "TEXT", .not_null = true, .primary_key = false });
    }
    for (table.userFields()) |field| {
        try columns.append(arena, .{
            .name = field.name,
            .sql_type = field.storage_type.toSqlType(),
            .not_null = field.required,
            .primary_key = false,
        });
    }
    for (schema_system.trailing_system_fields) |field| {
        try columns.append(arena, .{
            .name = field.name,
            .sql_type = field.storage_type.toSqlType(),
            .not_null = field.required,
            .primary_key = false,
        });
    }
    return columns.toOwnedSlice(arena);
}

/// Column names a generated copy carries over: system columns plus the user
/// fields present (by name) in both tables. Allocated in `arena`.
pub fn sharedColumnNames(arena: Allocator, from: *const Table, to: *const Table) ![]const []const u8 {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    const to_columns = try expectedColumns(arena, to);
    const from_columns = try expectedColumns(arena, from);
    for (to_columns) |column| {
        for (from_columns) |candidate| {
            if (std.mem.eql(u8, candidate.name, column.name)) {
                try names.append(arena, column.name);
                break;
            }
        }
    }
    return names.toOwnedSlice(arena);
}

pub const Drift = struct {
    missing: bool = false,
    not_strict: bool = false,
    columns: bool = false,
    foreign_keys: bool = false,
    indexes: bool = false,

    /// Drift that refuses startup. Index drift alone is repaired.
    pub fn isStructural(self: Drift) bool {
        return self.missing or self.not_strict or self.columns or self.foreign_keys;
    }

    pub fn any(self: Drift) bool {
        return self.isStructural() or self.indexes;
    }
};

/// Compares the catalog of `table.name` with the layout `table` implies.
/// Details go to `diag` when provided.
pub fn checkTable(arena: Allocator, db: *sqlite.Db, table: *const Table, diag: ?*Diagnostics) !Drift {
    var drift = Drift{};
    if (!try tableExists(db, table.name)) {
        if (diag) |d| d.add("  {s}: table is missing", .{table.name});
        drift.missing = true;
        return drift;
    }

    const strict = try db.oneDynamic(
        i64,
        "SELECT strict FROM pragma_table_list WHERE schema = 'main' AND name = ?",
        .{},
        .{table.name},
    );
    if ((strict orelse 0) == 0) {
        if (diag) |d| d.add("  {s}: table is not STRICT", .{table.name});
        drift.not_strict = true;
    }

    drift.columns = !try columnsMatch(arena, db, table, diag);
    drift.foreign_keys = !try foreignKeysMatch(arena, db, table, diag);
    drift.indexes = !try managedIndexesMatch(arena, db, table, diag);
    return drift;
}

const ColumnRow = struct {
    name: []const u8,
    type: []const u8,
    notnull: i64,
    pk: i64,
};

fn columnsMatch(arena: Allocator, db: *sqlite.Db, table: *const Table, diag: ?*Diagnostics) !bool {
    var stmt = try db.prepareDynamic("SELECT name, type, \"notnull\", pk FROM pragma_table_info(?)");
    defer stmt.deinit();
    const actual = try collectRows(ColumnRow, arena, &stmt, .{table.name});
    const expected = try expectedColumns(arena, table);

    var ok = true;
    for (expected) |column| {
        const row = findColumn(actual, column.name) orelse {
            if (diag) |d| d.add("  {s}: column \"{s}\" is missing", .{ table.name, column.name });
            ok = false;
            continue;
        };
        if (!std.mem.eql(u8, row.type, column.sql_type)) {
            if (diag) |d| d.add("  {s}: column \"{s}\" is {s}, expected {s}", .{ table.name, column.name, row.type, column.sql_type });
            ok = false;
        }
        if ((row.notnull != 0) != column.not_null) {
            if (diag) |d| d.add("  {s}: column \"{s}\" is {s}, expected {s}", .{
                table.name,
                column.name,
                if (row.notnull != 0) "NOT NULL" else "nullable",
                if (column.not_null) "NOT NULL" else "nullable",
            });
            ok = false;
        }
        if ((row.pk != 0) != column.primary_key) {
            if (diag) |d| d.add("  {s}: column \"{s}\" primary key mismatch", .{ table.name, column.name });
            ok = false;
        }
    }
    for (actual) |row| {
        if (findExpected(expected, row.name) == null) {
            if (diag) |d| d.add("  {s}: unexpected column \"{s}\"", .{ table.name, row.name });
            ok = false;
        }
    }
    return ok;
}

fn findColumn(rows: []const ColumnRow, name: []const u8) ?ColumnRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

fn findExpected(columns: []const ExpectedColumn, name: []const u8) ?ExpectedColumn {
    for (columns) |column| {
        if (std.mem.eql(u8, column.name, name)) return column;
    }
    return null;
}

const ForeignKeyRow = struct {
    id: i64,
    seq: i64,
    table: []const u8,
    from: []const u8,
    to: ?[]const u8,
    on_update: []const u8,
    on_delete: []const u8,
    match: []const u8,
};

fn foreignKeyRowMatches(field: schema_types.Field, row: ForeignKeyRow) bool {
    const reference = field.references orelse return false;
    const target_column = row.to orelse return false;
    return row.seq == 0 and
        std.mem.eql(u8, field.name, row.from) and
        std.mem.eql(u8, reference, row.table) and
        std.mem.eql(u8, "id", target_column) and
        std.mem.eql(u8, "NO ACTION", row.on_update) and
        std.mem.eql(u8, ddl.onDeleteSql(field.on_delete orelse .restrict).action, row.on_delete) and
        std.mem.eql(u8, "NONE", row.match);
}

fn foreignKeysMatch(arena: Allocator, db: *sqlite.Db, table: *const Table, diag: ?*Diagnostics) !bool {
    var stmt = try db.prepareDynamic(
        "SELECT id, seq, \"table\", \"from\", \"to\", on_update, on_delete, \"match\" FROM pragma_foreign_key_list(?)",
    );
    defer stmt.deinit();
    const rows = try collectRows(ForeignKeyRow, arena, &stmt, .{table.name});

    const fields = table.userFields();
    const seen = try arena.alloc(bool, fields.len);
    @memset(seen, false);

    var ok = true;
    row_loop: for (rows) |row| {
        for (fields, 0..) |field, i| {
            if (seen[i] or !foreignKeyRowMatches(field, row)) continue;
            seen[i] = true;
            continue :row_loop;
        }
        if (diag) |d| d.add("  {s}: unexpected foreign key on \"{s}\" -> {s} (ON DELETE {s})", .{ table.name, row.from, row.table, row.on_delete });
        ok = false;
    }
    for (fields, 0..) |field, i| {
        if (field.references != null and !seen[i]) {
            if (diag) |d| d.add("  {s}: foreign key on \"{s}\" is missing or differs", .{ table.name, field.name });
            ok = false;
        }
    }
    return ok;
}

const IndexListRow = struct {
    name: []const u8,
    unique: i64,
    partial: i64,
};

const IndexInfoRow = struct {
    seqno: i64,
    name: ?[]const u8,
};

fn managedIndexesMatch(arena: Allocator, db: *sqlite.Db, table: *const Table, diag: ?*Diagnostics) !bool {
    var list_stmt = try db.prepareDynamic("SELECT name, \"unique\", partial FROM pragma_index_list(?)");
    defer list_stmt.deinit();
    const actual = try collectRows(IndexListRow, arena, &list_stmt, .{table.name});
    const consumed = try arena.alloc(bool, actual.len);
    @memset(consumed, false);

    var ok = true;
    var iter = ddl.ManagedIndexIterator.init(table);
    while (iter.next()) |managed_index| {
        var name_buf = sql_buf.SqlBuf.init();
        defer name_buf.deinit(arena);
        try managed_index.appendName(arena, &name_buf, table);
        const quoted = name_buf.items();
        const expected_name = quoted[1 .. quoted.len - 1];

        const position = for (actual, 0..) |row, i| {
            if (!consumed[i] and std.mem.eql(u8, row.name, expected_name)) break i;
        } else {
            if (diag) |d| d.add("  {s}: index {s} is missing", .{ table.name, expected_name });
            ok = false;
            continue;
        };
        consumed[position] = true;
        const row = actual[position];

        const columns = try arena.alloc([]const u8, managed_index.columnCount(table));
        managed_index.columns(table, columns);
        if ((row.unique != 0) != managed_index.isUnique() or row.partial != 0 or
            !try indexColumnsMatch(arena, db, expected_name, columns))
        {
            if (diag) |d| d.add("  {s}: index {s} differs", .{ table.name, expected_name });
            ok = false;
        }
    }

    for (actual, 0..) |row, i| {
        if (consumed[i] or !isReservedManagedIndexName(row.name, table.name)) continue;
        if (diag) |d| d.add("  {s}: obsolete managed index {s}", .{ table.name, row.name });
        ok = false;
    }
    return ok;
}

fn indexColumnsMatch(arena: Allocator, db: *sqlite.Db, index_name: []const u8, expected: []const []const u8) !bool {
    var stmt = try db.prepareDynamic("SELECT seqno, name FROM pragma_index_info(?) ORDER BY seqno");
    defer stmt.deinit();
    const rows = try collectRows(IndexInfoRow, arena, &stmt, .{index_name});
    if (rows.len != expected.len) return false;
    for (rows, expected, 0..) |row, name, i| {
        if (row.seqno != @as(i64, @intCast(i))) return false;
        const actual_name = row.name orelse return false;
        if (!std.mem.eql(u8, actual_name, name)) return false;
    }
    return true;
}
