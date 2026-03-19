const std = @import("std");
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Config = @import("config_loader.zig").Config;

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
        \\{
        \\  "server": {
        \\    "port": 8080,
        \\    "host": "127.0.0.1",
        \\    "maxConnections": 50000
        \\  },
        \\  "dataDir": "./test-artifacts",
        \\  "logging": {
        \\    "level": "debug",
        \\    "format": "text"
        \\  },
        \\  "performance": {
        \\    "messageBufferSize": 2000,
        \\    "batchWrites": false,
        \\    "batchTimeoutMs": 20
        \\  },
        \\  "schema": "test-artifacts/test-config-schema.json"
        \\}
    ;

    const temp_file = "test-artifacts/test-config.json";
    const schema_file = "test-artifacts/test-config-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });
    defer std.fs.cwd().deleteFile(temp_file) catch {}; // zwanzig-disable-line: empty-catch-engine
    defer std.fs.cwd().deleteFile(schema_file) catch {}; // zwanzig-disable-line: empty-catch-engine

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify parsed values
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqual(@as(usize, 50000), config.server.max_connections);
    try std.testing.expectEqualStrings("./test-artifacts", config.data_dir);
    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);
    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);
    try std.testing.expectEqual(@as(u32, 20), config.performance.batch_timeout_ms);
}

test "ConfigLoader validates port range" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "server": {
        \\    "port": 70000
        \\  },
        \\  "schema": "test-artifacts/invalid-port-schema.json"
        \\}
    ;

    const temp_file = "test-artifacts/test-config-invalid-port.json";
    const schema_file = "test-artifacts/invalid-port-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });
    defer std.fs.cwd().deleteFile(temp_file) catch {}; // zwanzig-disable-line: empty-catch-engine
    defer std.fs.cwd().deleteFile(schema_file) catch {}; // zwanzig-disable-line: empty-catch-engine

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidPort, result);
}

test "ConfigLoader validates numeric ranges" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "performance": {
        \\    "messageBufferSize": 0
        \\  },
        \\  "schema": "test-artifacts/invalid-buffer-schema.json"
        \\}
    ;

    const temp_file = "test-artifacts/test-config-invalid-buffer.json";
    const schema_file = "test-artifacts/invalid-buffer-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });
    defer std.fs.cwd().deleteFile(temp_file) catch {}; // zwanzig-disable-line: empty-catch-engine
    defer std.fs.cwd().deleteFile(schema_file) catch {}; // zwanzig-disable-line: empty-catch-engine

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidBufferSize, result);
}

test "ConfigLoader parses auth config" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "authentication": {
        \\    "jwt": {
        \\      "secret": "my-secret-key",
        \\      "algorithm": "HS512",
        \\      "issuer": "zyncbase",
        \\      "audience": "api"
        \\    }
        \\  },
        \\  "schema": "test-artifacts/auth-schema.json"
        \\}
    ;

    const temp_file = "test-artifacts/test-config-auth.json";
    const schema_file = "test-artifacts/auth-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });
    defer std.fs.cwd().deleteFile(temp_file) catch {}; // zwanzig-disable-line: empty-catch-engine
    defer std.fs.cwd().deleteFile(schema_file) catch {}; // zwanzig-disable-line: empty-catch-engine

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
        \\{
        \\  "security": {
        \\    "allowedOrigins": ["https://example.com", "https://app.example.com"],
        \\    "allowLocalhost": false,
        \\    "rateLimitMessagesPerSecond": 200,
        \\    "rateLimitConnectionsPerIp": 20,
        \\    "maxMessageSize": 2097152
        \\  },
        \\  "schema": "test-artifacts/security-schema.json"
        \\}
    ;

    const temp_file = "test-artifacts/test-config-security.json";
    const schema_file = "test-artifacts/security-schema.json";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });
    defer std.fs.cwd().deleteFile(temp_file) catch {}; // zwanzig-disable-line: empty-catch-engine
    defer std.fs.cwd().deleteFile(schema_file) catch {}; // zwanzig-disable-line: empty-catch-engine

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
