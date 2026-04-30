const std = @import("std");
const types = @import("types.zig");

pub fn parseValue(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
}

pub fn cloneMetadata(allocator: std.mem.Allocator, value: std.json.Value) !types.Metadata {
    if (value != .object) return error.InvalidMetadata;

    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return .{ .json = try out.toOwnedSlice() };
}
