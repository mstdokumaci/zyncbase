const std = @import("std");

/// Allocator that fails exactly `remaining` allocations, then succeeds.
/// Used to inject OOM failures into specific code paths under test.
pub const FailNextAllocator = struct {
    backing: std.mem.Allocator,
    remaining: usize,

    pub fn allocator(self: *FailNextAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailNextAllocator = @ptrCast(@alignCast(ctx));
        if (self.remaining > 0) {
            self.remaining -= 1;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn free(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailNextAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(old_mem, alignment, return_address);
    }
};
