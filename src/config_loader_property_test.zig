const std = @import("std");
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Config = @import("config_loader.zig").Config;

const c = @cImport({
    @cInclude("stdlib.h");
});
const schema_helpers = @import("schema_test_helpers.zig");

// Configuration validation properties
// Invariant: Environment variable substitution
// For any configuration field containing ${VAR_NAME} syntax, the environment variable value should be substituted if it exists.
test "config: env var substitution" {
    const allocator = std.testing.allocator;

    // Set up test environment variables using C setenv
    _ = c.setenv("TEST_PORT", "8080", 1);
    _ = c.setenv("TEST_HOST", "192.168.1.1", 1);
    _ = c.setenv("TEST_JWT_SECRET", "test-secret-key", 1);
    _ = c.setenv("TEST_DATA_DIR", "/tmp/test-artifacts", 1);
    defer {
        _ = c.unsetenv("TEST_PORT");
        _ = c.unsetenv("TEST_HOST");
        _ = c.unsetenv("TEST_JWT_SECRET");
        _ = c.unsetenv("TEST_DATA_DIR");
    }

    var context = try schema_helpers.TestContext.init(allocator, "config-env-vars");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-env-vars.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-env.json" });
    defer allocator.free(schema_file_path);

    // Create config with environment variable substitution
    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "server": {{
        \\    "port": ${{TEST_PORT}},
        \\    "host": "${{TEST_HOST}}"
        \\  }},
        \\  "authentication": {{
        \\    "jwt": {{
        \\      "secret": "${{TEST_JWT_SECRET}}"
        \\    }}
        \\  }},
        \\  "dataDir": "${{TEST_DATA_DIR}}",
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify environment variables were substituted
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("192.168.1.1", config.server.host);
    try std.testing.expect(config.authentication.jwt_secret != null);
    try std.testing.expectEqualStrings("test-secret-key", config.authentication.jwt_secret.?);
    try std.testing.expectEqualStrings("/tmp/test-artifacts", config.data_dir);
}

test "config: env var substitution - missing variable keeps original" {
    const allocator = std.testing.allocator;

    // Ensure the variable doesn't exist
    _ = c.unsetenv("NONEXISTENT_VAR");

    var context = try schema_helpers.TestContext.init(allocator, "config-missing-env");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-missing-env-var.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-missing-env.json" });
    defer allocator.free(schema_file_path);

    // Create config with non-existent environment variable
    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "dataDir": "test-artifacts/${{NONEXISTENT_VAR}}",
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify original pattern is kept when variable doesn't exist
    try std.testing.expectEqualStrings("test-artifacts/${NONEXISTENT_VAR}", config.data_dir);
}

test "config: env var substitution - multiple variables" {
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

    var context = try schema_helpers.TestContext.init(allocator, "config-multiple-env");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-multiple-env-vars.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-multiple-env.json" });
    defer allocator.free(schema_file_path);

    // Create config with multiple environment variables
    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "security": {{
        \\    "allowedOrigins": ["${{TEST_ORIGIN_1}}", "${{TEST_ORIGIN_2}}"],
        \\    "rateLimitMessagesPerSecond": ${{TEST_RATE_LIMIT}}
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify all environment variables were substituted
    try std.testing.expectEqual(@as(usize, 2), config.security.allowed_origins.len);
    try std.testing.expectEqualStrings("https://example.com", config.security.allowed_origins[0]);
    try std.testing.expectEqualStrings("https://app.example.com", config.security.allowed_origins[1]);
    try std.testing.expectEqual(@as(u32, 200), config.security.rate_limit_messages_per_second);
}

// Server configuration properties
// Invariant: Configuration validation
// For any configuration, validation should catch invalid values and return descriptive errors.
test "config: validation - invalid port" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-invalid-port");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-port.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-invalid-port.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "server": {{
        \\    "port": 70000
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.InvalidPort, result);
}

test "config: validation - port zero" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-port-zero");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-port-zero.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-port-zero.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "server": {{
        \\    "port": 0
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.InvalidPort, result);
}

test "config: validation - invalid buffer size" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-invalid-buffer");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-buffer.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-invalid-buffer.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "performance": {{
        \\    "messageBufferSize": 0
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.InvalidBufferSize, result);
}

test "config: validation - invalid max message size" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-invalid-max-msg");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-max-message-size.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-invalid-max-message.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "security": {{
        \\    "maxMessageSize": 0
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.InvalidMaxMessageSize, result);
}

// Logging configuration properties
// Invariant: File existence validation
// For any file path in configuration, validation should verify the file exists.
test "config: file existence validation - schema file not found" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-missing-schema");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-missing-schema.json" });
    defer allocator.free(temp_file_path);

    const config_content =
        \\{
        \\  "schema": "/nonexistent/schema.json"
        \\}
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.SchemaFileNotFound, result);
}

test "config: file existence validation - auth rules file not found" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-missing-auth");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-missing-auth-rules.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-missing-auth.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "authorization": "/nonexistent/auth-rules.json",
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.AuthRulesFileNotFound, result);
}

