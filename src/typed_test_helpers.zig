const std = @import("std");
const typed = @import("typed.zig");
const TypedValue = typed.TypedValue;
const TypedRecord = typed.TypedRecord;
const ScalarValue = typed.ScalarValue;

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
    try result.sortedSet(allocator);
    return result;
}

/// Creates a TypedRecord without schema metadata.
/// Initializes all slots to nil, sets canonical trailing system timestamps
/// (`created_at`, `updated_at`) to 0 when present, then applies values starting at index 3.
pub fn recordFromTypedValues(
    allocator: std.mem.Allocator,
    typed_values: []const TypedValue,
) !TypedRecord {
    // Canonical minimum shape:
    // [id, namespace_id, owner_id, created_at, updated_at]
    const value_count: usize = @max(5, typed_values.len + 5);

    const values = try allocator.alloc(TypedValue, value_count);
    errdefer allocator.free(values);

    for (values) |*value| value.* = valNil();

    // Canonical layout is:
    // [id, namespace_id, owner_id, user fields..., created_at, updated_at]
    // In metadata-free tests, treat the trailing two slots as timestamps.
    if (values.len >= 2) {
        values[values.len - 2] = valInt(0);
        values[values.len - 1] = valInt(0);
    }

    for (typed_values, 0..) |value, index| {
        values[index + 3] = try value.clone(allocator);
    }

    return .{ .values = values };
}
