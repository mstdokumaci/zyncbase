const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const WebSocket = @import("../uwebsockets_wrapper.zig").WebSocket;

const memory_strategy = @import("../memory_strategy.zig");
const send_queue_mod = @import("../connection/send_queue.zig");
const send_queue_type = send_queue_mod.send_queue;

const app_helpers = @import("../app_test_helpers.zig");
const createMockWebSocket = app_helpers.createMockWebSocket;
const destroyMockWebSocket = app_helpers.destroyMockWebSocket;

const MS = memory_strategy.MemoryStrategy;
const NodePool = MS.IndexPool(send_queue_type.Node);

const payload_size: usize = 100;

const BenchmarkCtx = struct {
    allocator: Allocator,
    ms: *MS,
    node_pool: NodePool,
    send_queue: send_queue_type,
    connections: std.AutoHashMapUnmanaged(u64, WebSocket),
    conn_mutex: std.Thread.Mutex,

    fn init(self: *BenchmarkCtx, allocator: Allocator) !void {
        self.allocator = allocator;
        self.connections = .empty;
        self.conn_mutex = .{};

        const ms = try allocator.create(MS);
        errdefer allocator.destroy(ms);
        try ms.initWithConfig(allocator, .{ .arena_pool = .{ .pre_allocate = 16, .max_capacity = 65536 } });
        self.ms = ms;

        // SAFETY: overwritten by init on next line
        self.node_pool = undefined;
        // SAFETY: 65536 entries well within u32 capacity; pool returns OOM if exceeded.
        try self.node_pool.init(ms.generalAllocator(), 65536, null, null);
        errdefer self.node_pool.deinit();

        self.send_queue = try send_queue_type.init(&self.node_pool);
        errdefer self.send_queue.deinit();
    }

    fn deinit(self: *BenchmarkCtx) void {
        while (self.send_queue.pop()) |entry| entry.deinit();
        self.send_queue.deinit();
        self.node_pool.deinit();

        var it = self.connections.valueIterator();
        while (it.next()) |ws| destroyMockWebSocket(self.allocator, ws);
        self.connections.deinit(self.allocator);

        std.debug.assert(self.ms.deinit() == .ok);
        self.allocator.destroy(self.ms);
    }

    fn createConnections(self: *BenchmarkCtx, count: usize) !void { // zwanzig-disable-line: unused-parameter
        for (0..count) |_| {
            const ws = createMockWebSocket(self.allocator);
            try self.connections.put(self.allocator, ws.getConnId(), ws);
        }
    }

    fn populateQueue(self: *BenchmarkCtx, entry_count: usize) !void { // zwanzig-disable-line: unused-parameter
        const conn_ids = try self.allocator.alloc(u64, self.connections.count());
        defer self.allocator.free(conn_ids);
        {
            var idx: usize = 0;
            var it = self.connections.iterator();
            while (it.next()) |kv| {
                conn_ids[idx] = kv.key_ptr.*;
                idx += 1;
            }
        }
        if (conn_ids.len == 0) return;

        for (0..entry_count) |i| {
            const arena_handle = try self.ms.acquireArenaDeferred();
            errdefer arena_handle.release();
            const arena_alloc = arena_handle.allocator();
            const data = try arena_alloc.alloc(u8, payload_size);
            @memset(data, @as(u8, @intCast(i & 0xFF)));

            const conn_id = conn_ids[i % conn_ids.len];
            try self.send_queue.push(.{
                .conn_id = conn_id,
                .data = data,
                .arena = arena_handle,
            });
        }
    }

    fn drainAll(self: *BenchmarkCtx) u64 {
        var t = std.time.Timer.start() catch return 0;

        while (self.send_queue.pop()) |entry| {
            self.conn_mutex.lock();
            const ws_ptr = self.connections.getPtr(entry.conn_id);
            self.conn_mutex.unlock();

            if (ws_ptr) |ws| {
                _ = ws.send(entry.data, .binary);
            }
            entry.deinit();
        }

        return t.lap();
    }
};

fn runThroughputBenchmark(ctx: *BenchmarkCtx, conn_count: usize, entry_count: usize, label: []const u8) !void {
    try ctx.createConnections(conn_count);
    try ctx.populateQueue(entry_count);

    const total_ns = ctx.drainAll();
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1e6;
    const per_entry_us = total_ms / @as(f64, @floatFromInt(entry_count)) * 1000;

    std.debug.print("send_path {s}: N={d:>4} entries={d:>5} total={d:.4}ms per_entry={d:.4}us\n", .{
        label,
        conn_count,
        entry_count,
        total_ms,
        per_entry_us,
    });
}

test "send_path: throughput 100 conns 10k entries" {
    const allocator = testing.allocator;
    var ctx: BenchmarkCtx = undefined;
    try ctx.init(allocator);
    defer ctx.deinit();

    try runThroughputBenchmark(&ctx, 100, 10_000, "throughput-100");
}

test "send_path: connection scaling (50, 200, 500)" {
    const allocator = testing.allocator;
    const entry_count: usize = 5_000;

    const conn_counts = [_]usize{ 50, 200, 500 };
    for (conn_counts) |conn_count| {
        var ctx: BenchmarkCtx = undefined;
        try ctx.init(allocator);
        defer ctx.deinit();

        try runThroughputBenchmark(&ctx, conn_count, entry_count, "scaling");
    }
}

test "send_path: backpressure 100 conns 20k entries" {
    const allocator = testing.allocator;
    var ctx: BenchmarkCtx = undefined;
    try ctx.init(allocator);
    defer ctx.deinit();

    try runThroughputBenchmark(&ctx, 100, 20_000, "backpressure-100");
}
