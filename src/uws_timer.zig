const std = @import("std");
const c = @import("uwebsockets_wrapper.zig").c;

pub fn startTimer(
    comptime T: type,
    self_ptr: *T,
    loop: *c.struct_us_loop_t,
    callback: *const fn (?*c.struct_us_timer_t) callconv(.c) void,
    initial_ms: u32,
    repeat_ms: u32,
) !*c.struct_us_timer_t {
    const timer = c.us_create_timer(loop, 1, @sizeOf(*T)) orelse
        return error.TimerCreateFailed;
    const ext = c.us_timer_ext(timer);
    @memcpy(@as([*]u8, @ptrCast(ext))[0..@sizeOf(*T)], std.mem.asBytes(&self_ptr));
    c.us_timer_set(timer, callback, @intCast(initial_ms), @intCast(repeat_ms));
    return timer;
}

pub fn stopTimer(field: *?*c.struct_us_timer_t) void {
    if (field.*) |t| {
        c.us_timer_close(t);
        field.* = null;
    }
}

pub fn extractPtr(comptime T: type, timer: *c.struct_us_timer_t) *T {
    const ext = c.us_timer_ext(timer);
    // SAFETY: The extension slot was written by startTimer with a valid *T pointer.
    var ptr: *T = undefined;
    @memcpy(std.mem.asBytes(&ptr), @as([*]u8, @ptrCast(ext))[0..@sizeOf(*T)]);
    return ptr;
}
