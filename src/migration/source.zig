//! Loads and validates the migrations directory
//! (specs/implementation/schema-migrations.md#migration-directory).

const std = @import("std");

const canonical = @import("../schema/canonical.zig");
const schema_parse = @import("../schema/parse.zig");
const schema_types = @import("../schema/types.zig");
const Version = @import("../schema/version.zig").Version;
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const Schema = schema_types.Schema;

pub const before_file = "before.json";
pub const after_file = "after.json";
pub const sql_file = "migration.sql";

const max_file_bytes = 16 * 1024 * 1024;

/// One schema snapshot of a migration folder.
pub const Snapshot = struct {
    schema: Schema,
    /// Minified JSON, stored as `_zync_schema.schema` when this state is reached.
    json: []u8,
    hash: canonical.Hash,

    fn deinit(self: *Snapshot, allocator: Allocator) void {
        self.schema.deinit();
        allocator.free(self.json);
    }
};

pub const Migration = struct {
    /// Folder name, e.g. `20261117T140500Z_priority_to_string`.
    id: []u8,
    before: Snapshot,
    after: Snapshot,
    sql: []u8,
    sql_hash: canonical.Hash,

    fn deinit(self: *Migration, allocator: Allocator) void {
        allocator.free(self.id);
        self.before.deinit(allocator);
        self.after.deinit(allocator);
        allocator.free(self.sql);
    }
};

pub const MigrationSet = struct {
    allocator: Allocator,
    items: []Migration = &.{},

    pub fn empty(allocator: Allocator) MigrationSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MigrationSet) void {
        for (self.items) |*m| m.deinit(self.allocator);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = &.{};
    }

    pub fn find(self: *const MigrationSet, id: []const u8) ?*const Migration {
        for (self.items) |*m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }
};

/// `YYYYMMDDTHHMMSSZ_name`, name `[a-z0-9_]{1,64}`.
pub fn isValidId(id: []const u8) bool {
    const stamp_len = "20261117T140500Z".len;
    if (id.len < stamp_len + 2 or id.len > stamp_len + 1 + 64) return false;
    for (id[0..stamp_len], 0..) |ch, i| {
        const ok = switch (i) {
            8 => ch == 'T',
            15 => ch == 'Z',
            else => std.ascii.isDigit(ch),
        };
        if (!ok) return false;
    }
    if (id[stamp_len] != '_') return false;
    return isValidName(id[stamp_len + 1 ..]);
}

/// Migration names: `[a-z0-9_]{1,64}`.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| {
        if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    }
    return true;
}

/// Loads every migration folder under `dir_path`, sorted by id. A missing
/// directory means no migrations.
pub fn load(io: std.Io, allocator: Allocator, dir_path: []const u8, diag: *Diagnostics) !MigrationSet {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return MigrationSet.empty(allocator),
        else => {
            diag.add("Cannot open migrations directory {s}: {s}", .{ dir_path, @errorName(err) });
            return err;
        },
    };
    defer dir.close(io);

    var items = std.ArrayListUnmanaged(Migration).empty;
    errdefer {
        for (items.items) |*m| m.deinit(allocator);
        items.deinit(allocator);
    }

    var invalid = false;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (entry.kind != .directory) continue;
        if (!isValidId(entry.name)) {
            diag.add("{s}/{s}: migration folders must be named YYYYMMDDTHHMMSSZ_<name> with a lowercase [a-z0-9_] name", .{ dir_path, entry.name });
            invalid = true;
            continue;
        }
        var migration = loadOne(io, allocator, dir, dir_path, entry.name, diag) catch |err| switch (err) {
            error.InvalidMigration => {
                invalid = true;
                continue;
            },
            else => return err,
        };
        items.append(allocator, migration) catch |err| {
            migration.deinit(allocator);
            return err;
        };
    }
    if (invalid) return error.InvalidMigration;

    std.mem.sort(Migration, items.items, {}, struct {
        fn lessThan(_: void, a: Migration, b: Migration) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

fn loadOne(io: std.Io, allocator: Allocator, parent: std.Io.Dir, dir_path: []const u8, id: []const u8, diag: *Diagnostics) !Migration {
    var folder = try parent.openDir(io, id, .{ .iterate = true });
    defer folder.close(io);

    var bad_entry = false;
    var iter = folder.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const known = std.mem.eql(u8, entry.name, before_file) or
            std.mem.eql(u8, entry.name, after_file) or
            std.mem.eql(u8, entry.name, sql_file);
        if (!known or entry.kind != .file) {
            diag.add("{s}/{s}/{s}: unexpected entry; a migration folder holds only {s}, {s}, and {s}", .{ dir_path, id, entry.name, before_file, after_file, sql_file });
            bad_entry = true;
        }
    }
    if (bad_entry) return error.InvalidMigration;

    var before = try loadSnapshot(io, allocator, folder, dir_path, id, before_file, diag);
    errdefer before.deinit(allocator);
    var after = try loadSnapshot(io, allocator, folder, dir_path, id, after_file, diag);
    errdefer after.deinit(allocator);

    const sql = folder.readFileAlloc(io, sql_file, allocator, .limited(max_file_bytes)) catch |err| {
        diag.add("{s}/{s}/{s}: {s}", .{ dir_path, id, sql_file, @errorName(err) });
        return if (err == error.FileNotFound) error.InvalidMigration else err;
    };
    errdefer allocator.free(sql);

    const before_version = try Version.parse(before.schema.version);
    const after_version = try Version.parse(after.schema.version);
    if (after_version.order(before_version) == .lt) {
        diag.add("{s}/{s}: after.json version {s} is older than before.json version {s}", .{ dir_path, id, after.schema.version, before.schema.version });
        return error.InvalidMigration;
    }

    return .{
        .id = try allocator.dupe(u8, id),
        .before = before,
        .after = after,
        .sql = sql,
        .sql_hash = canonical.hashBytes(sql),
    };
}

fn loadSnapshot(io: std.Io, allocator: Allocator, folder: std.Io.Dir, dir_path: []const u8, id: []const u8, file: []const u8, diag: *Diagnostics) !Snapshot {
    const text = folder.readFileAlloc(io, file, allocator, .limited(max_file_bytes)) catch |err| {
        diag.add("{s}/{s}/{s}: {s}", .{ dir_path, id, file, @errorName(err) });
        return if (err == error.FileNotFound) error.InvalidMigration else err;
    };
    defer allocator.free(text);

    var schema = schema_parse.initFromJson(allocator, text) catch |err| {
        diag.add("{s}/{s}/{s}: not a valid schema: {s}", .{ dir_path, id, file, @errorName(err) });
        return error.InvalidMigration;
    };
    errdefer schema.deinit();
    const identity = try canonical.Identity.init(allocator, text);
    return .{ .schema = schema, .json = identity.json, .hash = identity.hash };
}
