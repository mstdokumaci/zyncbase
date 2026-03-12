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
    std.testing.refAllDecls(@import("uwebsockets_wrapper_test.zig"));
    std.testing.refAllDecls(@import("subscription_manager_test.zig"));
    std.testing.refAllDecls(@import("hook_server_client_test.zig"));
    std.testing.refAllDecls(@import("storage_engine_test.zig"));
    std.testing.refAllDecls(@import("violation_tracker_test.zig"));
    std.testing.refAllDecls(@import("lock_free_cache_test.zig"));
    std.testing.refAllDecls(@import("memory_strategy_test.zig"));
    std.testing.refAllDecls(@import("checkpoint_manager_test.zig"));
    std.testing.refAllDecls(@import("config_loader_test.zig"));
    std.testing.refAllDecls(@import("request_handler_test.zig"));
    std.testing.refAllDecls(@import("message_handler_test.zig"));
    std.testing.refAllDecls(@import("subscription_manager_perf_test.zig"));
    std.testing.refAllDecls(@import("storage_crud_test.zig"));
    
    // Property tests
    std.testing.refAllDecls(@import("message_handler_property_test.zig"));
    std.testing.refAllDecls(@import("hook_server_client_property_test.zig"));
    std.testing.refAllDecls(@import("config_loader_property_test.zig"));
    std.testing.refAllDecls(@import("checkpoint_manager_property_test.zig"));
    std.testing.refAllDecls(@import("subscription_manager_property_test.zig"));
    std.testing.refAllDecls(@import("message_buffer_property_test.zig"));
    std.testing.refAllDecls(@import("storage_engine_stability_property_test.zig"));
    std.testing.refAllDecls(@import("connection_state_property_test.zig"));
    std.testing.refAllDecls(@import("storage_engine_property_test.zig"));
    std.testing.refAllDecls(@import("server_init_property_test.zig"));
    std.testing.refAllDecls(@import("store_operations_property_test.zig"));
    std.testing.refAllDecls(@import("uwebsockets_wrapper_property_test.zig"));
    std.testing.refAllDecls(@import("storage_engine_error_property_test.zig"));
    std.testing.refAllDecls(@import("logging_property_test.zig"));
    std.testing.refAllDecls(@import("memory_safety_property_test.zig"));

    // Integration tests
    std.testing.refAllDecls(@import("integration_wiring_test.zig"));
    std.testing.refAllDecls(@import("message_handler_verification_test.zig"));
}
