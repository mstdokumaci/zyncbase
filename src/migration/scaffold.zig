//! Generates `migration.sql` scaffolds from a schema diff
//! (specs/implementation/schema-migrations.md#cli-contract).
//!
//! Unchanged columns are copied as-is. Every decision the developer must
//! make is a `zync_todo('...')` with a suggestion, which blocks the migration
//! until it is replaced.

const std = @import("std");

const schema_diff = @import("../schema/diff.zig");
const field_path = @import("../schema/field_path.zig");
const schema_types = @import("../schema/types.zig");
const catalog = @import("catalog.zig");
const step = @import("step.zig");

const Allocator = std.mem.Allocator;
const SchemaDiff = schema_diff.SchemaDiff;
const TableDiff = schema_diff.TableDiff;
const Field = schema_types.Field;
const Schema = schema_types.Schema;

pub const Input = struct {
    id: []const u8,
    before: *const Schema,
    before_hash: []const u8,
    after: *const Schema,
    after_hash: []const u8,
    diff: *const SchemaDiff,
};

pub fn generate(arena: Allocator, input: Input) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    const w = Writer{ .arena = arena, .out = &out };

    try writeHeader(w, input);
    var any_body = false;
    for (input.diff.tables) |*t| {
        if (try writeTable(w, t)) any_body = true;
    }
    if (!any_body) {
        try w.line("-- Write data updates here, e.g.", .{});
        try w.line("-- UPDATE \"<table>\" SET \"<field>\" = ... WHERE ...;", .{});
    }
    return out.toOwnedSlice(arena);
}

const Writer = struct {
    arena: Allocator,
    out: *std.ArrayListUnmanaged(u8),

    fn line(self: Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.arena, fmt ++ "\n", args);
    }

    fn blank(self: Writer) !void {
        try self.out.append(self.arena, '\n');
    }
};

fn writeHeader(w: Writer, input: Input) !void {
    try w.line("-- ZyncBase migration {s}", .{input.id});
    try w.line("-- Schema {s} -> {s}", .{ input.before.version, input.after.version });
    try w.line("--   before {s}", .{input.before_hash});
    try w.line("--   after  {s}", .{input.after_hash});
    try w.line("--", .{});
    try w.line("-- Before this file runs:", .{});
    try w.line("--   * Tables that change shape are empty and already have the new shape.", .{});
    try w.line("--     Their old rows are in \"_zync_prev_<table>\".", .{});
    try w.line("--   * Removed tables exist only as \"_zync_prev_<table>\".", .{});
    try w.line("--   * Every other table is already up to date and can be read or updated.", .{});
    try w.line("--   * Foreign keys are off and cascades do not run; integrity is checked at the end.", .{});
    try w.line("-- After it runs, every row left in \"_zync_prev_<table>\" must exist (by id) in \"<table>\".", .{});
    try w.line("-- To drop rows on purpose, DELETE them from \"_zync_prev_<table>\".", .{});
    try w.line("-- Replace every zync_todo(...) with your decision; the migration will not run until you do.", .{});
    try w.line("--", .{});
    try w.line("-- Changes:", .{});
    var any = false;
    for (input.diff.tables) |*t| {
        for (t.table_changes) |change| {
            try w.line("--   {s}  {s}  ({s})", .{ t.name, change.label(), change.bucket().label() });
            any = true;
        }
        for (t.field_changes) |change| {
            try w.line("--   {s}.{s}  {s}  ({s})", .{ t.name, try dotted(w.arena, change.name), change.kind.label(), change.kind.bucket().label() });
            any = true;
        }
    }
    if (!any) try w.line("--   none (data-only migration)", .{});
    try w.blank();
}

