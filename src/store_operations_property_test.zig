const std = @import("std");
const testing = std.testing;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const MessagePackParser = @import("messagepack_parser.zig").MessagePackParser;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const msgpack_helpers = @import("msgpack_test_helpers.zig");

// Helper function to create a mock WebSocket for testing
fn createMockWebSocket() WebSocket {
    return WebSocket{
        .ws = null, // Mock WebSocket
        .ssl = false,
        .user_data = null,
    };
}

// **Property 25: StoreSet field extraction**
// **Validates: Requirements 16.2**
//
// For any StoreSet message, the namespace, path, and value fields should be
// extractable from the MessagePack map.
test "Property 25: StoreSet field extraction" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/store_operations/test_data_property25");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/store_operations/test_data_property25") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        parser,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Basic StoreSet message field extraction
    {
        const message = try msgpack_helpers.createStoreSetMessage(allocator, 1, "test_ns", "/test/path", "test_value");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);

        // Should be able to route and process (which requires field extraction)
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // If we got a response, fields were extracted successfully
        try testing.expect(response.len > 0);
    }

    // Test 2: StoreSet with various field values
    {
        const test_cases = [_]struct {
            namespace: []const u8,
            path: []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = "/p1", .value = "v1" },
            .{ .namespace = "namespace_with_underscores", .path = "/long/nested/path", .value = "complex value" },
            .{ .namespace = "a", .path = "/", .value = "" },
            .{ .namespace = "test", .path = "/key", .value = "value with spaces" },
        };

        for (test_cases, 0..) |tc, i| {
            const message = try msgpack_helpers.createStoreSetMessage(allocator, @intCast(i), tc.namespace, tc.path, tc.value);
            defer allocator.free(message);

            const parsed = try parser.parse(message);
            defer parser.freeValue(parsed);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            try testing.expect(response.len > 0);
        }
    }

    // Test 3: StoreSet missing namespace should fail
    {
        // Manual msgpack map construction missing a field
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        // fixmap(4) - type, id, path, value (missing namespace)
        try buf.append(allocator, 0x84);
        try msgpack_helpers.writeString(allocator, &buf, "type");
        try msgpack_helpers.writeString(allocator, &buf, "StoreSet");
        try msgpack_helpers.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack_helpers.writeString(allocator, &buf, "path");
        try msgpack_helpers.writeString(allocator, &buf, "/test");
        try msgpack_helpers.writeString(allocator, &buf, "value");
        try msgpack_helpers.writeString(allocator, &buf, "val");

        const message = buf.items;
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 4: StoreSet missing path should fail
    {
        const message = try msgpack_helpers.createStoreSetMessage(allocator, 1, "test", "/path", "val");
        defer allocator.free(message);
        // Corrupt it manually by removing a field or using a shorter map
        message[0] = 0x83; // Change fixmap(4) to fixmap(3) - effectively "missing" one field during parse if we only read 3

        // Actually, MessagePackParser.parse will just read 3 entries.
        // If we want to test "missing field", we should construct a map with only 3 specific fields.
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack_helpers.writeString(allocator, &buf, "type");
        try msgpack_helpers.writeString(allocator, &buf, "StoreSet");
        try msgpack_helpers.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack_helpers.writeString(allocator, &buf, "namespace");
        try msgpack_helpers.writeString(allocator, &buf, "test");
        // Missing "path" and "value"

        const msg_buf = buf.items;
        const parsed = try parser.parse(msg_buf);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 5: StoreSet missing value should fail
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack_helpers.writeString(allocator, &buf, "type");
        try msgpack_helpers.writeString(allocator, &buf, "StoreSet");
        try msgpack_helpers.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack_helpers.writeString(allocator, &buf, "namespace");
        try msgpack_helpers.writeString(allocator, &buf, "test");

        const msg_buf = buf.items;
        const parsed = try parser.parse(msg_buf);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }
}

