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
const writeMsgPackStr = @import("notification_dispatcher.zig").writeMsgPackStr;

// ============================================================
// writeMsgPackStr tests
// ============================================================

test "NotificationDispatcher writeMsgPackStr: fixstr (≤31 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    try writeMsgPackStr(buf.writer(testing.allocator), "type");
    // fixstr(4) = 0xa4 | "type" = 5 bytes
    try testing.expectEqual(@as(usize, 5), buf.items.len);
    try testing.expectEqual(@as(u8, 0xa4), buf.items[0]);
    try testing.expectEqualSlices(u8, "type", buf.items[1..]);
}

test "NotificationDispatcher writeMsgPackStr: str8 (≤255 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    const long_str = "a" ** 100;

    try writeMsgPackStr(buf.writer(testing.allocator), long_str[0..]);
    // str8(100) = 0xd9 | 0x64 | "a"*100 = 102 bytes
    try testing.expectEqual(@as(usize, 102), buf.items.len);
    try testing.expectEqual(@as(u8, 0xd9), buf.items[0]);
    try testing.expectEqual(@as(u8, 100), buf.items[1]);
}

test "NotificationDispatcher writeMsgPackStr: empty string" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    try writeMsgPackStr(buf.writer(testing.allocator), "");
    // fixstr(0) = 0xa0 = 1 byte
    try testing.expectEqual(@as(usize, 1), buf.items.len);
    try testing.expectEqual(@as(u8, 0xa0), buf.items[0]);
}

// ============================================================
// encodeDeltaSuffix tests
// ============================================================

test "NotificationDispatcher encodeDeltaSuffix: set operation" {
    const alloc = testing.allocator;

    const id_payload = msgpack.Payload.uintToPayload(12345);
    const suffix = try encodeDeltaSuffix(alloc, "users", id_payload, false, null);
    defer alloc.free(suffix);

    try testing.expect(suffix.len > 0);
}

test "NotificationDispatcher encodeDeltaSuffix: delete operation" {
    const alloc = testing.allocator;

    const id_payload = msgpack.Payload.uintToPayload(999);
    const suffix = try encodeDeltaSuffix(alloc, "items", id_payload, true, null);
    defer alloc.free(suffix);

    try testing.expect(suffix.len > 0);
}

test "NotificationDispatcher encodeDeltaSuffix: with string id" {
    const alloc = testing.allocator;

    const id_payload = try Payload.strToPayload("doc-abc-123", alloc);
    defer id_payload.free(alloc);

    const suffix = try encodeDeltaSuffix(alloc, "posts", id_payload, false, null);
    defer alloc.free(suffix);

    try testing.expect(suffix.len > 0);
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
