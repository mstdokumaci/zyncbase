const std = @import("std");

const sqlite = @import("sqlite");

const connection = @import("connection.zig");

test "foreign key connection enforcement and integrity check" {
    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    try connection.configureDatabase(&db, false);
    try std.testing.expectEqual(@as(?i64, 1), try db.pragma(i64, .{}, "foreign_keys", null));
    try db.exec("CREATE TABLE parents (id INTEGER PRIMARY KEY)", .{}, .{});
    try db.exec("CREATE TABLE children (parent_id INTEGER REFERENCES parents(id))", .{}, .{});

    _ = try db.pragma(void, .{}, "foreign_keys", "off");
    try db.exec("INSERT INTO children(parent_id) VALUES (1)", .{}, .{});
    _ = try db.pragma(void, .{}, "foreign_keys", "on");
    try std.testing.expectError(error.ForeignKeyViolation, connection.verifyForeignKeys(&db));

    try db.exec("DELETE FROM children", .{}, .{});
    try connection.verifyForeignKeys(&db);
}
