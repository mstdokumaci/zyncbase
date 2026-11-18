//! `zyncbase migrate status|new|check|apply` and `zyncbase reset`
//! (specs/implementation/schema-migrations.md#cli-contract).
//!
//! Reports are written to `Context.out`. A command returns an error when it
//! fails, and `status`/`check` also return one when the next start would
//! fail, so `main` exits non-zero.

const std = @import("std");

const sqlite = @import("sqlite");

const backup = @import("../backup.zig");
const canonical = @import("../schema/canonical.zig");
const schema_diff = @import("../schema/diff.zig");
const schema_parse = @import("../schema/parse.zig");
const connection = @import("../storage_engine/connection.zig");
const storage_sql = @import("../storage_engine/sql.zig");
const scaffold = @import("scaffold.zig");
const source = @import("source.zig");
const startup = @import("startup.zig");
const state = @import("state.zig");
const migration_target = @import("target.zig");
const Config = @import("../config/state.zig").Config;
const DataLock = @import("../data_lock.zig").DataLock;
const Version = @import("../schema/version.zig").Version;
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const SchemaDiff = schema_diff.SchemaDiff;

pub const Subcommand = enum { status, new, check, apply, reset };

pub const Command = struct {
    sub: Subcommand,
    config_path: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    db: ?[]const u8 = null,
    name: ?[]const u8 = null,
    from: ?[]const u8 = null,
    amend: bool = false,
    dry_run: bool = false,
    yes: bool = false,
    no_safety_copy: bool = false,
};

/// Parses the arguments after `migrate`, e.g. `status --db copy.db`.
pub fn parseMigrate(args: []const []const u8) !Command {
    if (args.len == 0) return error.MissingCommand;
    const sub = std.meta.stringToEnum(Subcommand, args[0]) orelse return error.UnknownCommand;
    if (sub == .reset) return error.UnknownCommand;
    return parseFlags(sub, args[1..]);
}

/// Parses the arguments after `reset`.
pub fn parseReset(args: []const []const u8) !Command {
    return parseFlags(.reset, args);
}

fn parseFlags(sub: Subcommand, args: []const []const u8) !Command {
    var cmd = Command{ .sub = sub };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--config")) {
            cmd.config_path = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--data-dir") and sub != .check) {
            cmd.data_dir = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--db") and (sub == .status or sub == .apply)) {
            cmd.db = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--from") and sub == .new) {
            cmd.from = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--amend") and sub == .new) {
            cmd.amend = true;
        } else if (std.mem.eql(u8, arg, "--dry-run") and sub == .apply) {
            cmd.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") and sub == .reset) {
            cmd.yes = true;
        } else if (std.mem.eql(u8, arg, "--no-safety-copy") and sub == .reset) {
            cmd.no_safety_copy = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (sub == .new and cmd.name == null) {
            cmd.name = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }
    if (sub == .new) {
        const name = cmd.name orelse return error.MissingMigrationName;
        if (!source.isValidName(name)) return error.InvalidMigrationName;
        if (cmd.amend and cmd.from != null) return error.AmendWithFrom;
    }
    return cmd;
}

fn flagValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingOptionValue;
    return args[index.*];
}

pub const Context = struct {
    io: std.Io,
    allocator: Allocator,
    config: *const Config,
    out: *Writer,
};

pub fn execute(ctx: Context, cmd: Command) !void {
    return switch (cmd.sub) {
        .status => status(ctx, cmd),
        .new => if (cmd.amend) amend(ctx, cmd) else new(ctx, cmd),
        .check => check(ctx),
        .apply => apply(ctx, cmd),
        .reset => reset(ctx, cmd),
    };
}

// ─── Shared helpers ──────────────────────────────────────────────────────────

