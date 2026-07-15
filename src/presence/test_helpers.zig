const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const schema_types = @import("../schema/types.zig");

pub fn makeTestUserFields(allocator: std.mem.Allocator) ![]const schema_types.PresenceField {
    const fields = try allocator.alloc(schema_types.PresenceField, 3);
    errdefer allocator.free(fields);
    const cursor_x = try allocator.dupe(u8, "cursor__x");
    errdefer allocator.free(cursor_x);
    fields[0] = .{ .name = cursor_x, .declared_type = .real };
    const cursor_y = try allocator.dupe(u8, "cursor__y");
    errdefer allocator.free(cursor_y);
    fields[1] = .{ .name = cursor_y, .declared_type = .real };
    fields[2] = .{ .name = try allocator.dupe(u8, "status"), .declared_type = .text };
    return fields;
}

pub fn freeTestFields(allocator: std.mem.Allocator, fields: []const schema_types.PresenceField) void {
    for (fields) |f| f.deinit(allocator);
    allocator.free(fields);
}

pub fn makeTestSharedFields(allocator: std.mem.Allocator) ![]const schema_types.PresenceField {
    const fields = try allocator.alloc(schema_types.PresenceField, 2);
    errdefer allocator.free(fields);
    fields[0] = .{ .name = try allocator.dupe(u8, "slide"), .declared_type = .integer };
    errdefer allocator.free(fields[0].name);
    fields[1] = .{ .name = try allocator.dupe(u8, "playing"), .declared_type = .boolean };
    return fields;
}

pub fn makeTestSharedSingleField(allocator: std.mem.Allocator) ![]const schema_types.PresenceField {
    const fields = try allocator.alloc(schema_types.PresenceField, 1);
    errdefer allocator.free(fields);
    fields[0] = .{ .name = try allocator.dupe(u8, "slide"), .declared_type = .integer };
    return fields;
}

pub fn makePresencePatch(allocator: std.mem.Allocator, entries: []const struct { idx: usize, value: msgpack.Payload }) !msgpack.Payload {
    const pairs = try allocator.alloc(msgpack.Payload, entries.len);
    errdefer allocator.free(pairs);
    var i: usize = 0;
    errdefer {
        for (pairs[0..i]) |p| {
            allocator.free(p.arr);
        }
    }
    while (i < entries.len) : (i += 1) {
        const entry = entries[i];
        const pair = try allocator.alloc(msgpack.Payload, 2);
        pair[0] = msgpack.Payload.uintToPayload(entry.idx);
        pair[1] = entry.value;
        pairs[i] = .{ .arr = pair };
    }
    return .{ .arr = pairs };
}
