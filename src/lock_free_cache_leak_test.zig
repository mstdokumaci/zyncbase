const std = @import("std");
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const testing = std.testing;

test "LockFreeCache: pool stability and leak test" {
    const allocator = testing.allocator;
    const config = LockFreeCache.Config{
        .max_deferred_nodes = 4096,
        .reclamation_interval_ms = 10, // Fast reclamation for test
    };

    var cache = try LockFreeCache.init(allocator, config);
    defer cache.deinit();

    const namespace = "test-leak";
    try cache.create(namespace);

    // Initial pool state (activeCount should be 0 after reclamation)
    cache.reclaim(true);
    try testing.expectEqual(@as(usize, 0), cache.pool.activeCount());

    const num_updates = 10000;
    var i: usize = 0;
    while (i < num_updates) : (i += 1) {
        const state = try LockFreeCache.StateTree.init(allocator);
        try cache.update(namespace, state);

        // Occasionally wait to let background reclamation catch up
        if (i % 1000 == 0) {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }

    // Wait for final reclamation
    std.Thread.sleep(200 * std.time.ns_per_ms);
    cache.reclaim(true); // Force one final synchronous reclaim

    // Pool should return to nearly zero (no readers are pinning epochs)
    const active = cache.pool.activeCount();
    std.log.info("Final active nodes: {}", .{active});
    try testing.expect(active < 5); // Allow for minor background jitter but should keep it tight
}

test "LockFreeCache: pool exhaustion error" {
    const allocator = testing.allocator;
    const config = LockFreeCache.Config{
        .max_deferred_nodes = 10, // Small pool for exhaustion test
        .reclamation_interval_ms = 1000, // Slow reclamation
    };

    var cache = try LockFreeCache.init(allocator, config);
    defer cache.deinit();

    const namespace = "test-exhaustion";
    try cache.create(namespace);

    // Mock a slow reader by pinning an epoch - this prevents reclamation
    const handle = try cache.get(namespace);
    defer handle.release();

    // Perform updates until pool is exhausted
    // Each update(namespace) reserves 2 nodes
    var i: usize = 0;
    var exhausted = false;
    while (i < 20) : (i += 1) {
        const state = try LockFreeCache.StateTree.init(allocator);
        cache.update(namespace, state) catch |err| {
            var state_copy = state;
            state_copy.deinit();
            if (err == error.OutOfMemory) {
                exhausted = true;
                break;
            }
            return err;
        };
    }

    try testing.expect(exhausted);
}
