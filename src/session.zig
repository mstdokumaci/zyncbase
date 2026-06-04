const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Session = struct {
    external_id: []const u8,
    is_anonymous: bool,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        allocator.free(self.external_id);
    }
};
