//! Logical diff between two schemas and per-change classification
//! (specs/implementation/schema-migrations.md#change-classification).
//!
//! Pure: no database access. Tables match by name and fields by flattened
//! name, so a rename is a removal plus an addition. The result borrows table
//! and field pointers from both schemas and must not outlive them.

const std = @import("std");

const ddl = @import("../sql/ddl.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Constraints = types.Constraints;
const Field = types.Field;
const Schema = types.Schema;
const Table = types.Table;

pub const Bucket = enum(u8) {
    auto,
    checked,
    migration_required,

    pub fn max(a: Bucket, b: Bucket) Bucket {
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }

    pub fn label(self: Bucket) []const u8 {
        return switch (self) {
            .auto => "auto",
            .checked => "checked",
            .migration_required => "migration required",
        };
    }
};

/// Physical treatment of one table in a step.
pub const TableAction = enum {
    unchanged,
    create,
    /// Rename to `_zync_prev_<table>`, create the target shape, refill.
    rebuild,
    /// `ALTER TABLE ... ADD COLUMN` for added optional fields.
    alter,
    /// Rename to `_zync_prev_<table>`; the developer moves or deletes rows.
    remove,
};

pub const FieldChangeKind = enum {
    added_optional,
    added_required,
    removed,
    type_changed,
    items_changed,
    became_optional,
    became_required,
    reference_target_changed,
    on_delete_changed,
    indexed_changed,
    constraint_tightened,
    constraint_loosened,
    metadata_changed,

    pub fn bucket(self: FieldChangeKind) Bucket {
        return switch (self) {
            .removed, .type_changed, .items_changed => .migration_required,
            .added_required, .became_required, .reference_target_changed, .constraint_tightened => .checked,
            .added_optional, .became_optional, .on_delete_changed, .indexed_changed, .constraint_loosened, .metadata_changed => .auto,
        };
    }

    pub fn needsRebuild(self: FieldChangeKind) bool {
        return switch (self) {
            .added_required,
            .removed,
            .type_changed,
            .items_changed,
            .became_optional,
            .became_required,
            .reference_target_changed,
            .on_delete_changed,
            => true,
            .added_optional, .indexed_changed, .constraint_tightened, .constraint_loosened, .metadata_changed => false,
        };
    }

    pub fn label(self: FieldChangeKind) []const u8 {
        return switch (self) {
            .added_optional => "added",
            .added_required => "added (required)",
            .removed => "removed",
            .type_changed => "type changed",
            .items_changed => "array items changed",
            .became_optional => "now optional",
            .became_required => "now required",
            .reference_target_changed => "reference target changed",
            .on_delete_changed => "onDelete changed",
            .indexed_changed => "indexed changed",
            .constraint_tightened => "constraint tightened",
            .constraint_loosened => "constraint relaxed",
            .metadata_changed => "metadata changed",
        };
    }
};

pub const TableChangeKind = enum {
    added,
    removed,
    namespaced_changed,
    unique_tightened,
    unique_loosened,
    metadata_changed,

    pub fn bucket(self: TableChangeKind) Bucket {
        return switch (self) {
            .removed, .namespaced_changed => .migration_required,
            .unique_tightened => .checked,
            .added, .unique_loosened, .metadata_changed => .auto,
        };
    }

    pub fn label(self: TableChangeKind) []const u8 {
        return switch (self) {
            .added => "added",
            .removed => "removed",
            .namespaced_changed => "namespaced changed",
            .unique_tightened => "unique constraint added or changed",
            .unique_loosened => "unique constraint removed or reordered",
            .metadata_changed => "metadata changed",
        };
    }
};

pub const FieldChange = struct {
    kind: FieldChangeKind,
    /// Flattened field name (borrowed from whichever side has the field).
    name: []const u8,
    from: ?*const Field,
    to: ?*const Field,
};

pub const TableDiff = struct {
    name: []const u8,
    from: ?*const Table,
    to: ?*const Table,
    action: TableAction,
    table_changes: []const TableChangeKind,
    field_changes: []const FieldChange,
    /// Managed index statements differ between the two sides.
    indexes_changed: bool,

    pub fn bucket(self: *const TableDiff) Bucket {
        var result: Bucket = .auto;
        for (self.table_changes) |c| result = result.max(c.bucket());
        for (self.field_changes) |c| result = result.max(c.kind.bucket());
        return result;
    }

    pub fn isEmpty(self: *const TableDiff) bool {
        return self.action == .unchanged and !self.indexes_changed and
            self.table_changes.len == 0 and self.field_changes.len == 0;
    }
};

pub const SchemaDiff = struct {
    allocator: Allocator,
    /// Tables present in the target (target order), then removed tables (source order).
    tables: []TableDiff,

    pub fn deinit(self: *SchemaDiff) void {
        for (self.tables) |t| {
            self.allocator.free(t.table_changes);
            self.allocator.free(t.field_changes);
        }
        self.allocator.free(self.tables);
    }

    pub fn bucket(self: *const SchemaDiff) Bucket {
        var result: Bucket = .auto;
        for (self.tables) |*t| result = result.max(t.bucket());
        return result;
    }

    pub fn hasMigrationRequired(self: *const SchemaDiff) bool {
        return self.bucket() == .migration_required;
    }

    /// No table-level or field-level change at all.
    pub fn isEmpty(self: *const SchemaDiff) bool {
        for (self.tables) |*t| {
            if (!t.isEmpty()) return false;
        }
        return true;
    }
};

/// Diffs `from` (null = empty database) against `to`.
pub fn diff(allocator: Allocator, from: ?*const Schema, to: *const Schema) !SchemaDiff {
    var tables = std.ArrayListUnmanaged(TableDiff).empty;
    errdefer {
        for (tables.items) |t| {
            allocator.free(t.table_changes);
            allocator.free(t.field_changes);
        }
        tables.deinit(allocator);
    }

    for (to.tables) |*to_table| {
        const from_table: ?*const Table = if (from) |f| f.table(to_table.name) else null;
        var table_diff = try diffTable(allocator, from_table, to_table);
        tables.append(allocator, table_diff) catch |err| {
            freeTableDiff(allocator, &table_diff);
            return err;
        };
    }
    if (from) |f| {
        for (f.tables) |*from_table| {
            if (to.table(from_table.name) != null) continue;
            const changes = try allocator.dupe(TableChangeKind, &.{.removed});
            tables.append(allocator, .{
                .name = from_table.name,
                .from = from_table,
                .to = null,
                .action = .remove,
                .table_changes = changes,
                .field_changes = &.{},
                .indexes_changed = false,
            }) catch |err| {
                allocator.free(changes);
                return err;
            };
        }
    }

    return .{
        .allocator = allocator,
        .tables = try tables.toOwnedSlice(allocator),
    };
}

fn freeTableDiff(allocator: Allocator, t: *TableDiff) void {
    allocator.free(t.table_changes);
    allocator.free(t.field_changes);
}

fn diffTable(allocator: Allocator, from: ?*const Table, to: *const Table) !TableDiff {
    const source = from orelse {
        return .{
            .name = to.name,
            .from = null,
            .to = to,
            .action = .create,
            .table_changes = try allocator.dupe(TableChangeKind, &.{.added}),
            .field_changes = &.{},
            .indexes_changed = false,
        };
    };

    var table_changes = std.ArrayListUnmanaged(TableChangeKind).empty;
    defer table_changes.deinit(allocator);
    var field_changes = std.ArrayListUnmanaged(FieldChange).empty;
    defer field_changes.deinit(allocator);

    if (source.namespaced != to.namespaced) try table_changes.append(allocator, .namespaced_changed);
    switch (compareUnique(source, to)) {
        .same => {},
        .tightened => try table_changes.append(allocator, .unique_tightened),
        .loosened => try table_changes.append(allocator, .unique_loosened),
    }
    if (!metadataEqual(source.metadata, to.metadata)) try table_changes.append(allocator, .metadata_changed);

    for (to.userFields()) |*to_field| {
        const from_field = userField(source, to_field.name) orelse {
            try field_changes.append(allocator, .{
                .kind = if (to_field.required) .added_required else .added_optional,
                .name = to_field.name,
                .from = null,
                .to = to_field,
            });
            continue;
        };
        try diffField(allocator, &field_changes, from_field, to_field);
    }
    for (source.userFields()) |*from_field| {
        if (userField(to, from_field.name) != null) continue;
        try field_changes.append(allocator, .{
            .kind = .removed,
            .name = from_field.name,
            .from = from_field,
            .to = null,
        });
    }

    var action: TableAction = .unchanged;
    for (table_changes.items) |c| {
        if (c == .namespaced_changed) action = .rebuild;
    }
    for (field_changes.items) |c| {
        if (c.kind.needsRebuild()) action = .rebuild;
    }
    if (action == .unchanged) {
        for (field_changes.items) |c| {
            if (c.kind == .added_optional) action = .alter;
        }
    }

    const indexes_changed = !try ddl.managedIndexesEqual(allocator, source, to);

    const owned_table_changes = try table_changes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_table_changes);
    return .{
        .name = to.name,
        .from = source,
        .to = to,
        .action = action,
        .table_changes = owned_table_changes,
        .field_changes = try field_changes.toOwnedSlice(allocator),
        .indexes_changed = indexes_changed,
    };
}

