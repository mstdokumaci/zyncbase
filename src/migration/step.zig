//! Executes one migration step inside the caller's run transaction:
//! staging, fill, row guard, managed indexes, validation, catalog check, and
//! snapshot persistence (specs/implementation/schema-migrations.md#step-execution).

const std = @import("std");

const sqlite = @import("sqlite");

const canonical = @import("../schema/canonical.zig");
const schema_diff = @import("../schema/diff.zig");
const field_path = @import("../schema/field_path.zig");
const schema_types = @import("../schema/types.zig");
const ddl = @import("../sql/ddl.zig");
const storage_errors = @import("../storage_engine/errors.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const catalog = @import("catalog.zig");
const state = @import("state.zig");
const validate = @import("validate.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const c = sqlite.c;
const SchemaDiff = schema_diff.SchemaDiff;
const TableDiff = schema_diff.TableDiff;
const Schema = schema_types.Schema;
const Table = schema_types.Table;

pub const prev_prefix = "_zync_prev_";

/// How rebuilt tables are refilled.
pub const Fill = union(enum) {
    /// Copy shared columns from the prev table (auto steps).
    generated,
    /// Run developer SQL. Receives the staged step; returns the names of the
    /// tables it wrote so they are validated.
    developer: DeveloperFill,
};

pub const DeveloperFill = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, arena: Allocator, db: *sqlite.Db, staged: *const Staged, diag: *Diagnostics) anyerror![]const []const u8,
};

/// What staging produced; visible to developer fills.
pub const Staged = struct {
    diff: *const SchemaDiff,
    /// Managed target tables that SQL may write.
    writable_tables: []const []const u8,
    /// `_zync_prev_<table>` names that SQL may read, update, and delete from.
    prev_tables: []const []const u8,
};

pub const TableReport = struct {
    name: []const u8,
    action: schema_diff.TableAction,
    rows_before: u64,
    rows_after: u64,
    rows_dropped: u64,
};

pub const StepReport = struct {
    tables: []const TableReport,
    rebuilt: bool,
};

pub const Input = struct {
    /// Shown in diagnostics, e.g. "schema 1.2.0 -> 1.3.0" or a migration id.
    label: []const u8,
    diff: *const SchemaDiff,
    target: *const Schema,
    /// Minified target schema JSON and its hash, stored as the new snapshot.
    target_json: []const u8,
    target_hash: canonical.Hash,
    fill: Fill = .generated,
    /// Tables whose managed indexes drifted and must be reconciled.
    repair_indexes: []const []const u8 = &.{},
};

