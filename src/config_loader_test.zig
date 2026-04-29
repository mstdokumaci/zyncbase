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

    const final_config_content = try std.mem.concat(allocator, u8, &.{ "{\"security\": {\"allowedOrigins\": [\"https://example.com\", \"https://app.example.com\"], \"allowLocalhost\": false, \"maxMessagesPerSecond\": 200, \"maxConnectionsPerIP\": 20, \"maxMessageSize\": 2097152}, \"schema\": \"", context.test_dir, "/security-schema.json\"}" });
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
    try std.testing.expectEqual(@as(u32, 20), config.security.max_connections_per_ip);
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