fn diffField(allocator: Allocator, out: *std.ArrayListUnmanaged(FieldChange), from: *const Field, to: *const Field) !void {
    const change = struct {
        fn make(kind: FieldChangeKind, f: *const Field, t: *const Field) FieldChange {
            return .{ .kind = kind, .name = t.name, .from = f, .to = t };
        }
    }.make;

    const same_type = from.declared_type == to.declared_type and from.storage_type == to.storage_type;
    if (!same_type) {
        try out.append(allocator, change(.type_changed, from, to));
    } else if (from.items_type != to.items_type) {
        try out.append(allocator, change(.items_changed, from, to));
    }

    if (from.required != to.required) {
        try out.append(allocator, change(if (to.required) .became_required else .became_optional, from, to));
    }

    if (same_type and from.references != null and to.references != null) {
        if (!std.mem.eql(u8, from.references.?, to.references.?)) {
            try out.append(allocator, change(.reference_target_changed, from, to));
        }
        if ((from.on_delete orelse .restrict) != (to.on_delete orelse .restrict)) {
            try out.append(allocator, change(.on_delete_changed, from, to));
        }
    }

    if (from.indexed != to.indexed) try out.append(allocator, change(.indexed_changed, from, to));

    if (same_type and from.items_type == to.items_type) {
        switch (compareConstraints(from.constraints, to.constraints)) {
            .same => {},
            .tightened => try out.append(allocator, change(.constraint_tightened, from, to)),
            .loosened => try out.append(allocator, change(.constraint_loosened, from, to)),
        }
    }

    if (!metadataEqual(from.metadata, to.metadata)) try out.append(allocator, change(.metadata_changed, from, to));
}

