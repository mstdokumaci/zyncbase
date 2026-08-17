const std = @import("std");

const msgpack = @import("msgpack");

const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const authorization_presence = @import("presence.zig");
const auth_helpers = @import("test_helpers.zig");

const testing = std.testing;

test "authorizePresenceWrite enforces presenceWrite condition" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "cursor_x", .declared_type = .real },
    };
    var patch = try makePatch(allocator, 0, .{ .float = 42.0 });
    defer patch.free(allocator);

    try authorization_presence.authorizePresenceWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch, false);
    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceWrite(allocator, &config, "unknown:xyz", user_id, "external-1", null, &presence_fields, &patch, false));
}

test "authorizePresenceWrite denies when presenceWrite is false" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"readonly:{id}","storeFilter":true,"presenceRead":true,"presenceWrite":false}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "status", .declared_type = .text },
    };
    var patch = try makePatch(allocator, 0, try msgpack.Payload.strToPayload("online", allocator));
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceWrite(allocator, &config, "readonly:ns", user_id, "external-1", null, &presence_fields, &patch, false));
}

test "authorizePresenceSharedWrite enforces presenceSharedWrite condition" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true,"presenceSharedWrite":false}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "slide", .declared_type = .integer },
    };
    var patch = try makePatch(allocator, 0, .{ .uint = 5 });
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch, true));
    try authorization_presence.authorizePresenceWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch, false);
}

test "authorizePresenceSharedWrite falls back to presenceWrite when not specified" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":false}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);
    const presence_fields = [_]schema_types.PresenceField{
        .{ .name = "slide", .declared_type = .integer },
    };
    var patch = try makePatch(allocator, 0, .{ .uint = 5 });
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, authorization_presence.authorizePresenceWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch, true));
}

fn makePatch(allocator: std.mem.Allocator, field_index: usize, value: msgpack.Payload) !msgpack.Payload {
    errdefer value.free(allocator);
    const pair = try allocator.alloc(msgpack.Payload, 2);
    errdefer allocator.free(pair);
    pair[0] = msgpack.Payload.uintToPayload(field_index);
    pair[1] = value;
    const pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    return .{ .arr = pairs };
}
