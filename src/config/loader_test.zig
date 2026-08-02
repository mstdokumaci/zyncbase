const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
});

const schema_helpers = @import("../schema/test_helpers.zig");
const ConfigLoader = @import("loader.zig").ConfigLoader;
const Config = @import("state.zig").Config;

/// Writes an empty schema file and the given config content under `test_dir`,
/// returning an allocated path to the config file. The caller owns the returned
/// path and schema content.
fn writeConfigWithSchema(
    allocator: std.mem.Allocator,
    test_dir: []const u8,
    config_file_name: []const u8,
    schema_file_path: []const u8,
    config_content: []const u8,
) ![]const u8 {
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });
    const temp_file_path = try std.fs.path.join(allocator, &.{ test_dir, config_file_name });
    errdefer allocator.free(temp_file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    return temp_file_path;
}

/// Duplicates an optional getenv result into allocator-owned, sentinel-terminated
/// storage so later setenv/unsetenv calls cannot invalidate it. Returns null for
/// unset variables. The caller owns the returned copy.
fn dupeEnvZ(allocator: std.mem.Allocator, value: ?[*:0]const u8) !?[:0]u8 {
    return if (value) |v| try allocator.dupeZ(u8, std.mem.span(v)) else null;
}

test "ConfigLoader loads defaults when file not found" {
    const allocator = std.testing.allocator;

    var config = try ConfigLoader.load(allocator, "nonexistent-config.json");
    defer config.deinit();

    // Verify default values
    try std.testing.expectEqual(@as(u16, 3000), config.server.port);
    try std.testing.expectEqualStrings("0.0.0.0", config.server.host);
    try std.testing.expectEqualStrings("./data", config.data_dir);
    try std.testing.expectEqual(@as(usize, 200), config.performance.batch_size);
}

test "ConfigLoader parses valid JSON config" {
    const allocator = std.testing.allocator;

    // Create a temporary config file

    var context = try schema_helpers.TestContext.init(allocator, "config-parse");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.mem.concat(allocator, u8, &.{ "{ \"server\": { \"port\": 8080, \"host\": \"127.0.0.1\" }, \"dataDir\": \"", context.test_dir, "\", \"logging\": { \"level\": \"debug\", \"format\": \"text\" }, \"performance\": { \"messageBufferSize\": 2000, \"batchWrites\": false, \"batchSize\": 50, \"batchTimeout\": 20 }, \"schema\": \"", context.test_dir, "/test-config-schema.json\" }" });
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    // Verify parsed values
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqualStrings(context.test_dir, config.data_dir);
    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);
    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);
    try std.testing.expectEqual(@as(usize, 50), config.performance.batch_size);
    try std.testing.expectEqual(@as(u32, 20), config.performance.batch_timeout);
}

test "ConfigLoader validates port range" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-port");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-port.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "invalid-port-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.mem.concat(allocator, u8, &.{ "{\"server\": {\"port\": 70000}, \"schema\": \"", context.test_dir, "/invalid-port-schema.json\"}" });
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidPort, result);
}

test "ConfigLoader validates numeric ranges" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-buffer");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-buffer.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "invalid-buffer-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.mem.concat(allocator, u8, &.{ "{\"performance\": {\"messageBufferSize\": 0}, \"schema\": \"", context.test_dir, "/invalid-buffer-schema.json\"}" });
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidBufferSize, result);
}

test "ConfigLoader validates batch size" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-batch-size");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-invalid-batch-size.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "invalid-batch-size-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.mem.concat(allocator, u8, &.{ "{\"performance\": {\"batchSize\": 0}, \"schema\": \"", context.test_dir, "/invalid-batch-size-schema.json\"}" });
    defer allocator.free(final_config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = final_config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file, .data = "{}" });

    const result = ConfigLoader.load(allocator, temp_file);
    try std.testing.expectError(error.InvalidBatchSize, result);
}

