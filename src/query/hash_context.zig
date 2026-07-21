const std = @import("std");
const typed = @import("../typed/types.zig");
const query_ast = @import("ast.zig");

const Condition = query_ast.Condition;
const ScalarValue = typed.ScalarValue;
const Value = typed.Value;

pub fn hashValue(hasher: *std.hash.Wyhash, v: Value) void {
    std.hash.autoHash(hasher, std.meta.activeTag(v));
    switch (v) {
        .scalar => |s| hashScalarValue(hasher, s),
        .array => |arr| {
            for (arr) |item| hashScalarValue(hasher, item);
        },
        .nil => {},
    }
}

pub fn hashScalarValue(hasher: *std.hash.Wyhash, s: ScalarValue) void {
    std.hash.autoHash(hasher, std.meta.activeTag(s));
    switch (s) {
        .text => |t| hasher.update(t),
        .doc_id => |id| std.hash.autoHash(hasher, id),
        .integer => |i| std.hash.autoHash(hasher, i),
        .real => |r| std.hash.autoHash(hasher, @as(u64, @bitCast(r))),
        .boolean => |b| std.hash.autoHash(hasher, b),
    }
}

pub fn hashCondition(hasher: *std.hash.Wyhash, c: Condition) void {
    std.hash.autoHash(hasher, c.field_index);
    std.hash.autoHash(hasher, c.op);
    std.hash.autoHash(hasher, c.field_type);
    std.hash.autoHash(hasher, c.items_type);
    if (c.value) |v| hashValue(hasher, v);
}

pub fn eqlCondition(a: Condition, b: Condition) bool {
    if (a.field_index != b.field_index) return false;
    if (a.op != b.op) return false;
    if (a.field_type != b.field_type) return false;
    if (a.items_type != b.items_type) return false;
    if (a.value == null and b.value == null) return true;
    if (a.value == null or b.value == null) return false;
    return a.value.?.eql(b.value.?);
}

pub fn conditionValueLessThan(a: ?Value, b: ?Value) bool {
    if (a == null and b == null) return false;
    if (a == null) return true;
    if (b == null) return false;
    const av = a.?;
    const bv = b.?;
    const at = @intFromEnum(std.meta.activeTag(av));
    const bt = @intFromEnum(std.meta.activeTag(bv));
    if (at != bt) return at < bt;
    return switch (av) {
        .scalar => av.scalar.order(bv.scalar) == .lt,
        .array => |aa| blk: {
            const ba = bv.array;
            for (0..@min(aa.len, ba.len)) |i| {
                switch (ScalarValue.order(aa[i], ba[i])) {
                    .lt => break :blk true,
                    .gt => break :blk false,
                    .eq => {},
                }
            }
            break :blk aa.len < ba.len;
        },
        .nil => false,
    };
}
