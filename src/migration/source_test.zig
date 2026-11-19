const std = @import("std");

const source = @import("source.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const allocator = std.testing.allocator;

const schema_v1 =
    \\{"version":"1.0.0","store":{"t":{"fields":{"a":{"type":"string"}}}}}
;
const schema_v2 =
    \\{
    \\    "version": "2.0.0",
    \\    "store": { "t": { "fields": {} } }
    \\}
;

const Dir = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init() !Dir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "migrations" });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Dir) void {
        allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn write(self: *Dir, relative: []const u8, data: []const u8) !void {
        const full = try std.fs.path.join(allocator, &.{ self.path, relative });
        defer allocator.free(full);
        if (std.fs.path.dirname(full)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = full, .data = data });
    }

    fn migration(self: *Dir, id: []const u8, before: []const u8, after: []const u8, sql: []const u8) !void {
        const files = [_]struct { name: []const u8, data: []const u8 }{
            .{ .name = source.before_file, .data = before },
            .{ .name = source.after_file, .data = after },
            .{ .name = source.sql_file, .data = sql },
        };
        for (files) |file| {
            const rel = try std.fs.path.join(allocator, &.{ id, file.name });
            defer allocator.free(rel);
            try self.write(rel, file.data);
        }
    }
};

test "source: a missing directory means no migrations" {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var set = try source.load(std.testing.io, allocator, ".zig-cache/tmp/does-not-exist/migrations", &diag);
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 0), set.items.len);
}

test "source: loads, sorts, minifies, and hashes migrations" {
    var dir = try Dir.init();
    defer dir.deinit();
    try dir.migration("20261118T000000Z_second", schema_v2, schema_v2, "UPDATE t SET id = id;");
    try dir.migration("20261117T000000Z_first", schema_v1, schema_v2, "-- drop a\n");
    try dir.write("README.md", "notes");
    try dir.write(".DS_Store", "x");
    try dir.write("20261117T000000Z_first/.DS_Store", "x");

    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var set = try source.load(std.testing.io, allocator, dir.path, &diag);
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 2), set.items.len);
    try std.testing.expectEqualStrings("20261117T000000Z_first", set.items[0].id);
    try std.testing.expectEqualStrings("20261118T000000Z_second", set.items[1].id);
    try std.testing.expectEqualStrings("{\"version\":\"2.0.0\",\"store\":{\"t\":{\"fields\":{}}}}", set.items[0].after.json);
    // Pretty and compact forms of the same schema hash the same.
    try std.testing.expectEqualSlices(u8, &set.items[0].after.hash, &set.items[1].before.hash);
    try std.testing.expectEqualStrings("-- drop a\n", set.items[0].sql);
    try std.testing.expect(set.find("20261118T000000Z_second") != null);
}

test "source: invalid folders and contents are rejected with every problem listed" {
    var dir = try Dir.init();
    defer dir.deinit();
    try dir.migration("20261117T000000Z_ok", schema_v1, schema_v2, "");
    try dir.write("2026-11-17_bad/migration.sql", "");
    try dir.write("20261117T000001Z_Upper/migration.sql", "");
    try dir.migration("20261117T000002Z_extra", schema_v1, schema_v2, "");
    try dir.write("20261117T000002Z_extra/notes.txt", "x");
    try dir.write("20261117T000003Z_missing/before.json", schema_v1);
    try dir.migration("20261117T000004Z_badjson", "{\"version\":\"1.0.0\"}", schema_v2, "");
    try dir.migration("20261117T000005Z_downgrade", schema_v2, schema_v1, "");

    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    try std.testing.expectError(error.InvalidMigration, source.load(std.testing.io, allocator, dir.path, &diag));

    const expected = [_][]const u8{ "2026-11-17_bad", "_Upper", "notes.txt", "_missing", "_badjson", "_downgrade" };
    for (expected) |needle| {
        var found = false;
        for (diag.items()) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) found = true;
        }
        if (!found) {
            for (diag.items()) |line| std.debug.print("{s}\n", .{line});
            std.debug.print("missing diagnostic for {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
}

test "source: migration ids" {
    try std.testing.expect(source.isValidId("20261117T140500Z_priority_to_string"));
    try std.testing.expect(source.isValidId("20261117T140500Z_a"));
    try std.testing.expect(!source.isValidId("20261117T140500Z_"));
    try std.testing.expect(!source.isValidId("20261117T140500Z-name"));
    try std.testing.expect(!source.isValidId("20261117140500Z_name"));
    try std.testing.expect(!source.isValidId("20261117T140500Z_Name"));
    try std.testing.expect(!source.isValidId("20261117T140500Z_na-me"));
    try std.testing.expect(source.isValidName("x" ** 64));
    try std.testing.expect(!source.isValidName("x" ** 65));
}
