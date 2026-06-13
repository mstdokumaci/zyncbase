const std = @import("std");
const testing = std.testing;
const PresenceRecord = @import("presence/record.zig").PresenceRecord;
const PresenceManager = @import("presence/manager.zig").PresenceManager;
const schema_mod = @import("schema.zig");
const msgpack = @import("msgpack_utils.zig");
const typed = @import("typed.zig");

fn makeTestUserFields(allocator: std.mem.Allocator) ![]const schema_mod.PresenceField {
    const fields = try allocator.alloc(schema_mod.PresenceField, 3);
    fields[0] = .{ .name = try allocator.dupe(u8, "cursor__x"), .declared_type = .real };
    fields[1] = .{ .name = try allocator.dupe(u8, "cursor__y"), .declared_type = .real };
    fields[2] = .{ .name = try allocator.dupe(u8, "status"), .declared_type = .text };
    return fields;
}

fn freeTestFields(allocator: std.mem.Allocator, fields: []const schema_mod.PresenceField) void {
    for (fields) |f| f.deinit(allocator);
    allocator.free(fields);
}

fn makeTestSharedFields(allocator: std.mem.Allocator) ![]const schema_mod.PresenceField {
    const fields = try allocator.alloc(schema_mod.PresenceField, 2);
    fields[0] = .{ .name = try allocator.dupe(u8, "slide"), .declared_type = .integer };
    fields[1] = .{ .name = try allocator.dupe(u8, "playing"), .declared_type = .boolean };
    return fields;
}

fn makePresencePatch(allocator: std.mem.Allocator, entries: []const struct { idx: usize, value: msgpack.Payload }) !msgpack.Payload {
    var patch = msgpack.Payload.mapPayload(allocator);
    for (entries) |entry| {
        try patch.mapPutGeneric(msgpack.Payload.uintToPayload(entry.idx), entry.value);
    }
    return patch;
}

// ─── PresenceRecord tests ─────────────────────────────────────────────────────

test "PresenceRecord - init creates all-null slots" {
    const allocator = testing.allocator;
    var record = try PresenceRecord.init(allocator, 3);
    defer record.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), record.values.len);
    for (record.values) |slot| {
        try testing.expect(slot == null);
    }
}

test "PresenceRecord - mergeFromPayload applies sparse patch" {
    const allocator = testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 42.5 } },
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("active", allocator) },
    });
    defer patch.free(allocator);

    try record.mergeFromPayload(allocator, fields, patch);

    try testing.expect(record.values[0] != null);
    try testing.expect(record.values[1] == null);
    try testing.expect(record.values[2] != null);

    try testing.expectEqual(.scalar, std.meta.activeTag(record.values[0].?));
    try testing.expectEqual(@as(f64, 42.5), record.values[0].?.scalar.real);

    try testing.expectEqual(.scalar, std.meta.activeTag(record.values[2].?));
    try testing.expectEqualStrings("active", record.values[2].?.scalar.text);
}

test "PresenceRecord - mergeFromPayload rejects out-of-bounds field index" {
    const allocator = testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 99, .value = .{ .float = 1.0 } },
    });
    defer patch.free(allocator);

    try testing.expectError(error.InvalidFieldIndex, record.mergeFromPayload(allocator, fields, patch));
}

test "PresenceRecord - mergeFromPayload rejects non-map payload" {
    const allocator = testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    const bad_patch = msgpack.Payload{ .int = 42 };
    try testing.expectError(error.InvalidPayload, record.mergeFromPayload(allocator, fields, bad_patch));
}

test "PresenceRecord - clone deep copies values" {
    const allocator = testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 10.0 } },
    });
    defer patch.free(allocator);
    try record.mergeFromPayload(allocator, fields, patch);

    var cloned = try record.clone(allocator);
    defer cloned.deinit(allocator);

    try testing.expectEqual(record.values.len, cloned.values.len);
    try testing.expect(cloned.values[0] != null);
    try testing.expectEqual(@as(f64, 10.0), cloned.values[0].?.scalar.real);
    try testing.expect(cloned.values[1] == null);
}

test "PresenceRecord - mergeFromPayload overwrites existing value" {
    const allocator = testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("idle", allocator) },
    });
    defer patch1.free(allocator);
    try record.mergeFromPayload(allocator, fields, patch1);

    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("active", allocator) },
    });
    defer patch2.free(allocator);
    try record.mergeFromPayload(allocator, fields, patch2);

    try testing.expectEqualStrings("active", record.values[2].?.scalar.text);
}

// ─── PresenceManager tests ────────────────────────────────────────────────────

test "PresenceManager - setUser creates record and queues pending update" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    try manager.setUser(1, user_id, patch);

    try testing.expectEqual(@as(usize, 1), manager.user_state.count());
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expectEqual(@as(i64, 1), manager.pending_user_updates.items[0].namespace_id);
}

test "PresenceManager - setShared creates record and queues pending update" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .uint = 5 } },
    });
    defer patch.free(allocator);

    try manager.setShared(1, patch, 42);

    try testing.expectEqual(@as(usize, 1), manager.shared_state.count());
    try testing.expectEqual(@as(usize, 1), manager.pending_shared_updates.items.len);
    try testing.expectEqual(@as(u64, 42), manager.pending_shared_updates.items[0].source_conn);
}

