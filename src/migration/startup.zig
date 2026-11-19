//! Startup migration entry point used by the server, `migrate apply`, and
//! test helpers (specs/implementation/schema-migrations.md#startup-procedure).
//! Runs on the storage engine's setup connection while the exclusive data lock
//! is held and before any worker thread exists.

const std = @import("std");

const sqlite = @import("sqlite");

const backup = @import("../backup.zig");
const canonical = @import("../schema/canonical.zig");
const schema_diff = @import("../schema/diff.zig");
const field_path = @import("../schema/field_path.zig");
const schema_parse = @import("../schema/parse.zig");
const schema_types = @import("../schema/types.zig");
const connection = @import("../storage_engine/connection.zig");
const catalog = @import("catalog.zig");
const functions = @import("functions.zig");
const source = @import("source.zig");
const sql_runner = @import("sql_runner.zig");
const state = @import("state.zig");
const step = @import("step.zig");
const Version = @import("../schema/version.zig").Version;
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const SchemaDiff = schema_diff.SchemaDiff;
const Schema = schema_types.Schema;

/// The schema to reach.
pub const Target = struct {
    schema: *const Schema,
    /// Minified schema JSON (stored as the applied snapshot).
    json: []const u8,
    hash: canonical.Hash,
};

pub const Options = struct {
    /// Loaded migration folders, sorted by id.
    migrations: []const source.Migration = &.{},
    /// Path of the database file; the pre-migration snapshot is written next
    /// to it. Null disables the snapshot.
    snapshot_of: ?[]const u8 = null,
    /// Enforce the major-version rule. Only `migrate check` turns it off, for
    /// its per-migration runs: the rule applies to a deployment, not a file.
    enforce_major_bump: bool = true,
    /// Run the deployment-level foreign-key check. Per-migration `migrate check`
    /// runs skip it; the full chain still performs it.
    verify_foreign_keys: bool = true,
    /// Run every step, then roll back (`migrate apply --dry-run`).
    dry_run: bool = false,
    /// Plan only: describe the steps into `plan_out` and execute nothing.
    /// The connection may be read-only (`migrate status`).
    plan_only: bool = false,
    plan_out: ?*Diagnostics = null,
};

pub const Report = struct {
    /// Executed steps. Zero means nothing was written.
    steps: usize = 0,
    rebuilt: bool = false,
    migrations_applied: usize = 0,
    migrations_baselined: usize = 0,
    /// Pre-migration snapshot path, owned by the run's allocator.
    snapshot_path: ?[]u8 = null,

    pub fn deinit(self: *Report, allocator: Allocator) void {
        if (self.snapshot_path) |path| allocator.free(path);
        self.snapshot_path = null;
    }
};

const PlannedStep = struct {
    label: []const u8,
    to: *const Schema,
    to_json: []const u8,
    to_hash: canonical.Hash,
    migration: ?*const source.Migration = null,
    diff: SchemaDiff,
};

const Plan = struct {
    allocator: Allocator,
    steps: std.ArrayListUnmanaged(PlannedStep) = .empty,
    /// Migrations recorded as baseline (fresh databases only).
    baseline: []const source.Migration = &.{},
    repair: []const []const u8 = &.{},

    fn deinit(self: *Plan) void {
        for (self.steps.items) |*s| s.diff.deinit();
        self.steps.deinit(self.allocator);
    }

    fn add(self: *Plan, planned: PlannedStep) !void {
        var owned = planned;
        self.steps.append(self.allocator, owned) catch |err| {
            owned.diff.deinit();
            return err;
        };
    }

    fn firstMigrationId(self: *const Plan) ?[]const u8 {
        for (self.steps.items) |s| {
            if (s.migration) |m| return m.id;
        }
        return null;
    }
};

