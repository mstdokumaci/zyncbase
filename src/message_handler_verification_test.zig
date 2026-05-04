const std = @import("std");
const testing = std.testing;

const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const createMockWebSocket = helpers.createMockWebSocket;
const routeWithArena = helpers.routeWithArena;
const encodePayloadToBytes = helpers.encodePayloadToBytes;
const msgpack = @import("msgpack_test_helpers.zig");
const store_helpers = @import("store_test_helpers.zig");

const table_defs = [_]helpers.TableDef{
    .{ .name = "_dummy", .fields = &.{"val"} },
    .{ .name = "data_table", .fields = &.{"val"} },
};

test "Verification: WebSocket connection lifecycle" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-mixed", &table_defs);
    defer app.deinit();

    var ws = createMockWebSocket();
    try app.connection_manager.onOpen(&ws);
    var closed = false;
    defer if (!closed) app.connection_manager.onClose(&ws);

    const conn_id = ws.getConnId();
    try testing.expect(conn_id > 0);

    const state = try app.connection_manager.acquireConnection(conn_id);
    defer if (state.release()) app.memory_strategy.releaseConnection(state);
    try testing.expectEqual(conn_id, state.id);
    try testing.expectEqual(@as(i64, -1), state.namespace_id);

    app.connection_manager.onClose(&ws);
    closed = true;

    const removed = app.connection_manager.acquireConnection(conn_id);
    if (removed) |connection| {
        _ = connection.release();
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(error.ConnectionNotFound, err);
    }
}

test "Verification: StoreQuery routes to query response" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-query-route", &table_defs);
    defer app.deinit();

    try app.insertText("data_table", 1, 1, "val", "stored_value");
    try app.storage_engine.flushPendingWrites();

    const table = try app.tableMetadata("data_table");
    const message = try store_helpers.createStoreQueryMessageWithEmptyFilter(allocator, 11, 1, table.index);
    defer allocator.free(message);

    const sc = try app.setupMockConnection();
    defer sc.deinit();

    const response = try routeWithArena(&app.handler, allocator, sc.conn, message);
    defer allocator.free(response);

    var response_reader: std.Io.Reader = .fixed(response);
    const decoded = try msgpack.decode(allocator, &response_reader);
    defer decoded.free(allocator);

    const msg_type = (try msgpack.getMapValue(decoded, "type")) orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", msg_type.str.value());

    const value = (try msgpack.getMapValue(decoded, "value")) orelse return error.TestExpectedError;
    try testing.expect(value == .arr);
    try testing.expectEqual(@as(usize, 1), value.arr.len);
}

test "Verification: Error handling for invalid messages" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-invalid-messages", &table_defs);
    defer app.deinit();

    {
        const invalid_message = &[_]u8{0x81};
        var reader: std.Io.Reader = .fixed(invalid_message);
        const result = msgpack.decode(allocator, &reader);
        try testing.expectError(error.EndOfStream, result);
    }

    {
        var parsed = msgpack.Payload.mapPayload(allocator);
        defer parsed.free(allocator);
        try parsed.mapPut("type", try msgpack.Payload.strToPayload("StoreSet", allocator));

        const sc = try app.setupMockConnection();
        defer sc.deinit();
        const bytes = try encodePayloadToBytes(allocator, parsed);
        defer allocator.free(bytes);
        try testing.expectError(error.MissingRequiredFields, routeWithArena(&app.handler, allocator, sc.conn, bytes));
    }

    {
        var ws = createMockWebSocket();
        try app.connection_manager.onOpen(&ws);
        defer app.connection_manager.onClose(&ws);

        app.connection_manager.onMessage(&ws, "text message", .text);
    }

    {
        var parsed = msgpack.Payload.mapPayload(allocator);
        defer parsed.free(allocator);
        try parsed.mapPut("type", try msgpack.Payload.strToPayload("UnknownType", allocator));
        try parsed.mapPut("id", msgpack.Payload.uintToPayload(1));

        const sc = try app.setupMockConnection();
        defer sc.deinit();

        const bytes = try encodePayloadToBytes(allocator, parsed);
        defer allocator.free(bytes);
        const response = try routeWithArena(&app.handler, allocator, sc.conn, bytes);
        defer allocator.free(response);
        const decoded = try helpers.parseResponse(allocator, response);
        defer allocator.free(decoded.resp_type);
        defer if (decoded.code) |code| allocator.free(code);

        try testing.expectEqualStrings("error", decoded.resp_type);
        try testing.expectEqualStrings("INTERNAL_ERROR", decoded.code.?);
    }
}

