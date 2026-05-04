const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;

pub fn getViolationCount(tracker: *ViolationTracker, connection_id: u64) u32 {
    tracker.mutex.lock();
    defer tracker.mutex.unlock();
    return tracker.violations.get(connection_id) orelse 0;
}
