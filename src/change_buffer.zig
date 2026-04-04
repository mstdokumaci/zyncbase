const std = @import("std");
const Allocator = std.mem.Allocator;
const Payload = @import("msgpack_utils.zig").Payload;

pub const OwnedRowChange = struct {
    namespace: []const u8,
    collection: []const u8,
    operation: Operation,
    old_row: ?Payload,
    new_row: ?Payload,

    pub const Operation = enum { insert, update, delete };

    pub fn deinit(self: *OwnedRowChange, allocator: Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.collection);
        if (self.old_row) |*p| p.free(allocator);
        if (self.new_row) |*p| p.free(allocator);
    }
};

pub const ChangeBuffer = struct {
    buffer: []OwnedRowChange,
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),
    allocator: Allocator,

    const capacity = 8192; // Power of 2 makes modulo cheap

    pub fn init(allocator: Allocator) !ChangeBuffer {
        const buffer = try allocator.alloc(OwnedRowChange, capacity);
        return ChangeBuffer{
            .buffer = buffer,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    /// Called by write thread only.
    pub fn push(self: *ChangeBuffer, change: OwnedRowChange) !void {
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.acquire);
        if (wp -% rp >= capacity) return error.BufferFull;
        self.buffer[wp % capacity] = change;
        self.write_pos.store(wp +% 1, .release);
    }

    /// Called by event loop only.
    pub fn drainInto(self: *ChangeBuffer, out: *std.ArrayListUnmanaged(OwnedRowChange), alloc: Allocator) !void {
        const wp = self.write_pos.load(.acquire);
        const rp_initial = self.read_pos.load(.monotonic);
        var rp = rp_initial;

        // Amortize atomic store: update read_pos once at the end (or on early return due to error).
        // This remains safe against partial moves (preventing use-after-free) while being more performant.
        defer if (rp != rp_initial) self.read_pos.store(rp, .release);

        const count = wp -% rp;
        for (0..count) |_| {
            try out.append(alloc, self.buffer[rp % capacity]);
            rp = rp +% 1;
        }
    }

    pub fn deinit(self: *ChangeBuffer) void {
        const wp = self.write_pos.load(.acquire);
        var rp = self.read_pos.load(.monotonic);
        var count = wp -% rp;
        while (count > 0) : (count -= 1) {
            self.buffer[rp % capacity].deinit(self.allocator);
            rp = rp +% 1;
        }
        self.allocator.free(self.buffer);
    }
};
