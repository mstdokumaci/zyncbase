const std = @import("std");

const helpers = @import("app_test_helpers.zig");
const msgpack_helpers = @import("msgpack_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");
const schema_types = @import("schema/types.zig");
const sth = @import("storage_engine_test_helpers.zig");
const store_helpers = @import("store_test_helpers.zig");
const typed_doc_id = @import("typed/doc_id.zig");
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

const testing = std.testing;

const AppTestContext = helpers.AppTestContext;
const parseResponse = helpers.parseResponse;
const routeWithArena = helpers.routeWithArena;

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

test "MessageHandler: oversized rate limit does not divide by zero" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "mh-rate-limit-large", &.{});
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();

    app.handler.init(
        allocator,
        &app.memory_strategy,
        &app.violation_tracker,
        &app.store_service,
        &app.presence_service,
        &app.subscription_engine,
        .{ .max_messages_per_second = 1_000_001 },
        &app.auth_config,
        &app.schema,
        null,
        &app.empty_claims,
    );

    sc.conn.request_tokens = 1;
    sc.conn.last_request_time = std.time.microTimestamp() - 1_000_000;

    var message = [_]u8{0x81};
    try app.handler.handleMessage(sc.conn, &message);
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
    const record = try sth.readDoc(allocator, &app.storage_engine, table.index, 1, conn.namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
    try testing.expectEqualStrings("hello", record.?.values[table.fieldIndex("title").?].scalar.text);
    try testing.expectEqual(@as(i64, 100), record.?.values[table.fieldIndex("must_be_complete__before").?].scalar.integer);
    try testing.expectEqual(@as(i64, 200), record.?.values[table.fieldIndex("must_be_complete__after").?].scalar.integer);
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
    const doc_id_bytes = @import("typed/doc_id.zig").toBytes(1);
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

// ─── Namespace switching enforcement tests ────────────────────────────────

fn createStoreSetNamespaceMessageBytes(allocator: std.mem.Allocator, id: u64, namespace: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try buf.append(allocator, 0x83); // fixmap(3)
    try msgpack.writeMsgPackStr(writer, "type");
    try msgpack.writeMsgPackStr(writer, "StoreSetNamespace");
    try msgpack.writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf); // uint64
    try writer.writeInt(u64, id, .big);
    try msgpack.writeMsgPackStr(writer, "namespace");
    try msgpack.writeMsgPackStr(writer, namespace);

    return buf.toOwnedSlice(allocator);
}

fn createPresenceSetNamespaceMessageBytes(allocator: std.mem.Allocator, id: u64, namespace: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try buf.append(allocator, 0x83); // fixmap(3)
    try msgpack.writeMsgPackStr(writer, "type");
    try msgpack.writeMsgPackStr(writer, "PresenceSetNamespace");
    try msgpack.writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf); // uint64
    try writer.writeInt(u64, id, .big);
    try msgpack.writeMsgPackStr(writer, "namespace");
    try msgpack.writeMsgPackStr(writer, namespace);

    return buf.toOwnedSlice(allocator);
}

test "NamespaceSwitch: initial store namespace setup succeeds with users.namespaced=true" {
    const allocator = testing.allocator;
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": { "namespaced": true, "fields": {} },
        \\    "tasks": { "fields": { "title": { "type": "string" } } }
        \\  }
        \\}
    ;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "ns-switch-init", schema_json);
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

    // Pre-warm "public" in cache (implicit auth allows "public" namespace)
    _ = try app.resolveStoreScopeForTest("public", helpers.test_external_user_id);

    // Route the StoreSetNamespace message — initial setup always allowed
    const msg = try createStoreSetNamespaceMessageBytes(allocator, 1, "public");
    defer allocator.free(msg);

    const response = try routeWithArena(&app.handler, allocator, conn, msg);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |code| allocator.free(code);

    try testing.expectEqualStrings("ok", result.resp_type);
}

