const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const schema_types = @import("../schema/types.zig");

pub fn makeTestUserFields(allocator: std.mem.Allocator) ![]const schema_types.PresenceField {
    const fields = try allocator.alloc(schema_types.PresenceField, 3);
    fields[0] = .{ .name = try allocator.dupe(u8, "cursor__x"), .declared_type = .real };
    fields[1] = .{ .name = try allocator.dupe(u8, "cursor__y"), .declared_type = .real };
    fields[2] = .{ .name = try allocator.dupe(u8, "status"), .declared_type = .text };
    return fields;
}

pub fn freeTestFields(allocator: std.mem.Allocator, fields: []const schema_types.PresenceField) void {
    for (fields) |f| f.deinit(allocator);
    allocator.free(fields);
}

pub fn makeTestSharedFields(allocator: std.mem.Allocator) ![]const schema_types.PresenceField {
    const fields = try allocator.alloc(schema_types.PresenceField, 2);
    fields[0] = .{ .name = try allocator.dupe(u8, "slide"), .declared_type = .integer };
    fields[1] = .{ .name = try allocator.dupe(u8, "playing"), .declared_type = .boolean };
    return fields;
}

pub fn makeTestSharedSingleField(allocator: std.mem.Allocator) ![]const schema_types.PresenceField {
    const fields = try allocator.alloc(schema_types.PresenceField, 1);
    fields[0] = .{ .name = try allocator.dupe(u8, "slide"), .declared_type = .integer };
    return fields;
}

pub fn makePresencePatch(allocator: std.mem.Allocator, entries: []const struct { idx: usize, value: msgpack.Payload }) !msgpack.Payload {
    var pairs = try allocator.alloc(msgpack.Payload, entries.len);
    for (entries, 0..) |entry, i| {
        var pair = try allocator.alloc(msgpack.Payload, 2);
        pair[0] = msgpack.Payload.uintToPayload(entry.idx);
        pair[1] = entry.value;
        pairs[i] = .{ .arr = pair };
    }
    return .{ .arr = pairs };
}
