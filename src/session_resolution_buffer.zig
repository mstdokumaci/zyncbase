const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const DocId = typed.DocId;

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
    overflow: std.ArrayListUnmanaged(SessionResolutionResult),
    overflow_mutex: std.Thread.Mutex,
    allocator: Allocator,

    const capacity = 256;

    pub fn init(allocator: Allocator) !SessionResolutionBuffer {
        const buffer = try allocator.alloc(SessionResolutionResult, capacity);
        return .{
            .buffer = buffer,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
            .overflow = .empty,
            .overflow_mutex = .{},
            .allocator = allocator,
        };
    }

    /// Called by the writer thread only.
    pub fn push(self: *SessionResolutionBuffer, result: SessionResolutionResult) !void {
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.acquire);
        if (wp -% rp >= capacity) {
            self.overflow_mutex.lock();
            defer self.overflow_mutex.unlock();

            try self.overflow.append(self.allocator, result);
            return;
        }
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

        const count = wp -% rp;

        self.overflow_mutex.lock();
        defer self.overflow_mutex.unlock();

        const total_count = try std.math.add(usize, count, self.overflow.items.len);
        try out.ensureUnusedCapacity(allocator, total_count);
        for (0..count) |_| {
            out.appendAssumeCapacity(self.buffer[rp % capacity]);
            rp = rp +% 1;
        }
        if (rp != rp_initial) self.read_pos.store(rp, .release);

        for (self.overflow.items) |result| {
            out.appendAssumeCapacity(result);
        }
        self.overflow.clearRetainingCapacity();
    }

    pub fn deinit(self: *SessionResolutionBuffer) void {
        self.overflow.deinit(self.allocator);
        self.allocator.free(self.buffer);
    }
};
