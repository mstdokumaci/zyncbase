const std = @import("std");

const sqlite = @import("sqlite");

const backup = @import("backup.zig");

fn openDb(allocator: std.mem.Allocator, path: []const u8) !sqlite.Db {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{ .write = true, .create = true },
    });
}

test "backup: snapshot while live, verify, and restore" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const data_dir = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_dir);

    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ root, "snapshot.db" });
    defer allocator.free(snapshot_path);

    var snapshot: backup.CreateInfo = undefined;
    {
        var live = try openDb(allocator, db_path);
        defer live.deinit();

        try live.exec("CREATE TABLE _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)", .{}, .{});
        try live.exec("CREATE TABLE tasks (id INTEGER PRIMARY KEY, name TEXT)", .{}, .{});
        try live.exec("INSERT INTO tasks (id, name) VALUES (1, 'before')", .{}, .{});

        snapshot = try backup.create(std.testing.io, allocator, db_path, snapshot_path);
        try std.testing.expect(snapshot.bytes > 0);

        try backup.verify(std.testing.io, allocator, snapshot_path, true);

        try live.exec("INSERT INTO tasks (id, name) VALUES (2, 'after')", .{}, .{});
    }

    var restored = try backup.restore(std.testing.io, allocator, data_dir, snapshot_path, true);
    defer restored.deinit(allocator);
    try std.testing.expect(restored.safety_copy != null);

    var db = try openDb(allocator, db_path);
    defer db.deinit();

    const before = try db.oneAlloc([]const u8, allocator, "SELECT name FROM tasks WHERE id = 1", .{}, .{});
    defer if (before) |name| allocator.free(name);
    try std.testing.expectEqualStrings("before", before.?);

    const after = try db.oneAlloc([]const u8, allocator, "SELECT name FROM tasks WHERE id = 2", .{}, .{});
    defer if (after) |name| allocator.free(name);
    try std.testing.expect(after == null);
}
