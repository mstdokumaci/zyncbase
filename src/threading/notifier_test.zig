const std = @import("std");
const testing = std.testing;
const Notifier = @import("notifier.zig").Notifier;

fn testCallback(ctx: ?*anyopaque) void {
    const counter: *u32 = @ptrCast(@alignCast(ctx.?));
    counter.* += 1;
}

test "Notifier: notify triggers callback" {
    var counter: u32 = 0;
    const notifier = Notifier.init(testCallback, &counter);
    notifier.notify();
    try testing.expectEqual(@as(u32, 1), counter);
}

test "Notifier: null callback is safe" {
    const notifier = Notifier.init(null, null);
    notifier.notify();
}

test "Notifier: default init is null callback" {
    const notifier = Notifier{};
    notifier.notify();
}

test "Notifier: is a value type (copy)" {
    var counter: u32 = 0;
    var notifier = Notifier.init(testCallback, &counter);
    const notifier_copy = notifier;
    notifier.notify();
    notifier_copy.notify();
    try testing.expectEqual(@as(u32, 2), counter);
}
