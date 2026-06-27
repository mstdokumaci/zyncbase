const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn workerPool(comptime Worker: type) type { // zwanzig-disable-line: unused-parameter
    return struct {
        workers: []Worker,
        allocator: Allocator,

        const Self = @This();

        pub fn init(allocator: Allocator, count: usize) !Self {
            const workers = try allocator.alloc(Worker, count);
            return .{
                .workers = workers,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.workers);
        }

        pub fn start(self: *Self) !void {
            errdefer self.stop();
            for (self.workers) |*w| {
                try w.spawn();
            }
        }

        pub fn stop(self: *Self) void {
            for (self.workers) |*w| {
                w.stop();
            }
        }
    };
}
