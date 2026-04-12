const std = @import("std");
const testing = std.testing;

const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
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

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const state = sc.conn;

    try testing.expectEqual(sc.ws.getConnId(), state.id);
    try testing.expectEqual(@as(?[]const u8, null), state.user_id);
    try testing.expectEqualStrings("default", state.namespace);
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

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Success path: Valid literal array
    {
        const tags = try allocator.alloc(msgpack_utils.Payload, 2);
        tags[0] = msgpack_utils.Payload.uintToPayload(1);
        tags[1] = msgpack_utils.Payload.uintToPayload(2);
        const val = msgpack_utils.Payload{ .arr = tags };
        defer val.free(allocator);

        const msg = try msgpack_helpers.createStoreSetMessageWithPayload(allocator, 1, "default", &.{ "items", "doc1", "tags" }, val);
        defer allocator.free(msg);

        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = try routeWithArena(&app.handler, allocator, conn, parsed);
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

        const msg = try msgpack_helpers.createStoreSetMessageWithPayload(allocator, 2, "default", &.{ "items", "doc1", "tags" }, val);
        defer allocator.free(msg);

        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = try routeWithArena(&app.handler, allocator, conn, parsed);
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

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Test single segment (name)
    {
        const val_payload = try msgpack_utils.Payload.strToPayload("test", allocator);
        defer val_payload.free(allocator);
        const msg = try msgpack_helpers.createStoreSetMessageWithPayload(allocator, 1, "default", &.{ "items", "doc1", "name" }, val_payload);
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try helpers.routeWithArena(&app.handler, allocator, conn, parsed);
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
        const msg = try msgpack_helpers.createStoreSetMessageWithPayload(allocator, 2, "default", &.{ "items", "doc1", "metadata__tags" }, .{ .arr = tags });
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try helpers.routeWithArena(&app.handler, allocator, conn, parsed);
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
        const msg = try msgpack_helpers.createStoreSetMessageWithPayload(allocator, 3, "default", &.{ "items", "doc1", "metadata__tags" }, .{ .arr = inner_arr });
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try helpers.routeWithArena(&app.handler, allocator, conn, parsed);
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

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Set deep field: ["deep", "id1", "a", "b", "c"]
    {
        const val_payload = try msgpack_utils.Payload.strToPayload("value", allocator);
        defer val_payload.free(allocator);
        const msg = try msgpack_helpers.createStoreSetMessageWithPayload(allocator, 1, "default", &.{ "deep", "id1", "a__b__c" }, val_payload);
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response_copy = try routeWithArena(&app.handler, allocator, conn, parsed);
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
        const msg = try msgpack_helpers.createStoreQueryMessageWithEmptyFilter(allocator, 2, "default", "deep");
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response_copy = try routeWithArena(&app.handler, allocator, conn, parsed);
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

test "MessageHandler: StoreSet field extraction" {
    const allocator = testing.allocator;

    var app: AppTestContext = undefined;
    try app.init(allocator, "mh-set-extraction", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    // Test 1: Basic StoreSet message field extraction
    {
        const message = try msgpack_helpers.createStoreSetMessage(allocator, 1, "test_ns", &.{ "test", "id1" }, "test_value");
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = try routeWithArena(&app.handler, allocator, conn, parsed);
        defer allocator.free(response);
        try testing.expect(response.len > 0);
    }
    // Test 2: StoreSet with various field values
    {
        const test_cases = [_]struct {
            namespace: []const u8,
            path: []const []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = &.{ "test", "p1" }, .value = "v1" },
            .{ .namespace = "namespace_with_underscores", .path = &.{ "test", "long" }, .value = "complex value" },
            .{ .namespace = "a", .path = &.{ "test", "id2" }, .value = "" },
            .{ .namespace = "test", .path = &.{ "test", "key" }, .value = "value with spaces" },
        };
        for (test_cases, 0..) |tc, i| {
            const message = try msgpack_helpers.createStoreSetMessage(allocator, @intCast(i), tc.namespace, tc.path, tc.value);
            defer allocator.free(message);
            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack_utils.decode(allocator, &reader);
            defer parsed.free(allocator);

            const response = try routeWithArena(&app.handler, allocator, conn, parsed);
            defer allocator.free(response);
            try testing.expect(response.len > 0);
        }
    }
    // Test 3: StoreSet missing namespace should fail
    {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);
        try buf.append(allocator, 0x84);
        try msgpack_helpers.writeMsgPackStr(writer, "type");
        try msgpack_helpers.writeMsgPackStr(writer, "StoreSet");
        try msgpack_helpers.writeMsgPackStr(writer, "id");
        try buf.append(allocator, 0x01);
        try msgpack_helpers.writeMsgPackStr(writer, "path");
        try buf.append(allocator, 0x92);
        try msgpack_helpers.writeMsgPackStr(writer, "test");
        try msgpack_helpers.writeMsgPackStr(writer, "id1");
        try msgpack_helpers.writeMsgPackStr(writer, "value");
        try msgpack_helpers.writeMsgPackStr(writer, "val");
        const message = buf.items;
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = try routeWithArena(&app.handler, allocator, conn, parsed);
        defer allocator.free(response);
        const res_parsed = try helpers.parseResponse(allocator, response);
        defer {
            allocator.free(res_parsed.resp_type);
            if (res_parsed.code) |c| allocator.free(c);
        }
        try testing.expectEqualStrings("error", res_parsed.resp_type);
        try testing.expectEqualStrings("INVALID_MESSAGE_FORMAT", res_parsed.code.?);
    }
}

test "MessageHandler: StoreSet success response format" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "mh-set-success", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const conn = sc.conn;

    const message = try msgpack_helpers.createStoreSetMessage(allocator, 1, "test", &.{ "test", "key" }, "val");
    defer allocator.free(message);
    var reader_msg: std.Io.Reader = .fixed(message);
    const parsed = try msgpack_utils.decode(allocator, &reader_msg);
    defer parsed.free(allocator);

    const response = try routeWithArena(&app.handler, allocator, conn, parsed);
    defer allocator.free(response);

    var reader_resp: std.Io.Reader = .fixed(response);
    const resp_parsed = try msgpack_utils.decode(allocator, &reader_resp);
    defer resp_parsed.free(allocator);
    const msg_type = msgpack_helpers.getMapValue(resp_parsed, "type") orelse return error.TestExpectedError;
    const msg_id = msgpack_helpers.getMapValue(resp_parsed, "id") orelse return error.TestExpectedError;
    try testing.expectEqualStrings("ok", msg_type.str.value());
    try testing.expectEqual(@as(u64, 1), msg_id.uint);
}
