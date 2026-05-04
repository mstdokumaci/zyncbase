const std = @import("std");
const Allocator = std.mem.Allocator;

/// Connection violation tracker for repeated limit violations
pub const ConnectionViolationTracker = struct {
    violations: std.AutoHashMap(u64, u32),
    allocator: Allocator,
    threshold: u32,
    mutex: std.Thread.Mutex,

    pub fn init(self: *ConnectionViolationTracker, allocator: Allocator, threshold: u32) void {
        self.* = ConnectionViolationTracker{
            .violations = std.AutoHashMap(u64, u32).init(allocator),
            .allocator = allocator,
            .threshold = threshold,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConnectionViolationTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.violations.deinit();
    }

    /// Record a violation for a connection. Returns true if connection should be closed.
    pub fn recordViolation(self: *ConnectionViolationTracker, connection_id: u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = try self.violations.getOrPut(connection_id);
        if (result.found_existing) {
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
        return result.value_ptr.* >= self.threshold;
    }

    /// Clear violations for a connection after session teardown
    pub fn clearViolations(self: *ConnectionViolationTracker, connection_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.violations.remove(connection_id);
    }
};
