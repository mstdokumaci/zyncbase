const std = @import("std");

pub fn managedThread(comptime Context: type) type { // zwanzig-disable-line: unused-parameter
    return struct {
        thread: ?std.Thread = null,
        shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        cond: std.Thread.Condition = .{},
        mutex: std.Thread.Mutex = .{},
        is_joining: bool = false,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn isRequested(self: *const Self) bool {
            return self.shutdown_requested.load(.acquire);
        }

        pub fn spawn(self: *Self, comptime func: fn (*Context) void, ctx: *Context) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.thread != null or self.is_joining) return error.ThreadAlreadyRunning;
            self.shutdown_requested.store(false, .release);
            self.thread = try std.Thread.spawn(.{}, func, .{ctx});
        }

        pub fn requestStop(self: *Self) void {
            self.shutdown_requested.store(true, .release);
        }

        pub fn stop(self: *Self) void {
            const t = self.tryJoin() orelse return;
            t.join();
            self.doneJoining();
        }

        fn tryJoin(self: *Self) ?std.Thread {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.requestStop();
            self.cond.signal();

            if (self.is_joining) {
                while (self.is_joining) {
                    self.cond.wait(&self.mutex);
                }
                return null;
            }

            const t = self.thread orelse return null;
            self.is_joining = true;
            return t;
        }

        fn doneJoining(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.thread = null;
            self.is_joining = false;
            self.cond.broadcast();
        }

        pub fn signal(self: *Self) void {
            self.cond.signal();
        }

        pub fn broadcast(self: *Self) void {
            self.cond.broadcast();
        }

        /// Acquire the thread's internal mutex.
        /// Pair with unlockWork(). Use when you need the mutex for a push-then-signal sequence.
        pub fn lockWork(self: *Self) void {
            self.mutex.lock();
        }

        /// Release the thread's internal mutex.
        pub fn unlockWork(self: *Self) void {
            self.mutex.unlock();
        }

        /// Block until the thread receives a signal, a broadcast, or a stop request.
        /// MUST be called while holding the mutex (via lockWork).
        pub fn waitForWork(self: *Self) void {
            self.cond.wait(&self.mutex);
        }

        /// Result of a timed wait.
        pub const WaitResult = enum { signaled, timeout, stop };

        /// Block for up to `timeout_ns` nanoseconds, or until signaled or stop is requested.
        /// MUST be called while holding the mutex (via lockWork).
        /// Returns .stop if shutdown was requested, .timeout if the duration elapsed, .signaled otherwise.
        pub fn waitForWorkTimed(self: *Self, timeout_ns: u64) WaitResult {
            if (self.isRequested()) return .stop;
            self.cond.timedWait(&self.mutex, timeout_ns) catch |err| {
                if (err == error.Timeout) return if (self.isRequested()) .stop else .timeout;
                std.log.err("managedThread timedWait failed: {}", .{err});
            };
            return if (self.isRequested()) .stop else .signaled;
        }
    };
}
