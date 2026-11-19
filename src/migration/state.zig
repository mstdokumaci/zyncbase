//! Persistent migration state: the applied schema snapshot (`_zync_schema`)
//! and the migration ledger (`_zync_migrations`).

const std = @import("std");

const sqlite = @import("sqlite");

const canonical = @import("../schema/canonical.zig");
const catalog = @import("catalog.zig");

const Allocator = std.mem.Allocator;

/// Physical layout generation written by this binary.
pub const layout_version: i64 = 1;

pub const schema_table = "_zync_schema";
pub const migrations_table = "_zync_migrations";

const create_schema_table_sql =
    \\CREATE TABLE IF NOT EXISTS _zync_schema (
    \\  id INTEGER PRIMARY KEY CHECK (id = 1),
    \\  layout INTEGER NOT NULL,
    \\  version TEXT NOT NULL,
    \\  hash TEXT NOT NULL,
    \\  schema TEXT NOT NULL,
    \\  applied_at INTEGER NOT NULL
    \\) STRICT
;

const create_migrations_table_sql =
    \\CREATE TABLE IF NOT EXISTS _zync_migrations (
    \\  id TEXT PRIMARY KEY,
    \\  mode TEXT NOT NULL CHECK (mode IN ('applied', 'baseline')),
    \\  before_version TEXT NOT NULL,
    \\  after_version TEXT NOT NULL,
    \\  after_hash TEXT NOT NULL,
    \\  sql_hash TEXT NOT NULL,
    \\  batch_first TEXT NOT NULL DEFAULT '',
    \\  applied_at INTEGER NOT NULL
    \\) STRICT
;

/// Creates the system tables if needed. Runs inside the run transaction.
pub fn ensureSystemTables(db: *sqlite.Db) !void {
    try db.exec(create_schema_table_sql, .{}, .{});
    try db.exec(create_migrations_table_sql, .{}, .{});
}

pub fn hasSchemaTable(db: *sqlite.Db) !bool {
    return catalog.tableExists(db, schema_table);
}

pub const Applied = struct {
    layout: i64,
    version: []const u8,
    hash: []const u8,
    json: []const u8,
    applied_at: i64,

    pub fn deinit(self: Applied, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.hash);
        allocator.free(self.json);
    }
};

/// The applied snapshot, or null when the row is absent.
pub fn readApplied(allocator: Allocator, db: *sqlite.Db) !?Applied {
    const Row = struct {
        layout: i64,
        version: []const u8,
        hash: []const u8,
        schema: []const u8,
        applied_at: i64,
    };
    const row = (try db.oneAlloc(
        Row,
        allocator,
        "SELECT layout, version, hash, schema, applied_at FROM _zync_schema WHERE id = 1",
        .{},
        .{},
    )) orelse return null;
    return .{
        .layout = row.layout,
        .version = row.version,
        .hash = row.hash,
        .json = row.schema,
        .applied_at = row.applied_at,
    };
}

pub const LedgerMode = enum { applied, baseline };

pub const LedgerEntry = struct {
    id: []const u8,
    mode: LedgerMode,
    before_version: []const u8,
    after_version: []const u8,
    after_hash: []const u8,
    sql_hash: []const u8,
    /// First migration applied by the run that inserted this row; empty when unknown.
    batch_first: []const u8,
    applied_at: i64,
};

/// Every ledger row, ordered by id. Allocated in `arena`. Empty when the
/// table does not exist yet.
pub fn readLedger(arena: Allocator, db: *sqlite.Db) ![]const LedgerEntry {
    if (!try catalog.tableExists(db, migrations_table)) return &.{};
    const Row = struct {
        id: []const u8,
        mode: []const u8,
        before_version: []const u8,
        after_version: []const u8,
        after_hash: []const u8,
        sql_hash: []const u8,
        batch_first: []const u8,
        applied_at: i64,
    };
    var stmt = try db.prepare(
        "SELECT id, mode, before_version, after_version, after_hash, sql_hash, batch_first, applied_at FROM _zync_migrations ORDER BY id",
    );
    defer stmt.deinit();
    var entries = std.ArrayListUnmanaged(LedgerEntry).empty;
    var iter = try stmt.iteratorAlloc(Row, arena, .{});
    while (try iter.nextAlloc(arena, .{})) |row| {
        try entries.append(arena, .{
            .id = row.id,
            .mode = std.meta.stringToEnum(LedgerMode, row.mode) orelse return error.InvalidLedger,
            .before_version = row.before_version,
            .after_version = row.after_version,
            .after_hash = row.after_hash,
            .sql_hash = row.sql_hash,
            .batch_first = row.batch_first,
            .applied_at = row.applied_at,
        });
    }
    return entries.toOwnedSlice(arena);
}

pub const NewLedgerEntry = struct {
    id: []const u8,
    mode: LedgerMode,
    before_version: []const u8,
    after_version: []const u8,
    after_hash: []const u8,
    sql_hash: []const u8,
    batch_first: []const u8 = "",
};

pub fn insertLedger(io: std.Io, db: *sqlite.Db, entry: NewLedgerEntry) !void {
    const now = std.Io.Clock.real.now(io).toMicroseconds();
    try db.exec(
        \\INSERT INTO _zync_migrations
        \\  (id, mode, before_version, after_version, after_hash, sql_hash, batch_first, applied_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ,
        .{},
        .{
            entry.id,
            @as([]const u8, @tagName(entry.mode)),
            entry.before_version,
            entry.after_version,
            entry.after_hash,
            entry.sql_hash,
            entry.batch_first,
            now,
        },
    );
}

/// Records `json` (already minified) as the applied schema.
pub fn writeApplied(io: std.Io, db: *sqlite.Db, version: []const u8, json: []const u8, hash: canonical.Hash) !void {
    const now = std.Io.Clock.real.now(io).toMicroseconds();
    try db.exec(
        \\INSERT INTO _zync_schema (id, layout, version, hash, schema, applied_at)
        \\VALUES (1, ?, ?, ?, ?, ?)
        \\ON CONFLICT (id) DO UPDATE SET
        \\  layout = excluded.layout, version = excluded.version, hash = excluded.hash,
        \\  schema = excluded.schema, applied_at = excluded.applied_at
    ,
        .{},
        .{ layout_version, version, @as([]const u8, &hash), json, now },
    );
}
