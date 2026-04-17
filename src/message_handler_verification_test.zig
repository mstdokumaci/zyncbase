const std = @import("std");
const testing = std.testing;

const storage_mod = @import("storage_engine.zig");
const helpers = @import("app_test_helpers.zig");
const createMockWebSocket = helpers.createMockWebSocket;
const AppTestContext = helpers.AppTestContext;
const routeWithArena = helpers.routeWithArena;
const msgpack = @import("msgpack_test_helpers.zig");
const query_parser = @import("query_parser.zig");
const tth = @import("typed_test_helpers.zig");
const sth = @import("storage_engine_test_helpers.zig");

const table_defs = [_]helpers.TableDef{
    .{ .name = "_dummy", .fields = &.{"val"} },
    .{ .name = "data_table", .fields = &.{"val"} },
};

// Task 14 Verification: WebSocket connection lifecycle
test "Verification: WebSocket connection lifecycle" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-mixed", &table_defs);
    defer app.deinit();

    // Test connection open
    var ws = createMockWebSocket();
    try app.manager.onOpen(&ws);
    // Explicit close for middle-test state verification, plus defer for early failures
    var closed = false;
    defer if (!closed) app.manager.onClose(&ws, 1000, "Cleanup");

    const conn_id = ws.getConnId();
    try testing.expect(conn_id > 0);

    // Verify connection exists in manager
    const state = try app.manager.acquireConnection(conn_id);
    defer if (state.release()) app.memory_strategy.releaseConnection(state);
    try testing.expectEqual(conn_id, state.id);
    try testing.expectEqualStrings("default", state.namespace);

    // Test connection close
    app.manager.onClose(&ws, 1000, "Normal closure");
    closed = true;

    // Verify connection was removed
    const result = app.manager.acquireConnection(conn_id);
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

    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-basic", &table_defs);
    defer app.deinit();

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

    // Route and process the message
    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;
    const response_copy = try routeWithArena(&app.handler, allocator, conn, parsed);
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
    try app.storage_engine.flushPendingWrites();

    // Verify data was stored
    var managed = try app.storage_engine.selectDocument(allocator, "data_table", "key", "test_namespace");
    defer managed.deinit();
    if (managed.rows.len == 0) return error.DocumentNotFound;
    const doc = managed.rows[0];

    const data_table_md = app.store_service.schema_manager.getTable("data_table") orelse return error.ValueNotFound;
    _ = try sth.expectFieldString(doc, data_table_md, "val", "test_value");
}

// Task 14 Verification: StoreQuery message processing
test "Verification: StoreQuery message processing" {
    const allocator = testing.allocator;

    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-query", &table_defs);
    defer app.deinit();

    // First, store a value (typed storage)
    const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = tth.valText("stored_value"), .field_type = .text }};
    try app.storage_engine.insertOrReplace("data_table", "key", "test_namespace", &cols);
    try app.storage_engine.flushPendingWrites();

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

    // Route and process the message
    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    const response_copy = try routeWithArena(&app.handler, allocator, conn, parsed);
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
                try testing.expectEqualStrings("ok", val.str.value());
                found_type = true;
            } else if (std.mem.eql(u8, key_str, "value")) {
                try testing.expect(val == .arr);
                try testing.expectEqual(@as(usize, 1), val.arr.len);
                const doc = val.arr[0];
                try testing.expect(doc == .map);
                const v_opt = try msgpack.getMapValue(doc, "val");
                const v_payload = v_opt orelse return error.TestExpectedError;
                try testing.expectEqualStrings("stored_value", v_payload.str.value());
                found_value = true;
            }
        }
    }
    try testing.expect(found_type and found_value);
}

