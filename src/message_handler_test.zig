const std = @import("std");
const testing = std.testing;

const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const parseResponse = helpers.parseResponse;
const routeWithArena = helpers.routeWithArena;
const msgpack = @import("msgpack_utils.zig");
const store_helpers = @import("store_test_helpers.zig");

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
    try testing.expectEqual(@as(i64, 1), state.namespace_id);
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
    const field_index = table.fieldIndex("tags") orelse return error.UnknownField;

    {
        const tags = try allocator.alloc(msgpack.Payload, 2);
        tags[0] = msgpack.Payload.uintToPayload(1);
        tags[1] = msgpack.Payload.uintToPayload(2);
        const value = msgpack.Payload{ .arr = tags };
        defer value.free(allocator);

        const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 1, 1, table.index, 1, field_index, value);
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
        const value = msgpack.Payload{ .arr = items };
        defer value.free(allocator);

        const message = try store_helpers.createStoreSetMessageWithPayload(allocator, 2, 1, table.index, 1, field_index, value);
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
