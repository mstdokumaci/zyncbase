const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");

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

    pub fn cloneClaims(source: std.StringHashMapUnmanaged(typed.Value), allocator: Allocator) !std.StringHashMapUnmanaged(typed.Value) {
        var result: std.StringHashMapUnmanaged(typed.Value) = .{};
        errdefer {
            var it = result.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            result.deinit(allocator);
        }
        var it = source.iterator();
        while (it.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const val = try entry.value_ptr.clone(allocator);
            errdefer val.deinit(allocator);
            try result.put(allocator, key, val);
        }
        return result;
    }
};
