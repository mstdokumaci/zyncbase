const std = @import("std");
const msgpack = @import("msgpack");
const testing = std.testing;
const authorization_presence = @import("presence.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const schema_types = @import("../schema/types.zig");
const auth_helpers = @import("test_helpers.zig");

test "authorizePresenceWrite enforces presenceWrite condition" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "cursor_x", .declared_type = .real },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = .{ .float = 42.0 };
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try authorization_presence.authorizePresenceWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch);
    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceWrite(allocator, &config, "unknown:xyz", user_id, "external-1", null, &presence_fields, &patch));
}

test "authorizePresenceWrite denies when presenceWrite is false" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"readonly:{id}","storeFilter":true,"presenceRead":true,"presenceWrite":false}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "status", .declared_type = .text },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = try msgpack.Payload.strToPayload("online", allocator);
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceWrite(allocator, &config, "readonly:ns", user_id, "external-1", null, &presence_fields, &patch));
}

test "authorizePresenceSharedWrite enforces presenceSharedWrite condition" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true,"presenceSharedWrite":true}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "slide", .declared_type = .integer },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = .{ .uint = 5 };
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try authorization_presence.authorizePresenceSharedWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch);
    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceSharedWrite(allocator, &config, "unknown:xyz", user_id, "external-1", null, &presence_fields, &patch));
}

test "authorizePresenceSharedWrite falls back to presenceWrite when not specified" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":false}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "slide", .declared_type = .integer },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = .{ .uint = 5 };
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceSharedWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch));
}