/// Brings the database to `target`. On error nothing is changed and `diag`
/// explains why.
pub fn run(io: std.Io, allocator: Allocator, db: *sqlite.Db, target: Target, options: Options, diag: *Diagnostics) !Report {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var applied_schema: ?Schema = null;
    defer if (applied_schema) |*s| s.deinit();

    var plan = Plan{ .allocator = allocator };
    defer plan.deinit();

    if (try state.hasSchemaTable(db)) {
        const applied = (try state.readApplied(arena, db)) orelse {
            diag.add("The database has a {s} table without a schema record.", .{state.schema_table});
            return error.UnrecognizedDatabase;
        };
        if (applied.layout != state.layout_version) {
            diag.add("The database uses storage layout {d}; this build supports layout {d}.", .{ applied.layout, state.layout_version });
            return error.UnsupportedLayout;
        }
        const applied_from: *const Schema = if (std.mem.eql(u8, applied.hash, &target.hash))
            target.schema
        else blk: {
            applied_schema = schema_parse.initFromJson(allocator, applied.json) catch |err| {
                diag.add("The applied schema {s} stored in the database cannot be parsed by this build: {s}", .{ applied.version, @errorName(err) });
                return err;
            };
            break :blk &applied_schema.?;
        };

        var repair = std.ArrayListUnmanaged([]const u8).empty;
        try checkDrift(arena, allocator, db, applied_from, &repair, diag);
        plan.repair = repair.items;
        try planExisting(arena, allocator, db, &plan, applied_from, applied.hash, target, options, diag);
    } else {
        const tables = try catalog.listUserTables(arena, db);
        if (tables.len > 0) {
            diag.add("The database has tables but no ZyncBase schema record (first: \"{s}\").", .{tables[0]});
            diag.add("It was created by an older build or another tool. Recreate it with: zyncbase reset --yes", .{});
            return error.UnrecognizedDatabase;
        }
        try plan.add(.{
            .label = try std.fmt.allocPrint(arena, "initial schema {s}", .{target.schema.version}),
            .to = target.schema,
            .to_json = target.json,
            .to_hash = target.hash,
            .diff = try schema_diff.diff(allocator, null, target.schema),
        });
        plan.baseline = options.migrations;
    }

    if (options.plan_only) {
        if (options.plan_out) |out| try describePlan(arena, out, &plan);
        return .{ .steps = plan.steps.items.len, .migrations_baselined = plan.baseline.len };
    }
    if (plan.steps.items.len == 0) return .{};

    var report = Report{};
    errdefer report.deinit(allocator);
    if (!options.dry_run) {
        if (options.snapshot_of) |db_path| {
            if (plan.firstMigrationId()) |first| {
                const path = backup.snapshotHeld(io, allocator, db, db_path, first) catch |err| {
                    diag.add("Could not write the pre-migration snapshot of {s}: {s}", .{ db_path, @errorName(err) });
                    diag.add("Free disk space, or set migrations.snapshot to false if you have another restore point.", .{});
                    return error.SnapshotFailed;
                };
                report.snapshot_path = path;
                std.log.info("Pre-migration snapshot written to {s}", .{path});
            }
        }
    }

    try runTransaction(arena, io, allocator, db, &plan, options, &report, diag);
    return report;
}