test "NamespaceSwitch: namespaced=true enforces lock across both scopes" {
    const allocator = testing.allocator;
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": { "namespaced": true, "fields": {} },
        \\    "tasks": { "fields": { "title": { "type": "string" } } }
        \\  },
        \\  "presence": {
        \\    "user": { "cursor": { "type": "object", "fields": { "x": { "type": "number" }, "y": { "type": "number" } } } }
        \\  }
        \\}
    ;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "ns-scope-lock", schema_json);
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

    _ = try app.resolveStoreScopeForTest("public", helpers.test_external_user_id);

    {
        const msg = try createStoreSetNamespaceMessageBytes(allocator, 1, "public");
        defer allocator.free(msg);
        const resp = try routeWithArena(&app.handler, allocator, conn, msg);
        defer allocator.free(resp);
        const r = try parseResponse(allocator, resp);
        defer allocator.free(r.resp_type);
        defer if (r.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", r.resp_type);
    }

    // Same-scope store switch rejected
    {
        const msg = try createStoreSetNamespaceMessageBytes(allocator, 2, "beta");
        defer allocator.free(msg);
        const resp = try routeWithArena(&app.handler, allocator, conn, msg);
        defer allocator.free(resp);
        const r = try parseResponse(allocator, resp);
        defer allocator.free(r.resp_type);
        defer if (r.code) |c| allocator.free(c);
        try testing.expectEqualStrings("error", r.resp_type);
        try testing.expectEqualStrings("NAMESPACE_SWITCH_REJECTED", r.code.?);
    }

    // Cross-scope: presence with different ns rejected
    {
        const msg = try createPresenceSetNamespaceMessageBytes(allocator, 3, "beta");
        defer allocator.free(msg);
        const resp = try routeWithArena(&app.handler, allocator, conn, msg);
        defer allocator.free(resp);
        const r = try parseResponse(allocator, resp);
        defer allocator.free(r.resp_type);
        defer if (r.code) |c| allocator.free(c);
        try testing.expectEqualStrings("error", r.resp_type);
        try testing.expectEqualStrings("NAMESPACE_SWITCH_REJECTED", r.code.?);
    }

    // Cross-scope: presence with same ns accepted
    {
        const msg = try createPresenceSetNamespaceMessageBytes(allocator, 4, "public");
        defer allocator.free(msg);
        const resp = try routeWithArena(&app.handler, allocator, conn, msg);
        defer allocator.free(resp);
        const r = try parseResponse(allocator, resp);
        defer allocator.free(r.resp_type);
        defer if (r.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", r.resp_type);
    }
}

test "NamespaceSwitch: namespaced=false allows any switch" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "ns-switch-allowed", &.{
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

    _ = try app.resolveStoreScopeForTest("public", helpers.test_external_user_id);

    const msg1 = try createStoreSetNamespaceMessageBytes(allocator, 1, "public");
    defer allocator.free(msg1);
    const resp1 = try routeWithArena(&app.handler, allocator, conn, msg1);
    defer allocator.free(resp1);
    const result1 = try parseResponse(allocator, resp1);
    defer allocator.free(result1.resp_type);
    defer if (result1.code) |code| allocator.free(code);
    try testing.expectEqualStrings("ok", result1.resp_type);

    const msg2 = try createStoreSetNamespaceMessageBytes(allocator, 2, "public");
    defer allocator.free(msg2);
    const resp2 = try routeWithArena(&app.handler, allocator, conn, msg2);
    defer allocator.free(resp2);
    const result2 = try parseResponse(allocator, resp2);
    defer allocator.free(result2.resp_type);
    defer if (result2.code) |code| allocator.free(code);
    try testing.expectEqualStrings("ok", result2.resp_type);
}

const table_defs = [_]helpers.TableDef{
    .{ .name = "items", .fields = &.{ "value", "tags" } },
};

const routeWithArenaOptional = helpers.routeWithArenaOptional;

fn routeBytes(app: *AppTestContext, conn: anytype, allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try routeWithArena(&app.handler, allocator, conn, message);
}

fn routeBytesOptional(app: *AppTestContext, conn: anytype, allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    return try routeWithArenaOptional(&app.handler, allocator, conn, message);
}

fn decodeResponse(allocator: std.mem.Allocator, response: []const u8) !msgpack_helpers.Payload {
    var reader: std.Io.Reader = .fixed(response);
    return try msgpack_helpers.decode(allocator, &reader);
}

fn expectResponseType(allocator: std.mem.Allocator, response: []const u8, expected: []const u8) !void {
    const parsed = try decodeResponse(allocator, response);
    defer parsed.free(allocator);

    const value = (try msgpack_helpers.getMapValue(parsed, "type")) orelse return error.TestExpectedError;
    try testing.expect(value == .str);
    try testing.expectEqualStrings(expected, value.str.value());
}

fn expectResponseId(allocator: std.mem.Allocator, response: []const u8, expected: u64) !void {
    const parsed = try decodeResponse(allocator, response);
    defer parsed.free(allocator);

    const value = (try msgpack_helpers.getMapValue(parsed, "id")) orelse return error.TestExpectedError;
    try testing.expect(value == .uint);
    try testing.expectEqual(expected, value.uint);
}

fn expectErrorCode(allocator: std.mem.Allocator, response: []const u8, expected: []const u8) !void {
    const parsed = try decodeResponse(allocator, response);
    defer parsed.free(allocator);

    const resp_type = (try msgpack_helpers.getMapValue(parsed, "type")) orelse return error.TestExpectedError;
    try testing.expect(resp_type == .str);
    try testing.expectEqualStrings("error", resp_type.str.value());

    const code = (try msgpack_helpers.getMapValue(parsed, "code")) orelse return error.TestExpectedError;
    try testing.expect(code == .str);
    try testing.expectEqualStrings(expected, code.str.value());
}

test "message: representative frames route at protocol boundary" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-route", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const table = try app.tableMetadata("items");

    {
        const val = try store_helpers.createDocumentMapPayload(allocator, table, .{
            .{ "value", "value-a" },
        });
        defer val.free(allocator);
        const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 11, 1, table.index, 1, val);
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);

        try expectResponseType(allocator, response, "ok");
        try expectResponseId(allocator, response, 11);
    }

    {
        const message = try store_helpers.createStoreQueryMessageWithEmptyFilter(allocator, 12, 1, table.index);
        defer allocator.free(message);

        // StoreQuery is not yet implemented: no response is produced.
        const response = try routeBytesOptional(&app, sc.conn, allocator, message);
        try testing.expect(response == null);
    }

    {
        const message = try store_helpers.createCustomMessage(allocator, 13, "UnknownType", 1, table.index, &.{});
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);

        try expectErrorCode(allocator, response, "INTERNAL_ERROR");
        try expectResponseId(allocator, response, 13);
    }
}

