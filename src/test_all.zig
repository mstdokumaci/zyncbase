const std = @import("std");

pub const std_options = struct {
    pub const log_level = .debug;
    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        _ = level;
        _ = scope;
        _ = format;
        _ = args;
    }
};

test {
    // Import all test files to ensure they are picked up by the build system
    _ = @import("uwebsockets_wrapper_test.zig");
    _ = @import("subscription_manager_test.zig");
    _ = @import("hook_server_client_test.zig");
    _ = @import("storage_engine_test.zig");
    _ = @import("messagepack_parser_test.zig");
    _ = @import("lock_free_cache_test.zig");
    _ = @import("memory_strategy_test.zig");
    _ = @import("checkpoint_manager_test.zig");
    _ = @import("config_loader_test.zig");
    _ = @import("request_handler_test.zig");
    _ = @import("message_handler_test.zig");
    _ = @import("subscription_manager_perf_test.zig");
    _ = @import("test_storage_crud.zig");
    
    // Property tests
    _ = @import("message_handler_property_test.zig");
    _ = @import("hook_server_client_property_test.zig");
    _ = @import("config_loader_property_test.zig");
    _ = @import("checkpoint_manager_property_test.zig");
    _ = @import("subscription_manager_property_test.zig");
    _ = @import("message_buffer_property_test.zig");
    _ = @import("storage_engine_stability_property_test.zig");
    _ = @import("connection_state_property_test.zig");
    _ = @import("storage_engine_property_test.zig");
    _ = @import("server_init_property_test.zig");
    _ = @import("store_operations_property_test.zig");
    _ = @import("uwebsockets_wrapper_property_test.zig");
    _ = @import("storage_engine_error_property_test.zig");
    _ = @import("logging_property_test.zig");
    _ = @import("memory_safety_property_test.zig");
    _ = @import("messagepack_parser_fuzz.zig");

    // Integration tests
    _ = @import("integration_wiring_test.zig");
    _ = @import("message_handler_verification_test.zig");
}