/// Returns true when the table produced SQL or guidance.
fn writeTable(w: Writer, t: *const TableDiff) !bool {
    switch (t.action) {
        .remove => {
            const prev = try step.prevName(w.arena, t.name);
            try w.line("-- {s}: removed", .{t.name});
            const message = try std.fmt.allocPrint(w.arena, "{s} was removed. Move rows you need, then drop the rest with: DELETE FROM \"{s}\";", .{ t.name, prev });
            try w.line("SELECT zync_todo('{s}');", .{try sqlString(w.arena, message)});
            try w.blank();
            return true;
        },
        .rebuild => {
            try writeRebuild(w, t);
            return true;
        },
        .alter => {
            var names = std.ArrayListUnmanaged(u8).empty;
            for (t.field_changes) |change| {
                if (change.kind != .added_optional) continue;
                if (names.items.len > 0) try names.appendSlice(w.arena, ", ");
                try names.print(w.arena, "\"{s}\"", .{change.name});
            }
            try w.line("-- {s}: new columns {s} start as NULL; backfill them here if needed.", .{ t.name, names.items });
            _ = try writeCheckedHints(w, t);
            try w.blank();
            return true;
        },
        .unchanged => {
            if (!try writeCheckedHints(w, t)) return false;
            try w.blank();
            return true;
        },
        .create => return false,
    }
}

/// Comments for checked changes on tables that are not rebuilt.
fn writeCheckedHints(w: Writer, t: *const TableDiff) !bool {
    var wrote = false;
    for (t.field_changes) |change| {
        if (change.kind != .constraint_tightened) continue;
        try w.line("-- {s}.{s}: the constraint is stricter; rows that violate it fail validation. Fix them here, e.g.", .{ t.name, try dotted(w.arena, change.name) });
        try w.line("-- UPDATE \"{s}\" SET \"{s}\" = ... WHERE ...;", .{ t.name, change.name });
        wrote = true;
    }
    for (t.table_changes) |change| {
        if (change != .unique_tightened) continue;
        const table = t.to orelse continue;
        try w.line("-- {s}: a unique constraint was added or changed; duplicates fail startup. Find them with:", .{t.name});
        for (table.unique_constraints) |constraint| {
            var columns = std.ArrayListUnmanaged(u8).empty;
            var where = std.ArrayListUnmanaged(u8).empty;
            try columns.appendSlice(w.arena, "\"namespace_id\"");
            try where.appendSlice(w.arena, "\"namespace_id\" IS NOT NULL");
            for (constraint.field_indexes) |field_index| {
                const name = table.userFields()[field_index].name;
                try columns.print(w.arena, ", \"{s}\"", .{name});
                try where.print(w.arena, " AND \"{s}\" IS NOT NULL", .{name});
            }
            try w.line("-- SELECT {s}, count(*) FROM \"{s}\"", .{ columns.items, t.name });
            try w.line("--   WHERE {s}", .{where.items});
            try w.line("--   GROUP BY {s} HAVING count(*) > 1 LIMIT 5;", .{columns.items});
        }
        wrote = true;
    }
    return wrote;
}

fn writeRebuild(w: Writer, t: *const TableDiff) !void {
    const to = t.to orelse return error.InvalidState;
    const prev = try step.prevName(w.arena, t.name);
    const columns = try catalog.expectedColumns(w.arena, to);
    const renames = try renameCandidates(w.arena, t);

    try w.line("-- {s}: rebuilt", .{t.name});
    var list = std.ArrayListUnmanaged(u8).empty;
    for (columns, 0..) |column, i| {
        if (i > 0) try list.appendSlice(w.arena, ", ");
        try list.print(w.arena, "\"{s}\"", .{column.name});
    }
    try w.line("INSERT INTO \"{s}\" ({s})", .{ t.name, list.items });
    try w.line("SELECT", .{});
    for (columns, 0..) |column, i| {
        const expression = try columnExpression(w.arena, t, column.name, renames);
        try w.line("  {s}{s}", .{ expression, if (i + 1 < columns.len) "," else "" });
    }
    try w.line("FROM \"{s}\";", .{prev});
    for (t.field_changes) |change| {
        if (change.kind != .removed) continue;
        if (isRenameSource(renames, change.name)) continue;
        try w.line("-- Removed: \"{s}\" (its values are dropped).", .{change.name});
    }
    try w.blank();
}

