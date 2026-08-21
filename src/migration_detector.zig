const std = @import("std");

const sqlite = @import("sqlite");

const schema_system = @import("schema/system.zig");
const schema_types = @import("schema/types.zig");

pub const ChangeKind = enum { create_table, add_column, change_type, remove_column, change_foreign_keys, change_foreign_key_indexes };

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
            if (!try self.foreignKeysMatch(table)) {
                try changes.append(self.allocator, .{
                    .kind = .change_foreign_keys,
                    .table = table,
                    .field = null,
                });
            } else if (!try self.foreignKeyIndexesMatch(table)) {
                try changes.append(self.allocator, .{
                    .kind = .change_foreign_key_indexes,
                    .table = table,
                    .field = null,
                });
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

    fn foreignKeyIndexesMatch(self: *MigrationDetector, table: *const schema_types.Table) !bool {
        const fields = table.userFields();
        const seen = try self.allocator.alloc(bool, fields.len);
        defer self.allocator.free(seen);
        @memset(seen, false);

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

        var iter = try stmt.iteratorAlloc(IndexListRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            defer {
                self.allocator.free(row.name);
                self.allocator.free(row.origin);
            }
            if (row.partial != 0) continue;
            if (row.unique != 0) continue;
            for (fields, 0..) |field, field_idx| {
                if (field.references == null or seen[field_idx]) continue;
                if (isExpectedIndexName(row.name, table.name, field.name) and
                    try self.indexMatchesField(row.name, field.name))
                {
                    seen[field_idx] = true;
                    break;
                }
            }
        }

        for (fields, 0..) |field, field_idx| {
            if (field.references != null and !seen[field_idx]) return false;
        }
        return true;
    }

    fn indexMatchesField(self: *MigrationDetector, index_name: []const u8, field_name: []const u8) !bool {
        const pragma_sql = try std.fmt.allocPrint(self.allocator, "PRAGMA index_info(\"{s}\")", .{index_name});
        defer self.allocator.free(pragma_sql);
        var stmt = try self.db.prepareDynamic(pragma_sql);
        defer stmt.deinit();

        const IndexInfoRow = struct {
            seqno: i64,
            cid: i64,
            name: ?[]const u8,
        };

        var count: usize = 0;
        var valid = true;
        var iter = try stmt.iteratorAlloc(IndexInfoRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            defer if (row.name) |name| self.allocator.free(name);
            count += 1;
            if (row.seqno != 0 or row.name == null or !std.mem.eql(u8, field_name, row.name.?)) valid = false;
        }
        return valid and count == 1;
    }

    pub fn deinit(self: *MigrationDetector, plan: MigrationPlan) void {
        for (plan.changes) |c| self.freeChange(c);
        self.allocator.free(plan.changes);
    }

    fn freeChange(self: *MigrationDetector, c: Change) void {
        if (c.field) |f| f.deinit(self.allocator);
    }
};

fn isExpectedIndexName(index_name: []const u8, table_name: []const u8, field_name: []const u8) bool {
    const prefix = "idx_";
    const field_start = prefix.len + table_name.len + 1;
    return index_name.len == field_start + field_name.len and
        std.mem.startsWith(u8, index_name, prefix) and
        std.mem.eql(u8, table_name, index_name[prefix.len .. field_start - 1]) and
        index_name[field_start - 1] == '_' and
        std.mem.eql(u8, field_name, index_name[field_start..]);
}
