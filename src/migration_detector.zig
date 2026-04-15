const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const sqlite = @import("sqlite");

pub const ChangeKind = enum { create_table, add_column, change_type, remove_column };

pub const Change = struct {
    kind: ChangeKind,
    table_name: []const u8,
    field: ?schema_manager.Field,
};

pub const MigrationPlan = struct {
    changes: []Change,
    is_destructive: bool,
};

fn dbTypeToFieldType(db_type: []const u8) schema_manager.FieldType {
    if (std.mem.eql(u8, db_type, "TEXT")) return .text;
    if (std.mem.eql(u8, db_type, "INTEGER")) return .integer;
    if (std.mem.eql(u8, db_type, "REAL")) return .real;
    if (std.mem.eql(u8, db_type, "BLOB")) return .array;
    return .text;
}
fn typesMatch(target: schema_manager.FieldType, db_type: []const u8) bool {
    const sql_type = target.toSqlType();
    if (std.mem.eql(u8, sql_type, db_type)) return true;
    return false;
}

pub const MigrationDetector = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Db,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Db) MigrationDetector {
        return .{ .allocator = allocator, .db = db };
    }

    pub fn detectChanges(self: *MigrationDetector, target: schema_manager.Schema) !MigrationPlan {
        var changes: std.ArrayList(Change) = .{};
        errdefer {
            for (changes.items) |c| self.freeChange(c);
            changes.deinit(self.allocator);
        }

        for (target.tables) |table| {
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
                if (!schema_manager.isSystemColumn(row.name)) {
                    const owned_name = try self.allocator.dupe(u8, row.name);
                    errdefer self.allocator.free(owned_name);
                    const owned_type = try self.allocator.dupe(u8, row.type);
                    errdefer self.allocator.free(owned_type);
                    try existing.put(owned_name, owned_type);
                }
            }

            if (!table_exists) {
                const owned_name = try self.allocator.dupe(u8, table.name);
                errdefer self.allocator.free(owned_name);
                try changes.append(self.allocator, .{
                    .kind = .create_table,
                    .table_name = owned_name,
                    .field = null,
                });
                continue;
            }

            for (table.fields) |field| {
                if (schema_manager.isSystemColumn(field.name)) continue;
                if (existing.get(field.name)) |db_type| {
                    if (!typesMatch(field.sql_type, db_type)) {
                        const owned_table = try self.allocator.dupe(u8, table.name);
                        errdefer self.allocator.free(owned_table);
                        const owned_field = try field.clone(self.allocator);
                        errdefer schema_manager.freeField(self.allocator, owned_field);
                        try changes.append(self.allocator, .{
                            .kind = .change_type,
                            .table_name = owned_table,
                            .field = owned_field,
                        });
                    }
                } else {
                    const owned_table = try self.allocator.dupe(u8, table.name);
                    errdefer self.allocator.free(owned_table);
                    const owned_field = try field.clone(self.allocator);
                    errdefer schema_manager.freeField(self.allocator, owned_field);
                    try changes.append(self.allocator, .{
                        .kind = .add_column,
                        .table_name = owned_table,
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
                    const owned_table = try self.allocator.dupe(u8, table.name);
                    errdefer self.allocator.free(owned_table);
                    const owned_field_name = try self.allocator.dupe(u8, col_name);
                    errdefer self.allocator.free(owned_field_name);
                    const ft = dbTypeToFieldType(entry.value_ptr.*);
                    try changes.append(self.allocator, .{
                        .kind = .remove_column,
                        .table_name = owned_table,
                        .field = schema_manager.Field{
                            .name = owned_field_name,
                            .sql_type = ft,
                            .items_type = null,
                            .required = false,
                            .indexed = false,
                            .references = null,
                            .on_delete = null,
                        },
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
        self.allocator.free(c.table_name);
        if (c.field) |f| schema_manager.freeField(self.allocator, f);
    }
};
