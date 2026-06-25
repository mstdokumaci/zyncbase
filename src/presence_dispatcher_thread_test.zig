const std = @import("std");
const testing = std.testing;
const PresenceDispatcherThread = @import("presence/dispatcher_thread.zig").PresenceDispatcherThread;
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

test "PresenceDispatcherThread: lifecycle start and stop" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    // SAFETY: Immediately initialized by init() call below.
    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    var dispatcher: PresenceDispatcherThread = undefined;
    dispatcher.init(
        allocator,
        &presence_manager,
        &send_queue,
        notifierFn,
        &notifier_called,
    );
    defer dispatcher.deinit();

    try dispatcher.start();
    dispatcher.stop();
}

test "PresenceDispatcherThread: flush drains pending user updates to send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    // SAFETY: Immediately initialized by init() call below.
    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    // Add a subscriber for namespace 1
    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;

    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    // Create a pending user update
    const user_id: typed.DocId = 42;
    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 100.0 } },
    });
    defer patch.free(allocator);

    try presence_manager.setUser(namespace_id, user_id, patch);

    // Start dispatcher and signal it
    var dispatcher: PresenceDispatcherThread = undefined;
    dispatcher.init(
        allocator,
        &presence_manager,
        &send_queue,
        notifierFn,
        &notifier_called,
    );
    defer dispatcher.deinit();
    defer dispatcher.stop();

    try dispatcher.start();

    dispatcher.signal();

    // Wait for processing (flush interval is 50ms)
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify send_queue received the broadcast
    try testing.expect(send_queue.hasItems());

    // Verify notifier was called
    try testing.expect(notifier_called.load(.monotonic) > 0);

    // Drain and free the send_queue entry
    if (send_queue.pop()) |entry| {
        allocator.free(entry.data);
    }
}

test "PresenceDispatcherThread: no pending work does not push to send_queue" {
    const allocator = testing.allocator;
    const user_fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, user_fields);
    const shared_fields = try makeTestSharedFields(allocator);
    defer freeTestFields(allocator, shared_fields);

    // SAFETY: Immediately initialized by init() call below.
    var presence_manager: PresenceManager = undefined;
    presence_manager.init(allocator, user_fields, shared_fields);
    defer presence_manager.deinit();

    var send_queue = try send_queue_type.init(allocator);
    defer send_queue.deinit();

    var notifier_called = std.atomic.Value(u32).init(0);

    // Add a subscriber but no pending updates
    const conn_id: u64 = 100;
    const sub_id: u64 = 200;
    const namespace_id: i64 = 1;

    var snapshot = try presence_manager.onSubscribeUser(namespace_id, conn_id, sub_id);
    defer snapshot.deinit(allocator);

    // Start dispatcher and signal it
    var dispatcher: PresenceDispatcherThread = undefined;
    dispatcher.init(
        allocator,
        &presence_manager,
        &send_queue,
        notifierFn,
        &notifier_called,
    );
    defer dispatcher.deinit();
    defer dispatcher.stop();

    try dispatcher.start();

    dispatcher.signal();

    // Wait for processing
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify send_queue is empty (no pending work)
    try testing.expect(!send_queue.hasItems());

    // Verify notifier was NOT called
    try testing.expectEqual(@as(u32, 0), notifier_called.load(.monotonic));
}
