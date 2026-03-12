const std = @import("std");
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Initializing ZyncBase server...", .{});

    // Initialize server
    const server = try ZyncBaseServer.init(allocator);
    defer server.deinit();

    // Start server (blocks until shutdown)
    try server.start();

    std.log.info("Server shutdown complete", .{});
}
