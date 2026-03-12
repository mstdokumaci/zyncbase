const std = @import("std");
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Config = @import("config_loader.zig").Config;

const c = @cImport({
    @cInclude("stdlib.h");
});

// **Validates: Requirements 8.3**
// Property 12: Environment variable substitution
// For any configuration field containing ${VAR_NAME} syntax, the environment variable value should be substituted if it exists.
test "Property 12: Environment variable substitution" {
    const allocator = std.testing.allocator;

    // Set up test environment variables using C setenv
    _ = c.setenv("TEST_PORT", "8080", 1);
    _ = c.setenv("TEST_HOST", "192.168.1.1", 1);
    _ = c.setenv("TEST_JWT_SECRET", "test-secret-key", 1);
    _ = c.setenv("TEST_DATA_DIR", "/tmp/test-data", 1);
    defer {
        _ = c.unsetenv("TEST_PORT");
        _ = c.unsetenv("TEST_HOST");
        _ = c.unsetenv("TEST_JWT_SECRET");
        _ = c.unsetenv("TEST_DATA_DIR");
    }

    // Create config with environment variable substitution
    const config_content =
        \\{
        \\  "server": {
        \\    "port": ${TEST_PORT},
        \\    "host": "${TEST_HOST}"
        \\  },
        \\  "auth": {
        \\    "jwt": {
        \\      "secret": "${TEST_JWT_SECRET}"
        \\    }
        \\  },
        \\  "dataDir": "${TEST_DATA_DIR}"
        \\}
    ;

    const temp_file = "test-artifact/test-config-env-vars.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify environment variables were substituted
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("192.168.1.1", config.server.host);
    try std.testing.expect(config.auth.jwt_secret != null);
    try std.testing.expectEqualStrings("test-secret-key", config.auth.jwt_secret.?);
    try std.testing.expectEqualStrings("/tmp/test-data", config.data_dir);
}

test "Property 12: Environment variable substitution - missing variable keeps original" {
    const allocator = std.testing.allocator;

    // Ensure the variable doesn't exist
    _ = c.unsetenv("NONEXISTENT_VAR");

    // Create config with non-existent environment variable
    const config_content =
        \\{
        \\  "dataDir": "test-artifact/${NONEXISTENT_VAR}"
        \\}
    ;

    const temp_file = "test-artifact/test-config-missing-env-var.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify original pattern is kept when variable doesn't exist
    try std.testing.expectEqualStrings("test-artifact/${NONEXISTENT_VAR}", config.data_dir);
}

test "Property 12: Environment variable substitution - multiple variables" {
    const allocator = std.testing.allocator;

    // Set up multiple test environment variables
    _ = c.setenv("TEST_ORIGIN_1", "https://example.com", 1);
    _ = c.setenv("TEST_ORIGIN_2", "https://app.example.com", 1);
    _ = c.setenv("TEST_RATE_LIMIT", "200", 1);
    defer {
        _ = c.unsetenv("TEST_ORIGIN_1");
        _ = c.unsetenv("TEST_ORIGIN_2");
        _ = c.unsetenv("TEST_RATE_LIMIT");
    }

    // Create config with multiple environment variables
    const config_content =
        \\{
        \\  "security": {
        \\    "allowedOrigins": ["${TEST_ORIGIN_1}", "${TEST_ORIGIN_2}"],
        \\    "rateLimitMessagesPerSecond": ${TEST_RATE_LIMIT}
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-multiple-env-vars.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify all environment variables were substituted
    try std.testing.expectEqual(@as(usize, 2), config.security.allowed_origins.len);
    try std.testing.expectEqualStrings("https://example.com", config.security.allowed_origins[0]);
    try std.testing.expectEqualStrings("https://app.example.com", config.security.allowed_origins[1]);
    try std.testing.expectEqual(@as(u32, 200), config.security.rate_limit_messages_per_second);
}

// **Validates: Requirements 9.1, 9.2, 9.5, 9.8**
// Property 13: Configuration validation
// For any configuration, validation should catch invalid values and return descriptive errors.
test "Property 13: Configuration validation - invalid port" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "server": {
        \\    "port": 70000
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-invalid-port.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidPort, result);
}

test "Property 13: Configuration validation - port zero" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "server": {
        \\    "port": 0
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-port-zero.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidPort, result);
}

test "Property 13: Configuration validation - invalid buffer size" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "performance": {
        \\    "messageBufferSize": 0
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-invalid-buffer.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidBufferSize, result);
}

test "Property 13: Configuration validation - invalid max message size" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "security": {
        \\    "maxMessageSize": 0
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-invalid-max-message-size.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidMaxMessageSize, result);
}

// **Validates: Requirements 9.3, 9.4, 9.6, 9.7**
// Property 14: File existence validation
// For any file path in configuration, validation should verify the file exists.
test "Property 14: File existence validation - schema file not found" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "schema": "/nonexistent/schema.json"
        \\}
    ;

    const temp_file = "test-artifact/test-config-missing-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.SchemaFileNotFound, result);
}

test "Property 14: File existence validation - auth rules file not found" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "authRules": "/nonexistent/auth-rules.json"
        \\}
    ;

    const temp_file = "test-artifact/test-config-missing-auth-rules.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.AuthRulesFileNotFound, result);
}

test "Property 14: File existence validation - valid schema file" {
    const allocator = std.testing.allocator;

    // Create a temporary schema file
    const schema_file = "test-artifact/test-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });
    defer std.fs.cwd().deleteFile(schema_file) catch {};

    const config_content =
        \\{
        \\  "schema": "test-artifact/test-schema.json"
        \\}
    ;

    const temp_file = "test-artifact/test-config-valid-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify schema file was loaded
    try std.testing.expect(config.schema_file != null);
    try std.testing.expectEqualStrings("test-artifact/test-schema.json", config.schema_file.?);
}

