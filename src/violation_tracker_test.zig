const std = @import("std");
const testing = std.testing;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const violation_tracker_helpers = @import("violation_tracker_test_helpers.zig");

test "ConnectionViolationTracker: basic functionality" {
    const allocator = testing.allocator;
    var tracker: ViolationTracker = undefined;
    tracker.init(allocator, 3);
    defer tracker.deinit();

    const conn_id: u64 = 12345;

    // First violation
    {
        const should_close = try tracker.recordViolation(conn_id);
        try testing.expect(!should_close);
        try testing.expectEqual(@as(u32, 1), violation_tracker_helpers.getViolationCount(&tracker, conn_id));
    }

    // Second violation
    {
        const should_close = try tracker.recordViolation(conn_id);
        try testing.expect(!should_close);
        try testing.expectEqual(@as(u32, 2), violation_tracker_helpers.getViolationCount(&tracker, conn_id));
    }

    // Third violation - should trigger closure
    {
        const should_close = try tracker.recordViolation(conn_id);
        try testing.expect(should_close);
        try testing.expectEqual(@as(u32, 3), violation_tracker_helpers.getViolationCount(&tracker, conn_id));
    }

    tracker.clearViolations(conn_id);
    try testing.expectEqual(@as(u32, 0), violation_tracker_helpers.getViolationCount(&tracker, conn_id));
}

test "ConnectionViolationTracker: multiple connections" {
    const allocator = testing.allocator;
    var tracker: ViolationTracker = undefined;
    tracker.init(allocator, 2);
    defer tracker.deinit();

    const conn1: u64 = 1;
    const conn2: u64 = 2;

    // Conn1: one violation
    _ = try tracker.recordViolation(conn1);
    try testing.expectEqual(@as(u32, 1), violation_tracker_helpers.getViolationCount(&tracker, conn1));
    try testing.expectEqual(@as(u32, 0), violation_tracker_helpers.getViolationCount(&tracker, conn2));

    // Conn2: two violations (should close)
    _ = try tracker.recordViolation(conn2);
    const should_close = try tracker.recordViolation(conn2);
    try testing.expect(should_close);
    try testing.expectEqual(@as(u32, 1), violation_tracker_helpers.getViolationCount(&tracker, conn1));
    try testing.expectEqual(@as(u32, 2), violation_tracker_helpers.getViolationCount(&tracker, conn2));
}