// **Property 26: StoreSet storage engine call**
// **Validates: Requirements 16.3**
//
// For any StoreSet message, the Storage Engine insert or update function should be
// called with the extracted parameters.
test "Property 26: StoreSet storage engine call" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/store_operations/test_data_property26");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/store_operations/test_data_property26") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        parser,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreSet should call storage engine and persist data
    {
        const message = try msgpack_helpers.createStoreSetMessage(allocator, 1, "test", "/key1", "value1");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Wait for write to complete
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Verify data was stored by retrieving it
        const stored_value = try storage_engine.get("test", "/key1");
        defer if (stored_value) |v| allocator.free(v);
        try testing.expect(stored_value != null);
        
        // Value is stored as MessagePack-serialized
        const stored_parsed = try parser.parse(stored_value.?);
        defer parser.freeValue(stored_parsed);
        try testing.expectEqualStrings("value1", stored_parsed.string);
    }

    // Test 2: Multiple StoreSet calls should all persist
    {
        const test_data = [_]struct {
            namespace: []const u8,
            path: []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = "/k1", .value = "v1" },
            .{ .namespace = "ns1", .path = "/k2", .value = "v2" },
            .{ .namespace = "ns2", .path = "/k1", .value = "v3" },
        };

        for (test_data, 0..) |td, i| {
            const message = try msgpack_helpers.createStoreSetMessage(allocator, @intCast(i + 10), td.namespace, td.path, td.value);
            defer allocator.free(message);

            const parsed = try parser.parse(message);
            defer parser.freeValue(parsed);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);
        }

        // Wait for writes to complete
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Verify all data was stored
        for (test_data) |td| {
            const stored_value = try storage_engine.get(td.namespace, td.path);
            defer if (stored_value) |v| allocator.free(v);
            try testing.expect(stored_value != null);
            
            const stored_parsed = try parser.parse(stored_value.?);
            defer parser.freeValue(stored_parsed);
            try testing.expectEqualStrings(td.value, stored_parsed.string);
        }
    }

    // Test 3: StoreSet should update existing values
    {
        const namespace = "update_test";
        const path = "/update_key";

        // Set initial value
        const message1 = try msgpack_helpers.createStoreSetMessage(allocator, 1, namespace, path, "initial");
        defer allocator.free(message1);

        const parsed1 = try parser.parse(message1);
        defer parser.freeValue(parsed1);
        const info1 = try handler.extractMessageInfo(parsed1);
        const response1 = try handler.routeMessage(1, info1, parsed1);
        defer allocator.free(response1);

        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Update value
        const message2 = try msgpack_helpers.createStoreSetMessage(allocator, 2, namespace, path, "updated");
        defer allocator.free(message2);

        const parsed2 = try parser.parse(message2);
        defer parser.freeValue(parsed2);
        const info2 = try handler.extractMessageInfo(parsed2);
        const response2 = try handler.routeMessage(1, info2, parsed2);
        defer allocator.free(response2);

        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Verify value was updated
        const stored_value = try storage_engine.get(namespace, path);
        defer if (stored_value) |v| allocator.free(v);
        try testing.expect(stored_value != null);
        
        const stored_parsed = try parser.parse(stored_value.?);
        defer parser.freeValue(stored_parsed);
        try testing.expectEqualStrings("updated", stored_parsed.string);
    }
}

// **Property 27: StoreSet success response**
// **Validates: Requirements 16.4**
//
// For any successful StoreSet operation, a success response should be sent to the client.
test "Property 27: StoreSet success response" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/store_operations/test_data_property27");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/store_operations/test_data_property27") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        parser,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Successful StoreSet should return success response
    {
        const message = try msgpack_helpers.createStoreSetMessage(allocator, 1, "test", "/key", "val");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should indicate success
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var found_ok = false;
        var found_id = false;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string) {
                if (std.mem.eql(u8, entry.key.string, "type")) {
                    try testing.expectEqualStrings("ok", entry.value.string);
                    found_ok = true;
                } else if (std.mem.eql(u8, entry.key.string, "id")) {
                    try testing.expectEqual(@as(u64, 1), entry.value.unsigned);
                    found_id = true;
                }
            }
        }
        try testing.expect(found_ok and found_id);
    }

    // Test 2: Multiple successful StoreSet operations
    {
        for (0..10) |i| {
            const path_str = try std.fmt.allocPrint(allocator, "/key{}", .{i});
            defer allocator.free(path_str);
            const val_str = try std.fmt.allocPrint(allocator, "val{}", .{i});
            defer allocator.free(val_str);

            const msg = try msgpack_helpers.createStoreSetMessage(allocator, i, "test", path_str, val_str);
            defer allocator.free(msg);

            const parsed = try parser.parse(msg);
            defer parser.freeValue(parsed);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            // Each should return success
            const resp_parsed = try parser.parse(response);
            defer parser.freeValue(resp_parsed);
            try testing.expect(resp_parsed == .map);
            var found_ok = false;
            for (resp_parsed.map) |entry| {
                if (entry.key == .string and std.mem.eql(u8, entry.key.string, "type")) {
                    try testing.expectEqualStrings("ok", entry.value.string);
                    found_ok = true;
                }
            }
            try testing.expect(found_ok);
        }
    }

    // Test 3: Success response format should be consistent
    {
        const message = try msgpack_helpers.createStoreSetMessage(allocator, 999, "ns", "/p", "v");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should have expected format
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var found_type = false;
        var found_id = false;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string) {
                if (std.mem.eql(u8, entry.key.string, "type")) found_type = true;
                if (std.mem.eql(u8, entry.key.string, "id")) found_id = true;
            }
        }
        try testing.expect(found_type and found_id);
    }
}