/// The target schema and the migrations directory.
const Project = struct {
    target: migration_target.Loaded,
    migrations_dir: []u8,
    migrations: source.MigrationSet,

    fn load(ctx: Context) !Project {
        var target = try migration_target.load(ctx.io, ctx.allocator, ctx.config);
        errdefer target.deinit(ctx.allocator);
        const migrations_dir = try ctx.config.migrationsDir(ctx.allocator);
        errdefer ctx.allocator.free(migrations_dir);

        var diag = Diagnostics.init(ctx.allocator);
        defer diag.deinit();
        const migrations = source.load(ctx.io, ctx.allocator, migrations_dir, &diag) catch |err| {
            try ctx.out.print("Cannot load the migrations in {s} ({s}):\n", .{ migrations_dir, @errorName(err) });
            try printLines(ctx.out, &diag, "  ");
            return err;
        };
        return .{ .target = target, .migrations_dir = migrations_dir, .migrations = migrations };
    }

    fn deinit(self: *Project, allocator: Allocator) void {
        self.migrations.deinit();
        allocator.free(self.migrations_dir);
        self.target.deinit(allocator);
    }

    fn startupTarget(self: *const Project) startup.Target {
        return .{ .schema = &self.target.schema, .json = self.target.identity.json, .hash = self.target.identity.hash };
    }

    fn newest(self: *const Project) ?*const source.Migration {
        const items = self.migrations.items;
        return if (items.len > 0) &items[items.len - 1] else null;
    }
};

fn printLines(out: *Writer, diag: *const Diagnostics, indent: []const u8) !void {
    for (diag.items()) |line| try out.print("{s}{s}\n", .{ indent, line });
}

fn dirOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn dataDir(ctx: Context, cmd: Command) []const u8 {
    return cmd.data_dir orelse ctx.config.data_dir;
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn openFile(allocator: Allocator, path: []const u8, write: bool) !sqlite.Db {
    // zwanzig-disable-next-line: sentinel-alloc
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return sqlite.Db.init(.{ .mode = .{ .File = path_z }, .open_flags = .{ .write = write, .create = write } });
}

/// An empty database as `StorageEngine.init` leaves it.
fn openMemory() !sqlite.Db {
    var db = try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
    errdefer db.deinit();
    try connection.configureDatabase(&db, false, .normal);
    try storage_sql.ensureNamespaceTable(&db);
    return db;
}

/// What a database file records, read under a shared lock.
const DbState = struct {
    exists: bool = false,
    applied: ?state.Applied = null,
    ledger: []const state.LedgerEntry = &.{},

    fn ledgerIndex(self: DbState, id: []const u8) ?usize {
        return findLedger(self.ledger, id);
    }

    /// The newest ledger entry is `id`, applied (not baseline).
    fn newestApplied(self: DbState, id: []const u8) bool {
        if (self.ledger.len == 0) return false;
        const entry = self.ledger[self.ledger.len - 1];
        return entry.mode == .applied and std.mem.eql(u8, entry.id, id);
    }
};

fn findLedger(ledger: []const state.LedgerEntry, id: []const u8) ?usize {
    for (ledger, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, id)) return i;
    }
    return null;
}

fn readDbState(ctx: Context, arena: Allocator, db_path: []const u8) !DbState {
    if (!try fileExists(ctx.io, db_path)) return .{};
    var lock = try DataLock.acquireShared(ctx.io, ctx.allocator, dirOf(db_path));
    defer lock.release(ctx.io);
    var db = try openFile(ctx.allocator, db_path, false);
    defer db.deinit();
    if (!try state.hasSchemaTable(&db)) return .{ .exists = true };
    return .{
        .exists = true,
        .applied = try state.readApplied(arena, &db),
        .ledger = try state.readLedger(arena, &db),
    };
}

fn describeDiff(ctx: Context, arena: Allocator, d: *const SchemaDiff) !void {
    if (d.isEmpty()) {
        try ctx.out.print("  none: this is a data-only migration\n", .{});
        return;
    }
    var lines = Diagnostics.init(ctx.allocator);
    defer lines.deinit();
    try startup.describeDiff(arena, &lines, d, .auto);
    try printLines(ctx.out, &lines, "");
}

// ─── migrate status ──────────────────────────────────────────────────────────

