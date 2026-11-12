const std = @import("std");

const field_path = @import("field_path.zig");

test "field_path join: empty prefix returns copy of segment" {
    const allocator = std.testing.allocator;
    const result = try field_path.join(allocator, "", "city");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("city", result);
}

test "field_path join: non-empty prefix adds __ separator" {
    const allocator = std.testing.allocator;
    const result = try field_path.join(allocator, "address", "city");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("address__city", result);
}

test "field_path join: deep nesting composes correctly" {
    const allocator = std.testing.allocator;
    const inner = try field_path.join(allocator, "a", "b");
    defer allocator.free(inner);
    const outer = try field_path.join(allocator, inner, "c");
    defer allocator.free(outer);
    try std.testing.expectEqualStrings("a__b__c", outer);
}

test "field_path normalizeDots: converts dots to double underscores" {
    const allocator = std.testing.allocator;
    const result = try field_path.normalizeDots(allocator, "a.b.c");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a__b__c", result);
}

test "field_path toDotted: converts double underscores to dots" {
    const allocator = std.testing.allocator;
    const result = try field_path.toDotted(allocator, "a__b__c");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a.b.c", result);
}

test "field_path normalizeDots and toDotted round-trip" {
    const allocator = std.testing.allocator;
    const flat = try field_path.normalizeDots(allocator, "profile.address.city");
    defer allocator.free(flat);
    try std.testing.expectEqualStrings("profile__address__city", flat);
    const dotted = try field_path.toDotted(allocator, flat);
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("profile.address.city", dotted);
}
