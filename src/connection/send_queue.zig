const std = @import("std");

const memory_strategy = @import("../memory/strategy.zig");
const thread_budget = @import("../thread_budget.zig");
const mpscQueue = @import("../queues/mpsc_queue.zig").mpscQueue;

const ArenaHandle = memory_strategy.ArenaHandle;

/// One delivery inside a batched subscription-fanout entry. `loop_id` is the
/// event loop that owns the connection; it lets the producer split a change
/// into one batch per loop without a global lookup.
pub const Delivery = struct {
    conn_id: u64,
    data: []const u8,
    loop_id: u8 = 0,
};
pub const Entry = struct {
    conn_id: u64,
    data: []const u8,
    arena: ArenaHandle,
    /// Owning loop, used for the debug ownership invariant.
    loop_id: u8 = 0,
    /// Non-null for a batched subscription-fanout entry. The `data` slices in
    /// `items` point into the same arena and use the same lifetime as `data`.
    items: ?[]const Delivery = null,
    pub fn deinit(self: *const Entry) void {
        self.arena.release();
    }
    /// The queue allocates its node from this owner, so the arena must
    /// outlive the entry — the caller holds a reference across the push.
    pub fn owner(self: Entry) ArenaHandle {
        return self.arena;
    }
};
/// Per-loop send queues. Each queue has exactly one consumer (its event loop).
/// Producers pass the owning loop explicitly; there is no conn-id tag or global
/// lookup on the push path.
pub const SendQueue = struct {
    const event_loop_count = thread_budget.event_loop_count;
    const inner_queue = mpscQueue(Entry, ArenaHandle);
    queues: [event_loop_count]inner_queue,
    pub fn init(allocator: std.mem.Allocator) !@This() {
        // SAFETY: every queue is initialized in the loop below before return.
        var self: @This() = undefined;
        var initialized: usize = 0;
        errdefer for (0..initialized) |i| self.queues[i].deinit();
        for (0..event_loop_count) |i| {
            self.queues[i] = try inner_queue.init(allocator);
            initialized += 1;
        }
        return self;
    }
    pub fn deinit(self: *@This()) void {
        for (&self.queues) |*queue| queue.deinit();
    }
    pub fn push(self: *@This(), loop_id: u8, item: Entry) !void {
        if (loop_id >= event_loop_count) return error.InvalidLoop;
        if (item.items) |items| return self.pushBatch(item, items);
        var entry = item;
        entry.loop_id = loop_id;
        return self.queues[loop_id].push(entry);
    }
    fn pushBatch(self: *@This(), item: Entry, items: []const Delivery) !void {
        if (items.len == 0) {
            item.arena.release();
            return;
        }
        var per_loop = [_]usize{0} ** event_loop_count;
        for (items) |delivery| {
            if (delivery.loop_id >= event_loop_count) return error.InvalidLoop;
            per_loop[delivery.loop_id] += 1;
        }
        var only: ?usize = null;
        for (0..event_loop_count) |i| {
            if (per_loop[i] == 0) continue;
            if (only != null) {
                only = null;
                break;
            }
            only = i;
        }
        if (only) |idx| {
            var entry = item;
            entry.conn_id = items[0].conn_id;
            entry.loop_id = @intCast(idx);
            return self.queues[idx].push(entry);
        }
        // A change can match subscribers on more than one loop. Split the
        // batch into one queue entry per loop; all entries share the arena and
        // take their own reference.
        const alloc = item.arena.allocator();
        var slices = [_]?[]Delivery{null} ** event_loop_count;
        for (0..event_loop_count) |i| {
            if (per_loop[i] == 0) continue;
            slices[i] = try alloc.alloc(Delivery, per_loop[i]);
        }
        var positions = [_]usize{0} ** event_loop_count;
        for (items) |delivery| {
            const idx = delivery.loop_id;
            (slices[idx] orelse unreachable)[positions[idx]] = delivery;
            positions[idx] += 1;
        }
        var pushed: usize = 0;
        for (0..event_loop_count) |i| {
            const slice = slices[i] orelse continue;
            if (pushed > 0) item.arena.retain();
            const entry = Entry{
                .conn_id = slice[0].conn_id,
                .data = &.{},
                .items = slice,
                .arena = item.arena,
                .loop_id = @intCast(i),
            };
            self.queues[i].push(entry) catch |err| {
                if (pushed == 0) return err;
                item.arena.release();
                std.log.warn("send_queue: dropping fanout batch for loop {}: {}", .{ i, err });
            };
            pushed += 1;
        }
        if (pushed == 0) return error.OutOfMemory;
    }
    pub fn popFrom(self: *@This(), loop_index: usize) ?Entry {
        std.debug.assert(loop_index < event_loop_count);
        return self.queues[loop_index].pop();
    }
    pub fn hasItems(self: *const @This()) bool {
        for (&self.queues) |*queue| {
            if (queue.hasItems()) return true;
        }
        return false;
    }
};
