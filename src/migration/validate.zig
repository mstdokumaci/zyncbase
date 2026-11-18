//! Row validation against the target schema for values that STRICT and the
//! DDL cannot enforce: boolean 0/1, canonical array sets with typed items, and
//! schema constraints (enum, pattern, format, lengths, ranges).

const std = @import("std");

const sqlite = @import("sqlite");

const schema_constraints = @import("../schema/constraints.zig");
const schema_types = @import("../schema/types.zig");
const typed_codec = @import("../typed/codec.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const c = sqlite.c;
const Field = schema_types.Field;
const Table = schema_types.Table;

const max_samples = 5;

/// Validates `table`'s user columns in the database. `only` restricts the
/// check to the named fields. Returns the number of violating values and
/// writes one diagnostic line per violated field.
pub fn validateTable(
    arena: Allocator,
    db: *sqlite.Db,
    table: *const Table,
    only: ?[]const []const u8,
    diag: *Diagnostics,
) !u64 {
    var total: u64 = 0;
    for (table.userFields()) |*field| {
        if (only) |names| {
            if (!containsName(names, field.name)) continue;
        }
        total += try validateField(arena, db, table, field, diag);
    }
    return total;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const Samples = struct {
    count: u64 = 0,
    ids: [max_samples][32]u8 = @splat(@splat('?')),
    reasons: [max_samples][]const u8 = @splat(""),
    stored: usize = 0,

    fn note(self: *Samples, id_bytes: []const u8, reason: []const u8) void {
        self.count += 1;
        if (self.stored == max_samples) return;
        if (typed_doc_id.fromBytes(id_bytes)) |id| {
            _ = typed_doc_id.hexSlice(id, &self.ids[self.stored]);
        } else |_| {
            @memset(&self.ids[self.stored], '?');
        }
        self.reasons[self.stored] = reason;
        self.stored += 1;
    }

    fn report(self: *const Samples, diag: *Diagnostics, table: *const Table, field: *const Field) void {
        if (self.count == 0) return;
        diag.add("  {s}.{s}: {d} row(s) violate the schema", .{ table.name, field.name, self.count });
        for (self.ids[0..self.stored], self.reasons[0..self.stored]) |*id, reason| {
            diag.add("    id {s}: {s}", .{ id, reason });
        }
    }
};

fn validateField(arena: Allocator, db: *sqlite.Db, table: *const Table, field: *const Field, diag: *Diagnostics) !u64 {
    const needs_scan = switch (field.storage_type) {
        .boolean, .array => true,
        .doc_id => false,
        else => field.constraints != null,
    };
    if (!needs_scan) return 0;

    const value_expr = if (field.storage_type == .array)
        try std.fmt.allocPrint(arena, "json({s})", .{field.name_quoted})
    else
        field.name_quoted;
    const sql = try std.fmt.allocPrint(
        arena,
        "SELECT \"id\", {s} FROM {s} WHERE {s} IS NOT NULL",
        .{ value_expr, table.name_quoted, field.name_quoted },
    );

    var stmt = try db.prepareDynamic(sql);
    defer stmt.deinit();

    var samples = Samples{};
    var json_buf = std.ArrayListUnmanaged(u8).empty;
    while (true) {
        const rc = c.sqlite3_step(stmt.stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.SQLiteError;

        const id_bytes = columnBlob(stmt.stmt, 0);
        if (try checkValue(arena, stmt.stmt, field, &json_buf)) |reason| {
            samples.note(id_bytes, reason);
        }
    }
    samples.report(diag, table, field);
    return samples.count;
}

/// Returns a violation reason, or null when the value is valid.
fn checkValue(
    arena: Allocator,
    stmt: *c.sqlite3_stmt,
    field: *const Field,
    json_buf: *std.ArrayListUnmanaged(u8),
) !?[]const u8 {
    switch (field.storage_type) {
        .boolean => {
            const v = c.sqlite3_column_int64(stmt, 1);
            return if (v == 0 or v == 1) null else "boolean must be stored as 0 or 1";
        },
        .array => return checkArray(arena, stmt, field, json_buf),
        .text => {
            const constraints = field.constraints orelse return null;
            return constraintReason(arena, constraints, field.declared_type, .{ .text = columnText(stmt, 1) });
        },
        .integer => {
            const constraints = field.constraints orelse return null;
            return constraintReason(arena, constraints, field.declared_type, .{ .integer = c.sqlite3_column_int64(stmt, 1) });
        },
        .real => {
            const constraints = field.constraints orelse return null;
            return constraintReason(arena, constraints, field.declared_type, .{ .real = c.sqlite3_column_double(stmt, 1) });
        },
        .bytes => {
            const constraints = field.constraints orelse return null;
            return constraintReason(arena, constraints, field.declared_type, .{ .bytes = columnBlob(stmt, 1) });
        },
        .doc_id => return null,
    }
}

fn constraintReason(
    arena: Allocator,
    constraints: schema_types.Constraints,
    declared_type: schema_types.FieldType,
    value: schema_constraints.Scalar,
) !?[]const u8 {
    schema_constraints.validateScalar(constraints, declared_type, value, arena) catch |err| {
        return switch (err) {
            error.EnumViolation => "value is not in the enum",
            error.PatternViolation => "value does not match the pattern",
            error.FormatViolation => "value does not match the format",
            error.LengthViolation => "length is outside the allowed range",
            error.RangeViolation => "value is outside the allowed range",
            error.TypeMismatch => "value has the wrong type",
            else => return err,
        };
    };
    return null;
}

/// Arrays must hold exactly what the runtime writes: a JSON array of typed
/// scalars, sorted and de-duplicated, encoded by the runtime codec.
fn checkArray(
    arena: Allocator,
    stmt: *c.sqlite3_stmt,
    field: *const Field,
    json_buf: *std.ArrayListUnmanaged(u8),
) !?[]const u8 {
    const stored = columnText(stmt, 1);
    const items_type = field.items_type orelse return "array field has no items type";

    const parsed = std.json.parseFromSlice(std.json.Value, arena, stored, .{}) catch return "array is not valid JSON";
    defer parsed.deinit();
    const value = typed_codec.fromJson(arena, .array, items_type, parsed.value) catch return "array has an element of the wrong type";
    defer value.deinit(arena);

    json_buf.clearRetainingCapacity();
    try typed_codec.writeJsonToBuf(json_buf, arena, value);
    if (!std.mem.eql(u8, json_buf.items, stored)) {
        return "array is not in canonical form (sorted, unique, runtime encoding)";
    }
    return null;
}

fn columnText(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    return if (ptr != null) ptr[0..len] else "";
}

fn columnBlob(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_blob(stmt, index);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    return if (ptr != null) @as([*]const u8, @ptrCast(ptr))[0..len] else &.{};
}
