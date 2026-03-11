const std = @import("std");
const testing = std.testing;
const UWebSocketsWrapper = @import("uwebsockets_wrapper.zig").UWebSocketsWrapper;

test "UWebSocketsWrapper: init with valid config" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8080,
        .compression = false,
        .max_payload_length = 1024 * 1024,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    try testing.expectEqual(@as(u16, 8080), wrapper.config.port);
    try testing.expectEqual(false, wrapper.config.compression);
    try testing.expectEqual(@as(usize, 1024 * 1024), wrapper.config.max_payload_length);
}

test "UWebSocketsWrapper: init with invalid port" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 0, // Invalid port
        .compression = false,
        .max_payload_length = 1024 * 1024,
    };

    const result = UWebSocketsWrapper.init(allocator, config);
    try testing.expectError(error.InvalidConfig, result);
}

test "UWebSocketsWrapper: init with SSL cert but no key" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8443,
        .ssl_cert_path = "test_cert.pem",
        .ssl_key_path = null, // Missing key
        .compression = false,
        .max_payload_length = 1024 * 1024,
    };

    const result = UWebSocketsWrapper.init(allocator, config);
    try testing.expectError(error.InvalidConfig, result);
}

test "UWebSocketsWrapper: init with SSL key but no cert" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8443,
        .ssl_cert_path = null, // Missing cert
        .ssl_key_path = "test_key.pem",
        .compression = false,
        .max_payload_length = 1024 * 1024,
    };

    const result = UWebSocketsWrapper.init(allocator, config);
    try testing.expectError(error.InvalidConfig, result);
}

test "UWebSocketsWrapper: init with non-existent SSL cert" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8443,
        .ssl_cert_path = "non_existent_cert.pem",
        .ssl_key_path = "non_existent_key.pem",
        .compression = false,
        .max_payload_length = 1024 * 1024,
    };

    const result = UWebSocketsWrapper.init(allocator, config);
    try testing.expectError(error.SSLCertNotFound, result);
}

test "UWebSocketsWrapper: getStatus returns correct values" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8080,
        .compression = true,
        .max_payload_length = 5 * 1024 * 1024,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    const status = wrapper.getStatus();
    try testing.expectEqual(@as(u16, 8080), status.port);
    try testing.expectEqual(false, status.ssl_enabled);
}

test "UWebSocketsWrapper: compression configuration" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8080,
        .compression = true,
        .max_payload_length = 1024 * 1024,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    try testing.expectEqual(true, wrapper.config.compression);
}

test "UWebSocketsWrapper: max payload length configuration" {
    const allocator = testing.allocator;

    const max_payload = 10 * 1024 * 1024; // 10MB
    const config = UWebSocketsWrapper.Config{
        .port = 8080,
        .compression = false,
        .max_payload_length = max_payload,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    try testing.expectEqual(max_payload, wrapper.config.max_payload_length);
}

test "UWebSocketsWrapper: default max payload length" {
    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8080,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    // Default should be 10MB
    try testing.expectEqual(@as(usize, 10 * 1024 * 1024), wrapper.config.max_payload_length);
}

// Integration test for SSL configuration (requires test certificates)
// This test is skipped by default and should be run manually with test certificates
test "UWebSocketsWrapper: SSL configuration with test certificates" {
    if (true) return error.SkipZigTest; // Skip by default

    const allocator = testing.allocator;

    // Create temporary test certificates
    const cert_path = "test_cert.pem";
    const key_path = "test_key.pem";

    // Note: In a real test, you would generate or copy test certificates here
    // For now, this test is skipped

    const config = UWebSocketsWrapper.Config{
        .port = 8443,
        .ssl_cert_path = cert_path,
        .ssl_key_path = key_path,
        .compression = false,
        .max_payload_length = 1024 * 1024,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    const status = wrapper.getStatus();
    try testing.expectEqual(true, status.ssl_enabled);
}

// Integration test for listen() - requires C++ bindings
test "UWebSocketsWrapper: listen on configured port" {
    if (true) return error.SkipZigTest; // Skip until C++ bindings implemented

    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8080,
        .compression = false,
        .max_payload_length = 1024 * 1024,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    // This will work once C++ bindings are implemented
    try wrapper.listen();
}

// Integration test for full lifecycle - requires C++ bindings
test "UWebSocketsWrapper: full server lifecycle" {
    if (true) return error.SkipZigTest; // Skip until C++ bindings implemented

    const allocator = testing.allocator;

    const config = UWebSocketsWrapper.Config{
        .port = 8080,
        .compression = true,
        .max_payload_length = 1024 * 1024,
    };

    const wrapper = try UWebSocketsWrapper.init(allocator, config);
    defer wrapper.deinit();

    // Start listening
    try wrapper.listen();

    // In a real test, we would:
    // 1. Start the server in a separate thread
    // 2. Connect a WebSocket client
    // 3. Send/receive messages
    // 4. Verify compression works
    // 5. Verify payload limits enforced
    // 6. Shutdown gracefully

    wrapper.shutdown();
}
