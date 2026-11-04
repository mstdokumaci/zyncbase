const std = @import("std");

/// Runtime logging configuration.
/// Defaults to .info and text output until the server applies the loaded config.
var config: struct {
    level: std.log.Level = .info,
    json: bool = false,
} = .{};

/// Initialize runtime logging settings from loaded config.
pub fn init(level: std.log.Level, json: bool) void {
    config.level = level;
    config.json = json;
}

/// Custom log function matching std.Options.logFn signature.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Runtime level filtering
    if (@intFromEnum(level) > @intFromEnum(config.level)) return;

    if (config.json) {
        writeJsonLog(level, scope, format, args) catch |err| {
            std.log.defaultLog(.warn, .default, "Failed to format JSON log: {}", .{err});
            std.log.defaultLog(level, scope, format, args);
        };
    } else {
        std.log.defaultLog(level, scope, format, args);
    }
}

fn writeJsonLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) !void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    try formatJsonLog(stderr.writer, level, scope, format, args);
}

/// Write one JSON log line. Split from writeJsonLog so tests can target a buffer.
fn formatJsonLog(
    w: *std.Io.Writer,
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) !void {
    // Format message into temporary stack buffer
    var msg_buf: [2048]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, format, args);

    try w.writeAll("{\"level\":\"");
    try w.writeAll(levelName(level));
    try w.writeByte('"');

    if (scope != .default) {
        try w.writeAll(",\"scope\":\"");
        try w.print("{t}", .{scope});
        try w.writeByte('"');
    }

    try w.writeAll(",\"msg\":\"");
    for (msg) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                // JSON strings cannot contain raw control characters.
                if (ch < 0x20) {
                    try w.writeAll("\\u00");
                    try w.print("{x:0>2}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeAll("\"}\n");
}

/// Use the same level names as the `logging.level` config values.
fn levelName(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

test "log configuration init" {
    init(.debug, true);
    try std.testing.expectEqual(std.log.Level.debug, config.level);
    try std.testing.expect(config.json);
    init(.info, false);
    try std.testing.expectEqual(std.log.Level.info, config.level);
    try std.testing.expect(!config.json);
}

test "json log line escapes special characters" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatJsonLog(&w, .warn, .default, "a\"b\\c\nd\x01", .{});
    try std.testing.expectEqualStrings(
        "{\"level\":\"warn\",\"msg\":\"a\\\"b\\\\c\\nd\\u0001\"}\n",
        w.buffered(),
    );
}

test "json log line includes scope" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatJsonLog(&w, .info, .http, "ok", .{});
    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"scope\":\"http\",\"msg\":\"ok\"}\n",
        w.buffered(),
    );
}