test "Verification: StoreQuery includes opaque nextCursor token when more data exists" {
    const allocator = testing.allocator;

    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-query-pagination", &table_defs);
    defer app.deinit();

    // Insert two rows so a limited query must return nextCursor
    const cols_a = [_]storage_mod.ColumnValue{.{ .name = "val", .value = tth.valText("value_a"), .field_type = .text }};
    try app.storage_engine.insertOrReplace("data_table", "doc-a", "test_namespace", &cols_a);

    const cols_b = [_]storage_mod.ColumnValue{.{ .name = "val", .value = tth.valText("value_b"), .field_type = .text }};
    try app.storage_engine.insertOrReplace("data_table", "doc-b", "test_namespace", &cols_b);

    try app.storage_engine.flushPendingWrites();

    // Build filter: orderBy created_at DESC, limit 1
    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);

    var order_tuple = try allocator.alloc(msgpack.Payload, 2);
    order_tuple[0] = try msgpack.Payload.strToPayload("created_at", allocator);
    order_tuple[1] = msgpack.Payload.uintToPayload(1);
    try filter_map.mapPut("orderBy", msgpack.Payload{ .arr = order_tuple });
    try filter_map.mapPut("limit", msgpack.Payload.uintToPayload(1));

    const message = try msgpack.createStoreQueryMessage(
        allocator,
        42,
        "test_namespace",
        "data_table",
        filter_map,
    );
    defer allocator.free(message);

    var reader: std.Io.Reader = .fixed(message);
    const parsed = try msgpack.decode(allocator, &reader);
    defer parsed.free(allocator);

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    const response_copy = try routeWithArena(&app.handler, allocator, conn, parsed);
    defer allocator.free(response_copy);

    var resp_reader: std.Io.Reader = .fixed(response_copy);
    const resp_parsed = try msgpack.decode(allocator, &resp_reader);
    defer resp_parsed.free(allocator);

    const response_type_opt = try msgpack.getMapValue(resp_parsed, "type");
    const response_type = response_type_opt orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", response_type.str.value());

    const value_opt = try msgpack.getMapValue(resp_parsed, "value");
    const value = value_opt orelse return error.TestExpectedError;
    try testing.expect(value == .arr);
    try testing.expectEqual(@as(usize, 1), value.arr.len);

    const next_cursor_opt = try msgpack.getMapValue(resp_parsed, "nextCursor");
    const next_cursor = next_cursor_opt orelse return error.TestExpectedError;
    try testing.expect(next_cursor == .str);
    try testing.expect(next_cursor.str.value().len > 0);

    // Minimal validation to ensure it's a valid protocol token
    const cursor = try query_parser.parseCursorToken(allocator, next_cursor.str.value(), .integer, null);
    defer cursor.deinit(allocator);
    try testing.expect(cursor.id.len > 0);
}

// Task 14 Verification: Error handling for invalid messages
test "Verification: Error handling for invalid messages" {
    const allocator = testing.allocator;

    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-concurrency", &table_defs);
    defer app.deinit();

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
        const sc = try app.setupMockConnection();
        defer sc.deinit();
        const conn = sc.conn;

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

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        // Should fail to extract message info (missing id)
        const result = routeWithArena(&app.handler, allocator, conn, parsed);
        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 3: Text messages should be rejected
    {
        var ws = createMockWebSocket();
        try app.manager.onOpen(&ws);
        defer app.manager.onClose(&ws, 1000, "Normal closure");

        const text_message = "text message";

        // Should handle error gracefully (not crash) and reject by returning early
        // from manager.onMessage due to non-binary type.
        app.manager.onMessage(&ws, text_message, .text);
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

        const sc = try app.setupMockConnection();
        defer sc.deinit();
        const conn = sc.conn;

        const response = try routeWithArena(&app.handler, allocator, conn, parsed);
        defer allocator.free(response);
        const res_parsed = try helpers.parseResponse(allocator, response);
        defer {
            allocator.free(res_parsed.resp_type);
            if (res_parsed.code) |c| allocator.free(c);
        }
        try testing.expectEqualStrings("error", res_parsed.resp_type);
        try testing.expectEqualStrings("INTERNAL_ERROR", res_parsed.code.?);
    }
}

// Task 14 Verification: End-to-end message flow
test "Verification: End-to-end StoreSet and StoreQuery flow" {
    const allocator = testing.allocator;

    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-persistence", &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    // Open a connection
    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

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

            const response_copy = try routeWithArena(&app.handler, allocator, conn, parsed);
            defer allocator.free(response_copy);

            // Verify success response
            var resp_reader_any: std.Io.Reader = .fixed(response_copy);
            const resp_parsed = try msgpack.decode(allocator, &resp_reader_any);
            defer resp_parsed.free(allocator);

            const msg_type_opt = try msgpack.getMapValue(resp_parsed, "type");
            const msg_type = msg_type_opt orelse return error.TestExpectedError;
            try testing.expectEqualStrings("ok", msg_type.str.value());
        }
    }

    // Wait for writes to complete
    try app.storage_engine.flushPendingWrites();

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

            const response_copy = try routeWithArena(&app.handler, allocator, conn, parsed);
            defer allocator.free(response_copy);

            // Verify response contains the value
            var resp_reader: std.Io.Reader = .fixed(response_copy);
            const resp_parsed = try msgpack.decode(allocator, &resp_reader);
            defer resp_parsed.free(allocator);
            try testing.expect(resp_parsed == .map);

            const results_opt = try msgpack.getMapValue(resp_parsed, "value");
            const results = results_opt orelse return error.TestExpectedError;
            try testing.expect(results == .arr);
            try testing.expect(@as(usize, 1) <= results.arr.len);

            var found = false;
            for (results.arr) |doc| {
                const id_opt = try msgpack.getMapValue(doc, "id");
                const id_payload = id_opt orelse continue;
                if (std.mem.eql(u8, id_payload.str.value(), td.id)) {
                    const val_opt = try msgpack.getMapValue(doc, "val");
                    const val_payload = val_opt orelse return error.TestExpectedError;
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
        var managed = try app.storage_engine.selectDocument(allocator, "data_table", td.id, td.namespace);
        defer managed.deinit();
        try testing.expect(managed.rows.len > 0);
        const doc = managed.rows[0];

        const data_table_md = app.store_service.schema_manager.getTable("data_table") orelse return error.MissingValue;
        _ = try sth.expectFieldString(doc, data_table_md, "val", td.value);
    }
}

