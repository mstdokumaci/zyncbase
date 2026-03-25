const std = @import("std");
const MessageHandler = @import("message_handler.zig").MessageHandler;
const msgpack = @import("msgpack_test_helpers.zig");

pub fn routeWithArena(handler: *MessageHandler, allocator: std.mem.Allocator, conn_id: u64, msg_info: MessageHandler.MessageInfo, parsed: msgpack.Payload) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try handler.routeMessage(arena.allocator(), conn_id, msg_info, parsed);
    return try allocator.dupe(u8, result);
}
