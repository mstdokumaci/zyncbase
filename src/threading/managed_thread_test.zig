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
    mt.stop();

    try testing.expect(ctx.ran);
}

test "managedThread: requestStop and isRequested" {
    var mt = managedThread(TestContext).init();
    try testing.expect(!mt.isRequested());
    mt.requestStop();
    try testing.expect(mt.isRequested());
}

test "managedThread: re-spawn guard" {
    var mt = managedThread(TestContext).init();
    var ctx = TestContext{};

    try mt.spawn(worker, &ctx);
    defer mt.stop();

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

test "managedThread: stop frees the slot for a subsequent spawn" {
    var ctx = TestContext{};
    var mt = managedThread(TestContext).init();

    try mt.spawn(worker, &ctx);
    mt.stop();
    try testing.expect(ctx.ran);

    // After stop, the thread slot is available again.
    ctx.ran = false;
    try mt.spawn(worker, &ctx);
    mt.stop();
    try testing.expect(ctx.ran);
}

test "managedThread: concurrent stop does not double-join" {
    var ctx = TestContext{};
    var mt = managedThread(TestContext).init();

    try mt.spawn(worker, &ctx);
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const Runner = struct {
        fn run(mt_ptr: *@TypeOf(mt)) void {
            mt_ptr.stop();
        }
    };
    const t1 = try std.Thread.spawn(.{}, Runner.run, .{&mt});
    const t2 = try std.Thread.spawn(.{}, Runner.run, .{&mt});
    t1.join();
    t2.join();

    try testing.expect(ctx.ran);
}
