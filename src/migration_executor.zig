const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const ddl_generator = @import("ddl_generator.zig");
const migration_detector = @import("migration_detector.zig");
const sqlite = @import("sqlite");

pub const AutoMigrateMode = enum { full, additive_only, disabled };

pub const MigrationConfig = struct {
    auto_migrate: AutoMigrateMode = .full,
    allow_destructive: bool = false,
};

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

fn parseVersion(s: []const u8) !Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major_str = it.next() orelse return error.InvalidVersion;
    const minor_str = it.next() orelse return error.InvalidVersion;
    const patch_str = it.next() orelse return error.InvalidVersion;
    if (it.next() != null) return error.InvalidVersion;
    const major = std.fmt.parseInt(u32, major_str, 10) catch return error.InvalidVersion;
    const minor = std.fmt.parseInt(u32, minor_str, 10) catch return error.InvalidVersion;
    const patch = std.fmt.parseInt(u32, patch_str, 10) catch return error.InvalidVersion;
    return Version{ .major = major, .minor = minor, .patch = patch };
}

pub const MigrationExecutor = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    ddl_gen: *ddl_generator.DDLGenerator,
    config: MigrationConfig,

    pub fn init(
        allocator: std.mem.Allocator,
        db: *sqlite.Db,
        ddl_gen: *ddl_generator.DDLGenerator,
        config: MigrationConfig,
    ) MigrationExecutor {
        return .{
            .allocator = allocator,
            .db = db,
            .ddl_gen = ddl_gen,
            .config = config,
        };
    }

    pub fn execute(
        self: *MigrationExecutor,
        plan: migration_detector.MigrationPlan,
        target_version: []const u8,
    ) !void {
        // Nothing to do
        if (plan.changes.len == 0) {
            try self.persistVersion(target_version);
            return;
        }

        // Refuse destructive migrations when not allowed
        if (plan.is_destructive and !self.config.allow_destructive) {
            return error.DestructiveMigrationNotAllowed;
        }

        // Check major version bump - parse target version first (may return InvalidVersion)
        const target_ver = try parseVersion(target_version);
        if (try self.getPersistedVersion()) |persisted_ver| {
            if (target_ver.major > persisted_ver.major) {
                return error.MajorVersionBumpNotAllowed;
            }
        }

        // Begin transaction
        try self.db.exec("BEGIN", .{}, .{});

        // Apply each change
        for (plan.changes) |change| {
            self.applyChange(change) catch |err| {
                self.db.exec("ROLLBACK", .{}, .{}) catch |e| std.log.err("ROLLBACK failed: {}", .{e});
                return err;
            };
        }

        // Commit
        self.db.exec("COMMIT", .{}, .{}) catch |err| {
            self.db.exec("ROLLBACK", .{}, .{}) catch |e| std.log.err("ROLLBACK failed: {}", .{e});
            return err;
        };

        // Persist version after successful commit
        try self.persistVersion(target_version);
    }

    fn applyChange(self: *MigrationExecutor, change: migration_detector.Change) !void {
        switch (change.kind) {
            .create_table => {
                const ddl = try self.ddl_gen.generateDDL(change.table.*);
                defer self.allocator.free(ddl);
                const ddl_z = try self.allocator.dupeZ(u8, ddl);
                defer self.allocator.free(ddl_z);
                try self.db.execMulti(ddl_z, .{});
            },
            .add_column => {
                const field = change.field orelse return error.MissingFieldInChange;
                const sql_type_str = field.sql_type.toSqlType();
                // SQLite ALTER TABLE ADD COLUMN does NOT allow NOT NULL without DEFAULT
                const sql = try std.fmt.allocPrint(
                    self.allocator,
                    "ALTER TABLE {s} ADD COLUMN {s} {s}",
                    .{ change.table.name_quoted, field.name_quoted, sql_type_str },
                );
                defer self.allocator.free(sql);
                try self.db.execDynamic(sql, .{}, .{});
            },
            .change_type, .remove_column => {
                // Only reached when allow_destructive = true
                try self.recreateTable(change.table.*);
            },
        }
    }

    fn recreateTable(self: *MigrationExecutor, table: schema_manager.Table) !void {
        const name = table.name;
        const name_quoted = table.name_quoted;
        const backup_name = try std.fmt.allocPrint(self.allocator, "{s}_backup", .{name});
        defer self.allocator.free(backup_name);

        const backup_name_quoted = try std.fmt.allocPrint(self.allocator, "\"{s}_backup\"", .{name});
        defer self.allocator.free(backup_name_quoted);

        // 1. Backup
        const backup_sql = try std.fmt.allocPrint(
            self.allocator,
            "CREATE TABLE {s} AS SELECT * FROM {s}",
            .{ backup_name_quoted, name_quoted },
        );
        defer self.allocator.free(backup_sql);
        try self.db.execDynamic(backup_sql, .{}, .{});

        // 2. Drop original
        const drop_sql = try std.fmt.allocPrint(self.allocator, "DROP TABLE {s}", .{name_quoted});
        defer self.allocator.free(drop_sql);
        try self.db.execDynamic(drop_sql, .{}, .{});

        // 3. Create new table
        const ddl = try self.ddl_gen.generateDDL(table);
        defer self.allocator.free(ddl);
        const ddl_z = try self.allocator.dupeZ(u8, ddl);
        defer self.allocator.free(ddl_z);
        try self.db.execMulti(ddl_z, .{});

        // 4. Get columns of backup table via PRAGMA
        const backup_cols = try self.getTableColumns(backup_name);
        defer {
            for (backup_cols) |c| self.allocator.free(c);
            self.allocator.free(backup_cols);
        }

        // 5. Build common columns (intersection of backup cols and new table cols)
        var common: std.ArrayListUnmanaged([]const u8) = .empty;
        defer common.deinit(self.allocator);

        for (backup_cols) |bc| {
            var in_new = schema_manager.isSystemColumn(bc);
            if (!in_new) {
                for (table.fields) |f| {
                    if (std.mem.eql(u8, bc, f.name)) {
                        in_new = true;
                        break;
                    }
                }
            }
            if (in_new) {
                try common.append(self.allocator, bc);
            }
        }

        if (common.items.len > 0) {
            var col_list: std.ArrayListUnmanaged(u8) = .empty;
            defer col_list.deinit(self.allocator);
            for (common.items, 0..) |col, i| {
                if (i > 0) try col_list.appendSlice(self.allocator, ", ");
                try appendQuotedIdentifier(self.allocator, &col_list, col);
            }
            const cols_str = col_list.items;

            var insert_sql_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer insert_sql_buf.deinit(self.allocator);
            try insert_sql_buf.appendSlice(self.allocator, "INSERT INTO ");
            try insert_sql_buf.appendSlice(self.allocator, name_quoted);
            try insert_sql_buf.appendSlice(self.allocator, " (");
            try insert_sql_buf.appendSlice(self.allocator, cols_str);
            try insert_sql_buf.appendSlice(self.allocator, ") SELECT ");
            try insert_sql_buf.appendSlice(self.allocator, cols_str);
            try insert_sql_buf.appendSlice(self.allocator, " FROM ");
            try insert_sql_buf.appendSlice(self.allocator, backup_name_quoted);
            const insert_sql = try insert_sql_buf.toOwnedSlice(self.allocator);
            defer self.allocator.free(insert_sql);
            try self.db.execDynamic(insert_sql, .{}, .{});
        }

        // 6. Drop backup
        const drop_backup_sql = try std.fmt.allocPrint(
            self.allocator,
            "DROP TABLE {s}",
            .{backup_name_quoted},
        );
        defer self.allocator.free(drop_backup_sql);
        try self.db.execDynamic(drop_backup_sql, .{}, .{});
    }

    fn getTableColumns(self: *MigrationExecutor, table_name: []const u8) ![][]const u8 {
        const pragma_sql = try std.fmt.allocPrint(
            self.allocator,
            "PRAGMA table_info('{s}')",
            .{table_name},
        );
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

        var cols: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (cols.items) |c| self.allocator.free(c);
            cols.deinit(self.allocator);
        }

        var iter = try stmt.iteratorAlloc(PragmaRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            defer {
                self.allocator.free(row.type);
                if (row.dflt_value) |dv| self.allocator.free(dv);
            }
            try cols.append(self.allocator, row.name);
        }

        return cols.toOwnedSlice(self.allocator);
    }

    fn persistVersion(self: *MigrationExecutor, version: []const u8) !void {
        try self.db.exec(
            "CREATE TABLE IF NOT EXISTS schema_meta (version TEXT NOT NULL, applied_at INTEGER NOT NULL)",
            .{},
            .{},
        );
        try self.db.exec("DELETE FROM schema_meta", .{}, .{});

        const now = std.time.timestamp();
        const insert_sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO schema_meta (version, applied_at) VALUES ('{s}', {d})",
            .{ version, now },
        );
        defer self.allocator.free(insert_sql);
        try self.db.execDynamic(insert_sql, .{}, .{});
    }

    fn getPersistedVersion(self: *MigrationExecutor) !?Version {
        // Check if schema_meta exists
        var check_stmt = self.db.prepare(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_meta'",
        ) catch return null;
        defer check_stmt.deinit();

        const Row = struct { name: []const u8 };
        var check_iter = try check_stmt.iteratorAlloc(Row, self.allocator, .{});
        const row = try check_iter.nextAlloc(self.allocator, .{});
        if (row == null) return null;
        defer self.allocator.free(row.?.name);

        // Query version
        var stmt = self.db.prepare("SELECT version FROM schema_meta LIMIT 1") catch return null;
        defer stmt.deinit();

        const VersionRow = struct { version: []const u8 };
        var iter = try stmt.iteratorAlloc(VersionRow, self.allocator, .{});
        const ver_row = try iter.nextAlloc(self.allocator, .{});
        if (ver_row == null) return null;
        defer self.allocator.free(ver_row.?.version);

        return try parseVersion(ver_row.?.version);
    }
};

fn appendQuotedIdentifier(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    identifier: []const u8,
) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, identifier);
    try buf.append(allocator, '"');
}