test "PresenceManager - removeUser cleans up and queues leave" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 1.0 } },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, patch);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);

    try manager.removeUser(1, user_id);

    try testing.expectEqual(@as(usize, 2), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[1].patch == null);

    try testing.expectEqual(@as(usize, 1), manager.namespace_empty_at.count());
}

test "PresenceManager - removeUser on nonexistent namespace is no-op" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    try manager.removeUser(999, typed.zeroDocId);

    try testing.expectEqual(@as(usize, 0), manager.pending_user_updates.items.len);
}

test "PresenceManager - onSubscribeUser returns snapshot" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("online", allocator) },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, patch);

    var snapshot = try manager.onSubscribeUser(1, 100);
    defer snapshot.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.users.items.len);
    try testing.expectEqual(user_id, snapshot.users.items[0].user_id);

    const subs = manager.user_subscribers.get(1) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), subs.items.len);
    try testing.expectEqual(@as(u64, 100), subs.items[0]);
}

test "PresenceManager - onSubscribeShared returns current state" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    var set_patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .uint = 3 } },
    });
    defer set_patch.free(allocator);
    try manager.setShared(1, set_patch, 42);

    var shared = try manager.onSubscribeShared(1, 200);
    try testing.expect(shared != null);
    if (shared) |*rec| {
        defer rec.deinit(allocator);
        try testing.expect(rec.values[0] != null);
    }

    const subs = manager.shared_subscribers.get(1) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), subs.items.len);
}

test "PresenceManager - onSubscribeShared returns null when no state" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const shared = try manager.onSubscribeShared(1, 200);
    try testing.expect(shared == null);
}

test "PresenceManager - onUnsubscribeUser removes subscriber" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    _ = try manager.onSubscribeUser(1, 100);
    _ = try manager.onSubscribeUser(1, 200);

    {
        const subs = manager.user_subscribers.get(1) orelse return error.TestExpectedValue;
        try testing.expectEqual(@as(usize, 2), subs.items.len);
    }

    manager.onUnsubscribeUser(1, 100);

    {
        const subs = manager.user_subscribers.get(1) orelse return error.TestExpectedValue;
        try testing.expectEqual(@as(usize, 1), subs.items.len);
        try testing.expectEqual(@as(u64, 200), subs.items[0]);
    }
}

test "PresenceManager - setUser cancels grace period" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 1.0 } },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, patch);
    try manager.removeUser(1, user_id);

    try testing.expectEqual(@as(usize, 1), manager.namespace_empty_at.count());

    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 2.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, patch2);

    try testing.expectEqual(@as(usize, 0), manager.namespace_empty_at.count());
}

test "PresenceManager - multiple users in same namespace" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_a = typed.zeroDocId;
    var user_b_bytes = [_]u8{1} ** 16;
    const user_b = try typed.docIdFromBytes(&user_b_bytes);

    var patch_a = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("a", allocator) },
    });
    defer patch_a.free(allocator);
    try manager.setUser(1, user_a, patch_a);

    var patch_b = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("b", allocator) },
    });
    defer patch_b.free(allocator);
    try manager.setUser(1, user_b, patch_b);

    const ns_map = manager.user_state.get(1) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 2), ns_map.count());

    var snapshot = try manager.onSubscribeUser(1, 300);
    defer snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), snapshot.users.items.len);
}

test "PresenceManager - setUser tracks joined_at timestamp" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    try manager.setUser(1, user_id, patch);

    // Verify joined_at was recorded
    const joined_ns = manager.user_joined_at.get(1) orelse return error.TestExpectedValue;
    const joined_at = joined_ns.get(user_id) orelse return error.TestExpectedValue;
    try testing.expect(joined_at > 0);

    // Second setUser should NOT update joined_at (user already exists)
    const original_joined_at = joined_at;
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 200.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, patch2);

    const joined_ns2 = manager.user_joined_at.get(1) orelse return error.TestExpectedValue;
    const joined_at2 = joined_ns2.get(user_id) orelse return error.TestExpectedValue;
    try testing.expectEqual(original_joined_at, joined_at2);
}

test "PresenceManager - removeUser cleans up joined_at" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, patch);

    // Verify joined_at exists
    try testing.expect(manager.user_joined_at.get(1) != null);

    try manager.removeUser(1, user_id);

    // Verify joined_at was cleaned up
    const joined_ns = manager.user_joined_at.get(1);
    if (joined_ns) |ns| {
        try testing.expectEqual(@as(usize, 0), ns.count());
    }
}

test "PresenceManager - is_new_user flag set correctly" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;

    // First setUser should mark is_new_user = true
    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch1.free(allocator);
    try manager.setUser(1, user_id, patch1);
    try testing.expect(manager.pending_user_updates.items[0].is_new_user);

    // Second setUser should mark is_new_user = false
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 200.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, patch2);
    try testing.expect(!manager.pending_user_updates.items[1].is_new_user);

    // removeUser should mark is_new_user = false (leave event)
    try manager.removeUser(1, user_id);
    try testing.expect(!manager.pending_user_updates.items[2].is_new_user);
}

test "PresenceManager - snapshot includes joined_at" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = typed.zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("online", allocator) },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, patch);

    var snapshot = try manager.onSubscribeUser(1, 100);
    defer snapshot.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.users.items.len);
    try testing.expect(snapshot.users.items[0].joined_at > 0);
}
