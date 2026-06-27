const std = @import("std");
const testing = std.testing;
const workerPool = @import("worker_pool.zig").workerPool;
const managedThread = @import("managed_thread.zig").managedThread;

const TestWorker = struct {
    thread: managedThread(TestWorker),
    started: bool,

    fn init() TestWorker {
        return .{
            .thread = managedThread(TestWorker).init(),
            .started = false,
        };
    }

    pub fn spawn(self: *TestWorker) !void {
        self.started = true;
        try self.thread.spawn(workerFn, self);
    }

    pub fn stop(self: *TestWorker) void {
        self.thread.stop();
    }
};

fn workerFn(ctx: *TestWorker) void {
    while (!ctx.thread.isRequested()) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

fn initWorkers(pool: anytype) void {
    for (pool.workers) |*w| {
        w.* = TestWorker.init();
    }
}

test "workerPool: init and deinit" {
    const allocator = testing.allocator;
    var pool = try workerPool(TestWorker).init(allocator, 2);
    defer pool.deinit();
    try testing.expectEqual(@as(usize, 2), pool.workers.len);
}

test "workerPool: start and stop lifecycle" {
    const allocator = testing.allocator;
    var pool = try workerPool(TestWorker).init(allocator, 3);
    defer pool.deinit();
    initWorkers(&pool);
    try pool.start();
    pool.stop();
}

test "workerPool: stop does not panic on already stopped" {
    const allocator = testing.allocator;
    var pool = try workerPool(TestWorker).init(allocator, 2);
    defer pool.deinit();
    initWorkers(&pool);
    pool.stop();
    pool.stop();
}