/// Plans bridge, migration, and final steps from the applied schema.
fn planExisting(
    arena: Allocator,
    allocator: Allocator,
    db: *sqlite.Db,
    plan: *Plan,
    applied: *const Schema,
    applied_hash: []const u8,
    target: Target,
    options: Options,
    diag: *Diagnostics,
) !void {
    const ledger = try state.readLedger(arena, db);
    const pending = try checkHistory(arena, ledger, options.migrations, diag);

    var cur: *const Schema = applied;
    var cur_hash: []const u8 = applied_hash;
    var any_migration_required = false;

    for (pending) |m| {
        if (!std.mem.eql(u8, cur_hash, &m.before.hash)) {
            try checkStepVersion(cur, &m.before.schema, diag);
            var bridge = try schema_diff.diff(allocator, cur, &m.before.schema);
            if (bridge.hasMigrationRequired()) {
                defer bridge.deinit();
                diag.add("Migration {s} starts from a schema this database cannot reach automatically:", .{m.id});
                try describeDiff(arena, diag, &bridge, .migration_required);
                diag.add("Its before.json does not match this database. Regenerate the migration with: zyncbase migrate new <name>", .{});
                return error.MigrationBaseMismatch;
            }
            try plan.add(.{
                .label = try std.fmt.allocPrint(arena, "schema {s} -> {s} (start of {s})", .{ cur.version, m.before.schema.version, m.id }),
                .to = &m.before.schema,
                .to_json = m.before.json,
                .to_hash = m.before.hash,
                .diff = bridge,
            });
        }

        const migration_diff = try schema_diff.diff(allocator, &m.before.schema, &m.after.schema);
        if (migration_diff.hasMigrationRequired()) any_migration_required = true;
        try plan.add(.{
            .label = try std.fmt.allocPrint(arena, "migration {s}", .{m.id}),
            .to = &m.after.schema,
            .to_json = m.after.json,
            .to_hash = m.after.hash,
            .migration = m,
            .diff = migration_diff,
        });
        cur = &m.after.schema;
        cur_hash = &m.after.hash;
    }

    const needs_final = !std.mem.eql(u8, cur_hash, &target.hash);
    try checkStepVersion(cur, target.schema, diag);
    if (needs_final or (plan.steps.items.len == 0 and plan.repair.len > 0)) {
        var final = try schema_diff.diff(allocator, cur, target.schema);
        if (final.hasMigrationRequired()) {
            defer final.deinit();
            diag.add("schema.json needs a migration.", .{});
            diag.add("  applied {s} ({s}), target {s} ({s})", .{ cur.version, cur_hash, target.schema.version, &target.hash });
            try describeDiff(arena, diag, &final, .migration_required);
            diag.add("Create one with: zyncbase migrate new <name>", .{});
            return error.MigrationRequired;
        }
        try plan.add(.{
            .label = try std.fmt.allocPrint(arena, "schema {s} -> {s}", .{ cur.version, target.schema.version }),
            .to = target.schema,
            .to_json = target.json,
            .to_hash = target.hash,
            .diff = final,
        });
    }

    if (any_migration_required and options.enforce_major_bump) {
        const from_version = try Version.parse(applied.version);
        const to_version = try Version.parse(target.schema.version);
        if (to_version.major <= from_version.major) {
            diag.add("Pending migrations drop or reinterpret data, so the schema's major version must go up.", .{});
            if (from_version.major == std.math.maxInt(u32)) {
                diag.add("  applied {s}, target {s}: the major version cannot be raised further.", .{ applied.version, target.schema.version });
            } else {
                diag.add("  applied {s}, target {s}: set \"version\" in schema.json to {d}.0.0 or later.", .{ applied.version, target.schema.version, from_version.major + 1 });
            }
            return error.MajorVersionBumpRequired;
        }
    }
}

/// Validates the ledger against the migrations directory and returns the
/// pending migrations in order.
fn checkHistory(
    arena: Allocator,
    ledger: []const state.LedgerEntry,
    migrations: []const source.Migration,
    diag: *Diagnostics,
) ![]const *const source.Migration {
    var modified = false;
    for (ledger) |entry| {
        if (entry.mode != .applied) continue;
        const m = findMigration(migrations, entry.id) orelse continue;
        if (!std.mem.eql(u8, entry.after_hash, &m.after.hash) or !std.mem.eql(u8, entry.sql_hash, &m.sql_hash)) {
            diag.add("Migration {s} was changed after it was applied to this database.", .{entry.id});
            modified = true;
        }
    }
    if (modified) {
        diag.add("Applied migrations must not change. Restore their files, or restore this database from its pre-migration snapshot.", .{});
        return error.AppliedMigrationModified;
    }

    const newest: ?[]const u8 = if (ledger.len > 0) ledger[ledger.len - 1].id else null;
    var pending = std.ArrayListUnmanaged(*const source.Migration).empty;
    var out_of_order = false;
    for (migrations) |*m| {
        if (inLedger(ledger, m.id)) continue;
        if (newest) |n| {
            if (std.mem.order(u8, m.id, n) == .lt) {
                diag.add("Migration {s} sorts before {s}, which is already applied.", .{ m.id, n });
                out_of_order = true;
                continue;
            }
        }
        try pending.append(arena, m);
    }
    if (out_of_order) {
        diag.add("History is linear. Recreate the migration on top of the current schema with: zyncbase migrate new <name>", .{});
        return error.MigrationOutOfOrder;
    }
    return pending.toOwnedSlice(arena);
}

fn findMigration(migrations: []const source.Migration, id: []const u8) ?*const source.Migration {
    for (migrations) |*m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

fn inLedger(ledger: []const state.LedgerEntry, id: []const u8) bool {
    for (ledger) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return true;
    }
    return false;
}

fn checkStepVersion(from: *const Schema, to: *const Schema, diag: *Diagnostics) !void {
    const a = try Version.parse(from.version);
    const b = try Version.parse(to.version);
    if (b.order(a) == .lt) {
        diag.add("Schema version {s} is older than {s}; versions never go down.", .{ to.version, from.version });
        return error.SchemaVersionDowngrade;
    }
}

