const std = @import("std");
const testing = std.testing;
const managedThread = @import("managed_thread.zig").managedThread;

const TestContext = struct {
    ran: bool = false,
};

fn worker(ctx: *TestContext) void {
    ctx.ran = true;
}

test "managedThread: spawn and join lifecycle" {
    var ctx = TestContext{};
    var mt = managedThread(TestContext).init();

    try mt.spawn(worker, &ctx);
    mt.join();

    try testing.expect(ctx.ran);
}

test "managedThread: requestStop and isRequested" {
    var mt = managedThread(TestContext).init();
    try testing.expect(!mt.isRequested());
    mt.requestStop();
    try testing.expect(mt.isRequested());
}

test "managedThread: signal and wait" {
    var mt = managedThread(TestContext).init();
    var signaled = false;

    const ThreadContext = struct {
        mt: *managedThread(TestContext),
        signaled: *bool,
    };

    var thread_ctx = ThreadContext{ .mt = &mt, .signaled = &signaled };

    const thread = try std.Thread.spawn(.{}, struct {
        fn threadFn(ctx: *ThreadContext) void {
            ctx.mt.wait();
            ctx.signaled.* = true;
        }
    }.threadFn, .{&thread_ctx});

    std.Thread.sleep(10 * std.time.ns_per_ms);
    mt.signal();
    thread.join();
    try testing.expect(signaled);
}

test "managedThread: re-spawn guard" {
    var mt = managedThread(TestContext).init();
    var ctx = TestContext{};

    try mt.spawn(worker, &ctx);
    defer mt.join();

    try testing.expectError(error.ThreadAlreadyRunning, mt.spawn(worker, &ctx));
}

test "managedThread: stop bundles requestStop signal join" {
    var ctx = TestContext{};
    var mt = managedThread(TestContext).init();

    try mt.spawn(worker, &ctx);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    mt.stop();

    try testing.expect(mt.isRequested());
}

test "managedThread: timedWait returns false on timeout" {
    var mt = managedThread(TestContext).init();
    try testing.expect(!mt.timedWait(1 * std.time.ns_per_ms));
}
