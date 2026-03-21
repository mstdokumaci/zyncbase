const std = @import("std");
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config_path: ?[]const u8 = null;

    // Basic CLI argument parsing
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 < args.len) {
                config_path = args[i + 1];
                i += 1;
            } else {
                std.log.err("--config requires a path argument", .{});
                return error.InvalidArguments;
            }
        }
    }

    std.log.info("Initializing ZyncBase server...", .{});

    // Initialize server
    const server = try ZyncBaseServer.init(allocator, config_path);
    defer server.deinit();

    // Start server (blocks until shutdown)
    try server.start();

    std.log.info("Server shutdown complete", .{});
}
