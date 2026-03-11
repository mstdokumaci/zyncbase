const std = @import("std");

pub const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
pub const UWebSocketsWrapper = @import("uwebsockets_wrapper.zig").UWebSocketsWrapper;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("lock_free_cache_test.zig");
    _ = @import("uwebsockets_wrapper_test.zig");
    _ = @import("messagepack_parser_test.zig");
    _ = @import("hook_server_client_test.zig");
    _ = @import("hook_server_client_property_test.zig");
    _ = @import("checkpoint_manager_test.zig");
    _ = @import("checkpoint_manager_property_test.zig");
    _ = @import("subscription_manager_test.zig");
    _ = @import("subscription_manager_property_test.zig");
    _ = @import("subscription_manager_perf_test.zig");
}

pub fn main() !void {
    std.debug.print("ZyncBase - Lock-Free Cache Implementation\n", .{});
}