// Regression Test for Message Handler Double-Free in StoreSubscribe
test "Verification: StoreSubscribe message processing" {
    const allocator = testing.allocator;

    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-subscribe", &table_defs);
    defer app.deinit();

    // 1. Store a value
    const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = tth.valText("stored_value"), .field_type = .text }};
    try app.storage_engine.insertOrReplace("data_table", "key", "test_namespace", &cols);
    try app.storage_engine.flushPendingWrites();

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

    // 4. Route and process the message
    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    const response = try routeWithArena(&app.handler, allocator, conn, parsed);
    defer allocator.free(response);

    // 5. Verify response payload
    var resp_reader: std.Io.Reader = .fixed(response);
    const resp_parsed = try msgpack.decode(allocator, &resp_reader);
    defer resp_parsed.free(allocator);

    try testing.expect(resp_parsed == .map);

    const msg_type_opt = try msgpack.getMapValue(resp_parsed, "type");
    const msg_type = msg_type_opt orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", msg_type.str.value());

    const sub_id_opt = try msgpack.getMapValue(resp_parsed, "subId");
    const sub_id = sub_id_opt orelse return error.TestExpectedError;
    try testing.expect(sub_id == .uint);
    try testing.expect(sub_id.uint > 0);

    const has_more_opt = try msgpack.getMapValue(resp_parsed, "hasMore");
    const has_more = has_more_opt orelse return error.TestExpectedError;
    try testing.expect(has_more == .bool);
    try testing.expectEqual(false, has_more.bool);

    const next_cursor_opt = try msgpack.getMapValue(resp_parsed, "nextCursor");
    const next_cursor = next_cursor_opt orelse return error.TestExpectedError;
    try testing.expect(next_cursor == .nil);

    const results_p_opt = try msgpack.getMapValue(resp_parsed, "value");
    const results_p = results_p_opt orelse return error.TestExpectedError;
    try testing.expect(results_p == .arr);
    try testing.expectEqual(@as(usize, 1), results_p.arr.len);

    const doc = results_p.arr[0];
    const got_val_opt = try msgpack.getMapValue(doc, "val");
    const got_val = got_val_opt orelse return error.TestExpectedError;
    try testing.expectEqualStrings("stored_value", got_val.str.value());
}

