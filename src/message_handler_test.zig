const std = @import("std");
const testing = std.testing;

const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const parseResponse = helpers.parseResponse;
const routeWithArena = helpers.routeWithArena;
const msgpack = @import("msgpack_utils.zig");
const store_helpers = @import("store_test_helpers.zig");
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test "Connection - init and deinit" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-init", &.{});
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const state = sc.conn;

    try testing.expectEqual(sc.ws.getConnId(), state.id);
    try testing.expectEqualStrings(helpers.test_external_user_id, state.getExternalUserId() orelse return error.TestExpectedValue);
    try testing.expectEqual(@as(i64, 1), state.namespace_id);
    try testing.expect(state.store_ready);
    try testing.expectEqual(@as(usize, 0), state.subscription_ids.items.len);
}

test "Connection - add subscription IDs" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-subs", &.{});
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const state = sc.conn;

    try state.subscription_ids.append(state.allocator, 100);
    try state.subscription_ids.append(state.allocator, 200);
    try state.subscription_ids.append(state.allocator, 300);

    try testing.expectEqual(@as(usize, 3), state.subscription_ids.items.len);
    try testing.expectEqual(@as(u64, 100), state.subscription_ids.items[0]);
    try testing.expectEqual(@as(u64, 200), state.subscription_ids.items[1]);
    try testing.expectEqual(@as(u64, 300), state.subscription_ids.items[2]);
}

test "MessageHandler: store operations require ready scope" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "mh-store-not-ready", &.{
        .{ .name = "items", .fields = &.{"value"} },
    });
    defer app.deinit();

    const gpa = app.memory_strategy.generalAllocator();
    const ws = try gpa.create(WebSocket);
    defer gpa.destroy(ws);
    ws.* = helpers.createMockWebSocket(gpa);
    try app.connection_manager.onOpen(ws);
    const conn = try app.connection_manager.acquireConnection(ws.getConnId());
    defer {
        app.connection_manager.onClose(ws);
        if (conn.release()) app.memory_strategy.releaseConnection(conn);
    }

    const table = try app.tableMetadata("items");
    const field_index = table.fieldIndex("value") orelse return error.UnknownField;
    const val = try store_helpers.createDocumentMapPayload(allocator, table, .{
        .{ field_index, "blocked" },
    });
    defer val.free(allocator);
    const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 1, 1, table.index, 1, val);
    defer allocator.free(message);

    const response = try routeWithArena(&app.handler, allocator, conn, message);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |code| allocator.free(code);

    try testing.expectEqualStrings("error", result.resp_type);
    try testing.expectEqualStrings("SESSION_NOT_READY", result.code.?);
}

test "MessageHandler: StoreSet document with auth predicate persists and is readable" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "tasks": { "fields": { "title": { "type": "string" }, "must_be_complete": { "type": "object", "fields": { "before": { "type": "integer" }, "after": { "type": "integer" } } } } }
        \\  }
        \\}
    ;
    try app.initWithSchemaJSON(allocator, "mh-storeset-doc-auth", schema_json);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;
    const table = try app.tableMetadata("tasks");

    // Build a document map payload { title: "hello", must_be_complete__before: 100, must_be_complete__after: 200 }
    const doc_value = try store_helpers.createDocumentMapPayload(allocator, table, .{
        .{ "title", "hello" },
        .{ "must_be_complete__before", @as(i64, 100) },
        .{ "must_be_complete__after", @as(i64, 200) },
    });
    defer doc_value.free(allocator);

    const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 1, 1, table.index, 1, doc_value);
    defer allocator.free(message);

    const response = try routeWithArena(&app.handler, allocator, conn, message);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |code| allocator.free(code);

    try testing.expectEqualStrings("ok", result.resp_type);

    // Flush writes to ensure persistence
    try app.storage_engine.flushPendingWrites();

    // Read back via storage engine
    var managed = try app.storage_engine.selectDocument(allocator, table.index, 1, conn.namespace_id, null);
    defer managed.deinit();
    try testing.expectEqual(@as(usize, 1), managed.records.len);
    try testing.expectEqualStrings("hello", managed.records[0].values[table.fieldIndex("title").?].scalar.text);
    try testing.expectEqual(@as(i64, 100), managed.records[0].values[table.fieldIndex("must_be_complete__before").?].scalar.integer);
    try testing.expectEqual(@as(i64, 200), managed.records[0].values[table.fieldIndex("must_be_complete__after").?].scalar.integer);
}

