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
            if (self.thread != null) return error.ThreadAlreadyRunning;
            self.thread = try std.Thread.spawn(.{}, func, .{ctx});
        }

        pub fn requestStop(self: *Self) void {
            self.shutdown_requested.store(true, .release);
        }

        pub fn join(self: *Self) void {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
        }

        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.requestStop();
            self.cond.signal();
            self.mutex.unlock();
            self.join();
        }

        pub fn signal(self: *Self) void {
            self.cond.signal();
        }

        pub fn broadcast(self: *Self) void {
            self.cond.broadcast();
        }

        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.wait(&self.mutex);
        }

        pub fn timedWait(self: *Self, ns: u64) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.timedWait(&self.mutex, ns) catch {
                return false;
            };
            return true;
        }
    };
}