/// Runs one step. Caller owns the transaction; `arena` is reset by the caller.
pub fn execute(arena: Allocator, io: std.Io, db: *sqlite.Db, input: Input, diag: *Diagnostics) !StepReport {
    var gen = ddl.DDLGenerator.init(arena);
    const diff = input.diff;

    var reports = try arena.alloc(TableReport, diff.tables.len);
    var writable = std.ArrayListUnmanaged([]const u8).empty;
    var prev_tables = std.ArrayListUnmanaged([]const u8).empty;
    var rebuilt = false;

    // ─── Staging ────────────────────────────────────────────────────────
    for (diff.tables, 0..) |*t, i| {
        reports[i] = .{ .name = t.name, .action = t.action, .rows_before = 0, .rows_after = 0, .rows_dropped = 0 };
        switch (t.action) {
            .unchanged => {},
            .create => {
                if (try catalog.tableExists(db, t.name)) {
                    diag.add("Table \"{s}\" already exists in the database but is not managed by ZyncBase.", .{t.name});
                    return error.UnmanagedTableConflict;
                }
                try execSql(db, try gen.generateCreateTable((try targetOf(t)).*), diag);
            },
            .alter => {
                const to = try targetOf(t);
                for (t.field_changes) |change| {
                    if (change.kind != .added_optional) continue;
                    const field = change.to orelse return error.InvalidState;
                    try execSql(db, try gen.generateAddColumn(to.*, field.*), diag);
                }
            },
            .rebuild, .remove => {
                const prev = try prevName(arena, t.name);
                if (try catalog.tableExists(db, prev)) {
                    diag.add("Leftover table \"{s}\" exists; remove it before starting.", .{prev});
                    return error.InvalidState;
                }
                try dropManagedIndexes(arena, db, t.name, diag);
                try execSql(db, try std.fmt.allocPrint(arena, "ALTER TABLE \"{s}\" RENAME TO \"{s}\"", .{ t.name, prev }), diag);
                reports[i].rows_before = try countRows(arena, db, prev);
                try prev_tables.append(arena, prev);
                if (t.action == .rebuild) {
                    try execSql(db, try gen.generateCreateTable((try targetOf(t)).*), diag);
                    rebuilt = true;
                }
            },
        }
        if (t.to != null) try writable.append(arena, t.name);
    }
    const staged = Staged{
        .diff = diff,
        .writable_tables = writable.items,
        .prev_tables = prev_tables.items,
    };

    // ─── Fill ───────────────────────────────────────────────────────────
    var written: []const []const u8 = &.{};
    switch (input.fill) {
        .generated => try generatedFill(arena, db, diff, reports, diag),
        .developer => |dev| written = try dev.run(dev.context, arena, db, &staged, diag),
    }

    // ─── Row guard and prev cleanup ─────────────────────────────────────
    var guard_failed = false;
    for (diff.tables, 0..) |*t, i| {
        if (t.action != .rebuild and t.action != .remove) continue;
        const prev = try prevName(arena, t.name);
        const remaining = try countRows(arena, db, prev);
        reports[i].rows_dropped = reports[i].rows_before - @min(reports[i].rows_before, remaining);
        const missing = try reportMissingRows(arena, db, t, prev, input.label, diag);
        if (missing > 0) guard_failed = true;
    }
    if (guard_failed) return error.RowsNotCarriedOver;
    for (prev_tables.items) |prev| {
        try execSql(db, try std.fmt.allocPrint(arena, "DROP TABLE \"{s}\"", .{prev}), diag);
    }

    // ─── Managed indexes ────────────────────────────────────────────────
    for (diff.tables) |*t| {
        const to = t.to orelse continue;
        const needs_indexes = switch (t.action) {
            .create, .rebuild => true,
            .alter, .unchanged => t.indexes_changed or containsName(input.repair_indexes, t.name),
            .remove => false,
        };
        if (!needs_indexes) continue;
        if (t.action == .alter or t.action == .unchanged) try dropManagedIndexes(arena, db, t.name, diag);
        try createManagedIndexes(arena, db, &gen, to, diag);
    }

    // ─── Row counts and validation ──────────────────────────────────────
    var violations: u64 = 0;
    for (diff.tables, 0..) |*t, i| {
        const to = t.to orelse continue;
        if (t.action != .unchanged) reports[i].rows_after = try countRows(arena, db, t.name);

        const developer_wrote = containsName(written, t.name);
        if (developer_wrote or (input.fill == .developer and (t.action == .create or t.action == .rebuild))) {
            violations += try validate.validateTable(arena, db, to, null, diag);
        } else {
            const tightened = try tightenedFields(arena, t);
            if (tightened.len > 0) violations += try validate.validateTable(arena, db, to, tightened, diag);
        }
    }
    if (violations > 0) {
        diag.add("Fix the data with a migration (zyncbase migrate new <name>) or relax the schema.", .{});
        return error.DataValidationFailed;
    }

    // ─── Catalog check ──────────────────────────────────────────────────
    var drifted = false;
    for (input.target.tables) |*table| {
        const drift = try catalog.checkTable(arena, db, table, diag);
        if (drift.any()) drifted = true;
    }
    for (diff.tables) |t| {
        if (t.action == .remove and try catalog.tableExists(db, t.name)) {
            diag.add("  {s}: removed table still exists", .{t.name});
            drifted = true;
        }
    }
    if (drifted) {
        diag.add("Internal error: the database does not match the target schema after {s}.", .{input.label});
        return error.SchemaDriftDetected;
    }

    try state.writeApplied(io, db, input.target.version, input.target_json, input.target_hash);
    return .{ .tables = reports, .rebuilt = rebuilt };
}

fn targetOf(t: *const TableDiff) !*const Table {
    return t.to orelse error.InvalidState;
}