fn status(ctx: Context, cmd: Command) !void {
    const out = ctx.out;
    var project = try Project.load(ctx);
    defer project.deinit(ctx.allocator);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const db_path = cmd.db orelse try backup.dbPath(arena, dataDir(ctx, cmd));
    const exists = try fileExists(ctx.io, db_path);
    var lock: ?DataLock = if (exists) try DataLock.acquireShared(ctx.io, ctx.allocator, dirOf(db_path)) else null;
    defer if (lock) |*held| held.release(ctx.io);
    var db = if (exists) try openFile(ctx.allocator, db_path, false) else try openMemory();
    defer db.deinit();

    try out.print("Database:   {s}{s}\n", .{ db_path, if (exists) "" else " (not created yet)" });
    const has_schema = try state.hasSchemaTable(&db);
    const applied = if (has_schema) try state.readApplied(arena, &db) else null;
    if (applied) |a| {
        try out.print("Applied:    {s}  {s}\n", .{ a.version, a.hash });
    } else {
        try out.print("Applied:    none\n", .{});
    }
    const target = &project.target;
    const schema_source = if (ctx.config.schema_content != null) "inline schema" else ctx.config.schema_file;
    try out.print("Target:     {s}  {s}  ({s})\n", .{ target.schema.version, &target.identity.hash, schema_source });

    try out.print("Migrations: {s}\n", .{project.migrations_dir});
    const ledger = if (has_schema) try state.readLedger(arena, &db) else &.{};
    for (ledger) |entry| {
        const note = if (project.migrations.find(entry.id) == null) " (folder removed)" else "";
        try out.print("  {s}  {s}{s}\n", .{ entry.id, @tagName(entry.mode), note });
    }
    for (project.migrations.items) |*m| {
        if (findLedger(ledger, m.id) == null) try out.print("  {s}  pending\n", .{m.id});
    }
    if (ledger.len == 0 and project.migrations.items.len == 0) try out.print("  none\n", .{});

    var plan = Diagnostics.init(ctx.allocator);
    defer plan.deinit();
    var diag = Diagnostics.init(ctx.allocator);
    defer diag.deinit();
    var report = startup.run(ctx.io, ctx.allocator, &db, project.startupTarget(), .{
        .migrations = project.migrations.items,
        .plan_only = true,
        .plan_out = &plan,
    }, &diag) catch |err| {
        try out.print("\nThe next start fails ({s}):\n", .{@errorName(err)});
        try printLines(out, &diag, "  ");
        return err;
    };
    report.deinit(ctx.allocator);
    try out.print("\nNext start:\n", .{});
    try printLines(out, &plan, "  ");
}

// ─── migrate apply ───────────────────────────────────────────────────────────

fn apply(ctx: Context, cmd: Command) !void {
    const out = ctx.out;
    var project = try Project.load(ctx);
    defer project.deinit(ctx.allocator);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const db_path = cmd.db orelse try backup.dbPath(arena, dataDir(ctx, cmd));
    if (cmd.db != null and !try fileExists(ctx.io, db_path)) {
        try out.print("No database at {s}.\n", .{db_path});
        return error.DatabaseNotFound;
    }
    var lock = DataLock.acquire(ctx.io, ctx.allocator, dirOf(db_path)) catch |err| {
        if (err == error.DataDirLocked) {
            try out.print("{s} is in use by another zyncbase process. Stop the server first.\n", .{dirOf(db_path)});
        }
        return err;
    };
    defer lock.release(ctx.io);
    if (cmd.db == null) try backup.recoverInterruptedRestore(ctx.io, ctx.allocator, dataDir(ctx, cmd));

    var db = try openFile(ctx.allocator, db_path, true);
    defer db.deinit();
    try connection.configureDatabase(&db, true, ctx.config.storage.synchronous);
    try storage_sql.ensureNamespaceTable(&db);

    var diag = Diagnostics.init(ctx.allocator);
    defer diag.deinit();
    var report = startup.run(ctx.io, ctx.allocator, &db, project.startupTarget(), .{
        .migrations = project.migrations.items,
        .dry_run = cmd.dry_run,
        .snapshot_of = if (ctx.config.migrations.snapshot) db_path else null,
    }, &diag) catch |err| {
        try out.print("Cannot migrate {s} ({s}):\n", .{ db_path, @errorName(err) });
        try printLines(out, &diag, "  ");
        try out.print("Nothing was changed.\n", .{});
        return err;
    };
    defer report.deinit(ctx.allocator);

    if (report.steps == 0) {
        try out.print("{s} is up to date.\n", .{db_path});
        return;
    }
    if (report.snapshot_path) |path| try out.print("Pre-migration snapshot: {s}\n", .{path});
    if (cmd.dry_run) {
        try out.print("Dry run: {d} step(s) and {d} migration(s) ran against {s} and were rolled back.\n", .{ report.steps, report.migrations_applied, db_path });
    } else {
        try out.print("Applied {d} step(s) and {d} migration(s) to {s}; schema {s}.\n", .{ report.steps, report.migrations_applied, db_path, project.target.schema.version });
    }
    if (report.migrations_baselined > 0) {
        try out.print("Recorded {d} existing migration(s) as baseline.\n", .{report.migrations_baselined});
    }
}