const Rename = struct { added: []const u8, removed: []const u8 };

/// Pairs each added field with a removed field of the same type, in order.
fn renameCandidates(arena: Allocator, t: *const TableDiff) ![]const Rename {
    var pairs = std.ArrayListUnmanaged(Rename).empty;
    for (t.field_changes) |added| {
        if (added.kind != .added_optional and added.kind != .added_required) continue;
        const to = added.to orelse continue;
        for (t.field_changes) |removed| {
            if (removed.kind != .removed) continue;
            const from = removed.from orelse continue;
            if (!sameType(from, to) or isRenameSource(pairs.items, removed.name)) continue;
            try pairs.append(arena, .{ .added = added.name, .removed = removed.name });
            break;
        }
    }
    return pairs.toOwnedSlice(arena);
}

fn isRenameSource(renames: []const Rename, name: []const u8) bool {
    for (renames) |r| {
        if (std.mem.eql(u8, r.removed, name)) return true;
    }
    return false;
}

fn renameOf(renames: []const Rename, added: []const u8) ?[]const u8 {
    for (renames) |r| {
        if (std.mem.eql(u8, r.added, added)) return r.removed;
    }
    return null;
}

fn sameType(a: *const Field, b: *const Field) bool {
    return a.declared_type == b.declared_type and a.storage_type == b.storage_type and a.items_type == b.items_type;
}

fn columnExpression(arena: Allocator, t: *const TableDiff, column: []const u8, renames: []const Rename) ![]const u8 {
    const quoted = try std.fmt.allocPrint(arena, "\"{s}\"", .{column});
    const qualified = try std.fmt.allocPrint(arena, "{s}.{s}", .{ t.name, try dotted(arena, column) });

    if (std.mem.eql(u8, column, "namespace_id")) {
        for (t.table_changes) |change| {
            if (change == .namespaced_changed) {
                return todo(arena, "{s}.namespaced changed: choose namespace_id for each row (0 for tables that are not namespaced)", .{t.name});
            }
        }
        return quoted;
    }

    for (t.field_changes) |change| {
        if (!std.mem.eql(u8, change.name, column)) continue;
        switch (change.kind) {
            .type_changed, .items_changed => {
                const from = change.from orelse return quoted;
                const to = change.to orelse return quoted;
                var suffix: []const u8 = "";
                for (t.field_changes) |other| {
                    if (other.kind == .became_required and std.mem.eql(u8, other.name, change.name)) {
                        suffix = " Rows where it is NULL also need a replacement value.";
                    }
                }
                return todo(arena, "{s}: {s} -> {s}. {s}{s}", .{ qualified, try typeName(arena, from), try typeName(arena, to), try suggestion(arena, quoted, from, to), suffix });
            },
            .added_required => {
                if (renameOf(renames, column)) |old| {
                    return todo(arena, "{s} is new and required. Rename of \"{s}\"? Then use \"{s}\".", .{ qualified, old, old });
                }
                return todo(arena, "{s} is new and required: provide a value for every row", .{qualified});
            },
            .added_optional => {
                if (renameOf(renames, column)) |old| {
                    return todo(arena, "{s} is new. Rename of \"{s}\"? Then use \"{s}\", otherwise NULL.", .{ qualified, old, old });
                }
                return "NULL";
            },
            .became_required => {
                const placeholder = try todo(arena, "{s} is now required: value for rows where it is NULL", .{qualified});
                return std.fmt.allocPrint(arena, "coalesce({s}, {s})", .{ quoted, placeholder });
            },
            else => {},
        }
    }
    return quoted;
}

fn todo(arena: Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    const message = try std.fmt.allocPrint(arena, fmt, args);
    return std.fmt.allocPrint(arena, "zync_todo('{s}')", .{try sqlString(arena, message)});
}