pub fn prevName(arena: Allocator, table_name: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ prev_prefix, table_name });
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn tightenedFields(arena: Allocator, t: *const TableDiff) ![]const []const u8 {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    for (t.field_changes) |change| {
        if (change.kind == .constraint_tightened) try names.append(arena, change.name);
    }
    return names.toOwnedSlice(arena);
}

fn generatedFill(arena: Allocator, db: *sqlite.Db, diff: *const SchemaDiff, reports: []TableReport, diag: *Diagnostics) !void {
    for (diff.tables, 0..) |*t, i| {
        if (t.action != .rebuild) continue;
        const from = t.from orelse return error.InvalidState;
        const to = try targetOf(t);
        const prev = try prevName(arena, t.name);

        // Required values that a copy cannot supply: fail with counts, not a raw constraint error.
        for (t.field_changes) |change| {
            switch (change.kind) {
                .added_required => if (reports[i].rows_before > 0) {
                    diag.add("  {s}.{s} is new and required, but the table has {d} row(s).", .{ t.name, change.name, reports[i].rows_before });
                    diag.add("Provide the values with a migration: zyncbase migrate new <name>", .{});
                    return error.RequiredFieldNeedsValues;
                },
                .became_required => {
                    const nulls = try countWhere(arena, db, prev, try std.fmt.allocPrint(arena, "\"{s}\" IS NULL", .{change.name}));
                    if (nulls > 0) {
                        diag.add("  {s}.{s} is now required, but {d} row(s) have no value.", .{ t.name, change.name, nulls });
                        diag.add("Fill them with a migration: zyncbase migrate new <name>", .{});
                        return error.DataValidationFailed;
                    }
                },
                else => {},
            }
        }

        const columns = try catalog.sharedColumnNames(arena, from, to);
        var list = std.ArrayListUnmanaged(u8).empty;
        for (columns, 0..) |column, j| {
            if (j > 0) try list.appendSlice(arena, ", ");
            try list.append(arena, '"');
            try list.appendSlice(arena, column);
            try list.append(arena, '"');
        }
        const sql = try std.fmt.allocPrint(
            arena,
            "INSERT INTO {s} ({s}) SELECT {s} FROM \"{s}\"",
            .{ to.name_quoted, list.items, list.items, prev },
        );
        try execSql(db, sql, diag);
    }
}

fn reportMissingRows(
    arena: Allocator,
    db: *sqlite.Db,
    t: *const TableDiff,
    prev: []const u8,
    label: []const u8,
    diag: *Diagnostics,
) !u64 {
    const condition = if (t.to != null)
        try std.fmt.allocPrint(arena, "NOT EXISTS (SELECT 1 FROM \"{s}\" AS target WHERE target.\"id\" = \"{s}\".\"id\")", .{ t.name, prev })
    else
        "1";
    const missing = try countWhere(arena, db, prev, condition);
    if (missing == 0) return 0;

    var stmt = try db.prepareDynamic(try std.fmt.allocPrint(arena, "SELECT \"id\" FROM \"{s}\" WHERE {s} LIMIT 5", .{ prev, condition }));
    defer stmt.deinit();
    var samples = std.ArrayListUnmanaged(u8).empty;
    while (c.sqlite3_step(stmt.stmt) == c.SQLITE_ROW) {
        const ptr = c.sqlite3_column_blob(stmt.stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt.stmt, 0));
        const bytes = if (ptr != null) @as([*]const u8, @ptrCast(ptr))[0..len] else &[_]u8{};
        if (samples.items.len > 0) try samples.appendSlice(arena, ", ");
        if (typed_doc_id.fromBytes(bytes)) |id| {
            var hex: [32]u8 = undefined;
            try samples.appendSlice(arena, typed_doc_id.hexSlice(id, &hex));
        } else |_| {
            try samples.appendSlice(arena, "<malformed id>");
        }
    }

    if (t.to != null) {
        diag.add("{s} left {d} row(s) of \"{s}\" behind (e.g. id {s}).", .{ label, missing, t.name, samples.items });
    } else {
        diag.add("{s} left {d} row(s) of removed table \"{s}\" undecided (e.g. id {s}).", .{ label, missing, t.name, samples.items });
    }
    diag.add("  To drop rows on purpose, DELETE them from \"{s}\".", .{prev});
    return missing;
}

