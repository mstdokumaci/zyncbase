pub const Notifier = struct {
    callback: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    pub fn init(callback: ?*const fn (?*anyopaque) void, ctx: ?*anyopaque) Notifier {
        return .{ .callback = callback, .ctx = ctx };
    }

    pub fn notify(self: Notifier) void {
        if (self.callback) |cb| cb(self.ctx);
    }
};