test "ConfigLoader parses auth config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-auth");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-auth.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "auth-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.mem.concat(allocator, u8, &.{ "{\"authentication\": {\"jwt\": {\"secret\": \"my-secret-key\", \"algorithm\": \"HS512\", \"issuer\": \"zyncbase\", \"audience\": \"api\"}}, \"schema\": \"", context.test_dir, "/auth-schema.json\"}" });
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

    var context = try schema_helpers.TestContext.init(allocator, "config-security");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-security.json" });
    defer allocator.free(temp_file);
    const schema_file = try std.fs.path.join(allocator, &.{ context.test_dir, "security-schema.json" });
    defer allocator.free(schema_file);

    const final_config_content = try std.mem.concat(allocator, u8, &.{ "{\"security\": {\"allowedOrigins\": [\"https://example.com\", \"https://app.example.com\"], \"allowLocalhost\": false, \"maxMessagesPerSecond\": 200, \"maxConnections\": 20, \"maxMessageSize\": 2097152}, \"schema\": \"", context.test_dir, "/security-schema.json\"}" });
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
    try std.testing.expectEqual(@as(u32, 200), config.security.max_messages_per_second);
    try std.testing.expectEqual(@as(u32, 20), config.security.max_connections);
    try std.testing.expectEqual(@as(usize, 2097152), config.security.max_message_size);
}

test "ConfigLoader parses inline schema configuration" {
    const allocator = std.testing.allocator;

    const config_content =
        \\{
        \\  "schema": {
        \\    "tables": [
        \\      {
        \\        "name": "users",
        \\        "fields": [
        \\          { "name": "id", "type": "string" },
        \\          { "name": "name", "type": "string" }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var context = try schema_helpers.TestContext.init(allocator, "config-inline-schema");
    defer context.deinit();

    const temp_file = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-inline.json" });
    defer allocator.free(temp_file);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file, .data = config_content });

    var config = try ConfigLoader.load(allocator, temp_file);
    defer config.deinit();

    try std.testing.expect(config.schema_content != null);

    // Parse the generated JSON back to verify correctness
    var parsed_schema = try std.json.parseFromSlice(std.json.Value, allocator, config.schema_content.?, .{});
    defer parsed_schema.deinit();

    try std.testing.expect(parsed_schema.value == .object);
    const schema_obj = parsed_schema.value.object;
    const tables_val = schema_obj.get("tables") orelse unreachable;
    try std.testing.expect(tables_val == .array);

    const tables = tables_val.array;
    try std.testing.expectEqual(@as(usize, 1), tables.items.len);

    const user_table = tables.items[0].object;
    const name_val = user_table.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("users", name_val.string);

    const fields_val = user_table.get("fields") orelse unreachable;
    const fields = fields_val.array;
    try std.testing.expectEqual(@as(usize, 2), fields.items.len);

    const f0_name = fields.items[0].object.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("id", f0_name.string);

    const f1_name = fields.items[1].object.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("name", f1_name.string);
}

// Configuration validation properties
// Invariant: Environment variable substitution
// For any configuration field containing ${VAR_NAME} syntax, the environment variable value should be substituted if it exists.
test "config: env var substitution" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-env-vars");
    defer context.deinit();

    // Set up test environment variables using C setenv
    const prev_test_port = try dupeEnvZ(allocator, c.getenv("TEST_PORT"));
    defer if (prev_test_port) |v| allocator.free(v);
    const prev_test_host = try dupeEnvZ(allocator, c.getenv("TEST_HOST"));
    defer if (prev_test_host) |v| allocator.free(v);
    const prev_test_jwt_secret = try dupeEnvZ(allocator, c.getenv("TEST_JWT_SECRET"));
    defer if (prev_test_jwt_secret) |v| allocator.free(v);
    const prev_test_data_dir = try dupeEnvZ(allocator, c.getenv("TEST_DATA_DIR"));
    defer if (prev_test_data_dir) |v| allocator.free(v);
    defer {
        if (prev_test_port) |v| {
            _ = c.setenv("TEST_PORT", v, 1);
        } else {
            _ = c.unsetenv("TEST_PORT");
        }
        if (prev_test_host) |v| {
            _ = c.setenv("TEST_HOST", v, 1);
        } else {
            _ = c.unsetenv("TEST_HOST");
        }
        if (prev_test_jwt_secret) |v| {
            _ = c.setenv("TEST_JWT_SECRET", v, 1);
        } else {
            _ = c.unsetenv("TEST_JWT_SECRET");
        }
        if (prev_test_data_dir) |v| {
            _ = c.setenv("TEST_DATA_DIR", v, 1);
        } else {
            _ = c.unsetenv("TEST_DATA_DIR");
        }
    }
    _ = c.setenv("TEST_PORT", "8080", 1);
    _ = c.setenv("TEST_HOST", "192.168.1.1", 1);
    _ = c.setenv("TEST_JWT_SECRET", "test-secret-key", 1);
    const test_data_dir_z = try allocator.dupeZ(u8, context.test_dir);
    defer allocator.free(test_data_dir_z);
    _ = c.setenv("TEST_DATA_DIR", test_data_dir_z, 1);

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
    try std.testing.expectEqualStrings(context.test_dir, config.data_dir);
}

test "config: env var substitution - missing variable keeps original" {
    const allocator = std.testing.allocator;

    // Ensure the variable doesn't exist
    const prev_nonexistent_var = try dupeEnvZ(allocator, c.getenv("NONEXISTENT_VAR"));
    defer if (prev_nonexistent_var) |v| allocator.free(v);
    _ = c.unsetenv("NONEXISTENT_VAR");
    defer {
        if (prev_nonexistent_var) |v| {
            _ = c.setenv("NONEXISTENT_VAR", v, 1);
        }
    }

    var context = try schema_helpers.TestContext.init(allocator, "config-missing-env");
    defer context.deinit();

    const temp_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-config-missing-env-var.json" });
    defer allocator.free(temp_file_path);
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-missing-env.json" });
    defer allocator.free(schema_file_path);

    // Create config with non-existent environment variable
    // We use context.test_dir to ensure the directory is cleaned up even if substitution fails
    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "dataDir": "{s}/${{NONEXISTENT_VAR}}",
        \\  "schema": "{s}"
        \\}}
    , .{ context.test_dir, schema_file_path });
    defer allocator.free(config_content);

    try std.fs.cwd().writeFile(.{ .sub_path = temp_file_path, .data = config_content });
    try std.fs.cwd().writeFile(.{ .sub_path = schema_file_path, .data = "{}" });

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify original pattern is kept when variable doesn't exist
    const expected_data_dir = try std.fmt.allocPrint(allocator, "{s}/${{NONEXISTENT_VAR}}", .{context.test_dir});
    defer allocator.free(expected_data_dir);
    try std.testing.expectEqualStrings(expected_data_dir, config.data_dir);
}

