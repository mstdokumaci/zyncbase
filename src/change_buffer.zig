const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const TypedRecord = typed.TypedRecord;

pub const OwnedRecordChange = struct {
    table_index: usize,
    namespace_id: i64,
    operation: Operation,
    old_record: ?TypedRecord,
    new_record: ?TypedRecord,

    pub const Operation = enum { insert, update, delete };

    pub fn deinit(self: *OwnedRecordChange, allocator: Allocator) void {
        if (self.old_record) |r| r.deinit(allocator);
        if (self.new_record) |r| r.deinit(allocator);
    }
};

pub const ChangeBuffer = struct {
    buffer: []OwnedRecordChange,
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),
    allocator: Allocator,

    const capacity = 8192; // Power of 2 makes modulo cheap

    pub fn init(allocator: Allocator) !ChangeBuffer {
        const buffer = try allocator.alloc(OwnedRecordChange, capacity);
        return ChangeBuffer{
            .buffer = buffer,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    /// Called by write thread only.
    pub fn push(self: *ChangeBuffer, change: OwnedRecordChange) !void {
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.acquire);
        if (wp -% rp >= capacity) return error.BufferFull;
        self.buffer[wp % capacity] = change;
        self.write_pos.store(wp +% 1, .release);
    }

    /// Called by event loop only.
    pub fn drainInto(self: *ChangeBuffer, out: *std.ArrayListUnmanaged(OwnedRecordChange), alloc: Allocator) !void {
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
