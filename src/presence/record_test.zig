const std = @import("std");
const testing = std.testing;
const th = @import("test_helpers.zig");
const makeTestUserFields = th.makeTestUserFields;
const freeTestFields = th.freeTestFields;
const makePresencePatch = th.makePresencePatch;
const PresenceRecord = @import("record.zig").PresenceRecord;
const msgpack = @import("../msgpack_utils.zig");

test "PresenceRecord - init creates all-null slots" {
    const allocator = testing.allocator;
    var record = try PresenceRecord.init(allocator, 3);
    defer record.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), record.values.len);
    for (record.values) |slot| {
        try testing.expect(slot == null);
    }
}

test "PresenceRecord - mergeFromPayload applies sparse patch" {
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
    const fields = try makeTestUserFields(allocator);
    defer freeTestFields(allocator, fields);

    var record = try PresenceRecord.init(allocator, fields.len);
    defer record.deinit(allocator);

    const bad_patch = msgpack.Payload{ .int = 42 };
    try testing.expectError(error.InvalidPayload, record.mergeFromPayload(allocator, fields, bad_patch));
}

test "PresenceRecord - clone deep copies values" {
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
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