test "config: env var substitution - multiple variables" {
    const allocator = std.testing.allocator;

    // Set up multiple test environment variables
    const prev_test_origin_1 = try dupeEnvZ(allocator, c.getenv("TEST_ORIGIN_1"));
    defer if (prev_test_origin_1) |v| allocator.free(v);
    const prev_test_origin_2 = try dupeEnvZ(allocator, c.getenv("TEST_ORIGIN_2"));
    defer if (prev_test_origin_2) |v| allocator.free(v);
    const prev_test_rate_limit = try dupeEnvZ(allocator, c.getenv("TEST_RATE_LIMIT"));
    defer if (prev_test_rate_limit) |v| allocator.free(v);
    _ = c.setenv("TEST_ORIGIN_1", "https://example.com", 1);
    _ = c.setenv("TEST_ORIGIN_2", "https://app.example.com", 1);
    _ = c.setenv("TEST_RATE_LIMIT", "200", 1);
    defer {
        if (prev_test_origin_1) |v| {
            _ = c.setenv("TEST_ORIGIN_1", v, 1);
        } else {
            _ = c.unsetenv("TEST_ORIGIN_1");
        }
        if (prev_test_origin_2) |v| {
            _ = c.setenv("TEST_ORIGIN_2", v, 1);
        } else {
            _ = c.unsetenv("TEST_ORIGIN_2");
        }
        if (prev_test_rate_limit) |v| {
            _ = c.setenv("TEST_RATE_LIMIT", v, 1);
        } else {
            _ = c.unsetenv("TEST_RATE_LIMIT");
        }
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
        \\    "maxMessagesPerSecond": ${{TEST_RATE_LIMIT}}
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
    try std.testing.expectEqual(@as(u32, 200), config.security.max_messages_per_second);
}

// Server configuration properties
// Invariant: Configuration validation
// For any configuration, validation should catch invalid values and return descriptive errors.
test "config: validation - port zero" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-port-zero");
    defer context.deinit();

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

    const temp_file_path = try writeConfigWithSchema(allocator, context.test_dir, "test-config-port-zero.json", schema_file_path, config_content);
    defer allocator.free(temp_file_path);

    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.InvalidPort, result);
}

test "config: validation - invalid max message size" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-invalid-max-msg");
    defer context.deinit();

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

    const temp_file_path = try writeConfigWithSchema(allocator, context.test_dir, "test-config-invalid-max-message-size.json", schema_file_path, config_content);
    defer allocator.free(temp_file_path);

    const result = ConfigLoader.load(allocator, temp_file_path);
    try std.testing.expectError(error.InvalidMaxMessageSize, result);
}

