const std = @import("std");
const lockFreeCache = @import("lock_free_cache.zig").lockFreeCache;
const testing = std.testing;

test "LockFreeCache: pool stability and leak test" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(u32);
    const config = u32_cache.Config{
        .max_deferred_nodes = 4096,
        .reclamation_interval_ms = 10,
    };

    var cache: u32_cache = undefined;
    try cache.init(allocator, config, null);
    defer cache.deinit();

    const namespace = "test-leak";
    try cache.update(namespace, 1);

    const num_updates = 1000;
    var i: usize = 0;
    while (i < num_updates) : (i += 1) {
        try cache.update(namespace, @intCast(i));
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
        active = cache.pool.activeCount();
        if (active < 5) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expect(active < 5);
}

test "LockFreeCache: pool exhaustion behavior" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(u32);
    const config = u32_cache.Config{
        .max_deferred_nodes = 10,
        .reclamation_interval_ms = 10,
    };

    var cache: u32_cache = undefined;
    try cache.init(allocator, config, null);
    defer cache.deinit();

    const namespace = "test-exhaustion";
    try cache.update(namespace, 0);

    // Mock a slow reader by pinning an epoch
    const handle = try cache.get(namespace);
    defer handle.release();

    // Perform updates until pool is exhausted
    const updates_until_exhaustion = config.max_deferred_nodes + 2;
    var i: usize = 0;
    while (i < updates_until_exhaustion) : (i += 1) {
        try cache.update(namespace, @intCast(i));
    }

    // With current internalDefer, it just skips if pool is empty after force reclaim.
    // This test ensures we don't crash.
}
