const std = @import("std");
const types = @import("storage_engine/types.zig");
const TypedValue = types.TypedValue;
const TypedRow = types.TypedRow;
const FieldEntry = types.FieldEntry;
const ScalarValue = types.ScalarValue;

pub fn valText(t: []const u8) TypedValue {
    return .{ .scalar = .{ .text = t } };
}

pub fn valTextOwned(allocator: std.mem.Allocator, t: []const u8) !TypedValue {
    return .{ .scalar = .{ .text = try allocator.dupe(u8, t) } };
}

pub fn valInt(i: i64) TypedValue {
    return .{ .scalar = .{ .integer = i } };
}

pub fn valReal(r: f64) TypedValue {
    return .{ .scalar = .{ .real = r } };
}

pub fn valBool(b: bool) TypedValue {
    return .{ .scalar = .{ .boolean = b } };
}

pub fn valNil() TypedValue {
    return .nil;
}

pub fn valArray(allocator: std.mem.Allocator, scalars: []const ScalarValue) !TypedValue {
    const cloned = try allocator.alloc(ScalarValue, scalars.len);
    for (scalars, 0..) |s, i| {
        cloned[i] = switch (s) {
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            else => s,
        };
    }
    var result: TypedValue = .{ .array = cloned };
    result.sortedSet(allocator);
    return result;
}

pub fn row(allocator: std.mem.Allocator, fields: anytype) !TypedRow {
    const T = @TypeOf(fields);
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("row fields must be a struct");

    const entries = try allocator.alloc(FieldEntry, info.@"struct".fields.len);
    inline for (info.@"struct".fields, 0..) |f, i| {
        const val = @field(fields, f.name);
        entries[i] = .{
            .name = f.name,
            .value = try val.clone(allocator),
        };
    }
    return .{ .fields = entries };
}
