const std = @import("std");
const Allocator = std.mem.Allocator;

/// Connection violation tracker for repeated limit violations
pub const ConnectionViolationTracker = struct {
    violations: std.AutoHashMap(u64, u32),
    allocator: Allocator,
    threshold: u32,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, threshold: u32) ConnectionViolationTracker {
        return ConnectionViolationTracker{
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

    /// Clear violations for a connection (e.g., after successful parse)
    pub fn clearViolations(self: *ConnectionViolationTracker, connection_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.violations.remove(connection_id);
    }

    /// Get violation count for a connection
    pub fn getViolationCount(self: *ConnectionViolationTracker, connection_id: u64) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.violations.get(connection_id) orelse 0;
    }
};
