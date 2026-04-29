const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const sqlite = @import("sqlite");

pub const ChangeKind = enum { create_table, add_column, change_type, remove_column };

pub const Change = struct {
    kind: ChangeKind,
    table: *const schema_manager.Table,
    field: ?schema_manager.Field,
};

pub const MigrationPlan = struct {
    changes: []Change,
    is_destructive: bool,
};

fn typesMatch(target: schema_manager.FieldType, db_type: []const u8) bool {
    const sql_type = target.toSqlType();
    if (std.mem.eql(u8, sql_type, db_type)) return true;
    return false;
}

fn isManagedColumn(table: schema_manager.Table, name: []const u8) bool {
    return schema_manager.isSystemColumn(name) or
        (table.is_users_table and std.mem.eql(u8, name, "external_id"));
}

pub const MigrationDetector = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    current_schema: *const schema_manager.Schema,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Db, current_schema: *const schema_manager.Schema) MigrationDetector {
        return .{ .allocator = allocator, .db = db, .current_schema = current_schema };
    }

    pub fn detectChanges(self: *MigrationDetector, target: *const schema_manager.Schema) !MigrationPlan {
        var changes: std.ArrayListUnmanaged(Change) = .empty;
        errdefer {
            for (changes.items) |c| self.freeChange(c);
            changes.deinit(self.allocator);
        }

        for (target.tables) |*table| {
            const pragma_sql = try std.fmt.allocPrint(
                self.allocator,
                "PRAGMA table_info({s})",
                .{table.name},
            );
            defer self.allocator.free(pragma_sql);

            var existing = std.StringHashMap([]const u8).init(self.allocator);
            defer {
                var it = existing.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                existing.deinit();
            }

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

            var iter = try stmt.iteratorAlloc(PragmaRow, self.allocator, .{});
            var table_exists = false;

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

            if (!table_exists) {
                try changes.append(self.allocator, .{
                    .kind = .create_table,
                    .table = table,
                    .field = null,
                });
                continue;
            }

            for (table.fields) |field| {
                if (isManagedColumn(table.*, field.name)) continue;
                if (existing.get(field.name)) |db_type| {
                    if (!typesMatch(field.sql_type, db_type)) {
                        const owned_field = try field.clone(self.allocator);
                        errdefer schema_manager.freeField(self.allocator, owned_field);
                        try changes.append(self.allocator, .{
                            .kind = .change_type,
                            .table = table,
                            .field = owned_field,
                        });
                    }
                } else {
                    const owned_field = try field.clone(self.allocator);
                    errdefer schema_manager.freeField(self.allocator, owned_field);
                    try changes.append(self.allocator, .{
                        .kind = .add_column,
                        .table = table,
                        .field = owned_field,
                    });
                }
            }

            var ex_it = existing.iterator();
            while (ex_it.next()) |entry| {
                const col_name = entry.key_ptr.*;
                var found_in_target = false;
                for (table.fields) |field| {
                    if (std.mem.eql(u8, field.name, col_name)) {
                        found_in_target = true;
                        break;
                    }
                }
                if (!found_in_target) {
                    // Look up the field from the current schema (it was built with name_quoted etc.)
                    // SAFETY: assigned via clone() before use; guard-checked by found_in_current
                    var current_field: schema_manager.Field = undefined;
                    var found_in_current = false;
                    outer: for (self.current_schema.tables) |ct| {
                        if (std.mem.eql(u8, ct.name, table.name)) {
                            for (ct.fields) |f| {
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

                    errdefer schema_manager.freeField(self.allocator, current_field);
                    try changes.append(self.allocator, .{
                        .kind = .remove_column,
                        .table = table,
                        .field = current_field,
                    });
                }
            }
        }

        var is_destructive = false;
        for (changes.items) |c| {
            if (c.kind == .change_type or c.kind == .remove_column) {
                is_destructive = true;
                break;
            }
        }

        return MigrationPlan{
            .changes = try changes.toOwnedSlice(self.allocator),
            .is_destructive = is_destructive,
        };
    }

    pub fn deinit(self: *MigrationDetector, plan: MigrationPlan) void {
        for (plan.changes) |c| self.freeChange(c);
        self.allocator.free(plan.changes);
    }

    fn freeChange(self: *MigrationDetector, c: Change) void {
        if (c.field) |f| schema_manager.freeField(self.allocator, f);
    }
};
