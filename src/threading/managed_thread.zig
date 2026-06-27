const std = @import("std");

pub fn managedThread(comptime Context: type) type { // zwanzig-disable-line: unused-parameter
    return struct {
        thread: ?std.Thread = null,
        shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        cond: std.Thread.Condition = .{},
        mutex: std.Thread.Mutex = .{},

        const Self = @This();

        pub fn init() Self {
            return .{
                .shutdown_requested = std.atomic.Value(bool).init(false),
            };
        }

        pub fn isRequested(self: *const Self) bool {
            return self.shutdown_requested.load(.acquire);
        }

        pub fn spawn(self: *Self, comptime func: fn (*Context) void, ctx: *Context) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.thread != null) return error.ThreadAlreadyRunning;
            self.shutdown_requested.store(false, .release);
            self.thread = try std.Thread.spawn(.{}, func, .{ctx});
        }

        pub fn requestStop(self: *Self) void {
            self.shutdown_requested.store(true, .release);
        }

        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.requestStop();
            self.cond.signal();
            const maybe_thread = self.thread;
            self.mutex.unlock();
            if (maybe_thread) |t| {
                t.join();
                self.mutex.lock();
                defer self.mutex.unlock();
                self.thread = null;
            }
        }

        pub fn signal(self: *Self) void {
            self.cond.signal();
        }

        pub fn broadcast(self: *Self) void {
            self.cond.broadcast();
        }
    };
}