fn dropManagedIndexes(arena: Allocator, db: *sqlite.Db, table_name: []const u8, diag: *Diagnostics) !void {
    const names = try catalog.listManagedIndexNames(arena, db, table_name);
    for (names) |name| {
        try execSql(db, try std.fmt.allocPrint(arena, "DROP INDEX \"{s}\"", .{name}), diag);
    }
}

fn createManagedIndexes(arena: Allocator, db: *sqlite.Db, gen: *ddl.DDLGenerator, table: *const Table, diag: *Diagnostics) !void {
    var iter = ddl.ManagedIndexIterator.init(table);
    while (iter.next()) |managed_index| {
        const statement = try gen.generateIndexDDL(table.*, managed_index);
        execSqlQuiet(db, statement) catch |err| {
            if (err == error.UniqueConstraintViolation) {
                try reportDuplicates(arena, db, table, managed_index, diag);
            } else {
                diag.add("  {s}: {s}", .{ statement, std.mem.span(c.sqlite3_errmsg(db.db)) });
            }
            return err;
        };
    }
}

fn reportDuplicates(arena: Allocator, db: *sqlite.Db, table: *const Table, managed_index: ddl.ManagedIndex, diag: *Diagnostics) !void {
    const columns = try arena.alloc([]const u8, managed_index.columnCount(table));
    managed_index.columns(table, columns);

    var group = std.ArrayListUnmanaged(u8).empty;
    var rendered = std.ArrayListUnmanaged(u8).empty;
    var dotted = std.ArrayListUnmanaged(u8).empty;
    for (columns, 0..) |column, i| {
        if (i > 0) {
            try group.appendSlice(arena, ", ");
            try rendered.appendSlice(arena, " || ', ' || ");
        }
        try group.print(arena, "\"{s}\"", .{column});
        try rendered.print(arena, "quote(\"{s}\")", .{column});
        if (std.mem.eql(u8, column, "namespace_id")) continue;
        if (dotted.items.len > 0) try dotted.appendSlice(arena, ", ");
        try dotted.appendSlice(arena, try field_path.toDotted(arena, column));
    }

    diag.add("Cannot create the unique index on \"{s}\" ({s}): existing rows contain duplicates.", .{ table.name, dotted.items });
    const sql = try std.fmt.allocPrint(
        arena,
        "SELECT {s}, count(*) FROM {s} GROUP BY {s} HAVING count(*) > 1 LIMIT 5",
        .{ rendered.items, table.name_quoted, group.items },
    );
    var stmt = try db.prepareDynamic(sql);
    defer stmt.deinit();
    while (c.sqlite3_step(stmt.stmt) == c.SQLITE_ROW) {
        const ptr = c.sqlite3_column_text(stmt.stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt.stmt, 0));
        const values = if (ptr != null) ptr[0..len] else "";
        diag.add("  ({s}) appears {d} times", .{ values, c.sqlite3_column_int64(stmt.stmt, 1) });
    }
    diag.add("Remove or merge the duplicates with a migration (zyncbase migrate new <name>).", .{});
}

pub fn countRows(arena: Allocator, db: *sqlite.Db, table_name: []const u8) !u64 {
    return countWhere(arena, db, table_name, "1");
}

fn countWhere(arena: Allocator, db: *sqlite.Db, table_name: []const u8, condition: []const u8) !u64 {
    const sql = try std.fmt.allocPrint(arena, "SELECT count(*) FROM \"{s}\" WHERE {s}", .{ table_name, condition });
    const count = try db.oneDynamic(i64, sql, .{}, .{});
    return @intCast(count orelse 0);
}

/// Executes one statement; on failure records SQLite's message.
pub fn execSql(db: *sqlite.Db, sql: []const u8, diag: *Diagnostics) !void {
    execSqlQuiet(db, sql) catch |err| {
        diag.add("SQL failed: {s}", .{std.mem.span(c.sqlite3_errmsg(db.db))});
        diag.add("  {s}", .{sql});
        return err;
    };
}

/// Executes one statement and classifies failures before finalization can
/// change the connection error state.
fn execSqlQuiet(db: *sqlite.Db, sql: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        return storage_errors.classifyStepError(db);
    }
    defer _ = c.sqlite3_finalize(stmt);
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) return storage_errors.classifyStepError(db);
}
