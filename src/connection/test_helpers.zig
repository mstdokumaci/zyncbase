const ViolationTracker = @import("violations.zig").ConnectionViolationTracker;

pub fn getViolationCount(tracker: *ViolationTracker, connection_id: u64) u32 {
    tracker.mutex.lockUncancelable(tracker.io);
    defer tracker.mutex.unlock(tracker.io);
    return tracker.violations.get(connection_id) orelse 0;
}