// ─── migrate check ───────────────────────────────────────────────────────────

fn check(ctx: Context) !void {
    const out = ctx.out;
    var project = try Project.load(ctx);
    defer project.deinit(ctx.allocator);
    const items = project.migrations.items;
    if (items.len == 0) {
        try out.print("No migrations in {s}.\n", .{project.migrations_dir});
        return;
    }

    var failed: usize = 0;
    for (items) |*m| {
        var diag = Diagnostics.init(ctx.allocator);
        defer diag.deinit();
        if (checkOne(ctx, m, &diag)) {
            try out.print("ok    {s}\n", .{m.id});
        } else |err| {
            failed += 1;
            try out.print("FAIL  {s} ({s})\n", .{ m.id, @errorName(err) });
            try printLines(out, &diag, "      ");
        }
    }
    if (failed > 0) {
        try out.print("skip  chain to schema.json (fix the migrations above first)\n", .{});
        return error.MigrationCheckFailed;
    }

    var diag = Diagnostics.init(ctx.allocator);
    defer diag.deinit();
    checkChain(ctx, &project, &diag) catch |err| {
        try out.print("FAIL  chain to schema.json ({s})\n", .{@errorName(err)});
        try printLines(out, &diag, "      ");
        return error.MigrationCheckFailed;
    };
    try out.print("ok    chain {s} -> {s} (schema.json)\n", .{ items[0].before.schema.version, project.target.schema.version });
}

/// Runs one migration on an empty in-memory database built at its `before`.
/// The major-version rule is left to the chain check: it applies per deployment.
fn checkOne(ctx: Context, m: *const source.Migration, diag: *Diagnostics) !void {
    var db = try openMemory();
    defer db.deinit();
    var created = try startup.run(ctx.io, ctx.allocator, &db, .{ .schema = &m.before.schema, .json = m.before.json, .hash = m.before.hash }, .{}, diag);
    created.deinit(ctx.allocator);
    var report = try startup.run(ctx.io, ctx.allocator, &db, .{ .schema = &m.after.schema, .json = m.after.json, .hash = m.after.hash }, .{
        .migrations = m[0..1],
        .dry_run = true,
        .enforce_major_bump = false,
    }, diag);
    report.deinit(ctx.allocator);
}

/// Runs every migration from the first one's `before` to schema.json.
fn checkChain(ctx: Context, project: *const Project, diag: *Diagnostics) !void {
    const first = &project.migrations.items[0];
    var db = try openMemory();
    defer db.deinit();
    var created = try startup.run(ctx.io, ctx.allocator, &db, .{ .schema = &first.before.schema, .json = first.before.json, .hash = first.before.hash }, .{}, diag);
    created.deinit(ctx.allocator);
    var report = try startup.run(ctx.io, ctx.allocator, &db, project.startupTarget(), .{
        .migrations = project.migrations.items,
        .dry_run = true,
    }, diag);
    report.deinit(ctx.allocator);
}