// Logging configuration properties
// Invariant: Missing schema file falls back to the implicit users-only schema.
test "config: missing schema file is allowed" {
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
    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();
    try std.testing.expectEqualStrings("/nonexistent/schema.json", config.schema_file);
    try std.testing.expect(config.schema_content == null);
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
// Invariant: Configuration loading
// For any valid configuration, loading valid configuration produces the expected equivalent configuration.
test "config: load - server config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-server");
    defer context.deinit();

    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-server.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "server": {{
        \\    "port": 8080,
        \\    "host": "127.0.0.1"
        \\  }},
        \\  "schema": "{s}"
        \\}}
    , .{schema_file_path});
    defer allocator.free(config_content);

    const temp_file_path = try writeConfigWithSchema(allocator, context.test_dir, "test-config-roundtrip-server.json", schema_file_path, config_content);
    defer allocator.free(temp_file_path);

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
}

test "config: load - logging config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-logging");
    defer context.deinit();

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

    const temp_file_path = try writeConfigWithSchema(allocator, context.test_dir, "test-config-roundtrip-logging.json", schema_file_path, config_content);
    defer allocator.free(temp_file_path);

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify values match original
    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);
}

test "config: load - complete config" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "config-roundtrip-complete");
    defer context.deinit();

    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "test-schema-roundtrip-complete.json" });
    defer allocator.free(schema_file_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "server": {{
        \\    "port": 8080,
        \\    "host": "127.0.0.1"
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
        \\    "maxMessagesPerSecond": 200,
        \\    "maxConnections": 20,
        \\    "violationThreshold": 5,
        \\    "maxMessageSize": 2097152
        \\  }},
        \\  "logging": {{
        \\    "level": "debug",
        \\    "format": "text"
        \\  }},
        \\  "performance": {{
        \\    "messageBufferSize": 2000,
        \\    "batchWrites": false,
        \\    "batchSize": 50,
        \\    "batchTimeout": 20,
        \\    "statementCacheSize": 250
        \\  }},
        \\  "dataDir": "{s}",
        \\  "schema": "{s}"
        \\}}
    , .{ context.test_dir, schema_file_path });
    defer allocator.free(config_content);

    const temp_file_path = try writeConfigWithSchema(allocator, context.test_dir, "test-config-roundtrip-complete.json", schema_file_path, config_content);
    defer allocator.free(temp_file_path);

    var config = try ConfigLoader.load(allocator, temp_file_path);
    defer config.deinit();

    // Verify all values match original
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);

    try std.testing.expect(config.authentication.jwt_secret != null);
    try std.testing.expectEqualStrings("my-secret-key", config.authentication.jwt_secret.?);
    try std.testing.expectEqualStrings("HS512", config.authentication.jwt_algorithm);
    try std.testing.expect(config.authentication.jwt_issuer != null);
    try std.testing.expectEqualStrings("zyncbase", config.authentication.jwt_issuer.?);
    try std.testing.expect(config.authentication.jwt_audience != null);
    try std.testing.expectEqualStrings("api", config.authentication.jwt_audience.?);

    try std.testing.expectEqual(@as(usize, 1), config.security.allowed_origins.len);
    try std.testing.expectEqualStrings("https://example.com", config.security.allowed_origins[0]);
    try std.testing.expectEqual(false, config.security.allow_localhost);
    try std.testing.expectEqual(@as(u32, 200), config.security.max_messages_per_second);
    try std.testing.expectEqual(@as(u32, 20), config.security.max_connections);
    try std.testing.expectEqual(@as(u32, 5), config.security.violation_threshold);
    try std.testing.expectEqual(@as(usize, 2097152), config.security.max_message_size);

    try std.testing.expectEqual(Config.LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(Config.LoggingConfig.LogFormat.text, config.logging.format);

    try std.testing.expectEqual(@as(usize, 2000), config.performance.message_buffer_size);
    try std.testing.expectEqual(false, config.performance.batch_writes);
    try std.testing.expectEqual(@as(usize, 50), config.performance.batch_size);
    try std.testing.expectEqual(@as(u32, 20), config.performance.batch_timeout);
    try std.testing.expectEqual(@as(usize, 250), config.performance.statement_cache_size);

    try std.testing.expectEqualStrings(context.test_dir, config.data_dir);
}
