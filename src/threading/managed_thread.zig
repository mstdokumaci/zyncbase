const std = @import("std");

pub fn managedThread(comptime Context: type) type { // zwanzig-disable-line: unused-parameter
    return struct {
        thread: ?std.Thread = null,
        io: std.Io,
        shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        join_cond: std.Io.Condition = .init,
        work_event: std.Io.Event = .unset,
        mutex: std.Io.Mutex = .init,
        is_joining: bool = false,

        const Self = @This();

        pub fn init(io: std.Io) Self {
            return .{ .io = io };
        }

        pub fn isRequested(self: *const Self) bool {
            return self.shutdown_requested.load(.acquire);
        }

        pub fn spawn(self: *Self, comptime func: fn (*Context) void, ctx: *Context) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.thread != null or self.is_joining) return error.ThreadAlreadyRunning;
            self.shutdown_requested.store(false, .release);
            self.thread = try std.Thread.spawn(.{}, func, .{ctx});
        }

        pub fn requestStop(self: *Self) void {
            self.shutdown_requested.store(true, .release);
            self.work_event.set(self.io);
        }

        pub fn stop(self: *Self) void {
            const t = self.tryJoin() orelse return;
            t.join();
            self.doneJoining();
        }

        fn tryJoin(self: *Self) ?std.Thread {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.requestStop();

            if (self.is_joining) {
                while (self.is_joining) {
                    self.join_cond.waitUncancelable(self.io, &self.mutex);
                }
                return null;
            }

            const t = self.thread orelse return null;
            self.is_joining = true;
            return t;
        }

        fn doneJoining(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.thread = null;
            self.is_joining = false;
            self.join_cond.broadcast(self.io);
        }

        pub fn signal(self: *Self) void {
            self.work_event.set(self.io);
        }

        pub fn broadcast(self: *Self) void {
            self.work_event.set(self.io);
        }

        /// Acquire the thread's internal mutex.
        /// Pair with unlockWork(). Use when you need the mutex for a push-then-signal sequence.
        pub fn lockWork(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
        }

        /// Release the thread's internal mutex.
        pub fn unlockWork(self: *Self) void {
            self.mutex.unlock(self.io);
        }

        /// Block until the thread receives a signal, a broadcast, or a stop request.
        /// MUST be called while holding the mutex (via lockWork).
        pub fn waitForWork(self: *Self) void {
            self.work_event.reset();
            if (self.isRequested()) return;
            self.mutex.unlock(self.io);
            self.work_event.waitUncancelable(self.io);
            self.mutex.lockUncancelable(self.io);
        }

        /// Result of a timed wait.
        pub const WaitResult = enum { signaled, timeout, stop };

        /// Block for up to `timeout_ns` nanoseconds, or until signaled or stop is requested.
        /// MUST be called while holding the mutex (via lockWork).
        /// Returns .stop if shutdown was requested, .timeout if the duration elapsed, .signaled otherwise.
        pub fn waitForWorkTimed(self: *Self, timeout_ns: u64) WaitResult {
            if (self.isRequested()) return .stop;
            self.work_event.reset();
            if (self.isRequested()) return .stop;
            self.mutex.unlock(self.io);
            const wait_result = self.work_event.waitTimeout(self.io, .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
                .clock = .awake,
            } });
            self.mutex.lockUncancelable(self.io);
            wait_result catch |err| switch (err) {
                error.Timeout => return if (self.isRequested()) .stop else .timeout,
                error.Canceled => return if (self.isRequested()) .stop else .timeout,
            };
            return if (self.isRequested()) .stop else .signaled;
        }
    };
}
