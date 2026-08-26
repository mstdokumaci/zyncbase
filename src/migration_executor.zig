const std = @import("std");

const sqlite = @import("sqlite");

const migration_detector = @import("migration_detector.zig");
const field_path = @import("schema/field_path.zig");
const schema_system = @import("schema/system.zig");
const schema_types = @import("schema/types.zig");
const ddl_generator = @import("sql/ddl.zig");
const connection = @import("storage_engine/connection.zig");
const storage_errors = @import("storage_engine/errors.zig");

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

fn foreignKeysEnabled(db: *sqlite.Db) !bool {
    return (try db.pragma(i64, .{}, "foreign_keys", null) orelse return error.MissingForeignKeysPragma) != 0;
}

fn setForeignKeys(db: *sqlite.Db, enabled: bool) !void {
    if (enabled) {
        _ = try db.pragma(void, .{}, "foreign_keys", "on");
    } else {
        _ = try db.pragma(void, .{}, "foreign_keys", "off");
    }
}

pub const MigrationExecutor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    ddl_gen: *ddl_generator.DDLGenerator,
    config: MigrationConfig,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        db: *sqlite.Db,
        ddl_gen: *ddl_generator.DDLGenerator,
        config: MigrationConfig,
    ) MigrationExecutor {
        return .{
            .io = io,
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
        // Refuse destructive migrations when not allowed
        if (plan.is_destructive and !self.config.allow_destructive) {
            return error.DestructiveMigrationNotAllowed;
        }

        // Validate every version transition, including schema-identical plans.
        const target_ver = try parseVersion(target_version);
        if (try self.getPersistedVersion()) |persisted_ver| {
            if (target_ver.major > persisted_ver.major) {
                return error.MajorVersionBumpNotAllowed;
            }
        }

        const has_changes = plan.changes.len > 0;
        const foreign_keys_enabled = has_changes and try foreignKeysEnabled(self.db);
        if (foreign_keys_enabled) try setForeignKeys(self.db, false);
        var foreign_keys_restored = false;
        errdefer if (foreign_keys_enabled and !foreign_keys_restored) {
            setForeignKeys(self.db, true) catch |err| {
                std.log.err("Failed to restore SQLite foreign-key enforcement after migration error: {}", .{err});
            };
        };

        try self.db.exec("BEGIN", .{}, .{});
        var transaction_open = true;
        errdefer if (transaction_open) {
            self.db.exec("ROLLBACK", .{}, .{}) catch |err| std.log.err("ROLLBACK failed: {}", .{err});
        };

        for (plan.changes) |change| {
            try self.applyChange(change);
        }

        if (has_changes) try connection.verifyForeignKeys(self.db);

        // The schema and its recorded version commit or roll back together.
        try self.persistVersion(target_version);
        try self.db.exec("COMMIT", .{}, .{});
        transaction_open = false;

        if (foreign_keys_enabled) {
            try setForeignKeys(self.db, true);
            foreign_keys_restored = true;
        }
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
                const sql_type_str = field.storage_type.toSqlType();
                // SQLite ALTER TABLE ADD COLUMN does NOT allow NOT NULL without DEFAULT
                const sql = try std.fmt.allocPrint(
                    self.allocator,
                    "ALTER TABLE {s} ADD COLUMN {s} {s}",
                    .{ change.table.name_quoted, field.name_quoted, sql_type_str },
                );
                defer self.allocator.free(sql);
                try self.db.execDynamic(sql, .{}, .{});
            },
            .change_indexes => try self.reconcileManagedIndexes(change.table.*),
            .change_type, .remove_column, .change_foreign_keys => {
                try self.recreateTable(change.table.*);
            },
        }
    }

    /// Drop every current ZyncBase-managed index for the table, then create
    /// the full target set one statement at a time — all inside the caller's
    /// migration transaction. Unrelated manual indexes are untouched.
    fn reconcileManagedIndexes(self: *MigrationExecutor, table: schema_types.Table) !void {
        // rebuild all managed indexes for this table on mismatch; switch to
        // per-index diffs only if measured migration startup time makes it necessary.
        {
            var names = std.ArrayListUnmanaged([]const u8).empty;
            defer {
                for (names.items) |name| self.allocator.free(name);
                names.deinit(self.allocator);
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

            var iter = try stmt.iteratorAlloc(IndexListRow, self.allocator, .{});
            while (try iter.nextAlloc(self.allocator, .{})) |row| {
                defer {
                    self.allocator.free(row.name);
                    self.allocator.free(row.origin);
                }
                if (!migration_detector.isReservedManagedIndexName(row.name, table.name)) continue;
                const owned_name = try self.allocator.dupe(u8, row.name);
                names.append(self.allocator, owned_name) catch |err| {
                    self.allocator.free(owned_name);
                    return err;
                };
            }

            for (names.items) |name| {
                const drop_sql = try std.fmt.allocPrint(self.allocator, "DROP INDEX \"{s}\"", .{name});
                defer self.allocator.free(drop_sql);
                try self.execSingleStatement(drop_sql);
            }
        }

        var managed_iter = ddl_generator.ManagedIndexIterator.init(&table);
        while (managed_iter.next()) |managed_index| {
            const ddl = try self.ddl_gen.generateIndexDDL(table, managed_index);
            defer self.allocator.free(ddl);

            self.execSingleStatement(ddl) catch |err| {
                if (managed_index == .unique and err == error.UniqueConstraintViolation) {
                    self.logUniqueConstraintFailure(&table, managed_index.unique);
                }
                return err;
            };
        }
    }

    /// Execute one DDL statement through the raw C API and classify failures
    /// before statement finalization can change connection error state.
    fn execSingleStatement(self: *MigrationExecutor, sql: []const u8) !void {
        var stmt: ?*sqlite.c.sqlite3_stmt = null;
        const prep_rc = sqlite.c.sqlite3_prepare_v2(self.db.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prep_rc != sqlite.c.SQLITE_OK) return storage_errors.classifyStepError(self.db);
        defer _ = sqlite.c.sqlite3_finalize(stmt);
        if (sqlite.c.sqlite3_step(stmt) != sqlite.c.SQLITE_DONE) {
            return storage_errors.classifyStepError(self.db);
        }
    }

    fn logUniqueConstraintFailure(self: *MigrationExecutor, table: *const schema_types.Table, constraint_index: usize) void {
        const constraint = table.unique_constraints[constraint_index];
        const user_fields = table.userFields();
        var dotted = std.ArrayListUnmanaged(u8).empty;
        defer dotted.deinit(self.allocator);
        for (constraint.field_indexes, 0..) |field_index, i| {
            if (i > 0) dotted.appendSlice(self.allocator, ", ") catch return;
            const name = field_path.toDotted(self.allocator, user_fields[field_index].name) catch return;
            defer self.allocator.free(name);
            dotted.appendSlice(self.allocator, name) catch return;
        }
        // Warn, not err: the classified error propagates to the caller, whose
        // startup handler owns the fatal-error report.
        std.log.warn(
            "Cannot apply unique constraint on table '{s}' over fields ({s}): existing rows contain duplicates",
            .{ table.name, dotted.items },
        );
    }

    fn recreateTable(self: *MigrationExecutor, table: schema_types.Table) !void {
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
        var common = try buildCommonColumns(self.allocator, table, backup_cols);
        defer common.deinit(self.allocator);

        // 6. Copy data for common columns
        if (common.items.len > 0) {
            const insert_sql = try buildInsertSql(self.allocator, name_quoted, backup_name_quoted, common.items);
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
        try self.execSingleStatement(
            "CREATE TABLE IF NOT EXISTS schema_meta (version TEXT NOT NULL, applied_at INTEGER NOT NULL)",
        );
        try self.execSingleStatement("DELETE FROM schema_meta");

        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const insert_sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO schema_meta (version, applied_at) VALUES ('{s}', {d})",
            .{ version, now },
        );
        defer self.allocator.free(insert_sql);
        try self.execSingleStatement(insert_sql);
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

fn buildCommonColumns(
    allocator: std.mem.Allocator,
    table: schema_types.Table,
    backup_cols: []const []const u8,
) !std.ArrayListUnmanaged([]const u8) {
    var common: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer common.deinit(allocator);
    for (backup_cols) |bc| {
        var in_new = schema_system.isSystemColumn(bc);
        if (!in_new) {
            for (table.userFields()) |f| {
                if (std.mem.eql(u8, bc, f.name)) {
                    in_new = true;
                    break;
                }
            }
        }
        if (in_new) {
            try common.append(allocator, bc);
        }
    }
    return common;
}

fn buildInsertSql(
    allocator: std.mem.Allocator,
    name_quoted: []const u8,
    backup_name_quoted: []const u8,
    common: []const []const u8,
) ![]const u8 {
    var col_list: std.ArrayListUnmanaged(u8) = .empty;
    defer col_list.deinit(allocator);
    for (common, 0..) |col, i| {
        if (i > 0) try col_list.appendSlice(allocator, ", ");
        try appendQuotedIdentifier(allocator, &col_list, col);
    }
    const cols_str = col_list.items;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "INSERT INTO ");
    try buf.appendSlice(allocator, name_quoted);
    try buf.appendSlice(allocator, " (");
    try buf.appendSlice(allocator, cols_str);
    try buf.appendSlice(allocator, ") SELECT ");
    try buf.appendSlice(allocator, cols_str);
    try buf.appendSlice(allocator, " FROM ");
    try buf.appendSlice(allocator, backup_name_quoted);
    return try buf.toOwnedSlice(allocator);
}
