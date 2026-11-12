const std = @import("std");

const cli = @import("cli.zig");
const observability_log = @import("observability/log.zig");
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;
const ThreadBudget = @import("thread_budget.zig").ThreadBudget;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = observability_log.logFn,
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
    // Install SIGTERM/SIGINT handlers before any initialization. Without this a
    // signal during config load or schema migration kills the process with the
    // default action and skips the final checkpoint.
    ZyncBaseServer.installSignalHandlers();

    // prod allocator: SmpAllocator for all server flows (see memory/strategy.zig)
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    const cpu_count = std.Thread.getCpuCount() catch {
        std.log.err("Failed to detect CPU count", .{});
        return error.CpuCountDetectionFailed;
    };

    _ = ThreadBudget.init(cpu_count) catch {
        std.log.err("ZyncBase requires at least 2 CPU cores, found {}", .{cpu_count});
        return error.InsufficientCpuCores;
    };

    var config_path: ?[]const u8 = null;

    // Basic CLI argument parsing
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();

    var arg_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer arg_list.deinit(allocator);
    while (args.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    if (arg_list.items.len > 0 and cli.isCommand(arg_list.items[0])) {
        cli.run(io, init.minimal.environ, allocator, arg_list.items) catch |err| {
            std.log.err("zyncbase {s}: {s}", .{ arg_list.items[0], @errorName(err) });
            std.process.exit(1);
        };
        return;
    }

    var index: usize = 0;
    while (index < arg_list.items.len) : (index += 1) {
        const arg = arg_list.items[index];
        if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= arg_list.items.len) {
                std.log.err("--config requires a path argument", .{});
                return error.InvalidArguments;
            }
            config_path = arg_list.items[index];
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
