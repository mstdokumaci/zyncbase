const std = @import("std");

pub const ThreadBudgetError = error{
    InsufficientCpuCores,
};

pub const ThreadBudget = struct {
    event_loop: usize = 1,
    writer: usize = 1,
    checkpoint: usize = 1,
    presence: usize = 1,
    readers: usize,
    notification: usize,

    pub fn init(cpu_count: usize) ThreadBudgetError!ThreadBudget {
        if (cpu_count < 4) {
            return error.InsufficientCpuCores;
        }

        const remaining: usize = cpu_count - 4;
        const readers = @min(4, @max(1, remaining / 2));
        const notification = @max(1, remaining -| readers);

        return .{
            .readers = readers,
            .notification = notification,
        };
    }

    pub fn total(self: ThreadBudget) usize {
        return self.event_loop + self.writer + self.checkpoint + self.presence + self.readers + self.notification;
    }

    pub fn logSummary(self: ThreadBudget) void {
        std.log.info("Thread budget: event_loop={} writer={} checkpoint={} presence={} readers={} notification={} (total={})", .{
            self.event_loop,
            self.writer,
            self.checkpoint,
            self.presence,
            self.readers,
            self.notification,
            self.total(),
        });
    }
};
