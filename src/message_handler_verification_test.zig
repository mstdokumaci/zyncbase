const std = @import("std");
const testing = std.testing;

const MessageHandler = @import("message_handler.zig").MessageHandler;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const it_storage_mod = @import("storage_engine.zig");
const storage_mod = it_storage_mod;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const msgpack = @import("msgpack_test_helpers.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

var next_mock_ws_id = std.atomic.Value(u64).init(1);

// Helper function to create a mock WebSocket for testing
fn createMockWebSocket() WebSocket {
    return WebSocket{
        .ws = null,
        .ssl = false,
        .user_data = @ptrFromInt(next_mock_ws_id.fetchAdd(1, .monotonic)),
    };
}

// Task 14 Verification: WebSocket connection lifecycle
test "Verification: WebSocket connection lifecycle" {
    const allocator = testing.allocator;

    // Initialize all required components
    const violation_tracker = try allocator.create(ViolationTracker);
    violation_tracker.* = ViolationTracker.init(allocator, 3);
    defer {
        violation_tracker.deinit();
        allocator.destroy(violation_tracker);
    }

    var context = try schema_helpers.TestContext.init(allocator, "verification-lifecycle");
    defer context.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const storage_engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer storage_engine.deinit(); // Note: context.deinit() handles directory cleanup

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator, .{});
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        violation_tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test connection open
    var ws = createMockWebSocket();
    try handler.handleOpen(&ws);

    const conn_id = ws.getConnId();
    try testing.expect(conn_id > 0);

    // Verify connection exists in registry
    const state = try handler.connection_registry.acquireConnection(conn_id);
    defer state.release(allocator);
    try testing.expectEqual(conn_id, state.id);
    try testing.expectEqualStrings("default", state.namespace);

    // Test connection close
    try handler.handleClose(&ws, 1000, "Normal closure");

    // Verify connection was removed
    const result = handler.connection_registry.acquireConnection(conn_id);
    if (result) |s| {
        s.release(allocator);
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(error.ConnectionNotFound, err);
    }
}

// Task 14 Verification: StoreSet message processing
test "Verification: StoreSet message processing" {
    const allocator = testing.allocator;

    const violation_tracker = try allocator.create(ViolationTracker);
    violation_tracker.* = ViolationTracker.init(allocator, 3);
    defer {
        violation_tracker.deinit();
        allocator.destroy(violation_tracker);
    }

    var context = try schema_helpers.TestContext.init(allocator, "verification-storeset");
    defer context.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const storage_engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer storage_engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator, .{});
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        violation_tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Create a proper MessagePack StoreSet message
    const message = try msgpack.createStoreSetMessage(
        allocator,
        1,
        "test_namespace",
        &[_][]const u8{ "data_table", "key" },
        "test_value",
    );
    defer allocator.free(message);

    // Parse the message
    var reader: std.Io.Reader = .fixed(message);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    // Extract message info
    const msg_info = try handler.extractMessageInfo(parsed);
    try testing.expectEqualStrings("StoreSet", msg_info.type);
    try testing.expectEqual(@as(u64, 1), msg_info.id);

    // Route and process the message
    var ws = createMockWebSocket();
    try handler.handleOpen(&ws);
    defer handler.handleClose(&ws, 1000, "Normal closure") catch {}; // zwanzig-disable-line: empty-catch-engine

    const conn_id = ws.getConnId();
    const response = try handler.routeMessage(conn_id, msg_info, parsed);
    defer allocator.free(response);

    // Verify response indicates success
    var resp_reader: std.Io.Reader = .fixed(response);
    const resp_parsed = try msgpack.decode(allocator, &resp_reader);
    defer resp_parsed.free(allocator);

    try testing.expect(resp_parsed == .map);
    var found_type = false;
    var found_id = false;
    var it = resp_parsed.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (key == .str) {
            const key_str = key.str.value();
            if (std.mem.eql(u8, key_str, "type")) {
                try testing.expectEqualStrings("ok", val.str.value());
                found_type = true;
            } else if (std.mem.eql(u8, key_str, "id")) {
                try testing.expectEqual(@as(u64, 1), val.uint);
                found_id = true;
            }
        }
    }
    try testing.expect(found_type and found_id);

    // Wait for write to complete
    try storage_engine.flushPendingWrites();

    // Verify data was stored
    const stored_doc = try storage_engine.selectDocument("data_table", "key", "test_namespace");
    defer if (stored_doc) |d| d.free(std.testing.allocator);

    // Value is stored as MessagePack-serialized, but selectDocument decodes it
    if (stored_doc) |doc| {
        const val_payload = (try doc.mapGet("val")) orelse return error.ValueNotFound;
        try testing.expectEqualStrings("test_value", val_payload.str.value());
    } else {
        return error.DocumentNotFound;
    }
}

