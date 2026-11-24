const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const th = @import("test_helpers.zig");
const PresenceManager = @import("manager.zig").PresenceManager;

const testing = std.testing;
const docIdFromBytes = typed_doc_id.fromBytes;
const zeroDocId = typed_doc_id.zero;
const freeTestFields = th.freeTestFields;
const makePresencePatch = th.makePresencePatch;
const makeTestSharedFields = th.makeTestSharedFields;
const makeTestUserFields = th.makeTestUserFields;

test "PresenceManager - setUser creates record and queues pending update" {
    const allocator = std.testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    try manager.setUser(1, user_id, 1, patch);

    try testing.expectEqual(@as(usize, 1), manager.user_state.count());
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expectEqual(@as(i64, 1), manager.pending_user_updates.items[0].namespace_id);
}

test "PresenceManager - nil patch clears a user field in the snapshot" {
    const allocator = std.testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var set_patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer set_patch.free(allocator);
    try manager.setUser(1, user_id, 1, set_patch);

    var clear_patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .nil },
    });
    defer clear_patch.free(allocator);
    try manager.setUser(1, user_id, 1, clear_patch);

    var snapshot = try manager.onSubscribeUser(1, 100, 1);
    defer snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), snapshot.users.items.len);
    const value = snapshot.users.items[0].data.values[0];
    try testing.expect(value != null);
    try testing.expectEqual(.nil, std.meta.activeTag(value.?));
}

test "PresenceManager - setShared creates record and queues pending update" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
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

test "PresenceManager - setUser coalesces pending updates for same user" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .uint = 1 } },
    });
    defer patch1.free(allocator);
    try manager.setUser(1, user_id, 1, patch1);

    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 1, .value = .{ .uint = 2 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, 1, patch2);

    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    const merged_patch = manager.pending_user_updates.items[0].patch;
    try testing.expectEqual(@as(usize, 4), merged_patch.arr.len);
}

test "PresenceManager - coalesced pending update replaces duplicate field last-wins" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 1.0 } },
    });
    defer patch1.free(allocator);
    try manager.setUser(1, user_id, 1, patch1);

    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 2.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, 1, patch2);

    const merged_patch = manager.pending_user_updates.items[0].patch;
    try testing.expectEqual(@as(usize, 2), merged_patch.arr.len);
    try testing.expectEqual(@as(u64, 0), merged_patch.arr[0].uint);
    try testing.expectEqual(@as(f64, 2.0), merged_patch.arr[1].float);
}

test "PresenceManager - setShared coalesces pending shared updates for same namespace" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .uint = 5 } },
    });
    defer patch1.free(allocator);
    try manager.setShared(1, patch1, 42);

    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 1, .value = .{ .bool = true } },
    });
    defer patch2.free(allocator);
    try manager.setShared(1, patch2, 43);

    try testing.expectEqual(@as(usize, 1), manager.pending_shared_updates.items.len);
    const merged_patch = manager.pending_shared_updates.items[0].patch;
    try testing.expectEqual(@as(usize, 4), merged_patch.arr.len);
    try testing.expectEqual(@as(u64, 43), manager.pending_shared_updates.items[0].source_conn);
}

test "PresenceManager - removeUser cleans up and queues leave" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 1.0 } },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);

    try manager.removeUser(1, user_id);

    // If the user joined and left before flush, the pending join update is canceled
    // rather than emitting a leave event.
    try testing.expectEqual(@as(usize, 0), manager.pending_user_updates.items.len);

    try testing.expectEqual(@as(usize, 1), manager.namespace_empty_at.count());
}

test "PresenceManager - removeUser on nonexistent namespace is no-op" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    try manager.removeUser(999, zeroDocId);

    try testing.expectEqual(@as(usize, 0), manager.pending_user_updates.items.len);
}

test "PresenceManager - onSubscribeUser returns snapshot" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("online", allocator) },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);

    var snapshot = try manager.onSubscribeUser(1, 100, 1);
    defer snapshot.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.users.items.len);
    try testing.expectEqual(user_id, snapshot.users.items[0].user_id);

    const subs = manager.user_subscribers.get(1) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), subs.len);
    try testing.expectEqual(@as(u64, 100), subs[0].conn_id);
}