// **Property 28: StoreGet field extraction**
// **Validates: Requirements 16.6**
//
// For any StoreGet message, the namespace and path fields should be extractable
// from the MessagePack map.
test "Property 28: StoreGet field extraction" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/store_operations/test_data_property28");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/store_operations/test_data_property28") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        parser,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Basic StoreGet message field extraction
    {
        const message = try msgpack_helpers.createStoreGetMessage(allocator, 1, "test_ns", "/test/path");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);

        // Should be able to route and process (which requires field extraction)
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // If we got a response, fields were extracted successfully
        try testing.expect(response.len > 0);
    }

    // Test 2: StoreGet with various field values
    {
        const test_cases = [_]struct {
            namespace: []const u8,
            path: []const u8,
        }{
            .{ .namespace = "ns1", .path = "/p1" },
            .{ .namespace = "namespace_with_underscores", .path = "/long/nested/path" },
            .{ .namespace = "a", .path = "/" },
            .{ .namespace = "test", .path = "/key" },
        };

        for (test_cases, 0..) |tc, i| {
            const message = try msgpack_helpers.createStoreGetMessage(allocator, @intCast(i), tc.namespace, tc.path);
            defer allocator.free(message);

            const parsed = try parser.parse(message);
            defer parser.freeValue(parsed);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            try testing.expect(response.len > 0);
        }
    }

    // Test 3: StoreGet missing namespace should fail
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack_helpers.writeString(allocator, &buf, "type");
        try msgpack_helpers.writeString(allocator, &buf, "StoreGet");
        try msgpack_helpers.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack_helpers.writeString(allocator, &buf, "path");
        try msgpack_helpers.writeString(allocator, &buf, "/test");

        const message = buf.items;
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 4: StoreGet missing path should fail
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack_helpers.writeString(allocator, &buf, "type");
        try msgpack_helpers.writeString(allocator, &buf, "StoreGet");
        try msgpack_helpers.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack_helpers.writeString(allocator, &buf, "namespace");
        try msgpack_helpers.writeString(allocator, &buf, "test");

        const message = buf.items;
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }
}

// **Property 29: StoreGet storage engine call**
// **Validates: Requirements 16.7**
//
// For any StoreGet message, the Storage Engine get function should be called with
// the extracted parameters.
test "Property 29: StoreGet storage engine call" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/store_operations/test_data_property29");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/store_operations/test_data_property29") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        parser,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreGet should call storage engine get
    {
        // First store a value
        const val_encoded = try msgpack_helpers.encodeString(allocator, "value1");
        defer allocator.free(val_encoded);
        try storage_engine.set("test", "/key1", val_encoded);
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Now get it via message handler
        const message = try msgpack_helpers.createStoreGetMessage(allocator, 1, "test", "/key1");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should contain the value (proving storage engine was called)
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var val: ?[]const u8 = null;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string and std.mem.eql(u8, entry.key.string, "value")) {
                if (entry.value == .string) {
                    val = entry.value.string;
                }
            }
        }
        try testing.expect(val != null);
        try testing.expectEqualStrings("value1", val.?);
    }

    // Test 2: StoreGet for multiple keys
    {
        // Store multiple values
        const test_data = [_]struct {
            namespace: []const u8,
            path: []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = "/k1", .value = "v1" },
            .{ .namespace = "ns1", .path = "/k2", .value = "v2" },
            .{ .namespace = "ns2", .path = "/k1", .value = "v3" },
        };

        for (test_data) |td| {
            const encoded = try msgpack_helpers.encodeString(allocator, td.value);
            defer allocator.free(encoded);
            try storage_engine.set(td.namespace, td.path, encoded);
        }
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Get each value via message handler
        for (test_data, 0..) |td, i| {
            const message = try msgpack_helpers.createStoreGetMessage(allocator, @intCast(i + 10), td.namespace, td.path);
            defer allocator.free(message);

            const parsed = try parser.parse(message);
            defer parser.freeValue(parsed);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            // Response should contain the expected value
            const resp_parsed = try parser.parse(response);
            defer parser.freeValue(resp_parsed);
            try testing.expect(resp_parsed == .map);
            var val: ?[]const u8 = null;
            for (resp_parsed.map) |entry| {
                if (entry.key == .string and std.mem.eql(u8, entry.key.string, "value")) {
                    if (entry.value == .string) {
                        val = entry.value.string;
                    }
                }
            }
            try testing.expect(val != null);
            try testing.expectEqualStrings(td.value, val.?);
        }
    }

    // Test 3: StoreGet for nonexistent key should call storage engine
    {
        const message = try msgpack_helpers.createStoreGetMessage(allocator, 1, "test", "/nonexistent");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Should get a NOT_FOUND response
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var found_not_found = false;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string and std.mem.eql(u8, entry.key.string, "code")) {
                try testing.expectEqualStrings("NOT_FOUND", entry.value.string);
                found_not_found = true;
            }
        }
        try testing.expect(found_not_found);
    }
}

