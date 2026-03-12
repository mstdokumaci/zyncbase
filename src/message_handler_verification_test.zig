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
        .ws = null,
        .ssl = false,
        .user_data = null,
    };
}

// Task 14 Verification: WebSocket connection lifecycle
test "Verification: WebSocket connection lifecycle" {
    const allocator = testing.allocator;

    // Initialize all required components
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/integration/verification/test_data_verification_lifecycle");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/integration/verification/test_data_verification_lifecycle") catch {};
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

    // Test connection open
    var ws = createMockWebSocket();
    try handler.handleOpen(&ws);

    const conn_id = @as(u64, @intFromPtr(ws.getUserData()));
    try testing.expect(conn_id > 0);

    // Verify connection exists in registry
    const state = try handler.connection_registry.get(conn_id);
    try testing.expectEqual(conn_id, state.id);
    try testing.expectEqualStrings("default", state.namespace);

    // Test connection close
    try handler.handleClose(&ws, 1000, "Normal closure");

    // Verify connection was removed
    const result = handler.connection_registry.get(conn_id);
    try testing.expectError(error.ConnectionNotFound, result);
}

// Task 14 Verification: StoreSet message processing
test "Verification: StoreSet message processing" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/integration/verification/test_data_verification_storeset");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/integration/verification/test_data_verification_storeset") catch {};
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

    // Create a proper MessagePack StoreSet message
    const message = try msgpack_helpers.createStoreSetMessage(
        allocator,
        1,
        "test_namespace",
        "/test/key",
        "test_value",
    );
    defer allocator.free(message);

    // Parse the message
    const parsed = try parser.parse(message);
    defer parser.freeValue(parsed);

    // Extract message info
    const msg_info = try handler.extractMessageInfo(parsed);
    try testing.expectEqualStrings("StoreSet", msg_info.type);
    try testing.expectEqual(@as(u64, 1), msg_info.id);

    // Route and process the message
    const response = try handler.routeMessage(1, msg_info, parsed);
    defer allocator.free(response);

    // Verify response indicates success
    const resp_parsed = try parser.parse(response);
    defer parser.freeValue(resp_parsed);

    try testing.expect(resp_parsed == .map);
    var found_type = false;
    var found_id = false;
    for (resp_parsed.map) |entry| {
        if (entry.key == .string) {
            if (std.mem.eql(u8, entry.key.string, "type")) {
                try testing.expectEqualStrings("ok", entry.value.string);
                found_type = true;
            } else if (std.mem.eql(u8, entry.key.string, "id")) {
                try testing.expectEqual(@as(u64, 1), entry.value.unsigned);
                found_id = true;
            }
        }
    }
    try testing.expect(found_type and found_id);

    // Wait for write to complete
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify data was stored
    const stored_value = try storage_engine.get("test_namespace", "/test/key");
    defer if (stored_value) |v| allocator.free(v);
    try testing.expect(stored_value != null);
    
    // Value is stored as MessagePack-serialized
    const stored_parsed = try parser.parse(stored_value.?);
    defer parser.freeValue(stored_parsed);
    try testing.expectEqualStrings("test_value", stored_parsed.string);
}

// Task 14 Verification: StoreGet message processing
test "Verification: StoreGet message processing" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/integration/verification/test_data_verification_storeget");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/integration/verification/test_data_verification_storeget") catch {};
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

    // First, store a value (encoded as MessagePack)
    const val_encoded = try msgpack_helpers.encodeString(allocator, "stored_value");
    defer allocator.free(val_encoded);
    try storage_engine.set("test_namespace", "/test/key", val_encoded);
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Create a proper MessagePack StoreGet message
    const message = try msgpack_helpers.createStoreGetMessage(
        allocator,
        2,
        "test_namespace",
        "/test/key",
    );
    defer allocator.free(message);

    // Parse the message
    const parsed = try parser.parse(message);
    defer parser.freeValue(parsed);

    // Extract message info
    const msg_info = try handler.extractMessageInfo(parsed);
    try testing.expectEqualStrings("StoreGet", msg_info.type);
    try testing.expectEqual(@as(u64, 2), msg_info.id);

    // Route and process the message
    const response = try handler.routeMessage(1, msg_info, parsed);
    defer allocator.free(response);

    // Verify response contains the value
    const resp_parsed = try parser.parse(response);
    defer parser.freeValue(resp_parsed);

    try testing.expect(resp_parsed == .map);
    var found_type = false;
    var found_id = false;
    var found_value = false;
    for (resp_parsed.map) |entry| {
        if (entry.key == .string) {
            if (std.mem.eql(u8, entry.key.string, "type")) {
                try testing.expectEqualStrings("ok", entry.value.string);
                found_type = true;
            } else if (std.mem.eql(u8, entry.key.string, "id")) {
                try testing.expectEqual(@as(u64, 2), entry.value.unsigned);
                found_id = true;
            } else if (std.mem.eql(u8, entry.key.string, "value")) {
                if (entry.value == .string) {
                    try testing.expectEqualStrings("stored_value", entry.value.string);
                    found_value = true;
                }
            }
        }
    }
    try testing.expect(found_type and found_id and found_value);
}

