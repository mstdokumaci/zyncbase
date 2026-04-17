const std = @import("std");
const types = @import("storage_engine/types.zig");
const TypedValue = types.TypedValue;
const TypedRow = types.TypedRow;
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
    try result.sortedSet(allocator);
    return result;
}

pub const IndexedValue = struct {
    index: usize,
    value: TypedValue,
};

/// Creates a TypedRow without schema metadata.
/// Initializes all slots to nil, sets canonical trailing system timestamps
/// (`created_at`, `updated_at`) to 0 when present, then applies overrides.
pub fn rowFromIndexedValues(
    allocator: std.mem.Allocator,
    overrides: []const IndexedValue,
) !TypedRow {
    // Canonical minimum shape:
    // [id, namespace_id, created_at, updated_at]
    var value_count: usize = 4;
    for (overrides) |override| {
        const needed = override.index + 3;
        if (needed > value_count) value_count = needed;
    }

    const values = try allocator.alloc(TypedValue, value_count);
    errdefer allocator.free(values);

    for (values) |*value| value.* = valNil();

    // Canonical layout is:
    // [id, namespace_id, user fields..., created_at, updated_at]
    // In metadata-free tests, treat the trailing two slots as timestamps.
    if (values.len >= 2) {
        values[values.len - 2] = valInt(0);
        values[values.len - 1] = valInt(0);
    }

    for (overrides) |override| {
        if (override.index >= values.len) return error.IndexOutOfBounds;
        values[override.index] = try override.value.clone(allocator);
    }

    return .{ .values = values };
}
