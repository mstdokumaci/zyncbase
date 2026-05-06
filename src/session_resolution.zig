const std = @import("std");
const Allocator = std.mem.Allocator;
const DocId = @import("doc_id.zig").DocId;

pub const SessionResolutionResult = struct {
    conn_id: u64,
    msg_id: u64,
    scope_seq: u64,
    namespace_id: i64,
    user_doc_id: DocId,
    err: ?anyerror,
};

pub const SessionResolutionBuffer = struct {
    buffer: []SessionResolutionResult,
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),
    allocator: Allocator,

    const capacity = 256;

    pub fn init(allocator: Allocator) !SessionResolutionBuffer {
        const buffer = try allocator.alloc(SessionResolutionResult, capacity);
        return .{
            .buffer = buffer,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    /// Called by the writer thread only.
    pub fn push(self: *SessionResolutionBuffer, result: SessionResolutionResult) !void {
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.acquire);
        if (wp -% rp >= capacity) return error.BufferFull;
        self.buffer[wp % capacity] = result;
        self.write_pos.store(wp +% 1, .release);
    }

    /// Called by the uWS event loop only.
    pub fn drainInto(
        self: *SessionResolutionBuffer,
        out: *std.ArrayListUnmanaged(SessionResolutionResult),
        allocator: Allocator,
    ) !void {
        const wp = self.write_pos.load(.acquire);
        const rp_initial = self.read_pos.load(.monotonic);
        var rp = rp_initial;
        defer if (rp != rp_initial) self.read_pos.store(rp, .release);

        const count = wp -% rp;
        for (0..count) |_| {
            try out.append(allocator, self.buffer[rp % capacity]);
            rp = rp +% 1;
        }
    }

    pub fn deinit(self: *SessionResolutionBuffer) void {
        self.allocator.free(self.buffer);
    }
};
