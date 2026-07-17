const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed/types.zig");

pub const Session = struct {
    external_id: []const u8,
    is_anonymous: bool,
    token_expires_at: i64,
    claims: std.StringHashMapUnmanaged(typed.Value) = .{},

    pub fn deinit(self: *Session, allocator: Allocator) void {
        allocator.free(self.external_id);
        var it = self.claims.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.claims.deinit(allocator);
    }
};
