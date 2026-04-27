const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../msgpack_utils.zig");
const Payload = msgpack.Payload;

/// Extracts a struct of type T from a MessagePack map.
/// Uses ArenaAllocator or similar batch-deallocation for dynamic fields.
pub fn extractAs(comptime T: type, allocator: Allocator, payload: Payload) !T {
    if (payload != .map) return error.InvalidMessageFormat;

    var result: T = comptime blk: {
        // SAFETY: All fields are either initialized with defaults below or will be
        // explicitly set during payload extraction.
        var base: T = undefined;
        for (std.meta.fields(T)) |field| {
            if (field.default_value_ptr) |ptr| {
                const val = @as(*const field.type, @ptrCast(@alignCast(ptr))).*;
                @field(base, field.name) = val;
            }
        }
        break :blk base;
    };
    var found = [_]u8{0} ** std.meta.fields(T).len;

    var it = payload.map.iterator();
    outer: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (key != .str) continue;
        const key_str = key.str.value();

        inline for (std.meta.fields(T), 0..) |field, i| {
            if (std.mem.eql(u8, key_str, field.name)) {
                found[i] = 1;
                @field(result, field.name) = try extractValue(field.type, allocator, val);
                continue :outer;
            }
        }
    }

    inline for (std.meta.fields(T), 0..) |field, i| {
        if (found[i] == 0) {
            if (field.default_value_ptr != null) {
                // Default value already applied
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.MissingRequiredFields;
            }
        }
    }

    return result;
}

fn extractValue(comptime T: type, allocator: Allocator, val: Payload) anyerror!T {
    if (T == Payload) return val;
    if (T == ?Payload) return val;

    switch (@typeInfo(T)) {
        .bool => {
            if (val == .bool) return val.bool;
            return error.InvalidMessageFormat;
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                if (val == .str) return val.str.value();
                return error.InvalidMessageFormat;
            } else if (ptr.child == []const u8) {
                if (val == .arr) {
                    const arr = val.arr;
                    const slice = try allocator.alloc([]const u8, arr.len);
                    errdefer allocator.free(slice);
                    var valid = true;
                    for (arr, 0..) |elem, j| {
                        if (elem != .str) {
                            valid = false;
                            break;
                        }
                        slice[j] = elem.str.value();
                    }
                    if (!valid) return error.InvalidMessageFormat;
                    return slice;
                }
                return error.InvalidMessageFormat;
            } else {
                @compileError("Unsupported pointer field type: " ++ @typeName(T));
            }
        },
        .int => {
            if (val == .uint) return std.math.cast(T, val.uint) orelse error.InvalidMessageFormat;
            if (val == .int) return std.math.cast(T, val.int) orelse error.InvalidMessageFormat;
            return error.InvalidMessageFormat;
        },
        .optional => |opt| {
            if (val == .nil) return null;
            return try extractValue(opt.child, allocator, val);
        },
        else => {
            @compileError("Unsupported type: " ++ @typeName(T));
        },
    }
}