fn userField(table: *const Table, name: []const u8) ?*const Field {
    for (table.userFields()) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// ─── Constraint comparison ───────────────────────────────────────────────────

pub const ConstraintChange = enum { same, tightened, loosened };

const Accumulator = struct {
    tightened: bool = false,
    loosened: bool = false,

    fn note(self: *Accumulator, c: ConstraintChange) void {
        switch (c) {
            .same => {},
            .tightened => self.tightened = true,
            .loosened => self.loosened = true,
        }
    }

    fn result(self: Accumulator) ConstraintChange {
        if (self.tightened) return .tightened;
        if (self.loosened) return .loosened;
        return .same;
    }
};

/// Classifies how the set of accepted values changed. Any tightening wins.
pub fn compareConstraints(from: ?Constraints, to: ?Constraints) ConstraintChange {
    const empty = Constraints{};
    const a = from orelse empty;
    const b = to orelse empty;
    var acc = Accumulator{};

    acc.note(compareEnums(a.enum_values, b.enum_values));
    acc.note(compareExactText(a.pattern_source, b.pattern_source));
    acc.note(compareExactFormat(a.format, b.format));
    acc.note(compareLower(u64, a.min_length, b.min_length));
    acc.note(compareUpper(u64, a.max_length, b.max_length));
    acc.note(compareLowerBound(a.minimum, b.minimum));
    acc.note(compareUpperBound(a.maximum, b.maximum));
    return acc.result();
}

fn compareEnums(from: ?[]const Constraints.EnumValue, to: ?[]const Constraints.EnumValue) ConstraintChange {
    const old = from orelse return if (to == null) .same else .tightened;
    const new = to orelse return .loosened;
    for (old) |value| {
        if (!enumContains(new, value)) return .tightened;
    }
    for (new) |value| {
        if (!enumContains(old, value)) return .loosened;
    }
    return .same;
}

fn enumContains(list: []const Constraints.EnumValue, value: Constraints.EnumValue) bool {
    for (list) |candidate| {
        if (enumValueEql(candidate, value)) return true;
    }
    return false;
}

fn enumValueEql(a: Constraints.EnumValue, b: Constraints.EnumValue) bool {
    return switch (a) {
        .text => |at| switch (b) {
            .text => |bt| std.mem.eql(u8, at, bt),
            else => false,
        },
        .integer => |ai| switch (b) {
            .integer => |bi| ai == bi,
            .real => |br| @as(f64, @floatFromInt(ai)) == br,
            .text => false,
        },
        .real => |ar| switch (b) {
            .real => |br| ar == br,
            .integer => |bi| ar == @as(f64, @floatFromInt(bi)),
            .text => false,
        },
    };
}

fn compareExactText(from: ?[]const u8, to: ?[]const u8) ConstraintChange {
    const old = from orelse return if (to == null) .same else .tightened;
    const new = to orelse return .loosened;
    return if (std.mem.eql(u8, old, new)) .same else .tightened;
}

fn compareExactFormat(from: ?Constraints.Format, to: ?Constraints.Format) ConstraintChange {
    const old = from orelse return if (to == null) .same else .tightened;
    const new = to orelse return .loosened;
    return if (old == new) .same else .tightened;
}

/// A lower limit tightens when it appears or rises.
fn compareLower(comptime T: type, from: ?T, to: ?T) ConstraintChange {
    const old = from orelse return if (to == null) .same else .tightened;
    const new = to orelse return .loosened;
    if (new > old) return .tightened;
    if (new < old) return .loosened;
    return .same;
}

/// An upper limit tightens when it appears or falls.
fn compareUpper(comptime T: type, from: ?T, to: ?T) ConstraintChange {
    const old = from orelse return if (to == null) .same else .tightened;
    const new = to orelse return .loosened;
    if (new < old) return .tightened;
    if (new > old) return .loosened;
    return .same;
}

fn boundOrder(a: Constraints.Bound, b: Constraints.Bound) std.math.Order {
    if (a == .integer and b == .integer) return std.math.order(a.integer, b.integer);
    const af: f64 = switch (a) {
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
    };
    const bf: f64 = switch (b) {
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
    };
    return std.math.order(af, bf);
}

fn compareLowerBound(from: ?Constraints.Bound, to: ?Constraints.Bound) ConstraintChange {
    const old = from orelse return if (to == null) .same else .tightened;
    const new = to orelse return .loosened;
    return switch (boundOrder(new, old)) {
        .gt => .tightened,
        .lt => .loosened,
        .eq => .same,
    };
}

fn compareUpperBound(from: ?Constraints.Bound, to: ?Constraints.Bound) ConstraintChange {
    const old = from orelse return if (to == null) .same else .tightened;
    const new = to orelse return .loosened;
    return switch (boundOrder(new, old)) {
        .lt => .tightened,
        .gt => .loosened,
        .eq => .same,
    };
}

// ─── Unique constraints ──────────────────────────────────────────────────────

/// A target constraint whose ordered field list does not exist in the source
/// tightens; otherwise any difference (removal, reordering) loosens.
fn compareUnique(from: *const Table, to: *const Table) ConstraintChange {
    for (to.unique_constraints) |constraint| {
        if (!hasUnique(from, to, constraint)) return .tightened;
    }
    if (from.unique_constraints.len != to.unique_constraints.len) return .loosened;
    for (from.unique_constraints, to.unique_constraints) |a, b| {
        if (!sameUniqueFields(from, a, to, b)) return .loosened;
    }
    return .same;
}

fn hasUnique(haystack: *const Table, owner: *const Table, needle: types.UniqueConstraint) bool {
    for (haystack.unique_constraints) |candidate| {
        if (sameUniqueFields(haystack, candidate, owner, needle)) return true;
    }
    return false;
}

fn sameUniqueFields(a_table: *const Table, a: types.UniqueConstraint, b_table: *const Table, b: types.UniqueConstraint) bool {
    if (a.field_indexes.len != b.field_indexes.len) return false;
    const a_fields = a_table.userFields();
    const b_fields = b_table.userFields();
    for (a.field_indexes, b.field_indexes) |ai, bi| {
        if (!std.mem.eql(u8, a_fields[ai].name, b_fields[bi].name)) return false;
    }
    return true;
}

// ─── Non-physical sections ───────────────────────────────────────────────────

fn metadataEqual(a: ?types.Metadata, b: ?types.Metadata) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.json, b.?.json);
}
