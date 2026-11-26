const std = @import("std");

const thread_budget = @import("../thread_budget.zig");
const c = @import("../uwebsockets_wrapper.zig").c;

const event_loop_count = thread_budget.event_loop_count;

/// Cross-thread wake handles for the reactors. Both the pointer and an
/// in-flight counter are per loop: `clear` returns only after every wake that
/// observed the handle has finished, so the owning thread may free its loop.
pub const WakeRegistry = struct {
    loops: [event_loop_count]std.atomic.Value(?*c.struct_us_loop_t),
    inflight: [event_loop_count]std.atomic.Value(u32),

    pub fn init() @This() {
        // SAFETY: every field is assigned in the loop below before return.
        var self: @This() = undefined;
        for (0..event_loop_count) |i| {
            self.loops[i] = std.atomic.Value(?*c.struct_us_loop_t).init(null);
            self.inflight[i] = std.atomic.Value(u32).init(0);
        }
        return self;
    }

    /// Publish the loop once it is listening.
    pub fn set(self: *WakeRegistry, loop_id: u8, loop: *c.struct_us_loop_t) void {
        std.debug.assert(loop_id < event_loop_count);
        self.loops[loop_id].store(loop, .release);
    }

    /// Kick the reactor. Safe from any thread and from a signal handler: no
    /// locks, only atomics and the uSockets wakeup syscall.
    pub fn wake(self: *WakeRegistry, loop_id: u8) void {
        _ = self.inflight[loop_id].fetchAdd(1, .acq_rel);
        if (self.loops[loop_id].load(.acquire)) |loop| c.us_wakeup_loop(loop);
        _ = self.inflight[loop_id].fetchSub(1, .release);
    }

    /// Called on the owning reactor before it frees its loop. Waits out any
    /// wake already holding the handle so no thread can use it afterwards.
    pub fn clear(self: *WakeRegistry, loop_id: u8) void {
        std.debug.assert(loop_id < event_loop_count);
        self.loops[loop_id].store(null, .release);
        while (self.inflight[loop_id].load(.acquire) != 0) std.atomic.spinLoopHint();
    }
};
