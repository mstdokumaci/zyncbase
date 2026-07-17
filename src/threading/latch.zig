const std = @import("std");

/// Generic one-shot synchronisation primitive (promise/future).
///
/// A `Latch(Result)` can be resolved or rejected exactly once. Any number of
/// consumers may block on `wait()` until the producer calls `resolve` or `reject`.
///
/// Double-resolve or double-reject is a programming error and panics.
pub fn latch(comptime Result: type) type { // zwanzig-disable-line: unused-parameter identifier-style
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        state: State = .{ .pending = {} },

        const State = union(enum) {
            pending: void,
            resolved: Result,
            rejected: anyerror,
        };

        /// Block until the latch is resolved or rejected.
        /// Returns the resolved value or propagates the rejection error.
        pub fn wait(self: *Self) !Result {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.state == .pending) {
                self.cond.wait(&self.mutex);
            }
            return switch (self.state) {
                .pending => unreachable,
                .resolved => |v| v,
                .rejected => |e| e,
            };
        }

        /// Resolve with a value. Callers of `wait()` receive it.
        /// Panics if the latch has already been resolved or rejected.
        pub fn resolve(self: *Self, result: Result) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .pending) {
                std.debug.panic("Latch.resolve called on already-completed latch (state={s})", .{@tagName(self.state)});
            }
            self.state = .{ .resolved = result };
            self.cond.broadcast();
        }

        /// Reject with an error. Callers of `wait()` receive the error.
        /// Panics if the latch has already been resolved or rejected.
        pub fn reject(self: *Self, err: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .pending) {
                std.debug.panic("Latch.reject called on already-completed latch (state={s})", .{@tagName(self.state)});
            }
            self.state = .{ .rejected = err };
            self.cond.broadcast();
        }
    };
}
