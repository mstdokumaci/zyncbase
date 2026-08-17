const std = @import("std");

const Allocator = std.mem.Allocator;

/// Connection violation tracker for repeated limit violations
pub const ConnectionViolationTracker = struct {
    io: std.Io,
    violations: std.AutoHashMapUnmanaged(u64, u32),
    allocator: Allocator,
    threshold: u32,
    mutex: std.Io.Mutex,

    pub fn init(self: *ConnectionViolationTracker, io: std.Io, allocator: Allocator, threshold: u32) void {
        self.* = ConnectionViolationTracker{
            .io = io,
            .violations = .empty,
            .allocator = allocator,
            .threshold = threshold,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *ConnectionViolationTracker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.violations.deinit(self.allocator);
    }

    /// Record a violation for a connection. Returns true if connection should be closed.
    pub fn recordViolation(self: *ConnectionViolationTracker, connection_id: u64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const result = try self.violations.getOrPut(self.allocator, connection_id);
        if (result.found_existing) {
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
        return result.value_ptr.* >= self.threshold;
    }

    /// Clear violations for a connection after session teardown
    pub fn clearViolations(self: *ConnectionViolationTracker, connection_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.violations.remove(connection_id);
    }
};
