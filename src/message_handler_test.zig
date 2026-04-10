const std = @import("std");
const testing = std.testing;

const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const createMockWebSocket = helpers.createMockWebSocket;
const routeWithArena = helpers.routeWithArena;
const parseResponse = helpers.parseResponse;

const msgpack_utils = @import("msgpack_utils.zig");
const msgpack_helpers = @import("msgpack_test_helpers.zig");
const schema_manager = @import("schema_manager.zig");

test "Connection - init and deinit" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-init", &.{});
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const state = sc.conn;

    try testing.expectEqual(ws.getConnId(), state.id);
    try testing.expectEqual(@as(?[]const u8, null), state.user_id);
    try testing.expectEqualStrings("default", state.namespace);
    try testing.expectEqual(@as(usize, 0), state.subscription_ids.items.len);
}

test "Connection - add subscription IDs" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-subs", &.{});
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
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

// ─── Integration: Storage Operations ──────────────────────────────────────────

test "MessageHandler: StoreSet routes to StoreService and maps errors correctly" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;

    // We use a simple schema with one array field to test both happy path and error mapping
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "items": { "fields": { "tags": { "type": "array" } } }
        \\  }
        \\}
    ;
    try app.initWithSchemaJSON(allocator, "mh-storage-int", schema_json);
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Success path: Valid literal array
    {
        const tags = try allocator.alloc(msgpack_utils.Payload, 2);
        tags[0] = msgpack_utils.Payload.uintToPayload(1);
        tags[1] = msgpack_utils.Payload.uintToPayload(2);
        const val = msgpack_utils.Payload{ .arr = tags };
        defer val.free(allocator);

        const msg = try buildStoreSetWithFieldPath(allocator, 1, "items", "doc1", &.{"tags"}, val);
        defer allocator.free(msg);

        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = try routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        try testing.expectEqualStrings("ok", res.resp_type);
    }

    // 2. Error mapping: Invalid array element (nested map)
    {
        var inner_map = msgpack_utils.Payload.mapPayload(allocator);
        const arr_payload = try allocator.alloc(msgpack_utils.Payload, 1);
        arr_payload[0] = inner_map;
        inner_map = .nil; // ownership transferred
        const val = msgpack_utils.Payload{ .arr = arr_payload };
        defer val.free(allocator);

        const msg = try buildStoreSetWithFieldPath(allocator, 2, "items", "doc1", &.{"tags"}, val);
        defer allocator.free(msg);

        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = try routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        defer if (res.code) |c| allocator.free(c);

        try testing.expectEqualStrings("error", res.resp_type);
        // This verifies the critical "error routing" between StoreService and MessageHandler
        try testing.expectEqualStrings("INVALID_ARRAY_ELEMENT", res.code.?);
    }
}

// ─── Verification of Schema & Message Parsing Architecture Improvements ──────

