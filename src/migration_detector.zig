const std = @import("std");

const sqlite = @import("sqlite");

const schema_system = @import("schema/system.zig");
const schema_types = @import("schema/types.zig");
const sql_buf = @import("sql/buf.zig");
const ddl_generator = @import("sql/ddl.zig");

pub const ChangeKind = enum { create_table, add_column, change_type, remove_column, change_foreign_keys, change_indexes };

pub const Change = struct {
    kind: ChangeKind,
    table: *const schema_types.Table,
    field: ?schema_types.Field,
};

pub const MigrationPlan = struct {
    changes: []Change,
    is_destructive: bool,
};

fn typesMatch(target: schema_types.StorageType, db_type: []const u8) bool {
    const sql_type = target.toSqlType();
    if (std.mem.eql(u8, sql_type, db_type)) return true;
    return false;
}

fn isManagedColumn(table: schema_types.Table, name: []const u8) bool {
    return schema_system.isSystemColumn(name) or
        (table.is_users_table and std.mem.eql(u8, name, "external_id"));
}

pub const MigrationDetector = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    current_schema: *const schema_types.Schema,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Db, current_schema: *const schema_types.Schema) MigrationDetector {
        return .{ .allocator = allocator, .db = db, .current_schema = current_schema };
    }

    pub fn detectChanges(self: *MigrationDetector, target: *const schema_types.Schema) !MigrationPlan {
        var changes: std.ArrayListUnmanaged(Change) = .empty;
        errdefer {
            for (changes.items) |c| self.freeChange(c);
            changes.deinit(self.allocator);
        }

        for (target.tables) |*table| {
            var col_result = try self.queryExistingColumns(table);
            defer {
                var it = col_result.columns.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                col_result.columns.deinit();
            }

            if (!col_result.table_exists) {
                try changes.append(self.allocator, .{
                    .kind = .create_table,
                    .table = table,
                    .field = null,
                });
                continue;
            }

            try self.detectColumnChanges(&changes, table, &col_result.columns);
            try self.detectRemovedColumns(&changes, table, &col_result.columns);

            // Rebuild-classified changes install the complete target index set
            // themselves; scheduling index reconciliation would be redundant.
            var scheduled_rebuild = false;
            for (changes.items) |c| {
                if (c.table == table and
                    (c.kind == .change_type or c.kind == .remove_column or c.kind == .change_foreign_keys))
                {
                    scheduled_rebuild = true;
                    break;
                }
            }

            if (!scheduled_rebuild) {
                if (!try self.foreignKeysMatch(table)) {
                    try changes.append(self.allocator, .{
                        .kind = .change_foreign_keys,
                        .table = table,
                        .field = null,
                    });
                } else if (!try self.managedIndexesMatch(table)) {
                    try changes.append(self.allocator, .{
                        .kind = .change_indexes,
                        .table = table,
                        .field = null,
                    });
                }
            }
        }

        var is_destructive = false;
        for (changes.items) |c| {
            if (c.kind == .change_type or c.kind == .remove_column or c.kind == .change_foreign_keys) {
                is_destructive = true;
                break;
            }
        }

        return MigrationPlan{
            .changes = try changes.toOwnedSlice(self.allocator),
            .is_destructive = is_destructive,
        };
    }

    const ExistingColumns = struct {
        columns: std.StringHashMap([]const u8),
        table_exists: bool,
    };

    fn queryExistingColumns(self: *MigrationDetector, table: *const schema_types.Table) !ExistingColumns {
        var existing = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = existing.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            existing.deinit();
        }

        const pragma_sql = try std.fmt.allocPrint(self.allocator, "PRAGMA table_info({s})", .{table.name});
        defer self.allocator.free(pragma_sql);

        var stmt = try self.db.prepareDynamic(pragma_sql);
        defer stmt.deinit();

        const PragmaRow = struct {
            cid: i64,
            name: []const u8,
            type: []const u8,
            notnull: i64,
            dflt_value: ?[]const u8,
            pk: i64,
        };

        var table_exists = false;
        var iter = try stmt.iteratorAlloc(PragmaRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            defer {
                self.allocator.free(row.name);
                self.allocator.free(row.type);
                if (row.dflt_value) |dv| self.allocator.free(dv);
            }
            table_exists = true;
            if (!isManagedColumn(table.*, row.name)) {
                const owned_name = try self.allocator.dupe(u8, row.name);
                errdefer self.allocator.free(owned_name);
                const owned_type = try self.allocator.dupe(u8, row.type);
                errdefer self.allocator.free(owned_type);
                try existing.put(owned_name, owned_type);
            }
        }

        return .{ .columns = existing, .table_exists = table_exists };
    }

    fn detectColumnChanges(
        self: *MigrationDetector,
        changes: *std.ArrayListUnmanaged(Change),
        table: *const schema_types.Table,
        existing: *const std.StringHashMap([]const u8),
    ) !void {
        for (table.userFields()) |field| {
            if (isManagedColumn(table.*, field.name)) continue;
            if (existing.get(field.name)) |db_type| {
                if (!typesMatch(field.storage_type, db_type)) {
                    const owned_field = try field.clone(self.allocator);
                    errdefer owned_field.deinit(self.allocator);
                    try changes.append(self.allocator, .{
                        .kind = .change_type,
                        .table = table,
                        .field = owned_field,
                    });
                }
            } else {
                const owned_field = try field.clone(self.allocator);
                errdefer owned_field.deinit(self.allocator);
                try changes.append(self.allocator, .{
                    .kind = .add_column,
                    .table = table,
                    .field = owned_field,
                });
            }
        }
    }

    fn detectRemovedColumns(
        self: *MigrationDetector,
        changes: *std.ArrayListUnmanaged(Change),
        table: *const schema_types.Table,
        existing: *const std.StringHashMap([]const u8),
    ) !void {
        var ex_it = existing.iterator();
        while (ex_it.next()) |entry| {
            const col_name = entry.key_ptr.*;
            var found_in_target = false;
            for (table.userFields()) |field| {
                if (std.mem.eql(u8, field.name, col_name)) {
                    found_in_target = true;
                    break;
                }
            }
            if (!found_in_target) {
                // SAFETY: assigned via clone() before use; guard-checked by found_in_current
                var current_field: schema_types.Field = undefined;
                var found_in_current = false;
                outer: for (self.current_schema.tables) |ct| {
                    if (std.mem.eql(u8, ct.name, table.name)) {
                        for (ct.userFields()) |f| {
                            if (std.mem.eql(u8, f.name, col_name)) {
                                current_field = try f.clone(self.allocator);
                                found_in_current = true;
                                break :outer;
                            }
                        }
                        break;
                    }
                }

                if (!found_in_current) return error.ColumnNotFoundInCurrentSchema;

                errdefer current_field.deinit(self.allocator);
                try changes.append(self.allocator, .{
                    .kind = .remove_column,
                    .table = table,
                    .field = current_field,
                });
            }
        }
    }

    fn foreignKeysMatch(self: *MigrationDetector, table: *const schema_types.Table) !bool {
        const fields = table.userFields();
        const seen = try self.allocator.alloc(bool, fields.len);
        defer self.allocator.free(seen);
        @memset(seen, false);

        var expected_count: usize = 0;
        for (fields) |field| {
            if (field.references != null) expected_count += 1;
        }

        const pragma_sql = try std.fmt.allocPrint(self.allocator, "PRAGMA foreign_key_list({s})", .{table.name_quoted});
        defer self.allocator.free(pragma_sql);
        var stmt = try self.db.prepareDynamic(pragma_sql);
        defer stmt.deinit();

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

        var actual_count: usize = 0;
        var valid = true;
        var iter = try stmt.iteratorAlloc(ForeignKeyRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            defer {
                self.allocator.free(row.table);
                self.allocator.free(row.from);
                if (row.to) |to| self.allocator.free(to);
                self.allocator.free(row.on_update);
                self.allocator.free(row.on_delete);
                self.allocator.free(row.match);
            }
            actual_count += 1;

            var matched = false;
            for (fields, 0..) |field, field_idx| {
                const reference = field.references orelse continue;
                const expected_action = switch (field.on_delete orelse .restrict) {
                    .cascade => "CASCADE",
                    .restrict => "RESTRICT",
                    .set_null => "SET NULL",
                };
                if (std.mem.eql(u8, field.name, row.from) and
                    std.mem.eql(u8, reference, row.table) and
                    row.to != null and std.mem.eql(u8, "id", row.to.?) and
                    row.seq == 0 and
                    std.mem.eql(u8, "NO ACTION", row.on_update) and
                    std.mem.eql(u8, expected_action, row.on_delete) and
                    std.mem.eql(u8, "NONE", row.match) and
                    !seen[field_idx])
                {
                    seen[field_idx] = true;
                    matched = true;
                    break;
                }
            }
            if (!matched) valid = false;
        }

        if (!valid or actual_count != expected_count) return false;
        for (fields, 0..) |field, field_idx| {
            if (field.references != null and !seen[field_idx]) return false;
        }
        return true;
    }

    const ActualIndex = struct {
        name: []const u8,
        unique: bool,
        partial: bool,
        consumed: bool = false,
    };

    /// Compare the database's indexes against every managed index definition
    /// exported by `sql/ddl.zig`. Mismatched or obsolete ZyncBase-reserved
    /// indexes schedule a `change_indexes` reconciliation.
    fn managedIndexesMatch(self: *MigrationDetector, table: *const schema_types.Table) !bool {
        var actual_list = std.ArrayListUnmanaged(ActualIndex).empty;
        defer {
            for (actual_list.items) |ai| self.allocator.free(ai.name);
            actual_list.deinit(self.allocator);
        }

        const pragma_sql = try std.fmt.allocPrint(self.allocator, "PRAGMA index_list({s})", .{table.name_quoted});
        defer self.allocator.free(pragma_sql);
        var stmt = try self.db.prepareDynamic(pragma_sql);
        defer stmt.deinit();

        const IndexListRow = struct {
            seq: i64,
            name: []const u8,
            unique: i64,
            origin: []const u8,
            partial: i64,
        };

        {
            var iter = try stmt.iteratorAlloc(IndexListRow, self.allocator, .{});
            while (try iter.nextAlloc(self.allocator, .{})) |row| {
                defer {
                    self.allocator.free(row.name);
                    self.allocator.free(row.origin);
                }
                const owned_name = try self.allocator.dupe(u8, row.name);
                actual_list.append(self.allocator, .{
                    .name = owned_name,
                    .unique = row.unique != 0,
                    .partial = row.partial != 0,
                }) catch |err| {
                    self.allocator.free(owned_name);
                    return err;
                };
            }
        }

        // Expected indexes are exactly those emitted by generateIndexesDDL.
        var expected_iter = ddl_generator.ManagedIndexIterator.init(table);
        while (expected_iter.next()) |managed_index| {
            var name_buf = sql_buf.SqlBuf.init();
            defer name_buf.deinit(self.allocator);
            try managed_index.appendName(self.allocator, &name_buf, table);

            var found: ?*ActualIndex = null;
            for (actual_list.items) |*ai| {
                if (!ai.consumed and indexNameEql(name_buf.items(), ai.name)) {
                    found = ai;
                    break;
                }
            }
            const actual = found orelse return false;

            if (actual.unique != managed_index.isUnique()) return false;
            if (actual.partial) return false;

            const col_count = managed_index.columnCount(table);
            const expected_cols = try self.allocator.alloc([]const u8, col_count);
            defer self.allocator.free(expected_cols);
            managed_index.columns(table, expected_cols);
            if (!try self.indexColumnsMatch(name_buf.items(), expected_cols)) return false;

            // Consume this actual index so it cannot count as obsolete.
            actual.consumed = true;
        }

        // Any remaining reserved-prefix index is obsolete managed drift.
        for (actual_list.items) |ai| {
            if (ai.consumed) continue;
            if (isReservedManagedIndexName(ai.name, table.name)) return false;
        }
        return true;
    }

    fn indexColumnsMatch(self: *MigrationDetector, index_name_quoted: []const u8, expected: []const []const u8) !bool {
        const pragma_sql = try std.fmt.allocPrint(self.allocator, "PRAGMA index_info({s})", .{index_name_quoted});
        defer self.allocator.free(pragma_sql);
        var stmt = try self.db.prepareDynamic(pragma_sql);
        defer stmt.deinit();

        const IndexInfoRow = struct {
            seqno: i64,
            cid: i64,
            name: ?[]const u8,
        };

        var i: usize = 0;
        var valid = true;
        var iter = try stmt.iteratorAlloc(IndexInfoRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            defer if (row.name) |name| self.allocator.free(name);
            if (i >= expected.len or row.seqno != @as(i64, @intCast(i))) {
                valid = false;
            } else if (row.name == null or !std.mem.eql(u8, expected[i], row.name.?)) {
                valid = false;
            }
            i += 1;
        }
        return valid and i == expected.len;
    }

    pub fn deinit(self: *MigrationDetector, plan: MigrationPlan) void {
        for (plan.changes) |c| self.freeChange(c);
        self.allocator.free(plan.changes);
    }

    fn freeChange(self: *MigrationDetector, c: Change) void {
        if (c.field) |f| f.deinit(self.allocator);
    }
};

/// Compare an expected quoted index name (`"idx_t_f"`) with the unquoted name
/// reported by `PRAGMA index_list`.
fn indexNameEql(expected_quoted: []const u8, actual_unquoted: []const u8) bool {
    if (expected_quoted.len < 2 or expected_quoted[0] != '"') return false;
    return std.mem.eql(u8, expected_quoted[1 .. expected_quoted.len - 1], actual_unquoted);
}

/// True when `index_name` falls inside ZyncBase's reserved managed namespaces
/// for this table (`idx_<table>_...` / `uidx_<table>_...`).
pub fn isReservedManagedIndexName(index_name: []const u8, table_name: []const u8) bool {
    return hasManagedPrefix(index_name, table_name, "idx_") or
        hasManagedPrefix(index_name, table_name, "uidx_");
}

fn hasManagedPrefix(index_name: []const u8, table_name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, index_name, prefix)) return false;
    const rest = index_name[prefix.len..];
    if (!std.mem.startsWith(u8, rest, table_name)) return false;
    return rest.len > table_name.len and rest[table_name.len] == '_';
}