test "MessageHandler: StoreSet routes and maps StoreService errors" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "items": { "fields": { "tags": { "type": "array", "items": "integer" } } }
        \\  }
        \\}
    ;
    try app.initWithSchemaJSON(allocator, "mh-storeset-route", schema_json);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;
    const table = try app.tableMetadata("items");

    {
        const tags = try allocator.alloc(msgpack.Payload, 2);
        tags[0] = msgpack.Payload.uintToPayload(1);
        tags[1] = msgpack.Payload.uintToPayload(2);
        const tags_val = msgpack.Payload{ .arr = tags };
        defer tags_val.free(allocator);

        const doc_val = try store_helpers.createDocumentMapPayload(allocator, table, .{
            .{ "tags", tags_val },
        });
        defer doc_val.free(allocator);

        const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 1, 1, table.index, 1, doc_val);
        defer allocator.free(message);

        const response = try routeWithArena(&app.handler, allocator, conn, message);
        defer allocator.free(response);
        const result = try parseResponse(allocator, response);
        defer allocator.free(result.resp_type);
        defer if (result.code) |code| allocator.free(code);

        try testing.expectEqualStrings("ok", result.resp_type);
    }

    {
        var inner_map = msgpack.Payload.mapPayload(allocator);
        const items = try allocator.alloc(msgpack.Payload, 1);
        items[0] = inner_map;
        inner_map = .nil;
        const tags_val = msgpack.Payload{ .arr = items };
        defer tags_val.free(allocator);

        const doc_val = try store_helpers.createDocumentMapPayload(allocator, table, .{
            .{ "tags", tags_val },
        });
        defer doc_val.free(allocator);

        const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 2, 1, table.index, 1, doc_val);
        defer allocator.free(message);

        const response = try routeWithArena(&app.handler, allocator, conn, message);
        defer allocator.free(response);
        const result = try parseResponse(allocator, response);
        defer allocator.free(result.resp_type);
        defer if (result.code) |code| allocator.free(code);

        try testing.expectEqualStrings("error", result.resp_type);
        try testing.expectEqualStrings("INVALID_ARRAY_ELEMENT", result.code.?);
    }
}

test "MessageHandler: StoreSet with confirm=accepted and writeId returns INVALID_MESSAGE" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "mh-invalid-write-ack", &.{
        .{ .name = "items", .fields = &.{"val"} },
    });
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;
    const table = try app.tableMetadata("items");

    // Build a StoreSet message with confirm="accepted" + a writeId.
    // The server must reject this combination immediately.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try buf.append(allocator, 0x86); // fixmap(6)
    try msgpack.writeMsgPackStr(writer, "type");
    try msgpack.writeMsgPackStr(writer, "StoreSet");
    try msgpack.writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf);
    try writer.writeInt(u64, 1, .big);
    try msgpack.writeMsgPackStr(writer, "path");
    try buf.append(allocator, 0x92); // fixarray(2)
    try buf.append(allocator, 0xcf);
    try writer.writeInt(u64, table.index, .big);
    const doc_id_bytes = @import("typed.zig").docIdToBytes(1);
    try msgpack.writeMsgPackBin(writer, &doc_id_bytes);
    try msgpack.writeMsgPackStr(writer, "value");
    try msgpack.writeMsgPackStr(writer, "hello");
    try msgpack.writeMsgPackStr(writer, "confirm");
    try msgpack.writeMsgPackStr(writer, "accepted");
    try msgpack.writeMsgPackStr(writer, "writeId");
    // 32-char hex string (valid format)
    try msgpack.writeMsgPackStr(writer, "00000000000000000000000000000000");

    const message = try buf.toOwnedSlice(allocator);
    defer allocator.free(message);

    const response = try routeWithArena(&app.handler, allocator, conn, message);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |code| allocator.free(code);

    try testing.expectEqualStrings("error", result.resp_type);
    try testing.expectEqualStrings("INVALID_MESSAGE", result.code.?);
}
