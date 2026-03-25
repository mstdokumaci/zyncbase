const std = @import("std");
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Config = @import("config_loader.zig").Config;
const schema_helpers = @import("schema_test_helpers.zig");

test "ConfigLoader loads defaults when file not found" {
    const allocator = std.testing.allocator;

    var config = try ConfigLoader.load(allocator, "nonexistent-config.json");
    defer config.deinit();

    // Verify default values
    try std.testing.expectEqual(@as(u16, 3000), config.server.port);
    try std.testing.expectEqualStrings("0.0.0.0", config.server.host);
    try std.testing.expectEqual(@as(usize, 100_000), config.server.max_connections);
    try std.testing.expectEqualStrings("./data", config.data_dir);
}

test "ConfigLoader parses valid JSON config" {
    const allocator = std.testing.allocator;

    // Create a temporary config file
    const config_content =
        \\{{
        \\  "server": {{
        \\    "port": 8080,
        \\    "host": "127.0.0.1",
        \\    "maxConnections": 50000
        \\  }},
        \\  "dataDir": "{s}",
        \\  "logging": {{
        \\    "level": "debug",
        \\    "format": "text"
        \\  }},
        \\  "performance": {{
        \\    "messageBufferSize": 2000,
        \\    "batchWrites": false,
        \\    "batchTimeoutMs": 20
        \\  }},
        \\  "schema": "{s}/test-config-schema.json"
        \\}}
    ;

    var context = try schema_helpers.TestContext.init(allocator, "config-parse");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.fmt.allocPrint(allocator, config_content, .{ context.test_dir, context.test_dir });
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify parsed values
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqual(@as(usize, 50000), config.server.max_connections);
    try std.testing.expectEqualStrings(context.test_dir, config.data_dir);
    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);
    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);
    try std.testing.expectEqual(@as(u32, 20), config.performance.batch_timeout_ms);
}

test "ConfigLoader validates port range" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{{
        \\  "server": {{
        \\    "port": 70000
        \\  }},
        \\  "schema": "{s}/invalid-port-schema.json"
        \\}}
    ;

    var context = try schema_helpers.TestContext.init(allocator, "config-port");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-port.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "invalid-port-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.fmt.allocPrint(allocator, config_content, .{context.test_dir});
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidPort, result);
}

test "ConfigLoader validates numeric ranges" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{{
        \\  "performance": {{
        \\    "messageBufferSize": 0
        \\  }},
        \\  "schema": "{s}/invalid-buffer-schema.json"
        \\}}
    ;

    var context = try schema_helpers.TestContext.init(allocator, "config-buffer");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-buffer.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "invalid-buffer-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.fmt.allocPrint(allocator, config_content, .{context.test_dir});
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidBufferSize, result);
}

test "ConfigLoader parses auth config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{{
        \\  "authentication": {{
        \\    "jwt": {{
        \\      "secret": "my-secret-key",
        \\      "algorithm": "HS512",
        \\      "issuer": "zyncbase",
        \\      "audience": "api"
        \\    }}
        \\  }},
        \\  "schema": "{s}/auth-schema.json"
        \\}}
    ;

    var context = try schema_helpers.TestContext.init(allocator, "config-auth");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-auth.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "auth-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.fmt.allocPrint(allocator, config_content, .{context.test_dir});
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify auth config (JWT validation only - Hook Server is managed by CLI)
    try std.testing.expect(config.authentication.jwt_secret != null);
    try std.testing.expectEqualStrings("my-secret-key", config.authentication.jwt_secret.?);
    try std.testing.expectEqualStrings("HS512", config.authentication.jwt_algorithm);
    try std.testing.expect(config.authentication.jwt_issuer != null);
    try std.testing.expectEqualStrings("zyncbase", config.authentication.jwt_issuer.?);
    try std.testing.expect(config.authentication.jwt_audience != null);
    try std.testing.expectEqualStrings("api", config.authentication.jwt_audience.?);
}

test "ConfigLoader parses security config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{{
        \\  "security": {{
        \\    "allowedOrigins": ["https://example.com", "https://app.example.com"],
        \\    "allowLocalhost": false,
        \\    "rateLimitMessagesPerSecond": 200,
        \\    "rateLimitConnectionsPerIp": 20,
        \\    "maxMessageSize": 2097152
        \\  }},
        \\  "schema": "{s}/security-schema.json"
        \\}}
    ;

    var context = try schema_helpers.TestContext.init(allocator, "config-security");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-security.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "security-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.fmt.allocPrint(allocator, config_content, .{context.test_dir});
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify security config
    try std.testing.expectEqual(@as(usize, 2), config.security.allowed_origins.len);
    try std.testing.expectEqualStrings("https://example.com", config.security.allowed_origins[0]);
    try std.testing.expectEqualStrings("https://app.example.com", config.security.allowed_origins[1]);
    try std.testing.expectEqual(false, config.security.allow_localhost);
    try std.testing.expectEqual(@as(u32, 200), config.security.rate_limit_messages_per_second);
    try std.testing.expectEqual(@as(u32, 20), config.security.rate_limit_connections_per_ip);
    try std.testing.expectEqual(@as(usize, 2097152), config.security.max_message_size);
}
