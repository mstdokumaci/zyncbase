const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const schema_types = @import("../schema/types.zig");
const th = @import("test_helpers.zig");
const PresenceRecord = @import("record.zig").PresenceRecord;

const testing = std.testing;
const freeTestFields = th.freeTestFields;
const makePresencePatch = th.makePresencePatch;
const makeTestUserFields = th.makeTestUserFields;

test "PresenceRecord - init creates all-null slots" {
    const allocator = std.testing.allocator;
    var record = try PresenceRecord.init(allocator, 3);
    defer record.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), record.values.len);
    for (record.values) |slot| {
        try testing.expect(slot == null);
    }
}

test "PresenceRecord - mergeFromPayload applies sparse patch" {
    const allocator = std.testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 42.5 } },
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("active", allocator) },
    });
    defer patch.free(allocator);

    try record.mergeFromPayload(allocator, fields, patch);

    try testing.expect(record.values[0] != null);
    try testing.expect(record.values[1] == null);
    try testing.expect(record.values[2] != null);

    try testing.expectEqual(.scalar, std.meta.activeTag(record.values[0].?));
    try testing.expectEqual(@as(f64, 42.5), record.values[0].?.scalar.real);

    try testing.expectEqual(.scalar, std.meta.activeTag(record.values[2].?));
    try testing.expectEqualStrings("active", record.values[2].?.scalar.text);
}

test "PresenceRecord - mergeFromPayload rejects out-of-bounds field index" {
    const allocator = std.testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 99, .value = .{ .float = 1.0 } },
    });
    defer patch.free(allocator);

    try testing.expectError(error.InvalidFieldIndex, record.mergeFromPayload(allocator, fields, patch));
}

test "PresenceRecord - mergeFromPayload rejects non-map payload" {
    const allocator = std.testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    const bad_patch = msgpack.Payload{ .int = 42 };
    try testing.expectError(error.InvalidPayload, record.mergeFromPayload(allocator, fields, bad_patch));
}

test "PresenceRecord - clone deep copies values" {
    const allocator = std.testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch = try makePresencePatch(allocator, &.{
        .{ .idx = 0, .value = .{ .float = 10.0 } },
    });
    defer patch.free(allocator);
    try record.mergeFromPayload(allocator, fields, patch);

    var cloned = try record.clone(allocator);
    defer cloned.deinit(allocator);

    try testing.expectEqual(record.values.len, cloned.values.len);
    try testing.expect(cloned.values[0] != null);
    try testing.expectEqual(@as(f64, 10.0), cloned.values[0].?.scalar.real);
    try testing.expect(cloned.values[1] == null);
}

test "PresenceRecord - mergeFromPayload overwrites existing value" {
    const allocator = std.testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    var patch1 = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("idle", allocator) },
    });
    defer patch1.free(allocator);
    try record.mergeFromPayload(allocator, fields, patch1);

    var patch2 = try makePresencePatch(allocator, &.{
        .{ .idx = 2, .value = try msgpack.Payload.strToPayload("active", allocator) },
    });
    defer patch2.free(allocator);
    try record.mergeFromPayload(allocator, fields, patch2);

    try testing.expectEqualStrings("active", record.values[2].?.scalar.text);
}

test "PresenceRecord - mergeFromPayload enforces constraints" {
    const allocator = std.testing.allocator;

    const fields = try allocator.alloc(schema_types.PresenceField, 1);
    errdefer allocator.free(fields);

    const name = try allocator.dupe(u8, "status");
    const enum_vals = try allocator.alloc(schema_types.Constraints.EnumValue, 2);
    enum_vals[0] = .{ .text = try allocator.dupe(u8, "active") };
    enum_vals[1] = .{ .text = try allocator.dupe(u8, "idle") };
    fields[0] = .{
        .name = name,
        .declared_type = .text,
        .constraints = .{
            .enum_values = enum_vals,
        },
    };
    defer {
        for (fields) |f| f.deinit(allocator);
        allocator.free(fields);
    }

    var record = try PresenceRecord.init(allocator, 1);
    defer record.deinit(allocator);

    // Valid enum value passes
    {
        var valid_patch = try makePresencePatch(allocator, &.{
            .{ .idx = 0, .value = try msgpack.Payload.strToPayload("active", allocator) },
        });
        defer valid_patch.free(allocator);
        try record.mergeFromPayload(allocator, fields, valid_patch);
        try testing.expectEqualStrings("active", record.values[0].?.scalar.text);
    }

    // Invalid enum value rejected
    {
        var invalid_patch = try makePresencePatch(allocator, &.{
            .{ .idx = 0, .value = try msgpack.Payload.strToPayload("banned", allocator) },
        });
        defer invalid_patch.free(allocator);
        try testing.expectError(error.EnumViolation, record.mergeFromPayload(allocator, fields, invalid_patch));
    }
}