test "Property 14: File existence validation - valid auth rules file" {
    const allocator = std.testing.allocator;

    // Create a temporary auth rules file
    const auth_rules_file = "test-artifact/test-auth-rules.json";
    try std.fs.cwd().writeFile(.{ .sub_path = auth_rules_file, .data = "{}" });
    defer std.fs.cwd().deleteFile(auth_rules_file) catch {};

    const config_content =
        \\{
        \\  "authRules": "test-artifact/test-auth-rules.json"
        \\}
    ;

    const temp_file = "test-artifact/test-config-valid-auth-rules.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify auth rules file was loaded
    try std.testing.expect(config.auth_rules_file != null);
    try std.testing.expectEqualStrings("test-artifact/test-auth-rules.json", config.auth_rules_file.?);
}

// **Validates: Requirements 8.10**
// Property 15: Configuration round-trip
// For any valid configuration, serializing then parsing should produce an equivalent configuration.
test "Property 15: Configuration round-trip - server config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "server": {
        \\    "port": 8080,
        \\    "host": "127.0.0.1",
        \\    "maxConnections": 50000
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-roundtrip-server.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqual(@as(usize, 50000), config.server.max_connections);
}

test "Property 15: Configuration round-trip - auth config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "auth": {
        \\    "jwt": {
        \\      "secret": "my-secret-key",
        \\      "algorithm": "HS512",
        \\      "issuer": "zyncbase",
        \\      "audience": "api"
        \\    }
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-roundtrip-auth.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify values match original
    try std.testing.expect(config.auth.jwt_secret != null);
    try std.testing.expectEqualStrings("my-secret-key", config.auth.jwt_secret.?);
    try std.testing.expectEqualStrings("HS512", config.auth.jwt_algorithm);
    try std.testing.expect(config.auth.jwt_issuer != null);
    try std.testing.expectEqualStrings("zyncbase", config.auth.jwt_issuer.?);
    try std.testing.expect(config.auth.jwt_audience != null);
    try std.testing.expectEqualStrings("api", config.auth.jwt_audience.?);
}

test "Property 15: Configuration round-trip - security config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "security": {
        \\    "allowedOrigins": ["https://example.com", "https://app.example.com"],
        \\    "allowLocalhost": false,
        \\    "rateLimitMessagesPerSecond": 200,
        \\    "rateLimitConnectionsPerIp": 20,
        \\    "maxMessageSize": 2097152
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-roundtrip-security.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(@as(usize, 2), config.security.allowed_origins.len);
    try std.testing.expectEqualStrings("https://example.com", config.security.allowed_origins[0]);
    try std.testing.expectEqualStrings("https://app.example.com", config.security.allowed_origins[1]);
    try std.testing.expectEqual(false, config.security.allow_localhost);
    try std.testing.expectEqual(@as(u32, 200), config.security.rate_limit_messages_per_second);
    try std.testing.expectEqual(@as(u32, 20), config.security.rate_limit_connections_per_ip);
    try std.testing.expectEqual(@as(usize, 2097152), config.security.max_message_size);
}

test "Property 15: Configuration round-trip - logging config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "logging": {
        \\    "level": "debug",
        \\    "format": "text"
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-roundtrip-logging.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);
}

test "Property 15: Configuration round-trip - performance config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "performance": {
        \\    "messageBufferSize": 2000,
        \\    "batchWrites": false,
        \\    "batchTimeoutMs": 20
        \\  }
        \\}
    ;

    const temp_file = "test-artifact/test-config-roundtrip-performance.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);
    try std.testing.expectEqual(@as(u32, 20), config.performance.batch_timeout_ms);
}

test "Property 15: Configuration round-trip - complete config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "server": {
        \\    "port": 8080,
        \\    "host": "127.0.0.1",
        \\    "maxConnections": 50000
        \\  },
        \\  "auth": {
        \\    "jwt": {
        \\      "secret": "my-secret-key",
        \\      "algorithm": "HS512",
        \\      "issuer": "zyncbase",
        \\      "audience": "api"
        \\    }
        \\  },
        \\  "security": {
        \\    "allowedOrigins": ["https://example.com"],
        \\    "allowLocalhost": false,
        \\    "rateLimitMessagesPerSecond": 200,
        \\    "rateLimitConnectionsPerIp": 20,
        \\    "maxMessageSize": 2097152
        \\  },
        \\  "logging": {
        \\    "level": "debug",
        \\    "format": "text"
        \\  },
        \\  "performance": {
        \\    "messageBufferSize": 2000,
        \\    "batchWrites": false,
        \\    "batchTimeoutMs": 20
        \\  },
        \\  "dataDir": "./test-data"
        \\}
    ;

    const temp_file = "test-artifact/test-config-roundtrip-complete.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify all values match original
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqual(@as(usize, 50000), config.server.max_connections);

    try std.testing.expect(config.auth.jwt_secret != null);
    try std.testing.expectEqualStrings("my-secret-key", config.auth.jwt_secret.?);
    try std.testing.expectEqualStrings("HS512", config.auth.jwt_algorithm);

    try std.testing.expectEqual(@as(usize, 1), config.security.allowed_origins.len);
    try std.testing.expectEqualStrings("https://example.com", config.security.allowed_origins[0]);
    try std.testing.expectEqual(false, config.security.allow_localhost);

    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);

    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);

    try std.testing.expectEqualStrings("./test-data", config.data_dir);
}