test "PresenceManager - onSubscribeShared returns current state" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    var set_patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .uint = 3 } },
    });
    defer set_patch.free(allocator);
    try manager.setShared(1, set_patch, 42);

    var shared = try manager.onSubscribeShared(1, 200, 1);
    try testing.expect(shared != null);
    if (shared) |*rec| {
        defer rec.deinit(allocator);
        try testing.expect(rec.values[0] != null);
    }

    const subs = manager.shared_subscribers.get(1) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), subs.len);
}

test "PresenceManager - onSubscribeShared returns null when no state" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const shared = try manager.onSubscribeShared(1, 200, 1);
    try testing.expect(shared == null);
}

test "PresenceManager - onUnsubscribeUser removes subscriber" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    _ = try manager.onSubscribeUser(1, 100, 1);
    _ = try manager.onSubscribeUser(1, 200, 2);

    {
        const subs = manager.user_subscribers.get(1) orelse return error.TestExpectedValue;
        try testing.expectEqual(@as(usize, 2), subs.len);
    }

    manager.onUnsubscribeUser(1, 100);

    {
        const subs = manager.user_subscribers.get(1) orelse return error.TestExpectedValue;
        try testing.expectEqual(@as(usize, 1), subs.len);
        try testing.expectEqual(@as(u64, 200), subs[0].conn_id);
    }
}

test "PresenceManager - setUser cancels grace period" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 1.0 } },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);
    try manager.removeUser(1, user_id);

    try testing.expectEqual(@as(usize, 1), manager.namespace_empty_at.count());

    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 2.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, 1, patch2);

    try testing.expectEqual(@as(usize, 0), manager.namespace_empty_at.count());
}

test "PresenceManager - multiple users in same namespace" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_a = zeroDocId;
    var user_b_bytes = [_]u8{1} ** 16;
    const user_b = try docIdFromBytes(&user_b_bytes);

    var patch_a = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("a", allocator) },
    });
    defer patch_a.free(allocator);
    try manager.setUser(1, user_a, 1, patch_a);

    var patch_b = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("b", allocator) },
    });
    defer patch_b.free(allocator);
    try manager.setUser(1, user_b, 1, patch_b);

    const ns_map = manager.user_state.get(1) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 2), ns_map.count());

    var snapshot = try manager.onSubscribeUser(1, 300, 1);
    defer snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), snapshot.users.items.len);
}

test "PresenceManager - setUser tracks joined_at timestamp" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    try manager.setUser(1, user_id, 1, patch);

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
    try manager.setUser(1, user_id, 1, patch2);

    const joined_ns2 = manager.user_joined_at.get(1) orelse return error.TestExpectedValue;
    const joined_at2 = joined_ns2.get(user_id) orelse return error.TestExpectedValue;
    try testing.expectEqual(original_joined_at, joined_at2);
}

test "PresenceManager - removeUser cleans up joined_at" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);

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
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;

    // First setUser should mark is_new_user = true
    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch1.free(allocator);
    try manager.setUser(1, user_id, 1, patch1);
    try testing.expect(manager.pending_user_updates.items[0].is_new_user);

    // Second setUser is merged into the existing pending join update.
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 200.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, 1, patch2);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[0].is_new_user);

    // removeUser cancels the unflushed join update entirely.
    try manager.removeUser(1, user_id);
    try testing.expectEqual(@as(usize, 0), manager.pending_user_updates.items.len);
}

test "PresenceManager - snapshot includes joined_at" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("online", allocator) },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);

    var snapshot = try manager.onSubscribeUser(1, 100, 1);
    defer snapshot.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.users.items.len);
    try testing.expect(snapshot.users.items[0].joined_at > 0);
}