// ─── migrate new ─────────────────────────────────────────────────────────────

const BaseKind = enum { database, pending_migration, file };

const Base = struct {
    /// Minified schema JSON.
    json: []const u8,
    kind: BaseKind,
    /// Where the base came from, for the report.
    label: []const u8,
    /// The database the version rule is checked against.
    db: DbState,
};

fn new(ctx: Context, cmd: Command) !void {
    const name = cmd.name orelse return error.MissingMigrationName;
    var project = try Project.load(ctx);
    defer project.deinit(ctx.allocator);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = try selectBase(ctx, arena, cmd, &project);
    var base_schema = try schema_parse.initFromJson(ctx.allocator, base.json);
    defer base_schema.deinit();
    const base_hash = canonical.hashMinified(base.json);
    if (base.kind == .pending_migration and std.mem.eql(u8, &base_hash, &project.target.identity.hash)) {
        try ctx.out.print("Migration {s} already produces schema.json ({s}).\n", .{ base.label, base_schema.version });
        try ctx.out.print("Edit its migration.sql, or change schema.json first.\n", .{});
        return error.NothingToMigrate;
    }

    var d = try schema_diff.diff(ctx.allocator, &base_schema, &project.target.schema);
    defer d.deinit();
    try checkVersions(ctx, &project, base_schema.version, base.db, &d, .{
        .count_pending = base.kind == .pending_migration,
        .offer_amend = true,
    });

    var stamp_buf: [backup.utc_timestamp_len]u8 = undefined;
    const id = try std.fmt.allocPrint(arena, "{s}_{s}", .{ backup.utcTimestamp(ctx.io, &stamp_buf), name });
    if (project.newest()) |last| {
        if (std.mem.order(u8, id, last.id) != .gt) {
            try ctx.out.print("The new id {s} would not sort after {s}. Check the clock, or wait a second and retry.\n", .{ id, last.id });
            return error.MigrationOutOfOrder;
        }
    }

    const sql = try scaffold.generate(arena, .{
        .id = id,
        .before = &base_schema,
        .before_hash = &base_hash,
        .after = &project.target.schema,
        .after_hash = &project.target.identity.hash,
        .diff = &d,
    });
    const folder = try writeFolder(ctx, arena, project.migrations_dir, null, id, .{
        .before = try canonical.pretty(arena, base.json),
        .after = try canonical.pretty(arena, project.target.identity.json),
        .sql = sql,
    });

    try ctx.out.print("Created {s}\n", .{folder});
    try ctx.out.print("  from {s}  {s}  ({s} {s})\n", .{ base_schema.version, &base_hash, @tagName(base.kind), base.label });
    try ctx.out.print("  to   {s}  {s}\n", .{ project.target.schema.version, &project.target.identity.hash });
    try reportScaffold(ctx, arena, &d, sql);
}

fn selectBase(ctx: Context, arena: Allocator, cmd: Command, project: *const Project) !Base {
    if (cmd.from) |from| {
        if (std.mem.endsWith(u8, from, ".json")) {
            const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, from, arena, .limited(migration_target.max_schema_bytes));
            return .{ .json = try canonical.minify(arena, text), .kind = .file, .label = from, .db = .{} };
        }
        const db = try readDbState(ctx, arena, from);
        if (!db.exists) {
            try ctx.out.print("{s} does not exist.\n", .{from});
            return error.DatabaseNotFound;
        }
        const applied = db.applied orelse {
            try ctx.out.print("{s} has no ZyncBase schema record.\n", .{from});
            return error.UnrecognizedDatabase;
        };
        return .{ .json = applied.json, .kind = .database, .label = from, .db = db };
    }

    const db_path = try backup.dbPath(arena, dataDir(ctx, cmd));
    const db = try readDbState(ctx, arena, db_path);
    if (project.newest()) |last| {
        if (db.ledgerIndex(last.id) == null) {
            return .{ .json = last.after.json, .kind = .pending_migration, .label = last.id, .db = db };
        }
    }
    if (db.applied) |applied| return .{ .json = applied.json, .kind = .database, .label = db_path, .db = db };

    try ctx.out.print("There is nothing to migrate from: {s} has no schema yet, and there are no migrations.\n", .{db_path});
    try ctx.out.print("The next start creates the database from schema.json directly.\n", .{});
    try ctx.out.print("To write a migration anyway, pass --from <schema.json|file.db>.\n", .{});
    return error.NoMigrationBase;
}

