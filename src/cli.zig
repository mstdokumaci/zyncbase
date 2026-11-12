const std = @import("std");

const backup = @import("backup.zig");
const ConfigLoader = @import("config/loader.zig").ConfigLoader;
const Config = @import("config/state.zig").Config;

const Allocator = std.mem.Allocator;

const Parsed = struct {
    config_path: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    no_safety_copy: bool = false,
    path: []const u8,
};

pub fn isCommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "backup") or
        std.mem.eql(u8, arg, "restore") or
        std.mem.eql(u8, arg, "verify") or
        std.mem.eql(u8, arg, "help") or
        std.mem.eql(u8, arg, "--help");
}

pub fn run(
    io: std.Io,
    environ: std.process.Environ,
    allocator: Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) return error.MissingCommand;

    const command = args[0];
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        printUsage();
        return;
    }

    const rest = args[1..];
    if (std.mem.eql(u8, command, "backup")) {
        const parsed = try parseArgs(rest, false);
        return runBackup(io, environ, allocator, parsed);
    }
    if (std.mem.eql(u8, command, "restore")) {
        const parsed = try parseArgs(rest, true);
        return runRestore(io, environ, allocator, parsed);
    }
    if (std.mem.eql(u8, command, "verify")) {
        const parsed = try parseArgs(rest, false);
        if (parsed.config_path != null or parsed.data_dir != null) return error.UnknownOption;
        try backup.verify(io, allocator, parsed.path, true);
        std.log.info("verify: {s}: ok", .{parsed.path});
        return;
    }

    return error.UnknownCommand;
}

fn runBackup(
    io: std.Io,
    environ: std.process.Environ,
    allocator: Allocator,
    parsed: Parsed,
) !void {
    var config: ?Config = null;
    defer if (config) |*value| value.deinit();

    const data_dir = try resolveDataDir(io, environ, allocator, &config, parsed.config_path, parsed.data_dir);
    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    const info = try backup.create(io, allocator, db_path, parsed.path);
    std.log.info(
        "backup: {s} (from {s}, {d} bytes, {d} ms)",
        .{ parsed.path, db_path, info.bytes, info.duration_ms },
    );
}

fn runRestore(
    io: std.Io,
    environ: std.process.Environ,
    allocator: Allocator,
    parsed: Parsed,
) !void {
    var config: ?Config = null;
    defer if (config) |*value| value.deinit();

    const data_dir = try resolveDataDir(io, environ, allocator, &config, parsed.config_path, parsed.data_dir);
    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    var info = try backup.restore(io, allocator, data_dir, parsed.path, !parsed.no_safety_copy);
    defer info.deinit(allocator);

    std.log.info("restore: {s} -> {s}", .{ parsed.path, db_path });
    if (info.safety_copy) |path| {
        std.log.info("previous database kept at {s}", .{path});
    }
}

fn resolveDataDir(
    io: std.Io,
    environ: std.process.Environ,
    allocator: Allocator,
    config_out: *?Config,
    config_path: ?[]const u8,
    data_dir: ?[]const u8,
) ![]const u8 {
    if (data_dir) |dir| return dir;

    var env_map = try environ.createMap(allocator);
    defer env_map.deinit();

    config_out.* = try ConfigLoader.load(
        io,
        &env_map,
        allocator,
        config_path orelse "zyncbase-config.json",
    );
    return config_out.*.?.data_dir;
}

fn parseArgs(args: []const []const u8, allow_restore_flags: bool) !Parsed {
    var config_path: ?[]const u8 = null;
    var data_dir: ?[]const u8 = null;
    var no_safety_copy = false;
    var path: ?[]const u8 = null;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= args.len) return error.MissingConfigPath;
            config_path = args[index];
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingDataDir;
            data_dir = args[index];
        } else if (allow_restore_flags and std.mem.eql(u8, arg, "--no-safety-copy")) {
            no_safety_copy = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (path == null) {
            path = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }

    return .{
        .config_path = config_path,
        .data_dir = data_dir,
        .no_safety_copy = no_safety_copy,
        .path = path orelse return error.MissingPath,
    };
}

fn printUsage() void {
    std.log.info("{s}", .{
        \\Usage:
        \\  zyncbase [--config <path>]                 Start the server
        \\  zyncbase backup <out.db> [--config <path>] [--data-dir <dir>]
        \\  zyncbase restore <in.db> [--config <path>] [--data-dir <dir>] [--no-safety-copy]
        \\  zyncbase verify <in.db>
        \\
    });
}
