const std = @import("std");
const testing = std.testing;
const WaitGroup = @import("wait_group.zig").WaitGroup;

test "WaitGroup: add and done" {
    var wg = WaitGroup.init();
    try testing.expectEqual(@as(usize, 0), wg.value());

    wg.add(1);
    try testing.expectEqual(@as(usize, 1), wg.value());

    wg.done(1);
    try testing.expectEqual(@as(usize, 0), wg.value());
}

test "WaitGroup: wait returns when count reaches zero" {
    var wg = WaitGroup.init();
    wg.add(1);

    const ThreadContext = struct { wg: *WaitGroup };
    var tctx = ThreadContext{ .wg = &wg };

    const thread = try std.Thread.spawn(.{}, struct {
        fn threadFn(tc: *ThreadContext) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            tc.wg.done(1);
        }
    }.threadFn, .{&tctx});

    wg.wait();
    thread.join();
}

test "WaitGroup: broadcast wakes all waiters" {
    var wg = WaitGroup.init();
    wg.add(2);

    var waiter1_done = false;
    var waiter2_done = false;

    const ThreadContext = struct {
        wg: *WaitGroup,
        done: *bool,
    };

    var ctx1 = ThreadContext{ .wg = &wg, .done = &waiter1_done };
    var ctx2 = ThreadContext{ .wg = &wg, .done = &waiter2_done };

    const thread1 = try std.Thread.spawn(.{}, struct {
        fn threadFn(ctx: *ThreadContext) void {
            ctx.wg.wait();
            ctx.done.* = true;
        }
    }.threadFn, .{&ctx1});

    const thread2 = try std.Thread.spawn(.{}, struct {
        fn threadFn(ctx: *ThreadContext) void {
            ctx.wg.wait();
            ctx.done.* = true;
        }
    }.threadFn, .{&ctx2});

    std.Thread.sleep(10 * std.time.ns_per_ms);
    wg.done(2);

    thread1.join();
    thread2.join();

    try testing.expect(waiter1_done);
    try testing.expect(waiter2_done);
}

test "WaitGroup: value returns current count" {
    var wg = WaitGroup.init();
    try testing.expectEqual(@as(usize, 0), wg.value());
    wg.add(3);
    try testing.expectEqual(@as(usize, 3), wg.value());
    wg.done(1);
    try testing.expectEqual(@as(usize, 2), wg.value());
    wg.done(2);
    try testing.expectEqual(@as(usize, 0), wg.value());
}