// **Property 30: StoreGet value response**
// **Validates: Requirements 16.8**
//
// For any successful StoreGet operation, a response containing the value should be
// sent to the client.
test "Property 30: StoreGet value response" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/store_operations/test_data_property30");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/store_operations/test_data_property30") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        parser,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreGet should return value in response
    {
        // Store a value
        const val_encoded = try msgpack_helpers.encodeString(allocator, "test_value_123");
        defer allocator.free(val_encoded);
        try storage_engine.set("test", "/key1", val_encoded);
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Get it
        const message = try msgpack_helpers.createStoreGetMessage(allocator, 1, "test", "/key1");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should contain the value
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var found_type = false;
        var found_id = false;
        var val: ?[]const u8 = null;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string) {
                if (std.mem.eql(u8, entry.key.string, "type")) {
                    try testing.expectEqualStrings("ok", entry.value.string);
                    found_type = true;
                } else if (std.mem.eql(u8, entry.key.string, "id")) {
                    try testing.expectEqual(@as(u64, 1), entry.value.unsigned);
                    found_id = true;
                } else if (std.mem.eql(u8, entry.key.string, "value")) {
                    if (entry.value == .string) {
                        val = entry.value.string;
                    }
                }
            }
        }
        try testing.expect(found_type and found_id);
        try testing.expect(val != null);
        try testing.expectEqualStrings("test_value_123", val.?);
    }

    // Test 2: Multiple StoreGet operations should return correct values
    {
        // Store multiple values
        const test_data = [_]struct {
            namespace: []const u8,
            path: []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = "/k1", .value = "value_one" },
            .{ .namespace = "ns1", .path = "/k2", .value = "value_two" },
            .{ .namespace = "ns2", .path = "/k1", .value = "value_three" },
        };

        for (test_data) |td| {
            const encoded = try msgpack_helpers.encodeString(allocator, td.value);
            defer allocator.free(encoded);
            try storage_engine.set(td.namespace, td.path, encoded);
        }
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Get each value and verify response contains it
        for (test_data, 0..) |td, i| {
            const message = try msgpack_helpers.createStoreGetMessage(allocator, @intCast(i + 100), td.namespace, td.path);
            defer allocator.free(message);

            const parsed = try parser.parse(message);
            defer parser.freeValue(parsed);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            // Response should contain the specific value
            const resp_parsed = try parser.parse(response);
            defer parser.freeValue(resp_parsed);
            try testing.expect(resp_parsed == .map);
            var val: ?[]const u8 = null;
            for (resp_parsed.map) |entry| {
                if (entry.key == .string and std.mem.eql(u8, entry.key.string, "value")) {
                    if (entry.value == .string) {
                        val = entry.value.string;
                    }
                }
            }
            try testing.expect(val != null);
            try testing.expectEqualStrings(td.value, val.?);
        }
    }

    // Test 3: StoreGet for nonexistent key should return not found response
    {
        const message = try msgpack_helpers.createStoreGetMessage(allocator, 999, "test", "/does_not_exist");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should indicate not found
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var is_error = false;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string and std.mem.eql(u8, entry.key.string, "type")) {
                if (std.mem.eql(u8, entry.value.string, "error")) is_error = true;
            }
        }
        try testing.expect(is_error);
    }

    // Test 4: Response format should be consistent
    {
        // Store a value
        const val_encoded = try msgpack_helpers.encodeString(allocator, "format_value");
        defer allocator.free(val_encoded);
        try storage_engine.set("format_test", "/key", val_encoded);
        std.Thread.sleep(100 * std.time.ns_per_ms);

        const message = try msgpack_helpers.createStoreGetMessage(allocator, 777, "format_test", "/key");
        defer allocator.free(message);
        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should have expected format
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var found_type = false;
        var found_id = false;
        var found_value = false;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string) {
                if (std.mem.eql(u8, entry.key.string, "type")) found_type = true;
                if (std.mem.eql(u8, entry.key.string, "id")) found_id = true;
                if (std.mem.eql(u8, entry.key.string, "value")) found_value = true;
            }
        }
        try testing.expect(found_type and found_id and found_value);
    }
}
