const std = @import("std");
const testing = std.testing;
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const NotificationDispatcher = @import("notification_dispatcher.zig").NotificationDispatcher;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const encodeDeltaSuffix = @import("notification_dispatcher.zig").encodeDeltaSuffix;

// ============================================================
// encodeDeltaSuffix tests
// ============================================================

test "NotificationDispatcher encodeDeltaSuffix: set operation" {
    const alloc = testing.allocator;

    const id_payload = msgpack.Payload.uintToPayload(12345);
    const suffix = try encodeDeltaSuffix(alloc, "users", id_payload, false, null);
    defer alloc.free(suffix);

    // Decode and verify
    const full_msg = try std.mem.concat(alloc, u8, &.{ &[_]u8{0x81}, suffix });
    defer alloc.free(full_msg);
    var reader: std.Io.Reader = .fixed(full_msg);
    const p = try msgpack.decodeTrusted(alloc, &reader);
    defer p.free(alloc);

    const ops_opt = try p.mapGet("ops");
    try testing.expect(ops_opt != null);
    const ops = ops_opt.?;

    try testing.expect(ops == .arr);
    try testing.expectEqual(@as(usize, 1), ops.arr.len);

    const op_obj = ops.arr[0];
    try testing.expect(op_obj == .map);

    const op_opt = try op_obj.mapGet("op");
    try testing.expect(op_opt != null);
    const op = op_opt.?;

    try testing.expectEqualStrings("set", op.str.value());

    const path_opt = try op_obj.mapGet("path");
    try testing.expect(path_opt != null);
    const path = path_opt.?;

    try testing.expect(path == .arr);
    try testing.expectEqual(@as(usize, 2), path.arr.len);
    try testing.expectEqualStrings("users", path.arr[0].str.value());
    try testing.expectEqual(@as(u64, 12345), path.arr[1].uint);

    const value_opt = try op_obj.mapGet("value");
    try testing.expect(value_opt != null);
    const value = value_opt.?;
    try testing.expect(value == .nil);
}

test "NotificationDispatcher encodeDeltaSuffix: delete operation" {
    const alloc = testing.allocator;

    const id_payload = msgpack.Payload.uintToPayload(999);
    const suffix = try encodeDeltaSuffix(alloc, "items", id_payload, true, null);
    defer alloc.free(suffix);

    // Decode and verify
    const full_msg = try std.mem.concat(alloc, u8, &.{ &[_]u8{0x81}, suffix });
    defer alloc.free(full_msg);
    var reader: std.Io.Reader = .fixed(full_msg);
    const p = try msgpack.decodeTrusted(alloc, &reader);
    defer p.free(alloc);

    const ops_opt = try p.mapGet("ops");
    try testing.expect(ops_opt != null);
    const ops = ops_opt.?;
    const op_obj = ops.arr[0];

    const op_opt = try op_obj.mapGet("op");
    try testing.expect(op_opt != null);
    const op = op_opt.?;
    try testing.expectEqualStrings("remove", op.str.value());

    const path_opt = try op_obj.mapGet("path");
    try testing.expect(path_opt != null);
    const path = path_opt.?;
    try testing.expectEqualStrings("items", path.arr[0].str.value());
    try testing.expectEqual(@as(u64, 999), path.arr[1].uint);

    // No "value" key for delete
    try testing.expect((try op_obj.mapGet("value")) == null);
}

test "NotificationDispatcher encodeDeltaSuffix: with string id" {
    const alloc = testing.allocator;

    const id_payload = try Payload.strToPayload("doc-abc-123", alloc);
    defer id_payload.free(alloc);

    const suffix = try encodeDeltaSuffix(alloc, "posts", id_payload, false, null);
    defer alloc.free(suffix);

    // Decode and verify
    const full_msg = try std.mem.concat(alloc, u8, &.{ &[_]u8{0x81}, suffix });
    defer alloc.free(full_msg);
    var reader: std.Io.Reader = .fixed(full_msg);
    const p = try msgpack.decodeTrusted(alloc, &reader);
    defer p.free(alloc);

    const ops_opt = try p.mapGet("ops");
    try testing.expect(ops_opt != null);
    const ops = ops_opt.?;
    const op_obj = ops.arr[0];

    const path_opt = try op_obj.mapGet("path");
    try testing.expect(path_opt != null);
    const path = path_opt.?;
    try testing.expectEqualStrings("posts", path.arr[0].str.value());
    try testing.expectEqualStrings("doc-abc-123", path.arr[1].str.value());
}

// ============================================================
// Full dispatch integration tests
// ============================================================

test "NotificationDispatcher: empty poll" {
    const alloc = testing.allocator;

    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    var sub_engine = SubscriptionEngine.init(alloc);
    defer sub_engine.deinit();

    var memory: MemoryStrategy = undefined;
    try memory.init(alloc);
    defer memory.deinit();

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory);
    defer nd.deinit();

    var cm: ConnectionManager = undefined;
    nd.poll(&cm);
}

test "NotificationDispatcher: poll processes items" {
    const alloc = testing.allocator;

    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    var sub_engine = SubscriptionEngine.init(alloc);
    defer sub_engine.deinit();

    var memory: MemoryStrategy = undefined;
    try memory.init(alloc);
    defer memory.deinit();

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory);
    defer nd.deinit();

    // Create a row with an "id" field so dispatchChange doesn't skip it
    var row = Payload.mapPayload(alloc);
    try row.mapPut("id", Payload.uintToPayload(1));

    try cb.push(.{
        .namespace = try alloc.dupe(u8, "ns"),
        .collection = try alloc.dupe(u8, "coll"),
        .operation = .insert,
        .old_row = null,
        .new_row = row,
    });

    var cm: ConnectionManager = undefined;
    nd.poll(&cm);

    try testing.expectEqual(@as(usize, 0), nd.drain_buf.items.len);
}
