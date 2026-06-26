const std = @import("std");
const testing = std.testing;
const PresenceWorker = @import("presence/worker.zig").PresenceWorker;
const PresenceManager = @import("presence/manager.zig").PresenceManager;
const schema_mod = @import("schema.zig");
const msgpack = @import("msgpack_utils.zig");
const send_queue_type = @import("send_queue.zig").send_queue;
const typed = @import("typed.zig");

fn makeTestUserFields(allocator: std.mem.Allocator) ![]const schema_mod.PresenceField {
    const fields = try allocator.alloc(schema_mod.PresenceField, 2);
    fields[0] = .{ .name = try allocator.dupe(u8, "cursor__x"), .declared_type = .real };
    fields[1] = .{ .name = try allocator.dupe(u8, "status"), .declared_type = .text };
    return fields;
}

fn freeTestFields(allocator: std.mem.Allocator, fields: []const schema_mod.PresenceField) void {
    for (fields) |f| f.deinit(allocator);
    allocator.free(fields);
}

fn makeTestSharedFields(allocator: std.mem.Allocator) ![]const schema_mod.PresenceField {
    const fields = try allocator.alloc(schema_mod.PresenceField, 1);
    fields[0] = .{ .name = try allocator.dupe(u8, "slide"), .declared_type = .integer };
    return fields;
}

fn makePresencePatch(allocator: std.mem.Allocator, entries: []const struct { idx: usize, value: msgpack.Payload }) !msgpack.Payload {
    var patch = msgpack.Payload.mapPayload(allocator);
    for (entries) |entry| {
        try patch.mapPutGeneric(msgpack.Payload.uintToPayload(entry.idx), entry.value);
    }
    return patch;
}

fn notifierFn(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
    _ = counter.fetchAdd(1, .monotonic);
}

fn setupDispatcher(
    allocator: std.mem.Allocator,
    presence_manager: *PresenceManager,
    send_queue: *send_queue_type,
    notifier_counter: *std.atomic.Value(u32),
) !*PresenceWorker {
    const dispatcher = try allocator.create(PresenceWorker);
    try dispatcher.init(allocator, presence_manager, send_queue, notifierFn, notifier_counter);
    try dispatcher.spawn();
    return dispatcher;
}

test "PresenceWorker: lifecycle start and stop" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    const dispatcher = try setupDispatcher(allocator, &presence_manager, &send_queue, &notifier_called);
    defer {
        dispatcher.stop();
        dispatcher.deinit();
        allocator.destroy(dispatcher);
    }
}

test "PresenceWorker: set_user op produces broadcast to send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;

    // Subscribe synchronously so the dispatcher has a subscriber to broadcast to
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const dispatcher = try setupDispatcher(allocator, &presence_manager, &send_queue, &notifier_called);
    defer {
        dispatcher.stop();
        dispatcher.deinit();
        allocator.destroy(dispatcher);
    }

    // Enqueue a set_user op — the patch is cloned into the op's allocator
    const user_id: typed.DocId = 42;
    const patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    const cloned_patch = try patch.deepClone(allocator);
    try dispatcher.enqueue(.{
        .op = .{ .set_user = .{
            .namespace_id = namespace_id,
            .user_id = user_id,
            .patch = cloned_patch,
        } },
        .allocator = allocator,
    });

    // Wait for processing (condvar-based wakeup should be near-instant)
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue received the broadcast
    try testing.expect(send_queue.hasItems());

    // Verify notifier was called
    try testing.expect(notifier_called.load(.monotonic) > 0);

    // Drain and free the send_queue entry
    if (send_queue.pop()) |entry| {
        allocator.free(entry.data);
    }
}

test "PresenceWorker: no ops enqueued does not push to send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;

    // Add a subscriber but enqueue no ops
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const dispatcher = try setupDispatcher(allocator, &presence_manager, &send_queue, &notifier_called);
    defer {
        dispatcher.stop();
        dispatcher.deinit();
        allocator.destroy(dispatcher);
    }

    // Wait briefly — no work enqueued, nothing should happen
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue is empty
    try testing.expect(!send_queue.hasItems());

    // Verify notifier was NOT called
    try testing.expectEqual(@as(u32, 0), notifier_called.load(.monotonic));
}

test "PresenceWorker: subscribe_user op sends snapshot via send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    const dispatcher = try setupDispatcher(allocator, &presence_manager, &send_queue, &notifier_called);
    defer {
        dispatcher.stop();
        dispatcher.deinit();
        allocator.destroy(dispatcher);
    }

    // Enqueue a subscribe_user op
    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;
    const msg_id: u64 = 42;

    try dispatcher.enqueue(.{
        .op = .{ .subscribe_user = .{
            .namespace_id = namespace_id,
            .conn_id = conn_id,
            .sub_id = sub_id,
            .msg_id = msg_id,
        } },
        .allocator = allocator,
    });

    // Wait for processing
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue received the snapshot response
    try testing.expect(send_queue.hasItems());
    try testing.expect(notifier_called.load(.monotonic) > 0);

    // Drain and free
    if (send_queue.pop()) |entry| {
        allocator.free(entry.data);
    }
}

test "PresenceWorker: multiple ops batched into single flush" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;
    const user_id: typed.DocId = 42;

    // Subscribe synchronously
    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    const dispatcher = try setupDispatcher(allocator, &presence_manager, &send_queue, &notifier_called);
    defer {
        dispatcher.stop();
        dispatcher.deinit();
        allocator.destroy(dispatcher);
    }

    // Enqueue multiple set_user ops rapidly — they should coalesce in the
    // PresenceManager's pending list and produce a single broadcast.
    for (0..5) |i| {
        const patch = try makePresencePatch(allocator, &.{
            .{ .idx = 0, .value = .{ .float = @floatFromInt(i) } },
        });
        defer patch.free(allocator);
        const cloned = try patch.deepClone(allocator);
        try dispatcher.enqueue(.{
            .op = .{ .set_user = .{
                .namespace_id = namespace_id,
                .user_id = user_id,
                .patch = cloned,
            } },
            .allocator = allocator,
        });
    }

    // Wait for processing
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // The coalesced updates should produce at least one broadcast
    try testing.expect(send_queue.hasItems());

    // Drain all entries
    while (send_queue.pop()) |entry| {
        allocator.free(entry.data);
    }
}