test "Verification: StoreLoadMore uses subId and opaque nextCursor token" {
    const allocator = testing.allocator;

    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-loadmore", &table_defs);
    defer app.deinit();

    // Seed two docs so subscribe(limit=1) returns hasMore + nextCursor
    const cols_a = [_]storage_mod.ColumnValue{.{ .name = "val", .value = tth.valText("value_a"), .field_type = .text }};
    try app.storage_engine.insertOrReplace("data_table", "doc-a", "test_namespace", &cols_a);

    const cols_b = [_]storage_mod.ColumnValue{.{ .name = "val", .value = tth.valText("value_b"), .field_type = .text }};
    try app.storage_engine.insertOrReplace("data_table", "doc-b", "test_namespace", &cols_b);

    try app.storage_engine.flushPendingWrites();

    // Build subscribe filter with deterministic sort + limit
    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);

    var order_tuple = try allocator.alloc(msgpack.Payload, 2);
    order_tuple[0] = try msgpack.Payload.strToPayload("created_at", allocator);
    order_tuple[1] = msgpack.Payload.uintToPayload(1); // DESC
    try filter_map.mapPut("orderBy", msgpack.Payload{ .arr = order_tuple });
    try filter_map.mapPut("limit", msgpack.Payload.uintToPayload(1));

    // Subscribe (server will assign subId)
    const subscribe_message = try msgpack.createStoreSubscribeMessage(
        allocator,
        77,
        "test_namespace",
        "data_table",
        filter_map,
        9999,
    );
    defer allocator.free(subscribe_message);

    var subscribe_reader: std.Io.Reader = .fixed(subscribe_message);
    const subscribe_parsed = try msgpack.decode(allocator, &subscribe_reader);
    defer subscribe_parsed.free(allocator);

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    const subscribe_response_copy = try routeWithArena(&app.handler, allocator, conn, subscribe_parsed);
    defer allocator.free(subscribe_response_copy);

    var subscribe_resp_reader: std.Io.Reader = .fixed(subscribe_response_copy);
    const subscribe_resp = try msgpack.decode(allocator, &subscribe_resp_reader);
    defer subscribe_resp.free(allocator);

    const subscribe_type_opt = try msgpack.getMapValue(subscribe_resp, "type");
    const subscribe_type = subscribe_type_opt orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", subscribe_type.str.value());

    const sub_id_payload_opt = try msgpack.getMapValue(subscribe_resp, "subId");
    const sub_id_payload = sub_id_payload_opt orelse return error.TestExpectedError;
    try testing.expect(sub_id_payload == .uint);
    const sub_id = sub_id_payload.uint;

    const next_cursor_payload_opt = try msgpack.getMapValue(subscribe_resp, "nextCursor");
    const next_cursor_payload = next_cursor_payload_opt orelse return error.TestExpectedError;
    try testing.expect(next_cursor_payload == .str);
    const next_cursor = next_cursor_payload.str.value();

    const has_more_payload_opt = try msgpack.getMapValue(subscribe_resp, "hasMore");
    const has_more_payload = has_more_payload_opt orelse return error.TestExpectedError;
    try testing.expect(has_more_payload == .bool);
    try testing.expectEqual(true, has_more_payload.bool);

    // Build StoreLoadMore with { subId, nextCursor }
    var load_more_map = msgpack.Payload.mapPayload(allocator);
    defer load_more_map.free(allocator);
    try load_more_map.mapPut("type", try msgpack.Payload.strToPayload("StoreLoadMore", allocator));
    try load_more_map.mapPut("id", msgpack.Payload.uintToPayload(78));
    try load_more_map.mapPut("subId", msgpack.Payload.uintToPayload(sub_id));
    try load_more_map.mapPut("nextCursor", try msgpack.Payload.strToPayload(next_cursor, allocator));

    var load_buf: std.ArrayList(u8) = .{};
    defer load_buf.deinit(allocator);
    try msgpack.encode(load_more_map, load_buf.writer(allocator));
    const load_more_message = try load_buf.toOwnedSlice(allocator);
    defer allocator.free(load_more_message);

    var load_reader: std.Io.Reader = .fixed(load_more_message);
    const load_parsed = try msgpack.decode(allocator, &load_reader);
    defer load_parsed.free(allocator);

    const load_response_copy = try routeWithArena(&app.handler, allocator, conn, load_parsed);
    defer allocator.free(load_response_copy);

    // Verify response indicates success and returns requested subId
    var load_resp_reader: std.Io.Reader = .fixed(load_response_copy);
    const load_resp = try msgpack.decode(allocator, &load_resp_reader);
    defer load_resp.free(allocator);

    const load_type_opt = try msgpack.getMapValue(load_resp, "type");
    const load_type = load_type_opt orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", load_type.str.value());

    const load_sub_id_opt = try msgpack.getMapValue(load_resp, "subId");
    const load_sub_id = load_sub_id_opt orelse return error.TestExpectedError;
    try testing.expectEqual(sub_id, load_sub_id.uint);

    const load_value_opt = try msgpack.getMapValue(load_resp, "value");
    const load_value = load_value_opt orelse return error.TestExpectedError;
    try testing.expect(load_value == .arr);
    try testing.expectEqual(@as(usize, 1), load_value.arr.len);

    const load_has_more_opt = try msgpack.getMapValue(load_resp, "hasMore");
    const load_has_more = load_has_more_opt orelse return error.TestExpectedError;
    try testing.expect(load_has_more == .bool);
    try testing.expectEqual(false, load_has_more.bool);

    const load_next_cursor_opt = try msgpack.getMapValue(load_resp, "nextCursor");
    const load_next_cursor = load_next_cursor_opt orelse return error.TestExpectedError;
    try testing.expect(load_next_cursor == .nil);
}