test "Verification: StoreLoadMore uses subscription state and returns requested subId" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "verify-loadmore", &table_defs);
    defer app.deinit();

    try app.insertText("data_table", 1, 1, "val", "value_a");
    try app.insertText("data_table", 2, 1, "val", "value_b");
    try app.storage_engine.flushPendingWrites();

    var filter = msgpack.Payload.mapPayload(allocator);
    defer filter.free(allocator);

    const table = try app.tableMetadata("data_table");
    const created_at_index = table.fieldIndex("created_at") orelse return error.UnknownField;
    const order_tuple = try allocator.alloc(msgpack.Payload, 2);
    order_tuple[0] = msgpack.Payload.uintToPayload(created_at_index);
    order_tuple[1] = msgpack.Payload.uintToPayload(1);
    try filter.mapPut("orderBy", msgpack.Payload{ .arr = order_tuple });
    try filter.mapPut("limit", msgpack.Payload.uintToPayload(1));

    const subscribe_message = try store_helpers.createStoreSubscribeMessage(allocator, 77, 1, table.index, filter, 0);
    defer allocator.free(subscribe_message);

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    const subscribe_response = try routeWithArena(&app.handler, allocator, conn, subscribe_message);
    defer allocator.free(subscribe_response);

    var subscribe_response_reader: std.Io.Reader = .fixed(subscribe_response);
    const subscribe_decoded = try msgpack.decode(allocator, &subscribe_response_reader);
    defer subscribe_decoded.free(allocator);

    const subscribe_type = (try msgpack.getMapValue(subscribe_decoded, "type")) orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", subscribe_type.str.value());

    const sub_id_payload = (try msgpack.getMapValue(subscribe_decoded, "subId")) orelse return error.TestExpectedError;
    try testing.expect(sub_id_payload == .uint);
    const sub_id = sub_id_payload.uint;
    try testing.expectEqual(@as(usize, 1), conn.subscription_ids.items.len);
    try testing.expectEqual(sub_id, conn.subscription_ids.items[0]);

    const next_cursor_payload = (try msgpack.getMapValue(subscribe_decoded, "nextCursor")) orelse return error.TestExpectedError;
    try testing.expect(next_cursor_payload == .str);
    const next_cursor = next_cursor_payload.str.value();

    const has_more_payload = (try msgpack.getMapValue(subscribe_decoded, "hasMore")) orelse return error.TestExpectedError;
    try testing.expect(has_more_payload == .bool);
    try testing.expectEqual(true, has_more_payload.bool);

    var load_more = msgpack.Payload.mapPayload(allocator);
    defer load_more.free(allocator);
    try load_more.mapPut("type", try msgpack.Payload.strToPayload("StoreLoadMore", allocator));
    try load_more.mapPut("id", msgpack.Payload.uintToPayload(78));
    try load_more.mapPut("subId", msgpack.Payload.uintToPayload(sub_id));
    try load_more.mapPut("nextCursor", try msgpack.Payload.strToPayload(next_cursor, allocator));

    const load_more_bytes = try encodePayloadToBytes(allocator, load_more);
    defer allocator.free(load_more_bytes);
    const load_response = try routeWithArena(&app.handler, allocator, conn, load_more_bytes);
    defer allocator.free(load_response);

    var load_response_reader: std.Io.Reader = .fixed(load_response);
    const load_decoded = try msgpack.decode(allocator, &load_response_reader);
    defer load_decoded.free(allocator);

    const load_type = (try msgpack.getMapValue(load_decoded, "type")) orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", load_type.str.value());

    const load_sub_id = (try msgpack.getMapValue(load_decoded, "subId")) orelse return error.TestExpectedError;
    try testing.expectEqual(sub_id, load_sub_id.uint);

    const value = (try msgpack.getMapValue(load_decoded, "value")) orelse return error.TestExpectedError;
    try testing.expect(value == .arr);
    try testing.expectEqual(@as(usize, 1), value.arr.len);

    const has_more = (try msgpack.getMapValue(load_decoded, "hasMore")) orelse return error.TestExpectedError;
    try testing.expect(has_more == .bool);
    try testing.expectEqual(false, has_more.bool);
}
