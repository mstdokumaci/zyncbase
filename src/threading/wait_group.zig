const std = @import("std");

pub const WaitGroup = struct {
    count: std.atomic.Value(usize) = .{ .raw = 0 },
    cond: std.Thread.Condition = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn init() WaitGroup {
        return .{ .count = std.atomic.Value(usize).init(0) };
    }

    pub fn add(self: *WaitGroup, delta: usize) void {
        _ = self.count.fetchAdd(delta, .acq_rel);
    }

    pub fn done(self: *WaitGroup, delta: usize) void {
        const prev = self.count.fetchSub(delta, .acq_rel);
        if (prev > 0 and prev - delta == 0) {
            self.mutex.lock();
            self.cond.broadcast();
            self.mutex.unlock();
        }
    }

    pub fn value(self: *const WaitGroup) usize {
        return self.count.load(.acquire);
    }

    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.value() > 0) {
            self.cond.wait(&self.mutex);
        }
    }

    pub fn broadcast(self: *WaitGroup) void {
        self.mutex.lock();
        self.cond.broadcast();
        self.mutex.unlock();
    }
};