const VersionCheck = struct {
    /// Pending migrations ship in the same deployment as the new one.
    count_pending: bool,
    /// Skip this pending migration (the one being amended).
    exclude: ?[]const u8 = null,
    offer_amend: bool,
};

/// Versions never go down, and the deployment rule against `db`: a
/// migration-required change needs a higher major version than `db` is on.
fn checkVersions(
    ctx: Context,
    project: *const Project,
    base_version: []const u8,
    db: DbState,
    d: *const SchemaDiff,
    options: VersionCheck,
) !void {
    const target_text = project.target.schema.version;
    const target = try Version.parse(target_text);
    if (target.order(try Version.parse(base_version)) == .lt) {
        try ctx.out.print("schema.json version {s} is older than {s}; versions never go down.\n", .{ target_text, base_version });
        return error.SchemaVersionDowngrade;
    }
    // Without a database the rule is checked when one is migrated.
    const applied = db.applied orelse return;

    var required = d.hasMigrationRequired();
    if (options.count_pending) {
        for (project.migrations.items) |*m| {
            if (db.ledgerIndex(m.id) != null) continue;
            if (options.exclude) |skip| if (std.mem.eql(u8, skip, m.id)) continue;
            var pending = try schema_diff.diff(ctx.allocator, &m.before.schema, &m.after.schema);
            defer pending.deinit();
            if (pending.hasMigrationRequired()) required = true;
        }
    }
    if (!required) return;
    const from = try Version.parse(applied.version);
    if (target.major > from.major) return;

    try ctx.out.print("This deployment drops or reinterprets data, so the schema's major version must go up.\n", .{});
    try ctx.out.print("  The database is on {s} and schema.json is {s}: set \"version\" to {d}.0.0 or later.\n", .{ applied.version, target_text, from.major + 1 });
    if (options.offer_amend) {
        if (project.newest()) |last| {
            if (db.newestApplied(last.id)) {
                try ctx.out.print("  Or fold this change into {s} with: zyncbase migrate new <name> --amend\n", .{last.id});
            }
        }
    }
    return error.MajorVersionBumpRequired;
}

const Files = struct { before: []const u8, after: []const u8, sql: []const u8 };

/// Writes the folder under a dot-prefixed temporary name (ignored by the
/// loader), then renames it into place. With `replace`, that folder is
/// removed first. Returns the folder path.
fn writeFolder(ctx: Context, arena: Allocator, dir: []const u8, replace: ?[]const u8, id: []const u8, files: Files) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(ctx.io, dir);
    const final = try std.fs.path.join(arena, &.{ dir, id });
    const replacing_same = if (replace) |old| std.mem.eql(u8, old, id) else false;
    if (!replacing_same and try fileExists(ctx.io, final)) {
        try ctx.out.print("{s} already exists.\n", .{final});
        return error.PathAlreadyExists;
    }

    const partial = try std.fmt.allocPrint(arena, "{s}/.{s}.partial", .{ dir, id });
    try cwd.deleteTree(ctx.io, partial);
    try cwd.createDirPath(ctx.io, partial);
    errdefer cwd.deleteTree(ctx.io, partial) catch |err| {
        std.log.warn("could not remove {s}: {}", .{ partial, err });
    };
    const entries = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = source.before_file, .data = files.before },
        .{ .name = source.after_file, .data = files.after },
        .{ .name = source.sql_file, .data = files.sql },
    };
    for (entries) |entry| {
        const path = try std.fs.path.join(arena, &.{ partial, entry.name });
        try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = entry.data });
    }

    if (replace) |old| try cwd.deleteTree(ctx.io, try std.fs.path.join(arena, &.{ dir, old }));
    try cwd.rename(partial, cwd, final, ctx.io);
    return final;
}

