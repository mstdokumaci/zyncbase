const std = @import("std");

const json_write = @import("../json/write.zig");

const Allocator = std.mem.Allocator;

/// Runtime logging configuration.
/// Defaults to .info and JSON output until the server applies the loaded config.
var config: struct {
    level: std.log.Level = .info,
    json: bool = true,
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
            // The sink failed or the line could not be built. There is no other
            // output channel, and text output would break the JSON format.
            writeJsonFailure(level, err) catch return;
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
    const allocator = std.heap.smp_allocator;

    // Build the line before writing so a failure leaves no partial JSON behind.
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);
    try line.ensureTotalCapacity(allocator, 256);
    try appendJsonLine(allocator, &line, level, scope, format, args);

    try writeStderr(line.items);
}

/// Format one JSON log line (with trailing newline) into `line`.
pub fn appendJsonLine(
    allocator: Allocator,
    line: *std.ArrayListUnmanaged(u8),
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) !void {
    var msg_buf: [2048]u8 = undefined;
    if (std.fmt.bufPrint(&msg_buf, format, args)) |msg| {
        try appendJsonObject(allocator, line, level, scope, msg);
    } else |err| switch (err) {
        // Long messages allocate instead of truncating or switching to text.
        error.NoSpaceLeft => {
            const msg = try std.fmt.allocPrint(allocator, format, args);
            defer allocator.free(msg);
            try appendJsonObject(allocator, line, level, scope, msg);
        },
    }
}

fn appendJsonObject(
    allocator: Allocator,
    line: *std.ArrayListUnmanaged(u8),
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    msg: []const u8,
) !void {
    var json: json_write.Writer = .{ .buf = line, .allocator = allocator };
    try json.beginObject();
    try json.field("level", levelName(level));
    if (scope != .default) {
        try json.field("scope", std.fmt.comptimePrint("{t}", .{scope}));
    }
    try json.field("msg", msg);
    try json.endObject();
    try line.append(allocator, '\n');
}

/// Emit a valid JSON record when building the requested message failed.
fn writeJsonFailure(comptime level: std.log.Level, err: anyerror) !void {
    var line_buf: [128]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buf);
    // Error names are ASCII identifiers, so they need no escaping.
    try line.print("{{\"level\":\"{s}\",\"msg\":\"log formatting failed: {s}\"}}\n", .{
        levelName(level),
        @errorName(err),
    });
    try writeStderr(line.buffered());
}

fn writeStderr(data: []const u8) !void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    try stderr.writer.writeAll(data);
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
