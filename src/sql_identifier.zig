const std = @import("std");

pub fn appendQuoted(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    identifier: []const u8,
) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, identifier);
    try buf.append(allocator, '"');
}

pub fn appendQualified(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    qualifier: []const u8,
    identifier: []const u8,
) !void {
    try appendQuoted(allocator, buf, qualifier);
    try buf.append(allocator, '.');
    try appendQuoted(allocator, buf, identifier);
}
