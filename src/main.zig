const std = @import("std");

const ZyncBaseServer = @import("server.zig").ZyncBaseServer;
const ThreadBudget = @import("thread_budget.zig").ThreadBudget;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const logo_color = "\x1b[95m";
const logo_reset = "\x1b[0m";
const logo =
    \\███████╗██╗   ██╗███╗   ██╗ ██████╗██████╗  █████╗ ███████╗███████╗
    \\╚══███╔╝╚██╗ ██╔╝████╗  ██║██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝
    \\  ███╔╝  ╚████╔╝ ██╔██╗ ██║██║     ██████╔╝███████║███████╗█████╗  
    \\ ███╔╝    ╚██╔╝  ██║╚██╗██║██║     ██╔══██╗██╔══██║╚════██║██╔══╝  
    \\███████╗   ██║   ██║ ╚████║╚██████╗██████╔╝██║  ██║███████║███████╗
    \\╚══════╝   ╚═╝   ╚═╝  ╚═══╝ ╚═════╝╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝
    \\
;

pub fn main(init: std.process.Init) !void {
    // prod allocator: SmpAllocator for all server flows (see memory/strategy.zig)
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    const cpu_count = std.Thread.getCpuCount() catch {
        std.log.err("Failed to detect CPU count", .{});
        return error.CpuCountDetectionFailed;
    };

    _ = ThreadBudget.init(cpu_count) catch {
        std.log.err("ZyncBase requires at least 4 CPU cores, found {}", .{cpu_count});
        return error.InsufficientCpuCores;
    };

    var config_path: ?[]const u8 = null;

    // Basic CLI argument parsing
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            if (args.next()) |path| {
                config_path = path;
            } else {
                std.log.err("--config requires a path argument", .{});
                return error.InvalidArguments;
            }
        }
    }

    try std.Io.File.writeStreamingAll(.stdout(), io, logo_color ++ logo ++ logo_reset);
    std.log.info("Initializing ZyncBase server...", .{});

    // Initialize server
    const server = try ZyncBaseServer.init(io, init.minimal.environ, allocator, config_path);
    defer server.deinit();

    // Start server (blocks until shutdown)
    try server.start();

    std.log.info("Server shutdown complete", .{});
}