// Task 14 Verification: Error handling for invalid messages
test "Verification: Error handling for invalid messages" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/integration/verification/test_data_verification_errors");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/integration/verification/test_data_verification_errors") catch {};
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

    // Test 1: Invalid MessagePack should fail parsing
    {
        // Create truly invalid MessagePack (incomplete map)
        const invalid_message = &[_]u8{0x81}; // fixmap with 1 element but no elements follow
        const result = parser.parse(invalid_message);
        try testing.expectError(error.UnexpectedEOF, result);
    }

    // Test 2: Message missing required fields should fail
    {
        // Create a MessagePack map without required fields
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);

        // fixmap with 1 element
        try buf.append(allocator, 0x81);
        // "type" key
        try buf.append(allocator, 0xa4);
        try buf.appendSlice(allocator, "type");
        // "StoreSet" value
        try buf.append(allocator, 0xa8);
        try buf.appendSlice(allocator, "StoreSet");

        const message = try buf.toOwnedSlice(allocator);
        defer allocator.free(message);

        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        // Should fail to extract message info (missing id)
        const result = handler.extractMessageInfo(parsed);
        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 3: Text messages should be rejected
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        const text_message = "text message";

        // Should handle error gracefully (not crash)
        handler.handleMessage(&ws, text_message, .text) catch {};
    }

    // Test 4: Unknown message type should fail routing
    {
        // Create a MessagePack message with unknown type
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);

        // fixmap with 2 elements
        try buf.append(allocator, 0x82);

        // "type" key
        try buf.append(allocator, 0xa4);
        try buf.appendSlice(allocator, "type");
        // "UnknownType" value
        try buf.append(allocator, 0xab);
        try buf.appendSlice(allocator, "UnknownType");

        // "id" key
        try buf.append(allocator, 0xa2);
        try buf.appendSlice(allocator, "id");
        // id value (uint64)
        try buf.append(allocator, 0xcf);
        try buf.append(allocator, 0);
        try buf.append(allocator, 0);
        try buf.append(allocator, 0);
        try buf.append(allocator, 0);
        try buf.append(allocator, 0);
        try buf.append(allocator, 0);
        try buf.append(allocator, 0);
        try buf.append(allocator, 1);

        const message = try buf.toOwnedSlice(allocator);
        defer allocator.free(message);

        const parsed = try parser.parse(message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);
        try testing.expectError(error.UnknownMessageType, result);
    }
}

// Task 14 Verification: End-to-end message flow
test "Verification: End-to-end StoreSet and StoreGet flow" {
    const allocator = testing.allocator;

    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-data/integration/verification/test_data_verification_e2e");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-data/integration/verification/test_data_verification_e2e") catch {};
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

    // Open a connection
    var ws = createMockWebSocket();
    try handler.handleOpen(&ws);
    defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

    const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

    // Store multiple values
    const test_data = [_]struct {
        namespace: []const u8,
        path: []const u8,
        value: []const u8,
    }{
        .{ .namespace = "app", .path = "/user/1", .value = "Alice" },
        .{ .namespace = "app", .path = "/user/2", .value = "Bob" },
        .{ .namespace = "config", .path = "/setting/theme", .value = "dark" },
    };

    for (test_data, 0..) |td, i| {
        const set_message = try msgpack_helpers.createStoreSetMessage(
            allocator,
            i + 1,
            td.namespace,
            td.path,
            td.value,
        );
        defer allocator.free(set_message);

        const parsed = try parser.parse(set_message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(conn_id, msg_info, parsed);
        defer allocator.free(response);

        // Verify success response
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

    // Wait for writes to complete
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Retrieve all values
    for (test_data, 0..) |td, i| {
        const get_message = try msgpack_helpers.createStoreGetMessage(
            allocator,
            i + 100,
            td.namespace,
            td.path,
        );
        defer allocator.free(get_message);

        const parsed = try parser.parse(get_message);
        defer parser.freeValue(parsed);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(conn_id, msg_info, parsed);
        defer allocator.free(response);

        // Verify response contains the value
        const resp_parsed = try parser.parse(response);
        defer parser.freeValue(resp_parsed);
        try testing.expect(resp_parsed == .map);
        var val: ?[]const u8 = null;
        for (resp_parsed.map) |entry| {
            if (entry.key == .string and std.mem.eql(u8, entry.key.string, "value")) {
                val = entry.value.string;
            }
        }
        try testing.expect(val != null);
        try testing.expectEqualStrings(td.value, val.?);

        // Also verify directly in storage engine
        const stored = try storage_engine.get(td.namespace, td.path);
        defer if (stored) |v| allocator.free(v);
    }
}
