const std = @import("std");
const testing = std.testing;
const PresenceService = @import("service.zig").PresenceService;
const th = @import("test_helpers.zig");
const auth_helpers = @import("../authorization/test_helpers.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const msgpack = @import("../msgpack_utils.zig");
const schema_types = @import("../schema/types.zig");
const auth_types = @import("../authorization/types.zig");

fn makeServiceTestSchema(allocator: std.mem.Allocator) !schema_types.Schema {
    return schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{
        .{ .name = "posts", .fields = &[_][]const u8{"visibility"}, .types = &[_]schema_types.FieldType{.text} },
    });
}

fn makePermissiveConfig(allocator: std.mem.Allocator, schema: *const schema_types.Schema) !auth_types.AuthConfig {
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true,"presenceSharedWrite":true}],"store":[]}
    ;
    _ = schema;
    return auth_helpers.initTestConfig(allocator, json);
}

fn makePermissiveSession(claims: *const std.StringHashMapUnmanaged(typed.Value), arena: std.mem.Allocator) PresenceService.Session {
    return .{
        .namespace_id = 1,
        .user_doc_id = typed_doc_id.generateUuidV7(),
        .conn_id = 100,
        .external_user_id = "external-test-user",
        .session_claims = claims,
        .presence_namespace = "room:lobby",
        .arena = arena,
    };
}

fn makeTestPatch(allocator: std.mem.Allocator) !msgpack.Payload {
    return th.makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 42.0 } },
    });
}

fn makeTestSharedPatch(allocator: std.mem.Allocator) !msgpack.Payload {
    return th.makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .uint = 5 } },
    });
}

fn denyWriteSession(claims: *const std.StringHashMapUnmanaged(typed.Value), arena: std.mem.Allocator) PresenceService.Session {
    var s = makePermissiveSession(claims, arena);
    s.presence_namespace = "unknown:xyz";
    return s;
}

// ─── Auth: setUser ───────────────────────────────────────────────────────────

test "PresenceService: setUser authorized with permissive config" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);
    const patch = try makeTestPatch(allocator);
    defer patch.free(allocator);

    try svc.setUser(session, patch);
}

test "PresenceService: setUser rejected with unauthorized namespace" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = denyWriteSession(&claims, allocator);
    const patch = try makeTestPatch(allocator);
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, svc.setUser(session, patch));
}

// ─── Auth: setShared ─────────────────────────────────────────────────────────

test "PresenceService: setShared authorized with permissive config" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);
    const patch = try makeTestSharedPatch(allocator);
    defer patch.free(allocator);

    try svc.setShared(session, patch);
}

test "PresenceService: setShared rejected with unauthorized namespace" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = denyWriteSession(&claims, allocator);
    const patch = try makeTestSharedPatch(allocator);
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, svc.setShared(session, patch));
}

// ─── Null worker silently drops ops ──────────────────────────────────────────

test "PresenceService: removeUser with null worker (no crash)" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);

    try svc.removeUser(session);
}

test "PresenceService: subscribeUser with null worker (no crash)" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);

    try svc.subscribeUser(session, 200, 42);
}

test "PresenceService: subscribeShared with null worker (no crash)" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);

    try svc.subscribeShared(session, 200, 42);
}

test "PresenceService: unsubscribeUser with null worker (no crash)" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);

    try svc.unsubscribeUser(session);
}

test "PresenceService: unsubscribeShared with null worker (no crash)" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);

    try svc.unsubscribeShared(session);
}

test "PresenceService: removeAllForConnection with null worker (no crash)" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    svc.removeAllForConnection(1, 42, 100);
}

// ─── Patch cloning ───────────────────────────────────────────────────────────

test "PresenceService: setUser clones patch — original can be freed after call" {
    const allocator = testing.allocator;
    var schema = try makeServiceTestSchema(allocator);
    defer schema.deinit();
    var config = try makePermissiveConfig(allocator, &schema);
    defer config.deinit();

    var svc = PresenceService.init(allocator, null, &config, &schema);
    defer svc.deinit();

    const claims = std.StringHashMapUnmanaged(typed.Value){};
    const session = makePermissiveSession(&claims, allocator);
    const patch = try makeTestPatch(allocator);
    defer patch.free(allocator);

    try svc.setUser(session, patch);
    // original patch freed by defer — no crash, service cloned it internally
}
