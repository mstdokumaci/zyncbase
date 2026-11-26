const std = @import("std");

pub const ThreadBudgetError = error{
    InsufficientCpuCores,
};
/// ZyncBase runs two uWebSockets reactors: the main thread runs loop 0 and the
/// server spawns loop 1.
pub const event_loop_count: usize = 2;
pub const ThreadBudget = struct {
    writer: usize = 1,
    checkpoint: usize = 1,
    presence: usize = 1,
    readers: usize,
    subscription: usize,
    pub fn init(cpu_count: usize) ThreadBudgetError!ThreadBudget {
        if (cpu_count < 2) {
            return error.InsufficientCpuCores;
        }
        const fixed = event_loop_count + 3; // reactors + writer + checkpoint + presence
        const remaining: usize = @max(cpu_count, fixed + 2) - fixed;
        const readers = @min(4, @max(1, remaining / 2));
        const subscription = @max(1, remaining -| readers);
        return .{
            .readers = readers,
            .subscription = subscription,
        };
    }
    pub fn total(self: ThreadBudget) usize {
        return event_loop_count + self.writer + self.checkpoint + self.presence + self.readers + self.subscription;
    }
    pub fn logSummary(self: ThreadBudget) void {
        std.log.info("Thread budget: event_loop={} writer={} checkpoint={} presence={} readers={} subscription={} (total={})", .{
            event_loop_count,
            self.writer,
            self.checkpoint,
            self.presence,
            self.readers,
            self.subscription,
            self.total(),
        });
    }
};