test "PresenceManager - leave event after successful flush is preserved" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;

    // Join user
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("online", allocator) },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(!manager.pending_user_updates.items[0].is_leave);

    // Flush: drain pending batches to simulate a successful flush cycle
    // After drain, pending_user_updates is cleared.
    {
        var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
        defer {
            for (user_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            user_batches.deinit(allocator);
        }
        var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
        defer {
            for (shared_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            shared_batches.deinit(allocator);
        }
        try manager.drainPendingBatches(&user_batches, &shared_batches);
        try testing.expectEqual(@as(usize, 0), manager.pending_user_updates.items.len);
        try testing.expectEqual(@as(usize, 1), user_batches.items.len);
        try testing.expectEqual(@as(usize, 1), user_batches.items[0].updates.items.len);
    }

    // Leave: after flush, removeUser queues a new leave entry in pending_user_updates
    try manager.removeUser(1, user_id);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[0].is_leave);
    try testing.expect(manager.pending_user_updates.items[0].patch == .nil);

    // Second flush: leave should survive the cleanup and appear in the batch
    {
        var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
        defer {
            for (user_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            user_batches.deinit(allocator);
        }
        var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
        defer {
            for (shared_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            shared_batches.deinit(allocator);
        }
        try manager.drainPendingBatches(&user_batches, &shared_batches);
        try testing.expectEqual(@as(usize, 1), user_batches.items.len);
        try testing.expectEqual(@as(usize, 1), user_batches.items[0].updates.items.len);
        try testing.expect(user_batches.items[0].updates.items[0].is_leave);
        try testing.expect(user_batches.items[0].updates.items[0].patch == .nil);
    }
}

test "PresenceManager - leave event with leftover transferred item is preserved" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;

    // Join user
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("online", allocator) },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);

    // Flush successfully — pending_user_updates is cleared
    {
        var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
        defer {
            for (user_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            user_batches.deinit(allocator);
        }
        var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
        defer {
            for (shared_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            shared_batches.deinit(allocator);
        }
        try manager.drainPendingBatches(&user_batches, &shared_batches);
    }

    // User makes an update (patch != .nil)
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 42.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, 1, patch2);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[0].patch != .nil);
    try testing.expect(!manager.pending_user_updates.items[0].is_leave);

    // Now simulate a failed partial drain:
    //   Free the patch and null it (as drainPendingBatches does after transferring to a batch),
    //   but leave the item in the list (as happens when success stays false).
    if (manager.pending_user_updates.items[0].patch != .nil) manager.pending_user_updates.items[0].patch.free(allocator);
    manager.pending_user_updates.items[0].patch = .nil;

    // User leaves — removeUser should convert the leftover transferred item into a leave
    // (not early-return because is_leave is false on the transferred item).
    try manager.removeUser(1, user_id);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[0].is_leave);

    // Next flush: the leave should survive the cleanup and appear in the batch
    {
        var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
        defer {
            for (user_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            user_batches.deinit(allocator);
        }
        var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
        defer {
            for (shared_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            shared_batches.deinit(allocator);
        }
        try manager.drainPendingBatches(&user_batches, &shared_batches);
        try testing.expectEqual(@as(usize, 1), user_batches.items.len);
        try testing.expectEqual(@as(usize, 1), user_batches.items[0].updates.items.len);
        try testing.expect(user_batches.items[0].updates.items[0].is_leave);
    }
}

test "PresenceManager - setUser after removeUser coalesce resets is_leave" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;

    // Join user
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("online", allocator) },
    });
    defer patch.free(allocator);
    try manager.setUser(1, user_id, 1, patch);

    // Flush to clear pending
    {
        var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
        defer {
            for (user_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            user_batches.deinit(allocator);
        }
        var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
        defer {
            for (shared_batches.items) |*batch| {
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }
            shared_batches.deinit(allocator);
        }
        try manager.drainPendingBatches(&user_batches, &shared_batches);
    }

    // Update (existing user, not new)
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 42.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, 1, patch2);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(!manager.pending_user_updates.items[0].is_new_user);
    try testing.expect(!manager.pending_user_updates.items[0].is_leave);

    // Remove user — converts pending update to is_leave=true, patch=null
    try manager.removeUser(1, user_id);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[0].is_leave);
    try testing.expect(manager.pending_user_updates.items[0].patch == .nil);

    // Set user again — coalesces with the leave-converted pending update
    var patch3 = try makePresencePatch(allocator, &.{
        .{ .idx = 1, .value = .{ .float = 99.0 } },
    });
    defer patch3.free(allocator);
    try manager.setUser(1, user_id, 1, patch3);

    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(!manager.pending_user_updates.items[0].is_leave);
    try testing.expect(manager.pending_user_updates.items[0].is_new_user);
    try testing.expect(manager.pending_user_updates.items[0].patch != .nil);
}

test "PresenceManager - second connection keeps user after first leaves" {
    const allocator = std.testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch1.free(allocator);
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 1, .value = .{ .float = 200.0 } },
    });
    defer patch2.free(allocator);

    try manager.setUser(1, user_id, 100, patch1);
    try manager.setUser(1, user_id, 200, patch2);
    try flushPending(&manager, allocator);

    try manager.removeConnection(1, user_id, 100);
    try testing.expect(manager.user_state.get(1) != null);
    try testing.expect(manager.user_connections.get(1) != null);
    for (manager.pending_user_updates.items) |update| {
        try testing.expect(!update.is_leave);
    }

    try manager.removeConnection(1, user_id, 200);
    try testing.expect(manager.user_state.get(1) == null);
    try testing.expect(manager.user_connections.get(1) == null);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[0].is_leave);
}

