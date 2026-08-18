const std = @import("std");

pub const WaitGroup = struct {
    io: std.Io,
    count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    cond: std.Io.Condition = .init,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io) WaitGroup {
        return .{ .io = io };
    }

    pub fn add(self: *WaitGroup, delta: usize) void {
        _ = self.count.fetchAdd(delta, .acq_rel);
    }

    pub fn done(self: *WaitGroup, delta: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const prev = self.count.fetchSub(delta, .acq_rel);
        std.debug.assert(prev >= delta);
        if (prev == delta) {
            self.cond.broadcast(self.io);
        }
    }

    pub fn value(self: *const WaitGroup) usize {
        return self.count.load(.acquire);
    }

    pub fn wait(self: *WaitGroup) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.value() > 0) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    pub fn broadcast(self: *WaitGroup) void {
        self.mutex.lockUncancelable(self.io);
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
};
