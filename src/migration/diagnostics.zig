//! Owned, line-oriented diagnostics attached to migration errors. Zig errors
//! carry no payload, so callers collect human-readable lines here and the
//! server logs one record per line.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Diagnostics = struct {
    allocator: Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    /// Set when a line could not be recorded; the error itself still propagates.
    truncated: bool = false,

    pub fn init(allocator: Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    /// Records one line. Allocation failure marks the diagnostics truncated
    /// instead of replacing the error being reported.
    pub fn add(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            self.truncated = true;
            return;
        };
        self.lines.append(self.allocator, line) catch {
            self.allocator.free(line);
            self.truncated = true;
        };
    }

    pub fn items(self: *const Diagnostics) []const []const u8 {
        return self.lines.items;
    }

    /// Writes every line through `std.log.err`.
    pub fn logErrors(self: *const Diagnostics) void {
        for (self.lines.items) |line| std.log.err("{s}", .{line});
        if (self.truncated) std.log.err("(some diagnostics were dropped: out of memory)", .{});
    }
};