// Task 14 Verification: StoreGet message processing
test "Verification: StoreGet message processing" {
    const allocator = testing.allocator;

    const violation_tracker = try allocator.create(ViolationTracker);
    violation_tracker.* = ViolationTracker.init(allocator, 3);
    defer {
        violation_tracker.deinit();
        allocator.destroy(violation_tracker);
    }

    var context = try schema_helpers.TestContext.init(allocator, "verification-storeget");
    defer context.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const storage_engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer storage_engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator, .{});
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        violation_tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // First, store a value (typed storage)
    const val_payload = try msgpack.Payload.strToPayload("stored_value", allocator);
    defer val_payload.free(allocator); // Fix leak
    const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = val_payload }};
    try storage_engine.insertOrReplace("data_table", "key", "test_namespace", &cols);
    try storage_engine.flushPendingWrites();

    // Create a proper MessagePack StoreGet message with array path
    const message = try msgpack.createStoreGetMessage(
        allocator,
        2,
        "test_namespace",
        &.{ "data_table", "key", "val" },
    );
    defer allocator.free(message);

    // Parse the message
    var reader: std.Io.Reader = .fixed(message);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    // Extract message info
    const msg_info = try handler.extractMessageInfo(parsed);
    try testing.expectEqualStrings("StoreGet", msg_info.type);
    try testing.expectEqual(@as(u64, 2), msg_info.id);

    // Route and process the message
    var ws = createMockWebSocket();
    try handler.handleOpen(&ws);
    defer handler.handleClose(&ws, 1000, "Normal closure") catch {}; // zwanzig-disable-line: empty-catch-engine

    const conn_id = ws.getConnId();
    const response = try handler.routeMessage(conn_id, msg_info, parsed);
    defer allocator.free(response);

    // Verify response contains the value
    var resp_reader: std.Io.Reader = .fixed(response);
    const resp_parsed = try msgpack.decode(allocator, &resp_reader);
    defer resp_parsed.free(allocator);

    try testing.expect(resp_parsed == .map);
    var found_type = false;
    var found_id = false;
    var found_value = false;
    var it = resp_parsed.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (key == .str) {
            const key_str = key.str.value();
            if (std.mem.eql(u8, key_str, "type")) {
                try testing.expectEqualStrings("ok", val.str.value());
                found_type = true;
            } else if (std.mem.eql(u8, key_str, "id")) {
                try testing.expectEqual(@as(u64, 2), val.uint);
                found_id = true;
            } else if (std.mem.eql(u8, key_str, "value")) {
                if (val == .str) {
                    try testing.expectEqualStrings("stored_value", val.str.value());
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

    const violation_tracker = try allocator.create(ViolationTracker);
    violation_tracker.* = ViolationTracker.init(allocator, 3);
    defer {
        violation_tracker.deinit();
        allocator.destroy(violation_tracker);
    }

    var context = try schema_helpers.TestContext.init(allocator, "verification-errors");
    defer context.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const storage_engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer storage_engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator, .{});
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        violation_tracker,
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
        var reader_invalid: std.Io.Reader = .fixed(invalid_message);
        const result = msgpack.decode(allocator, &reader_invalid);
        try testing.expectError(error.EndOfStream, result);
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

        var reader_m: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader_m);
        defer parsed.free(allocator);

        // Should fail to extract message info (missing id)
        const result = handler.extractMessageInfo(parsed);
        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 3: Text messages should be rejected
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {}; // zwanzig-disable-line: empty-catch-engine

        const text_message = "text message";

        // Should handle error gracefully (not crash)
        handler.handleMessage(&ws, text_message, .text) catch {}; // zwanzig-disable-line: empty-catch-engine
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

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);

        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);
        try testing.expectError(error.UnknownMessageType, result);
    }
}

// Task 14 Verification: End-to-end message flow
test "Verification: End-to-end StoreSet and StoreGet flow" {
    const allocator = testing.allocator;

    const violation_tracker = try allocator.create(ViolationTracker);
    violation_tracker.* = ViolationTracker.init(allocator, 3);
    defer {
        violation_tracker.deinit();
        allocator.destroy(violation_tracker);
    }

    var context = try schema_helpers.TestContext.init(allocator, "verification-e2e");
    defer context.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const storage_engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer storage_engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator, .{});
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        violation_tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Open a connection
    var ws = createMockWebSocket();
    try handler.handleOpen(&ws);
    defer handler.handleClose(&ws, 1000, "Normal closure") catch {}; // zwanzig-disable-line: empty-catch-engine

    const conn_id = ws.getConnId();

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
        const set_message = try msgpack.createStoreSetMessage(
            allocator,
            i + 1,
            td.namespace,
            &[_][]const u8{ "data_table", td.path },
            td.value,
        );
        defer allocator.free(set_message);

        var reader_set: std.Io.Reader = .fixed(set_message);
        const parsed = try msgpack.decode(allocator, &reader_set);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(conn_id, msg_info, parsed);
        defer allocator.free(response);

        // Verify success response
        var resp_reader_any: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &resp_reader_any);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var found_ok = false;
        var rit = resp_parsed.map.iterator();
        while (rit.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key == .str and std.mem.eql(u8, key.str.value(), "type")) {
                try testing.expectEqualStrings("ok", val.str.value());
                found_ok = true;
            }
        }
        try testing.expect(found_ok);
    }

    // Wait for writes to complete
    try storage_engine.flushPendingWrites();

    // Retrieve all values
    for (test_data, 0..) |td, i| {
        const get_message = try msgpack.createStoreGetMessage(
            allocator,
            i + 100,
            td.namespace,
            &.{ "data_table", td.path, "val" },
        );
        defer allocator.free(get_message);

        var reader: std.Io.Reader = .fixed(get_message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(conn_id, msg_info, parsed);
        defer allocator.free(response);

        // Verify response contains the value
        var resp_reader: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var val: ?[]const u8 = null;
        var rit = resp_parsed.map.iterator();
        while (rit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key == .str and std.mem.eql(u8, key.str.value(), "value")) {
                val = entry.value_ptr.*.str.value();
            }
        }
        try testing.expect(val != null);
        try testing.expectEqualStrings(td.value, val.?);

        // Also verify directly in storage engine
        const stored_doc = try storage_engine.selectDocument("data_table", td.path, td.namespace);
        defer if (stored_doc) |d| d.free(allocator);
        try testing.expect(stored_doc != null);

        const k_payload = try msgpack.Payload.strToPayload("val", allocator);
        defer k_payload.free(allocator);
        const val_field = stored_doc.?.map.get(k_payload);
        try testing.expect(val_field != null);
        try testing.expectEqualStrings(td.value, val_field.?.str.value());
    }
}
