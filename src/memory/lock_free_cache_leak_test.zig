const std = @import("std");

const lockFreeCache = @import("lock_free_cache.zig").lockFreeCache;

const testing = std.testing;

const U32Value = struct {
    value: u32,

    pub fn deinit(self: U32Value, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const CountingValue = struct {
    value: u32,
    deinit_count: *std.atomic.Value(usize),

    pub fn deinit(self: CountingValue, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self.deinit_count.fetchAdd(1, .seq_cst);
    }
};

test "LockFreeCache: pool stability and leak test" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);
    const config = u32_cache.Config{
        .max_deferred_nodes = 4096,
        .reclamation_interval_ms = 10,
    };

    var cache: u32_cache = undefined;
    try cache.init(allocator, config);
    defer cache.deinit();

    try cache.update(1, .{ .value = 1 });

    const num_updates = 1000;
    var i: usize = 0;
    while (i < num_updates) : (i += 1) {
        try cache.update(1, .{ .value = @intCast(i) });
        if (i % 100 == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Increase robustness by retrying the check in case the background thread
    // is currently reclaiming some nodes.
    var active: usize = 0;
    var retries: u32 = 0;
    while (retries < 10) : (retries += 1) {
        cache.reclaim(true);
        active = cache.pool.active_count.load(.acquire);
        if (active < 5) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expect(active < 5);
}

test "LockFreeCache: pool exhaustion retains and eventually reclaims all resources" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(CountingValue, i64);
    const config = u32_cache.Config{
        .max_deferred_nodes = 10,
        .reclamation_interval_ms = 10,
    };

    var deinit_count = std.atomic.Value(usize).init(0);

    var cache: u32_cache = undefined;
    try cache.init(allocator, config);
    defer cache.deinit();

    try cache.update(1, .{ .value = 0, .deinit_count = &deinit_count });

    // Mock a slow reader by pinning an epoch
    const handle = try cache.get(1);

    // Perform updates until the deferred-node pool is exhausted; retired
    // resources must be retained (allocator-backed overflow), not dropped.
    const updates_until_exhaustion = config.max_deferred_nodes + 2;
    var i: usize = 0;
    while (i < updates_until_exhaustion) : (i += 1) {
        try cache.update(1, .{ .value = @intCast(i), .deinit_count = &deinit_count });
    }

    // While the reader pins the epoch, no retired entry may be reclaimed early.
    try testing.expectEqual(@as(usize, 0), deinit_count.load(.acquire));

    // Unpin the epoch, then verify every retired entry is eventually reclaimed.
    handle.release();

    var retries: u32 = 0;
    while (retries < 10) : (retries += 1) {
        cache.reclaim(true);
        if (deinit_count.load(.acquire) == updates_until_exhaustion) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, updates_until_exhaustion), deinit_count.load(.acquire));
    try testing.expectEqual(@as(usize, 0), cache.pool.active_count.load(.acquire));
}