test "config: file existence validation - valid schema file" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-valid-schema");
    defer context.deinit();

    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-valid-schema-extra.json" });
    defer allocator.free(schema_file);
    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-valid-schema.json" });
    defer allocator.free(temp_file_path);

    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schema": "{s}"
        \\}}
    , .{schema_file});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify schema file was loaded
    try std.testing.expectEqualStrings(schema_file, config.schema_file);
}

test "config: file existence validation - valid auth rules file" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-valid-auth");
    defer context.deinit();

    const auth_rules_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-auth-rules.json" });
    defer allocator.free(auth_rules_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-valid-auth.json" });
    defer allocator.free(schema_file);
    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-valid-auth-rules.json" });
    defer allocator.free(temp_file_path);

    try std.fs.cwd().writeFile(.{ .sub_path = auth_rules_file, .data = "{}" });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "authorization": "{s}",
        \\  "schema": "{s}"
        \\}}
    , .{ auth_rules_file, schema_file });
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify auth rules file was loaded
    try std.testing.expect(config.authorization_file != null);
    try std.testing.expectEqualStrings(auth_rules_file, config.authorization_file.?);
}

// Authorization selection properties
// Invariant: Configuration round-trip
// For any valid configuration, serializing then parsing should produce an equivalent configuration.
test "config: round-trip - server config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-server");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-roundtrip-server.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-server.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "server": {{
        \\    "port": 8080,
        \\    "host": "127.0.0.1",
        \\    "maxConnections": 50000
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqual(@as(usize, 50000), config.server.max_connections);
}

test "config: round-trip - auth config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-auth");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-roundtrip-auth.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-auth.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "authentication": {{
        \\    "jwt": {{
        \\      "secret": "my-secret-key",
        \\      "algorithm": "HS512",
        \\      "issuer": "zyncbase",
        \\      "audience": "api"
        \\    }}
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify values match original
    try std.testing.expect(config.authentication.jwt_secret != null);
    try std.testing.expectEqualStrings("my-secret-key", config.authentication.jwt_secret.?);
    try std.testing.expectEqualStrings("HS512", config.authentication.jwt_algorithm);
    try std.testing.expect(config.authentication.jwt_issuer != null);
    try std.testing.expectEqualStrings("zyncbase", config.authentication.jwt_issuer.?);
    try std.testing.expect(config.authentication.jwt_audience != null);
    try std.testing.expectEqualStrings("api", config.authentication.jwt_audience.?);
}

test "config: round-trip - security config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-security");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-roundtrip-security.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-security.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "security": {{
        \\    "allowedOrigins": ["https://example.com", "https://app.example.com"],
        \\    "allowLocalhost": false,
        \\    "rateLimitMessagesPerSecond": 200,
        \\    "rateLimitConnectionsPerIp": 20,
        \\    "maxMessageSize": 2097152
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
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

test "config: round-trip - logging config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-logging");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-roundtrip-logging.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-logging.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "logging": {{
        \\    "level": "debug",
        \\    "format": "text"
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);
}

test "config: round-trip - performance config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-perf");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-roundtrip-performance.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-performance.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "performance": {{
        \\    "messageBufferSize": 2000,
        \\    "batchWrites": false,
        \\    "batchTimeoutMs": 20
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);
    try std.testing.expectEqual(@as(u32, 20), config.performance.batch_timeout_ms);
}

test "config: round-trip - complete config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-complete");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-roundtrip-complete.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-complete.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "server": {{
        \\    "port": 8080,
        \\    "host": "127.0.0.1",
        \\    "maxConnections": 50000
        \\  }},
        \\  "authentication": {{
        \\    "jwt": {{
        \\      "secret": "my-secret-key",
        \\      "algorithm": "HS512",
        \\      "issuer": "zyncbase",
        \\      "audience": "api"
        \\    }}
        \\  }},
        \\  "security": {{
        \\    "allowedOrigins": ["https://example.com"],
        \\    "allowLocalhost": false,
        \\    "rateLimitMessagesPerSecond": 200,
        \\    "rateLimitConnectionsPerIp": 20,
        \\    "maxMessageSize": 2097152
        \\  }},
        \\  "logging": {{
        \\    "level": "debug",
        \\    "format": "text"
        \\  }},
        \\  "performance": {{
        \\    "messageBufferSize": 2000,
        \\    "batchWrites": false,
        \\    "batchTimeoutMs": 20
        \\  }},
        \\  "dataDir": "{s}",
        \\  "schema": "{s}"
        \\}}
    , .{ context.test_dir, schema_file_path });
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify all values match original
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqual(@as(usize, 50000), config.server.max_connections);

    try std.testing.expect(config.authentication.jwt_secret != null);
    try std.testing.expectEqualStrings("my-secret-key", config.authentication.jwt_secret.?);
    try std.testing.expectEqualStrings("HS512", config.authentication.jwt_algorithm);

    try std.testing.expectEqual(@as(usize, 1), config.security.allowed_origins.len);
    try std.testing.expectEqualStrings("https://example.com", config.security.allowed_origins[0]);
    try std.testing.expectEqual(false, config.security.allow_localhost);

    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);

    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);

    try std.testing.expectEqualStrings(context.test_dir, config.data_dir);
}