fn typeName(arena: Allocator, field: *const Field) ![]const u8 {
    if (field.references) |ref| return std.fmt.allocPrint(arena, "reference to {s}", .{ref});
    if (field.storage_type == .array) {
        const items = if (field.items_type) |it| it.schemaName() else "?";
        return std.fmt.allocPrint(arena, "array of {s}", .{items});
    }
    return field.declared_type.schemaName();
}

/// A conversion the developer is likely to want; they must still decide.
fn suggestion(arena: Allocator, column: []const u8, from: *const Field, to: *const Field) ![]const u8 {
    if (from.references != null or to.references != null) {
        return "SQL cannot convert between document-id strings and references. Expand and contract instead: keep the old field, add a new reference field, backfill it through the SDK, and remove the old field in a later migration.";
    }
    if (to.storage_type == .array) {
        const items = if (to.items_type) |it| it.schemaName() else "string";
        if (from.storage_type == .array) {
            const item_expr = if (to.items_type == .boolean)
                "CASE WHEN value THEN json('true') ELSE json('false') END"
            else blk: {
                const sql_type = if (to.items_type) |it| it.toSqlType() else "TEXT";
                break :blk try std.fmt.allocPrint(arena, "CAST(value AS {s})", .{sql_type});
            };
            return std.fmt.allocPrint(arena, "Example: CASE WHEN {0s} IS NULL THEN NULL ELSE jsonb(zync_array((SELECT json_group_array({1s}) FROM json_each({0s})), '{2s}')) END", .{ column, item_expr, items });
        }
        const scalar_expr = if (to.items_type == .boolean)
            try std.fmt.allocPrint(arena, "CASE WHEN {s} THEN json('true') ELSE json('false') END", .{column})
        else
            column;
        return std.fmt.allocPrint(arena, "Example: CASE WHEN {0s} IS NULL THEN NULL ELSE jsonb(zync_array(json_array({1s}), '{2s}')) END", .{ column, scalar_expr, items });
    }
    if (from.storage_type == .array) {
        return std.fmt.allocPrint(arena, "Example: json_extract({s}, '$[0]')", .{column});
    }
    if (from.storage_type == .bytes or to.storage_type == .bytes) {
        return if (to.storage_type == .bytes)
            std.fmt.allocPrint(arena, "Example: CAST({s} AS BLOB)", .{column})
        else
            std.fmt.allocPrint(arena, "Example: CASE WHEN {s} IS NULL THEN NULL ELSE hex({s}) END", .{ column, column });
    }
    return switch (to.declared_type) {
        .text => std.fmt.allocPrint(arena, "Example: CAST({s} AS TEXT)", .{column}),
        .integer => switch (from.declared_type) {
            .boolean => std.fmt.allocPrint(arena, "Example: {s}", .{column}),
            .real => std.fmt.allocPrint(arena, "Example: CAST({s} AS INTEGER) (drops fractions)", .{column}),
            else => std.fmt.allocPrint(arena, "Example: CAST({s} AS INTEGER) (non-numeric text becomes 0)", .{column}),
        },
        .real => switch (from.declared_type) {
            .integer => std.fmt.allocPrint(arena, "Example: CAST({s} AS REAL) (integers above 2^53 lose precision)", .{column}),
            else => std.fmt.allocPrint(arena, "Example: CAST({s} AS REAL) (non-numeric text becomes 0.0)", .{column}),
        },
        .boolean => switch (from.declared_type) {
            .text => std.fmt.allocPrint(arena, "Example: {s} IN ('true', '1')", .{column}),
            else => std.fmt.allocPrint(arena, "Example: {s} != 0", .{column}),
        },
        else => "Convert the value explicitly.",
    };
}

fn dotted(arena: Allocator, name: []const u8) ![]const u8 {
    return field_path.toDotted(arena, name);
}

/// Escapes a value for a single-quoted SQL string literal.
fn sqlString(arena: Allocator, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, text, "'", "''");
}
