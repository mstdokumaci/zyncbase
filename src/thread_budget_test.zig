const std = @import("std");
const ThreadBudget = @import("thread_budget.zig").ThreadBudget;

test "ThreadBudget with 4 cores" {
    const budget = try ThreadBudget.init(4);
    try std.testing.expectEqual(@as(usize, 1), budget.readers);
    try std.testing.expectEqual(@as(usize, 1), budget.notification);
    try std.testing.expectEqual(@as(usize, 6), budget.total());
}

test "ThreadBudget with 8 cores" {
    const budget = try ThreadBudget.init(8);
    try std.testing.expectEqual(@as(usize, 2), budget.readers);
    try std.testing.expectEqual(@as(usize, 2), budget.notification);
    try std.testing.expectEqual(@as(usize, 8), budget.total());
}

test "ThreadBudget with 16 cores" {
    const budget = try ThreadBudget.init(16);
    try std.testing.expectEqual(@as(usize, 4), budget.readers);
    try std.testing.expectEqual(@as(usize, 8), budget.notification);
    try std.testing.expectEqual(@as(usize, 16), budget.total());
}

test "ThreadBudget with 32 cores" {
    const budget = try ThreadBudget.init(32);
    try std.testing.expectEqual(@as(usize, 4), budget.readers);
    try std.testing.expectEqual(@as(usize, 24), budget.notification);
    try std.testing.expectEqual(@as(usize, 32), budget.total());
}

test "ThreadBudget rejects less than 4 cores" {
    try std.testing.expectError(error.InsufficientCpuCores, ThreadBudget.init(3));
    try std.testing.expectError(error.InsufficientCpuCores, ThreadBudget.init(1));
    try std.testing.expectError(error.InsufficientCpuCores, ThreadBudget.init(0));
}