fn reportScaffold(ctx: Context, arena: Allocator, d: *const SchemaDiff, sql: []const u8) !void {
    try ctx.out.print("Changes:\n", .{});
    try describeDiff(ctx, arena, d);
    const todos = std.mem.count(u8, sql, "zync_todo('");
    if (todos > 0) {
        try ctx.out.print("{d} decision(s) to make: edit migration.sql and replace every zync_todo(...).\n", .{todos});
    } else {
        try ctx.out.print("Review migration.sql; it runs as generated.\n", .{});
    }
    try ctx.out.print("Then run: zyncbase migrate check\n", .{});
}

// ─── migrate new --amend ─────────────────────────────────────────────────────

fn amend(ctx: Context, cmd: Command) !void {
    const out = ctx.out;
    const name = cmd.name orelse return error.MissingMigrationName;
    var project = try Project.load(ctx);
    defer project.deinit(ctx.allocator);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = project.migrations.items;
    const last = project.newest() orelse {
        try out.print("There is no migration to amend in {s}.\n", .{project.migrations_dir});
        return error.NothingToAmend;
    };
    const data_dir = dataDir(ctx, cmd);
    const db_path = try backup.dbPath(arena, data_dir);
    const db = try readDbState(ctx, arena, db_path);

    // An applied migration is undone by restoring its pre-migration snapshot.
    var snapshot: ?[]const u8 = null;
    var rule_db = db;
    if (db.ledgerIndex(last.id) != null) {
        if (!db.newestApplied(last.id)) {
            try out.print("{s} is not the newest migration applied to {s}; create a new migration instead.\n", .{ last.id, db_path });
            return error.CannotAmend;
        }
        const path = try findSnapshot(ctx, arena, db_path, last.id) orelse {
            try out.print("No pre-migration snapshot of {s} next to {s}; --amend needs it to undo the migration.\n", .{ last.id, db_path });
            try out.print("Create a new migration instead, or start over with: zyncbase reset --yes\n", .{});
            return error.SnapshotNotFound;
        };
        snapshot = path;
        rule_db = try readDbState(ctx, arena, path);
    }

    if (std.mem.eql(u8, &last.after.hash, &project.target.identity.hash)) {
        try out.print("{s} already produces schema.json; edit its migration.sql instead.\n", .{last.id});
        return error.NothingToMigrate;
    }
    var d = try schema_diff.diff(ctx.allocator, &last.before.schema, &project.target.schema);
    defer d.deinit();
    try checkVersions(ctx, &project, last.before.schema.version, rule_db, &d, .{
        .count_pending = true,
        .exclude = last.id,
        .offer_amend = false,
    });

    const id = try std.fmt.allocPrint(arena, "{s}_{s}", .{ last.id[0..backup.utc_timestamp_len], name });
    if (items.len > 1 and std.mem.order(u8, id, items[items.len - 2].id) != .gt) {
        try out.print("The amended id {s} would not sort after {s}; choose another name.\n", .{ id, items[items.len - 2].id });
        return error.MigrationOutOfOrder;
    }

    var sql = std.ArrayListUnmanaged(u8).empty;
    try sql.appendSlice(arena, try scaffold.generate(arena, .{
        .id = id,
        .before = &last.before.schema,
        .before_hash = &last.before.hash,
        .after = &project.target.schema,
        .after_hash = &project.target.identity.hash,
        .diff = &d,
    }));
    try sql.print(arena, "\n-- Previous migration.sql of {s}, kept by --amend for reference:\n", .{last.id});
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, last.sql, "\n"), '\n');
    while (lines.next()) |line| try sql.print(arena, "-- {s}\n", .{line});

    if (snapshot) |path| {
        var info = backup.restore(ctx.io, ctx.allocator, data_dir, path, true) catch |err| {
            if (err == error.DataDirLocked) try out.print("{s} is in use by another zyncbase process. Stop the server first.\n", .{data_dir});
            return err;
        };
        defer info.deinit(ctx.allocator);
        try out.print("Restored {s} from {s}\n", .{ db_path, path });
        if (info.safety_copy) |copy| try out.print("  previous database kept at {s}\n", .{copy});
    }

    const folder = try writeFolder(ctx, arena, project.migrations_dir, last.id, id, .{
        .before = try canonical.pretty(arena, last.before.json),
        .after = try canonical.pretty(arena, project.target.identity.json),
        .sql = sql.items,
    });
    try out.print("Amended {s}\n", .{folder});
    try out.print("  from {s}  {s}\n", .{ last.before.schema.version, &last.before.hash });
    try out.print("  to   {s}  {s}\n", .{ project.target.schema.version, &project.target.identity.hash });
    try reportScaffold(ctx, arena, &d, sql.items);
}