fn checkDrift(
    arena: Allocator,
    allocator: Allocator,
    db: *sqlite.Db,
    applied: *const Schema,
    repair: *std.ArrayListUnmanaged([]const u8),
    diag: *Diagnostics,
) !void {
    var details = Diagnostics.init(allocator);
    defer details.deinit();

    var structural = false;
    for (applied.tables) |*table| {
        const before = details.items().len;
        const drift = try catalog.checkTable(arena, db, table, &details);
        if (drift.isStructural()) {
            structural = true;
        } else if (drift.indexes) {
            // Index drift is repaired; its details are informational only.
            for (details.items()[before..]) |line| std.log.info("Repairing managed index drift:{s}", .{line});
            try repair.append(arena, table.name);
        }
    }
    if (!structural) return;

    diag.add("The database schema differs from its recorded snapshot (was it changed outside ZyncBase?):", .{});
    for (details.items()) |line| diag.add("{s}", .{line});
    return error.SchemaDriftDetected;
}

/// Developer fill for a migration step: helpers, authorizer, `migration.sql`.
const DeveloperRun = struct {
    io: std.Io,
    allocator: Allocator,
    migration: *const source.Migration,

    fn run(context: *anyopaque, arena: Allocator, db: *sqlite.Db, staged: *const step.Staged, diag: *Diagnostics) anyerror![]const []const u8 {
        const self: *DeveloperRun = @ptrCast(@alignCast(context));

        const tables = try std.mem.concat(arena, []const u8, &.{ staged.writable_tables, staged.prev_tables });
        const floor = functions.nowFloor(self.io, db, arena, tables) catch |err| switch (err) {
            error.TimestampRangeExhausted => null,
            else => return err,
        };
        var helper_context = functions.Context{
            .io = self.io,
            .allocator = self.allocator,
            .next_now = floor orelse 0,
            .exhausted = floor == null,
        };
        try functions.register(db, &helper_context);
        defer functions.unregister(db);

        return sql_runner.execute(arena, db, .{ .label = self.migration.id, .sql = self.migration.sql }, .{
            .writable = staged.writable_tables,
            .prev = staged.prev_tables,
        }, diag);
    }
};

fn runTransaction(
    arena: Allocator,
    io: std.Io,
    allocator: Allocator,
    db: *sqlite.Db,
    plan: *const Plan,
    options: Options,
    report: *Report,
    diag: *Diagnostics,
) !void {
    const foreign_keys_were_on = (try db.pragma(i64, .{}, "foreign_keys", null) orelse 0) != 0;
    const legacy_alter_was_on = (try db.pragma(i64, .{}, "legacy_alter_table", null) orelse 0) != 0;

    // Both pragmas must change outside a transaction; restore them on every path.
    _ = try db.pragma(void, .{}, "foreign_keys", "off");
    defer if (foreign_keys_were_on) {
        _ = db.pragma(void, .{}, "foreign_keys", "on") catch |err| {
            std.log.err("Failed to restore foreign-key enforcement after migration: {}", .{err});
        };
    };
    _ = try db.pragma(void, .{}, "legacy_alter_table", "on");
    defer if (!legacy_alter_was_on) {
        _ = db.pragma(void, .{}, "legacy_alter_table", "off") catch |err| {
            std.log.err("Failed to restore legacy_alter_table after migration: {}", .{err});
        };
    };

    try db.exec("BEGIN IMMEDIATE", .{}, .{});
    var open = true;
    defer if (open) {
        db.exec("ROLLBACK", .{}, .{}) catch |err| std.log.err("ROLLBACK failed: {}", .{err});
    };

    try state.ensureSystemTables(db);
    const StepLog = struct { label: []const u8, result: step.StepReport };
    var logs = std.ArrayListUnmanaged(StepLog).empty;
    for (plan.steps.items, 0..) |*planned, i| {
        var developer: ?DeveloperRun = if (planned.migration) |m| .{ .io = io, .allocator = allocator, .migration = m } else null;
        const fill: step.Fill = if (developer) |*d|
            .{ .developer = .{ .context = d, .run = DeveloperRun.run } }
        else
            .generated;

        const result = try step.execute(arena, io, db, .{
            .label = planned.label,
            .diff = &planned.diff,
            .target = planned.to,
            .target_json = planned.to_json,
            .target_hash = planned.to_hash,
            .fill = fill,
            .repair_indexes = if (i == 0) plan.repair else &.{},
        }, diag);

        if (planned.migration) |m| {
            try state.insertLedger(io, db, .{
                .id = m.id,
                .mode = .applied,
                .before_version = m.before.schema.version,
                .after_version = m.after.schema.version,
                .after_hash = &m.after.hash,
                .sql_hash = &m.sql_hash,
            });
            report.migrations_applied += 1;
        }
        report.steps += 1;
        if (result.rebuilt) report.rebuilt = true;
        try logs.append(arena, .{ .label = planned.label, .result = result });
    }
    for (plan.baseline) |*m| {
        try state.insertLedger(io, db, .{
            .id = m.id,
            .mode = .baseline,
            .before_version = m.before.schema.version,
            .after_version = m.after.schema.version,
            .after_hash = &m.after.hash,
            .sql_hash = &m.sql_hash,
        });
        report.migrations_baselined += 1;
    }

    if (options.verify_foreign_keys) {
        connection.verifyForeignKeys(db) catch |err| {
            if (err == error.ForeignKeyViolation) {
                diag.add("Foreign key violations remain after the migration run (details logged above).", .{});
            }
            return err;
        };
    }

    if (options.dry_run) {
        try db.exec("ROLLBACK", .{}, .{});
        open = false;
        for (logs.items) |entry| logStep(entry.label, entry.result, true);
        std.log.info("Dry run: rolled back {d} step(s).", .{report.steps});
        return;
    }
    try db.exec("COMMIT", .{}, .{});
    open = false;
    for (logs.items) |entry| logStep(entry.label, entry.result, false);

    if (report.rebuilt) {
        // Rebuilds rewrite whole tables; shrink the WAL while readers are idle.
        const Checkpoint = struct { busy: i64, log: i64, checkpointed: i64 };
        _ = db.one(Checkpoint, "PRAGMA wal_checkpoint(TRUNCATE)", .{}, .{}) catch |err| {
            std.log.warn("WAL checkpoint after migration failed: {}", .{err});
        };
    }
}

