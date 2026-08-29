const std = @import("std");

const schema_system = @import("../schema/system.zig");
const write_worker = @import("write_worker.zig");

test "created_at claim follows wall time then advances monotonically" {
    var last: i64 = 0;
    try std.testing.expectEqual(@as(i64, 100), try write_worker.claimNextCreatedAt(&last, 100));
    try std.testing.expectEqual(@as(i64, 101), try write_worker.claimNextCreatedAt(&last, 100));
    try std.testing.expectEqual(@as(i64, 102), try write_worker.claimNextCreatedAt(&last, 50));

    var other_table: i64 = 0;
    try std.testing.expectEqual(@as(i64, 100), try write_worker.claimNextCreatedAt(&other_table, 100));
    try std.testing.expectEqual(@as(i64, 102), last);

    last = schema_system.max_safe_timestamp_us;
    try std.testing.expectError(error.InvalidOperation, write_worker.claimNextCreatedAt(&last, 0));
}
