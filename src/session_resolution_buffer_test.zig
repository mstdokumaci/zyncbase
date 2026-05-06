const std = @import("std");
const testing = std.testing;
const session_resolution = @import("session_resolution_buffer.zig");
const SessionResolutionBuffer = session_resolution.SessionResolutionBuffer;
const SessionResolutionResult = session_resolution.SessionResolutionResult;

fn makeResult(index: usize) SessionResolutionResult {
    return .{
        .conn_id = @intCast(index),
        .msg_id = @intCast(index + 1),
        .scope_seq = @intCast(index + 2),
        .namespace_id = @intCast(index + 3),
        .user_doc_id = @intCast(index + 4),
        .err = null,
    };
}

test "SessionResolutionBuffer: overflow preserves results when ring is full" {
    const allocator = testing.allocator;
    var buffer = try SessionResolutionBuffer.init(allocator);
    defer buffer.deinit();

    const result_count = 300;
    for (0..result_count) |i| {
        try buffer.push(makeResult(i));
    }

    var out = std.ArrayListUnmanaged(SessionResolutionResult).empty;
    defer out.deinit(allocator);

    try buffer.drainInto(&out, allocator);
    try testing.expectEqual(@as(usize, result_count), out.items.len);

    for (out.items, 0..) |result, i| {
        try testing.expectEqual(@as(u64, @intCast(i)), result.conn_id);
        try testing.expectEqual(@as(u64, @intCast(i + 1)), result.msg_id);
        try testing.expectEqual(@as(u64, @intCast(i + 2)), result.scope_seq);
        try testing.expectEqual(@as(i64, @intCast(i + 3)), result.namespace_id);
        try testing.expectEqual(@as(u128, @intCast(i + 4)), result.user_doc_id);
    }

    out.clearRetainingCapacity();
    try buffer.drainInto(&out, allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
