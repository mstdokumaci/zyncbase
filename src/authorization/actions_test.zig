const std = @import("std");

const msgpack = @import("msgpack");

const schema_parse = @import("../schema/parse.zig");
const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const authorization_actions = @import("actions.zig");
const authorization_parse = @import("parse.zig");
const auth_helpers = @import("test_helpers.zig");

const testing = std.testing;

fn makeActionSchema(allocator: std.mem.Allocator) !schema_types.Schema {
    return schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{},"actions":{
        \\  "checkout":{"params":{"amount":{"type":"integer"}}},
        \\  "ping":{"params":{"seq":{"type":"integer"}},"scope":"presence"}
        \\}}
    );
}

fn makePairs(allocator: std.mem.Allocator, field_index: usize, value: msgpack.Payload) !msgpack.Payload {
    errdefer value.free(allocator);
    const pair = try allocator.alloc(msgpack.Payload, 2);
    errdefer allocator.free(pair);
    pair[0] = msgpack.Payload.uintToPayload(field_index);
    pair[1] = value;
    const pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    return .{ .arr = pairs };
}

test "authorizeActionInvoke evaluates $value against params" {
    const allocator = std.heap.smp_allocator;

    var schema = try makeActionSchema(allocator);
    defer schema.deinit();

    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],
        \\ "store":[],
        \\ "actions":[{"action":"checkout","invoke":{"$value.amount":{"lte":100}},"register":{"$session.role":{"eq":"worker"}}}]}
    ;
    var config = try authorization_parse.initFromJson(allocator, json, &schema);
    defer config.deinit();

    const checkout = schema.action("checkout") orelse return error.TestExpectedValue;
    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);

    var small = try makePairs(allocator, 0, msgpack.Payload.uintToPayload(50));
    defer small.free(allocator);
    try authorization_actions.authorizeActionInvoke(allocator, &config, checkout, "room:lobby", user_id, "external-1", null, &small);

    var large = try makePairs(allocator, 0, msgpack.Payload.uintToPayload(500));
    defer large.free(allocator);
    try testing.expectError(error.PermissionDenied, authorization_actions.authorizeActionInvoke(allocator, &config, checkout, "room:lobby", user_id, "external-1", null, &large));

    // No matching rule for an undeclared action → fail closed.
    const ping = schema.action("ping") orelse return error.TestExpectedValue;
    try testing.expectError(error.PermissionDenied, authorization_actions.authorizeActionInvoke(allocator, &config, ping, "room:lobby", user_id, "external-1", null, &small));

    // Namespace admission still applies.
    try testing.expectError(error.NamespaceUnauthorized, authorization_actions.authorizeActionInvoke(allocator, &config, checkout, "other:ns", user_id, "external-1", null, &small));
}

test "authorizeActionRegister evaluates $session claims and wildcard fallback" {
    const allocator = std.heap.smp_allocator;

    var schema = try makeActionSchema(allocator);
    defer schema.deinit();

    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],
        \\ "store":[],
        \\ "actions":[
        \\   {"action":"checkout","invoke":true,"register":{"$session.role":{"eq":"worker"}}},
        \\   {"action":"*","invoke":false,"register":false}
        \\ ]}
    ;
    var config = try authorization_parse.initFromJson(allocator, json, &schema);
    defer config.deinit();

    const checkout = schema.action("checkout") orelse return error.TestExpectedValue;
    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);

    var worker_claims = std.StringHashMapUnmanaged(typed.Value){};
    defer worker_claims.deinit(allocator);
    try worker_claims.put(allocator, "role", .{ .scalar = .{ .text = "worker" } });
    try authorization_actions.authorizeActionRegister(allocator, &config, checkout, "room:lobby", user_id, "external-1", &worker_claims);

    var user_claims = std.StringHashMapUnmanaged(typed.Value){};
    defer user_claims.deinit(allocator);
    try user_claims.put(allocator, "role", .{ .scalar = .{ .text = "member" } });
    try testing.expectError(error.PermissionDenied, authorization_actions.authorizeActionRegister(allocator, &config, checkout, "room:lobby", user_id, "external-1", &user_claims));

    // Exact match wins over the wildcard deny.
    try authorization_actions.authorizeActionRegister(allocator, &config, checkout, "room:lobby", user_id, "external-1", &worker_claims);

    // Actions without an exact rule fall through to the wildcard.
    const ping = schema.action("ping") orelse return error.TestExpectedValue;
    try testing.expectError(error.PermissionDenied, authorization_actions.authorizeActionRegister(allocator, &config, ping, "room:lobby", user_id, "external-1", &worker_claims));
}

test "implicit defaults allow invoke and deny register" {
    const allocator = std.heap.smp_allocator;

    var schema = try makeActionSchema(allocator);
    defer schema.deinit();

    var config = try auth_helpers.implicitTestConfig(allocator);
    defer config.deinit();

    const checkout = schema.action("checkout") orelse return error.TestExpectedValue;
    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);

    var params = try makePairs(allocator, 0, msgpack.Payload.uintToPayload(1));
    defer params.free(allocator);
    try authorization_actions.authorizeActionInvoke(allocator, &config, checkout, "public", user_id, "external-1", null, &params);
    try testing.expectError(error.PermissionDenied, authorization_actions.authorizeActionRegister(allocator, &config, checkout, "public", user_id, "external-1", null));
}

test "authorization parse: rejects malformed action rules" {
    const allocator = std.heap.smp_allocator;

    var schema = try makeActionSchema(allocator);
    defer schema.deinit();

    const base =
        \\{"namespaces":[{"pattern":"public","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[],
    ;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, base);
    try buf.appendSlice(allocator, "\"actions\":5}");
    try testing.expectError(error.InvalidAuthConfig, authorization_parse.initFromJson(allocator, buf.items, &schema));

    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, base);
    try buf.appendSlice(allocator, "\"actions\":[5]}");
    try testing.expectError(error.InvalidActionRule, authorization_parse.initFromJson(allocator, buf.items, &schema));

    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, base);
    try buf.appendSlice(allocator, "\"actions\":[{\"action\":\"a\",\"invoke\":true}]}");
    try testing.expectError(error.InvalidActionRule, authorization_parse.initFromJson(allocator, buf.items, &schema));

    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, base);
    try buf.appendSlice(allocator, "\"actions\":[{\"action\":\"a\",\"invoke\":true,\"register\":true,\"extra\":1}]}");
    try testing.expectError(error.UnknownAuthKey, authorization_parse.initFromJson(allocator, buf.items, &schema));
}