test "PresenceManager - removeAllForConnection only clears the last connection" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch1.free(allocator);
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 1, .value = .{ .float = 200.0 } },
    });
    defer patch2.free(allocator);

    try manager.setUser(1, user_id, 100, patch1);
    try manager.setUser(1, user_id, 200, patch2);
    try flushPending(&manager, allocator);

    try manager.removeAllForConnection(1, user_id, 100);
    try testing.expect(manager.user_state.get(1) != null);
    for (manager.pending_user_updates.items) |update| {
        try testing.expect(!update.is_leave);
    }

    try manager.removeAllForConnection(1, user_id, 200);
    try testing.expect(manager.user_state.get(1) == null);
    try testing.expectEqual(@as(usize, 1), manager.pending_user_updates.items.len);
    try testing.expect(manager.pending_user_updates.items[0].is_leave);
}

test "PresenceManager - removeConnection ignores unknown and repeated connections" {
    const allocator = std.heap.smp_allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    try manager.setUser(1, user_id, 100, patch);

    // A connection that never wrote presence does not remove the record.
    try manager.removeConnection(1, user_id, 999);
    try testing.expect(manager.user_state.get(1) != null);

    try manager.removeConnection(1, user_id, 100);
    try testing.expect(manager.user_state.get(1) == null);

    // Repeated teardown is a no-op.
    try manager.removeConnection(1, user_id, 100);
    try testing.expect(manager.user_state.get(1) == null);

    // A new write from the same connection recreates the record.
    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 101.0 } },
    });
    defer patch2.free(allocator);
    try manager.setUser(1, user_id, 100, patch2);
    try testing.expect(manager.user_state.get(1) != null);
    try manager.removeConnection(1, user_id, 100);
    try testing.expect(manager.user_state.get(1) == null);
}

test "PresenceManager - failed setUser does not keep a stale connection registration" {
    const allocator = std.testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var valid = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer valid.free(allocator);

    // A contributes and its join is flushed.
    try manager.setUser(1, user_id, 100, valid);
    try flushPending(&manager, allocator);

    // B is newly tracked; setUserLocked rejects the out-of-range field.
    var invalid = try makePresencePatch(allocator, &.{
        .{ .idx = 99, .value = .{ .float = 1.0 } },
    });
    defer invalid.free(allocator);
    try testing.expectError(error.InvalidFieldIndex, manager.setUser(1, user_id, 200, invalid));

    // B must be rolled back, leaving A as the last contributor.
    try manager.removeConnection(1, user_id, 100);
    try testing.expect(manager.user_state.get(1) == null);
    try testing.expect(manager.user_connections.get(1) == null);
}

test "PresenceManager - failed setUser keeps an existing connection registration" {
    const allocator = std.testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var manager: PresenceManager = undefined;
    manager.init(testing.io, allocator, user_fields, shared_fields);
    defer manager.deinit();

    const user_id = zeroDocId;
    var valid = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer valid.free(allocator);
    var invalid = try makePresencePatch(allocator, &.{
        .{ .idx = 99, .value = .{ .float = 1.0 } },
    });
    defer invalid.free(allocator);

    try manager.setUser(1, user_id, 100, valid);
    try flushPending(&manager, allocator);

    // The connection was tracked before this call; a failed write keeps it.
    try testing.expectError(error.InvalidFieldIndex, manager.setUser(1, user_id, 100, invalid));

    try manager.removeConnection(1, user_id, 100);
    try testing.expect(manager.user_state.get(1) == null);
}

fn flushPending(manager: *PresenceManager, allocator: std.mem.Allocator) !void {
    var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
    defer {
        for (user_batches.items) |*batch| {
            for (batch.updates.items) |*update| update.patch.free(allocator);
            batch.updates.deinit(allocator);
            batch.subscribers.deinit(allocator);
        }
        user_batches.deinit(allocator);
    }
    var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
    defer {
        for (shared_batches.items) |*batch| {
            for (batch.updates.items) |*update| update.patch.free(allocator);
            batch.updates.deinit(allocator);
            batch.subscribers.deinit(allocator);
        }
        shared_batches.deinit(allocator);
    }
    try manager.drainPendingBatches(&user_batches, &shared_batches);
}