/// The newest `<db file>.pre-migration-<id>-<timestamp>` next to `db_path`.
fn findSnapshot(ctx: Context, arena: Allocator, db_path: []const u8, id: []const u8) !?[]const u8 {
    const dir_path = dirOf(db_path);
    const prefix = try std.fmt.allocPrint(arena, "{s}{s}{s}-", .{ std.fs.path.basename(db_path), backup.pre_migration_infix, id });
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(ctx.io);

    const Candidate = struct { name: []const u8, stamp: []const u8, suffix: u32 };
    var best: ?Candidate = null;
    var iter = dir.iterate();
    while (try iter.next(ctx.io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        const rest = entry.name[prefix.len..];
        if (rest.len < backup.utc_timestamp_len) continue;
        // `<timestamp>` or `<timestamp>-<n>` (see backup.snapshotHeld).
        const stamp = rest[0..backup.utc_timestamp_len];
        const tail = rest[backup.utc_timestamp_len..];
        const suffix: u32 = if (tail.len == 0) 0 else if (tail[0] == '-')
            std.fmt.parseInt(u32, tail[1..], 10) catch continue
        else
            continue;
        const newer = if (best) |current| switch (std.mem.order(u8, stamp, current.stamp)) {
            .gt => true,
            .lt => false,
            .eq => suffix > current.suffix,
        } else true;
        if (newer) {
            const name = try arena.dupe(u8, entry.name);
            best = .{ .name = name, .stamp = name[prefix.len..][0..backup.utc_timestamp_len], .suffix = suffix };
        }
    }
    const found = best orelse return null;
    return try std.fs.path.join(arena, &.{ dir_path, found.name });
}

// ─── reset ───────────────────────────────────────────────────────────────────

fn reset(ctx: Context, cmd: Command) !void {
    const out = ctx.out;
    const data_dir = dataDir(ctx, cmd);
    if (!cmd.yes) {
        try out.print("reset moves the database in {s} aside and the next start creates an empty one.\n", .{data_dir});
        try out.print("Run it again with --yes to confirm.\n", .{});
        return error.ConfirmationRequired;
    }
    const db_path = try backup.dbPath(ctx.allocator, data_dir);
    defer ctx.allocator.free(db_path);
    const existed = try fileExists(ctx.io, db_path);

    var info = backup.reset(ctx.io, ctx.allocator, data_dir, !cmd.no_safety_copy) catch |err| {
        if (err == error.DataDirLocked) try out.print("{s} is in use by another zyncbase process. Stop the server first.\n", .{data_dir});
        return err;
    };
    defer info.deinit(ctx.allocator);
    if (!existed) {
        try out.print("There is no database in {s}; nothing to reset.\n", .{data_dir});
    } else if (info.moved_to) |path| {
        try out.print("Moved {s} to {s}. The next start creates an empty database.\n", .{ db_path, path });
    } else {
        try out.print("Deleted {s}. The next start creates an empty database.\n", .{db_path});
    }
}
