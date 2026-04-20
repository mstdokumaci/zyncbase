pub const std_options = struct {
    pub const log_level = .debug;
};

test {
    // Import all test files to ensure they are picked up by the build system
    _ = @import("uwebsockets_wrapper_test.zig");
    _ = @import("hook_server_client_test.zig");
    _ = @import("storage_engine_test.zig");
    _ = @import("storage_engine_types_test.zig");
    _ = @import("violation_tracker_test.zig");
    _ = @import("lock_free_cache_test.zig");
    _ = @import("lock_free_cache_leak_test.zig");
    _ = @import("memory_strategy_test.zig");
    _ = @import("checkpoint_manager_test.zig");
    _ = @import("config_loader_test.zig");
    _ = @import("connection_manager_test.zig");
    _ = @import("message_handler_test.zig");
    _ = @import("store_service_test.zig");
    _ = @import("schema_parser_test.zig");
    _ = @import("ddl_generator_test.zig");
    _ = @import("migration_executor_test.zig");
    _ = @import("msgpack_utils_test.zig");
    _ = @import("query_parser_test.zig");
    _ = @import("storage_query_test.zig");
    _ = @import("change_buffer_test.zig");
    _ = @import("protocol_test.zig");
    _ = @import("notification_dispatcher_test.zig");
    _ = @import("sync_consistency_test.zig");

    // Property tests
    _ = @import("message_handler_property_test.zig");
    _ = @import("hook_server_client_property_test.zig");
    _ = @import("config_loader_property_test.zig");
    _ = @import("checkpoint_manager_property_test.zig");
    _ = @import("message_buffer_property_test.zig");
    _ = @import("storage_engine_stability_property_test.zig");
    _ = @import("connection_state_property_test.zig");
    _ = @import("storage_engine_property_test.zig");
    _ = @import("server_init_property_test.zig");
    _ = @import("uwebsockets_wrapper_property_test.zig");
    _ = @import("storage_engine_error_property_test.zig");
    _ = @import("logging_property_test.zig");
    _ = @import("memory_safety_property_test.zig");
    _ = @import("msgpack_utils_property_test.zig");
    _ = @import("schema_parser_property_test.zig");
    _ = @import("ddl_generator_property_test.zig");
    _ = @import("migration_detector_property_test.zig");
    _ = @import("migration_executor_property_test.zig");
    _ = @import("query_parser_property_test.zig");
    _ = @import("storage_engine_query_property_test.zig");
    _ = @import("subscription_engine_test.zig");
    _ = @import("subscription_engine_perf_test.zig");
    _ = @import("contains_array_equivalence_test.zig");

    // Thread-safety tests
    _ = @import("subscription_engine_thread_safety_test.zig");

    // Integration tests
    _ = @import("integration_wiring_test.zig");
    _ = @import("message_handler_verification_test.zig");
}
