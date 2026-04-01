const std = @import("std");
const testing = std.testing;

const storage_mod = @import("storage_engine.zig");
const helpers = @import("message_handler_test_helpers.zig");
const createMockWebSocket = helpers.createMockWebSocket;
const AppTestContext = helpers.AppTestContext;
const routeWithArena = helpers.routeWithArena;
const msgpack = @import("msgpack_test_helpers.zig");

// Task 14 Verification: WebSocket connection lifecycle
test "Verification: WebSocket connection lifecycle" {
    const allocator = testing.allocator;
    var app = try AppTestContext.init(allocator, "verification-lifecycle", &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = app.manager;

    // Test connection open
    var ws = createMockWebSocket();
    try manager.onOpen(&ws);
    // Explicit close for middle-test state verification, plus defer for early failures
    var closed = false;
    defer if (!closed) manager.onClose(&ws, 1000, "Cleanup");

    const conn_id = ws.getConnId();
    try testing.expect(conn_id > 0);

    // Verify connection exists in manager
    const state = try manager.acquireConnection(conn_id);
    defer if (state.release()) app.memory_strategy.releaseConnection(state);
    try testing.expectEqual(conn_id, state.id);
    try testing.expectEqualStrings("default", state.namespace);

    // Test connection close
    manager.onClose(&ws, 1000, "Normal closure");
    closed = true;

    // Verify connection was removed
    const result = manager.acquireConnection(conn_id);
    if (result) |s| {
        _ = s.release();
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(error.ConnectionNotFound, err);
    }
}

// Task 14 Verification: StoreSet message processing
test "Verification: StoreSet message processing" {
    const allocator = testing.allocator;

    var app = try AppTestContext.init(allocator, "verification-storeset", &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = app.handler;
    const manager = app.manager;
    const storage_engine = app.storage_engine;

    // Create a proper MessagePack StoreSet message
    const message = try msgpack.createStoreSetMessage(
        allocator,
        1,
        "test_namespace",
        &[_][]const u8{ "data_table", "key", "val" },
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
    try manager.onOpen(&ws);
    defer manager.onClose(&ws, 1000, "Normal closure");

    const conn = try manager.acquireConnection(ws.getConnId());
    defer if (conn.release()) app.memory_strategy.releaseConnection(conn);
    const response_copy = try routeWithArena(handler, allocator, conn, msg_info, parsed);
    defer allocator.free(response_copy);

    // Verify response indicates success
    var resp_reader: std.Io.Reader = .fixed(response_copy);
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
    var managed = try storage_engine.selectDocument(allocator, "data_table", "key", "test_namespace");
    defer managed.deinit();
    const stored_doc = managed.value;

    // Value is stored as MessagePack-serialized, but selectDocument decodes it
    if (stored_doc) |doc| {
        const val_payload = (try doc.mapGet("val")) orelse return error.ValueNotFound;
        try testing.expectEqualStrings("test_value", val_payload.str.value());
    } else {
        return error.DocumentNotFound;
    }
}

// Task 14 Verification: StoreQuery message processing
test "Verification: StoreQuery message processing" {
    const allocator = testing.allocator;

    var app = try AppTestContext.init(allocator, "verification-storequery", &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = app.handler;
    const manager = app.manager;
    const storage_engine = app.storage_engine;

    // First, store a value (typed storage)
    const val_payload = try msgpack.Payload.strToPayload("stored_value", allocator);
    defer val_payload.free(allocator);
    const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = val_payload }};
    try storage_engine.insertOrReplace("data_table", "key", "test_namespace", &cols);
    try storage_engine.flushPendingWrites();

    // Create a filter: { "conditions": [ ["id", 0, "key"] ] }
    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);

    var conds_arr = try allocator.alloc(msgpack.Payload, 1);
    var cond_arr = try allocator.alloc(msgpack.Payload, 3);
    cond_arr[0] = try msgpack.Payload.strToPayload("id", allocator);
    cond_arr[1] = msgpack.Payload.uintToPayload(0); // eq
    cond_arr[2] = try msgpack.Payload.strToPayload("key", allocator);
    conds_arr[0] = msgpack.Payload{ .arr = cond_arr };
    try filter_map.mapPut("conditions", msgpack.Payload{ .arr = conds_arr });

    // Create a StoreQuery message
    const message = try msgpack.createStoreQueryMessage(
        allocator,
        2,
        "test_namespace",
        "data_table",
        filter_map,
    );
    defer allocator.free(message);

    // Parse the message
    var reader: std.Io.Reader = .fixed(message);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    // Extract message info
    const msg_info = try handler.extractMessageInfo(parsed);
    try testing.expectEqualStrings("StoreQuery", msg_info.type);
    try testing.expectEqual(@as(u64, 2), msg_info.id);

    // Route and process the message
    var ws = createMockWebSocket();
    try manager.onOpen(&ws);
    defer manager.onClose(&ws, 1000, "Normal closure");

    const conn = try manager.acquireConnection(ws.getConnId());
    defer if (conn.release()) app.memory_strategy.releaseConnection(conn);
    const response_copy = try routeWithArena(handler, allocator, conn, msg_info, parsed);
    defer allocator.free(response_copy);

    // Verify response contains the value
    var resp_reader: std.Io.Reader = .fixed(response_copy);
    const resp_parsed = try msgpack.decode(allocator, &resp_reader);
    defer resp_parsed.free(allocator);

    try testing.expect(resp_parsed == .map);
    var found_type = false;
    var found_value = false;
    var rit = resp_parsed.map.iterator();
    while (rit.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (key == .str) {
            const key_str = key.str.value();
            if (std.mem.eql(u8, key_str, "type")) {
                try testing.expectEqualStrings("StoreQueryResponse", val.str.value());
                found_type = true;
            } else if (std.mem.eql(u8, key_str, "value")) {
                try testing.expect(val == .arr);
                try testing.expectEqual(@as(usize, 1), val.arr.len);
                const doc = val.arr[0];
                try testing.expect(doc == .map);
                const v_payload = msgpack.getMapValue(doc, "val") orelse return error.TestExpectedError;
                try testing.expectEqualStrings("stored_value", v_payload.str.value());
                found_value = true;
            }
        }
    }
    try testing.expect(found_type and found_value);
}

// Task 14 Verification: Error handling for invalid messages
test "Verification: Error handling for invalid messages" {
    const allocator = testing.allocator;

    var app = try AppTestContext.init(allocator, "verification-errors", &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = app.handler;
    const manager = app.manager;

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
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        const text_message = "text message";

        // Should handle error gracefully (not crash) and reject by returning early
        // from manager.onMessage due to non-binary type.
        manager.onMessage(&ws, text_message, .text);
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

        var ws = createMockWebSocket();
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");
        const conn = try manager.acquireConnection(ws.getConnId());
        defer if (conn.release()) app.memory_strategy.releaseConnection(conn);

        const result = routeWithArena(handler, allocator, conn, msg_info, parsed);
        try testing.expectError(error.UnknownMessageType, result);
    }
}

// Task 14 Verification: End-to-end message flow
test "Verification: End-to-end StoreSet and StoreQuery flow" {
    const allocator = testing.allocator;

    var app = try AppTestContext.init(allocator, "verification-e2e", &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = app.handler;
    const manager = app.manager;
    const storage_engine = app.storage_engine;

    // Open a connection
    var ws = createMockWebSocket();
    try manager.onOpen(&ws);
    defer manager.onClose(&ws, 1000, "Normal closure");

    const conn = try manager.acquireConnection(ws.getConnId());
    defer if (conn.release()) app.memory_strategy.releaseConnection(conn);

    // Store multiple values
    const test_data = [_]struct {
        namespace: []const u8,
        id: []const u8,
        value: []const u8,
    }{
        .{ .namespace = "app", .id = "user1", .value = "Alice" },
        .{ .namespace = "app", .id = "user2", .value = "Bob" },
        .{ .namespace = "config", .id = "theme", .value = "dark" },
    };

    for (test_data, 0..) |td, i| {
        {
            const set_message = try msgpack.createStoreSetMessage(
                allocator,
                i + 1,
                td.namespace,
                &[_][]const u8{ "data_table", td.id, "val" },
                td.value,
            );
            defer allocator.free(set_message);

            var reader_set: std.Io.Reader = .fixed(set_message);
            const parsed = try msgpack.decode(allocator, &reader_set);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response_copy = try routeWithArena(handler, allocator, conn, msg_info, parsed);
            defer allocator.free(response_copy);

            // Verify success response
            var resp_reader_any: std.Io.Reader = .fixed(response_copy);
            const resp_parsed = try msgpack.decode(allocator, &resp_reader_any);
            defer resp_parsed.free(allocator);

            const msg_type = msgpack.getMapValue(resp_parsed, "type") orelse return error.TestExpectedError;
            try testing.expectEqualStrings("ok", msg_type.str.value());
        }
    }

    // Wait for writes to complete
    try storage_engine.flushPendingWrites();

    // Retrieve all values
    for (test_data, 0..) |td, i| {
        {
            // Create a filter: { "conditions": [ ["id", 0, td.id] ] }
            var filter_map = msgpack.Payload.mapPayload(allocator);
            defer filter_map.free(allocator);

            var conds_arr = try allocator.alloc(msgpack.Payload, 1);
            var cond_arr = try allocator.alloc(msgpack.Payload, 3);
            cond_arr[0] = try msgpack.Payload.strToPayload("id", allocator);
            cond_arr[1] = msgpack.Payload.uintToPayload(0); // eq
            cond_arr[2] = try msgpack.Payload.strToPayload(td.id, allocator);
            conds_arr[0] = msgpack.Payload{ .arr = cond_arr };
            try filter_map.mapPut("conditions", msgpack.Payload{ .arr = conds_arr });

            const query_message = try msgpack.createStoreQueryMessage(
                allocator,
                i + 100,
                td.namespace,
                "data_table",
                filter_map,
            );
            defer allocator.free(query_message);

            var reader: std.Io.Reader = .fixed(query_message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response_copy = try routeWithArena(handler, allocator, conn, msg_info, parsed);
            defer allocator.free(response_copy);

            // Verify response contains the value
            var resp_reader: std.Io.Reader = .fixed(response_copy);
            const resp_parsed = try msgpack.decode(allocator, &resp_reader);
            defer resp_parsed.free(allocator);
            try testing.expect(resp_parsed == .map);

            const results = msgpack.getMapValue(resp_parsed, "value") orelse return error.TestExpectedError;
            try testing.expect(results == .arr);
            try testing.expect(@as(usize, 1) <= results.arr.len);

            var found = false;
            for (results.arr) |doc| {
                const id_payload = msgpack.getMapValue(doc, "id") orelse continue;
                if (std.mem.eql(u8, id_payload.str.value(), td.id)) {
                    const val_payload = msgpack.getMapValue(doc, "val") orelse return error.TestExpectedError;
                    try testing.expectEqualStrings(td.value, val_payload.str.value());
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
    }

    // Also verify directly in storage engine
    for (test_data) |td| {
        var managed = try storage_engine.selectDocument(allocator, "data_table", td.id, td.namespace);
        defer managed.deinit();
        const stored_doc = managed.value;
        try testing.expect(stored_doc != null);
        const doc = stored_doc.?;

        const got_val = (try doc.mapGet("val")) orelse return error.MissingValue;
        try testing.expectEqualStrings(td.value, got_val.str.value());
    }
}

// Regression Test for Message Handler Double-Free in StoreSubscribe
test "Verification: StoreSubscribe message processing" {
    const allocator = testing.allocator;

    var app = try AppTestContext.init(allocator, "verification-storesubscribe", &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = app.handler;
    const manager = app.manager;
    const storage_engine = app.storage_engine;

    // 1. Store a value
    const val_payload = try msgpack.Payload.strToPayload("stored_value", allocator);
    defer val_payload.free(allocator);
    const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = val_payload }};
    try storage_engine.insertOrReplace("data_table", "key", "test_namespace", &cols);
    try storage_engine.flushPendingWrites();

    // 2. Create a StoreSubscribe message
    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);
    var conds_arr = try allocator.alloc(msgpack.Payload, 1);
    var cond_arr = try allocator.alloc(msgpack.Payload, 3);
    cond_arr[0] = try msgpack.Payload.strToPayload("id", allocator);
    cond_arr[1] = msgpack.Payload.uintToPayload(0); // eq
    cond_arr[2] = try msgpack.Payload.strToPayload("key", allocator);
    conds_arr[0] = msgpack.Payload{ .arr = cond_arr };
    try filter_map.mapPut("conditions", msgpack.Payload{ .arr = conds_arr });

    const message = try msgpack.createStoreSubscribeMessage(
        allocator,
        3,
        "test_namespace",
        "data_table",
        filter_map,
        12345,
    );
    defer allocator.free(message);

    // 3. Parse the message
    var reader: std.Io.Reader = .fixed(message);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    const msg_info = try handler.extractMessageInfo(parsed);

    // 4. Route and process the message
    var ws = createMockWebSocket();
    try manager.onOpen(&ws);
    defer manager.onClose(&ws, 1000, "Normal closure");

    const conn = try manager.acquireConnection(ws.getConnId());
    defer if (conn.release()) app.memory_strategy.releaseConnection(conn);

    // Use an arena for routing to avoid leaks of the response map and its contents
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result_raw = try handler.routeMessage(arena.allocator(), conn, msg_info, parsed);
    const response = try allocator.dupe(u8, result_raw);
    defer allocator.free(response);

    // 5. Verify response payload
    var resp_reader: std.Io.Reader = .fixed(response);
    const resp_parsed = try msgpack.decode(allocator, &resp_reader);
    defer resp_parsed.free(allocator);

    try testing.expect(resp_parsed == .map);
    const msg_type = msgpack.getMapValue(resp_parsed, "type") orelse return error.TestExpectedError;
    try testing.expectEqualStrings("StoreSubscribeResponse", msg_type.str.value());

    const results_p = msgpack.getMapValue(resp_parsed, "value") orelse return error.TestExpectedError;
    try testing.expect(results_p == .arr);
    try testing.expectEqual(@as(usize, 1), results_p.arr.len);
    
    const doc = results_p.arr[0];
    const got_val = msgpack.getMapValue(doc, "val") orelse return error.TestExpectedError;
    try testing.expectEqualStrings("stored_value", got_val.str.value());
}