fn logStep(label: []const u8, result: step.StepReport, dry_run: bool) void {
    std.log.info("{s} {s}", .{ if (dry_run) "Dry run:" else "Applied", label });
    for (result.tables) |t| {
        switch (t.action) {
            .unchanged => {},
            .create => std.log.info("  {s}: created", .{t.name}),
            .alter => std.log.info("  {s}: columns added", .{t.name}),
            .rebuild => std.log.info("  {s}: rebuilt, rows {d} -> {d} ({d} dropped)", .{ t.name, t.rows_before, t.rows_after, t.rows_dropped }),
            .remove => std.log.info("  {s}: removed, {d} rows dropped", .{ t.name, t.rows_dropped }),
        }
    }
}

fn describePlan(arena: Allocator, out: *Diagnostics, plan: *const Plan) !void {
    if (plan.steps.items.len == 0) {
        out.add("Up to date: the next start changes nothing.", .{});
        return;
    }
    for (plan.steps.items, 1..) |*planned, i| {
        const kind = if (planned.migration != null) "migration" else "automatic";
        out.add("{d}. {s} ({s}, {s})", .{ i, planned.label, kind, planned.diff.bucket().label() });
        if (planned.diff.isEmpty()) {
            out.add("     no table changes", .{});
        } else {
            try describeDiff(arena, out, &planned.diff, .auto);
        }
    }
    if (plan.baseline.len > 0) {
        out.add("{d} existing migration(s) will be recorded as baseline.", .{plan.baseline.len});
    }
    if (plan.repair.len > 0) {
        out.add("Managed indexes will be repaired on: {d} table(s).", .{plan.repair.len});
    }
}

/// Lists the changes of `d` whose bucket is at least `min`.
pub fn describeDiff(arena: Allocator, diag: *Diagnostics, d: *const SchemaDiff, min: schema_diff.Bucket) !void {
    for (d.tables) |*t| {
        for (t.table_changes) |change| {
            if (@intFromEnum(change.bucket()) < @intFromEnum(min)) continue;
            diag.add("  {s}  {s}  ({s})", .{ t.name, change.label(), change.bucket().label() });
        }
        for (t.field_changes) |change| {
            if (@intFromEnum(change.kind.bucket()) < @intFromEnum(min)) continue;
            const dotted = try field_path.toDotted(arena, change.name);
            diag.add("  {s}.{s}  {s}  ({s})", .{ t.name, dotted, change.kind.label(), change.kind.bucket().label() });
        }
    }
}