test "message: response id is preserved across routed requests" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-correlation", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const table = try app.tableMetadata("items");

    {
        const val = try store_helpers.createDocumentMapPayload(allocator, table, .{
            .{ "value", "value-b" },
        });
        defer val.free(allocator);
        const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 101, 1, table.index, 1, val);
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);
        try expectResponseId(allocator, response, 101);
    }

    {
        const message = try store_helpers.createStoreQueryMessageWithEmptyFilter(allocator, 202, 1, table.index);
        defer allocator.free(message);

        // StoreQuery is not yet implemented: no response is produced.
        const response = try routeBytesOptional(&app, sc.conn, allocator, message);
        try testing.expect(response == null);
    }

    {
        const message = try store_helpers.createCustomMessage(allocator, 303, "InvalidType", 1, table.index, &.{});
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);
        try expectResponseId(allocator, response, 303);
    }
}

test "message: invalid envelopes fail before store dispatch" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-invalid-envelope", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();

    const missing_id = try store_helpers.createInvalidStoreSetMessageMissingId(allocator, 1);
    defer allocator.free(missing_id);

    try testing.expectError(error.MissingRequiredFields, routeWithArena(&app.handler, allocator, sc.conn, missing_id));
}

test "message: repeated routed requests release per-message allocations" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-lifetime", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const table = try app.tableMetadata("items");

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const msg_id: u64 = @intCast(i + 1);
        const doc_id: typed_doc_id.DocId = @intCast(i + 1);
        const val = try store_helpers.createDocumentMapPayload(allocator, table, .{
            .{ "value", "value-c" },
        });
        defer val.free(allocator);
        const message = try store_helpers.createStoreSetMessageWithPayload(allocator, msg_id, 1, table.index, doc_id, val);
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);

        try expectResponseType(allocator, response, "ok");
        try expectResponseId(allocator, response, msg_id);
    }
}

test "message: concurrent routed requests release response allocations" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-concurrent-lifetime", &table_defs);
    defer app.deinit();

    const table = try app.tableMetadata("items");

    const ThreadContext = struct {
        app: *AppTestContext,
        table_index: usize,
        table: *const schema_types.Table,
        thread_index: usize,
        iterations: usize,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            runInternal(ctx) catch |err| {
                std.log.err("message routing property failed: {}", .{err});
                ctx.failure = err;
            };
        }

        fn runInternal(ctx: *@This()) !void {
            const thread_allocator = ctx.app.allocator;
            const sc = try ctx.app.setupMockConnection();
            defer sc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const raw_id = ctx.thread_index * 1000 + i + 1;
                const msg_id: u64 = @intCast(raw_id);
                const doc_id: typed_doc_id.DocId = @intCast(raw_id);

                const val = try store_helpers.createDocumentMapPayload(thread_allocator, ctx.table, .{
                    .{ "value", "value-d" },
                });
                defer val.free(thread_allocator);
                const message = try store_helpers.createStoreSetMessageWithPayload(
                    thread_allocator,
                    msg_id,
                    1,
                    ctx.table_index,
                    doc_id,
                    val,
                );
                defer thread_allocator.free(message);

                const response = try routeBytes(ctx.app, sc.conn, thread_allocator, message);
                defer thread_allocator.free(response);

                try expectResponseType(thread_allocator, response, "ok");
                try expectResponseId(thread_allocator, response, msg_id);
            }
        }
    };

    var contexts: [4]ThreadContext = undefined;
    var threads: [4]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{
            .app = &app,
            .table_index = table.index,
            .table = table,
            .thread_index = idx,
            .iterations = 8,
        };
        threads[idx] = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }

    for (threads) |thread| {
        thread.join();
    }

    for (contexts) |ctx| {
        if (ctx.failure) |err| return err;
    }
}
