const std = @import("std");

const server_mod = @import("server.zig");

const testing = std.testing;
const ZyncBaseServer = server_mod.ZyncBaseServer;

// A SIGTERM that lands before the server instance is published must not kill the
// process: the handler parks it in `pending_signal` so activateSignalHandling()
// can replay it once startup finishes.
test "signals: SIGTERM before activation is parked instead of fatal" {
    ZyncBaseServer.installSignalHandlers();
    server_mod.pending_signal.store(false, .release);
    server_mod.signal_seen.store(false, .release);
    defer {
        server_mod.pending_signal.store(false, .release);
        server_mod.signal_seen.store(false, .release);
    }

    try std.posix.raise(std.posix.SIG.TERM);

    // Reaching this line already proves the handler replaced the default action.
    try testing.expect(server_mod.pending_signal.load(.acquire));
    try testing.expect(server_mod.signal_seen.load(.acquire));
}