test "MessageHandler - flattened field path via StoreSet" {
    const allocator = testing.allocator;

    // Create a schema with a flattened multi-segment field
    const fields = try allocator.alloc(schema_manager.Field, 2);
    fields[0] = .{
        .name = try allocator.dupe(u8, "metadata__tags"),
        .sql_type = .array,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
    fields[1] = .{
        .name = try allocator.dupe(u8, "name"),
        .sql_type = .text,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };

    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "items"),
        .fields = fields,
    };

    const schema = schema_manager.Schema{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };
    defer schema_manager.freeSchema(allocator, schema);

    var app: AppTestContext = undefined;
    try app.initWithSchema(allocator, "mh-resolve-field", schema);
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Test single segment (name)
    {
        const val_payload = try msgpack_utils.Payload.strToPayload("test", allocator);
        defer val_payload.free(allocator);
        const msg = try buildStoreSetWithFieldPath(allocator, 1, "items", "doc1", &.{"name"}, val_payload);
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try helpers.routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        defer if (res.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", res.resp_type);
    }

    // 2. Test multi-segment (metadata.tags)
    {
        const tags = try allocator.alloc(msgpack_utils.Payload, 2);
        tags[0] = try msgpack_utils.Payload.strToPayload("a", allocator);
        tags[1] = try msgpack_utils.Payload.strToPayload("b", allocator);
        defer {
            tags[0].free(allocator);
            tags[1].free(allocator);
            allocator.free(tags);
        }
        const msg = try buildStoreSetWithFieldPath(allocator, 2, "items", "doc1", &.{"metadata__tags"}, .{ .arr = tags });
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try helpers.routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        defer if (res.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", res.resp_type);
    }

    // 3. Test nested array validation for multi-segment path
    {
        // Invalid element (map) in field metadata.tags
        const inner_arr = try allocator.alloc(msgpack_utils.Payload, 1);
        inner_arr[0] = msgpack_utils.Payload.mapPayload(allocator);
        defer {
            inner_arr[0].free(allocator);
            allocator.free(inner_arr);
        }
        const msg = try buildStoreSetWithFieldPath(allocator, 3, "items", "doc1", &.{"metadata__tags"}, .{ .arr = inner_arr });
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try helpers.routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        defer if (res.code) |c| allocator.free(c);
        try testing.expectEqualStrings("error", res.resp_type);
        try testing.expectEqualStrings("INVALID_ARRAY_ELEMENT", res.code.?);
    }
}

test "MessageHandler - deep nested schema round-trip (3+ levels)" {
    const allocator = testing.allocator;

    // a.b.c -> a__b__c
    const fields = try allocator.alloc(schema_manager.Field, 1);
    fields[0] = .{
        .name = try allocator.dupe(u8, "a__b__c"),
        .sql_type = .text,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };

    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "deep"),
        .fields = fields,
    };

    const schema = schema_manager.Schema{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };
    defer schema_manager.freeSchema(allocator, schema);

    var app: AppTestContext = undefined;
    try app.initWithSchema(allocator, "mh-deep-nested", schema);
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Set deep field: ["deep", "id1", "a", "b", "c"]
    {
        const val_payload = try msgpack_utils.Payload.strToPayload("value", allocator);
        defer val_payload.free(allocator);
        const msg = try buildStoreSetWithFieldPath(allocator, 1, "deep", "id1", &.{"a__b__c"}, val_payload);
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response_copy = try routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response_copy);

        // Verify Set response is "ok"
        var resp_reader: std.Io.Reader = .fixed(response_copy);
        const resp_parsed = try msgpack_utils.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);
        const resp_type = msgpack_helpers.getMapValue(resp_parsed, "type") orelse return error.MissingType;
        try testing.expectEqualStrings("ok", resp_type.str.value());
    }

    // Flush pending writes so the document is persisted before reading
    try app.storage_engine.flushPendingWrites();

    // 2. Get document and verify flat response: Expect { "a__b__c": "value" } (stay flat architecture)
    {
        const msg = try buildStoreQuery(allocator, 2, "deep");
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response_copy = try routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response_copy);

        // Parse actual value
        var resp_reader: std.Io.Reader = .fixed(response_copy);
        const resp_parsed = try msgpack_utils.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);
        const value = msgpack_helpers.getMapValue(resp_parsed, "value") orelse return error.MissingValue;

        // For StoreQueryResponse, the value is an array of records
        try testing.expect(value == .arr);
        try testing.expectEqual(@as(usize, 1), value.arr.len);
        const doc = value.arr[0];

        // Verify structure: doc.map["a__b__c"] == "value" (stay flat architecture)
        const abc = msgpack_helpers.getMapValue(doc, "a__b__c") orelse return error.ValueMismatch;
        try testing.expectEqualStrings("value", abc.str.value());
    }
}

fn buildStoreSetWithFieldPath(
    allocator: std.mem.Allocator,
    id: u64,
    table: []const u8,
    doc_id: []const u8,
    field_segments: []const []const u8,
    val: msgpack_utils.Payload,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // fixmap(5)
    try buf.append(allocator, 0x85);

    try msgpack_helpers.writeMsgPackStr(writer, "type");
    try msgpack_helpers.writeMsgPackStr(writer, "StoreSet");

    try msgpack_helpers.writeMsgPackStr(writer, "id");
    // encode id as uint64
    try buf.append(allocator, 0xcf);
    for (0..8) |i| try buf.append(allocator, @intCast((id >> @intCast((7 - i) * 8)) & 0xFF));

    try msgpack_helpers.writeMsgPackStr(writer, "namespace");
    try msgpack_helpers.writeMsgPackStr(writer, "default");

    try msgpack_helpers.writeMsgPackStr(writer, "path");
    // array length is 2 + field_segments.len
    const path_len = 2 + field_segments.len;
    if (path_len < 16) {
        try buf.append(allocator, @intCast(0x90 | path_len));
    } else {
        try buf.append(allocator, 0xdc);
        try buf.append(allocator, @intCast((path_len >> 8) & 0xFF));
        try buf.append(allocator, @intCast(path_len & 0xFF));
    }
    try msgpack_helpers.writeMsgPackStr(writer, table);
    try msgpack_helpers.writeMsgPackStr(writer, doc_id);
    for (field_segments) |seg| try msgpack_helpers.writeMsgPackStr(writer, seg);

    try msgpack_helpers.writeMsgPackStr(writer, "value");
    try msgpack_utils.encode(val, buf.writer(allocator));

    return buf.toOwnedSlice(allocator);
}

fn buildStoreQuery(allocator: std.mem.Allocator, id: u64, table: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try buf.append(allocator, 0x85); // fixmap(5)
    try msgpack_helpers.writeMsgPackStr(writer, "type");
    try msgpack_helpers.writeMsgPackStr(writer, "StoreQuery");
    try msgpack_helpers.writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf);
    for (0..8) |i| try buf.append(allocator, @intCast((id >> @intCast((7 - i) * 8)) & 0xFF));
    try msgpack_helpers.writeMsgPackStr(writer, "namespace");
    try msgpack_helpers.writeMsgPackStr(writer, "default");
    try msgpack_helpers.writeMsgPackStr(writer, "collection");
    try msgpack_helpers.writeMsgPackStr(writer, table);
    try msgpack_helpers.writeMsgPackStr(writer, "filter");
    try buf.append(allocator, 0x80); // empty map {}
    return buf.toOwnedSlice(allocator);
}
