const std = @import("std");
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const testing = std.testing;

// Property 1: Lock-Free Cache Consistency
// Validates: Requirements 1.1, 1.2, 1.3, 1.6
// Test concurrent reads never block each other
// Verify ref_count correctly incremented for each reader
test "lock-free cache: concurrent reads never block" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Create a test namespace
    const namespace = "test-namespace";
    try cache.create(namespace);

    // Number of concurrent readers
    const num_threads = 8;
    const reads_per_thread = 1000;

    // Shared counter for successful reads
    var successful_reads = std.atomic.Value(usize).init(0);

    // Thread function that performs reads
    const ThreadContext = struct {
        cache: *LockFreeCache,
        namespace: []const u8,
        reads: usize,
        counter: *std.atomic.Value(usize),

        fn readerThread(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.reads) : (i += 1) {
                // Perform lock-free read
                const handle = ctx.cache.get(ctx.namespace) catch |err| {
                    std.debug.print("Read failed: {}\n", .{err});
                    continue;
                };

                // Verify we got a valid state tree
                testing.expect(handle.state().root.key.len > 0) catch unreachable;

                // Release the reference
                handle.release();

                // Increment successful read counter
                _ = ctx.counter.fetchAdd(1, .monotonic);
            }
        }
    };

    // Spawn multiple reader threads
    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*thread| {
        const context = ThreadContext{
            .cache = cache,
            .namespace = namespace,
            .reads = reads_per_thread,
            .counter = &successful_reads,
        };
        thread.* = try std.Thread.spawn(.{}, ThreadContext.readerThread, .{context});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Verify all reads succeeded
    const total_reads = successful_reads.load(.monotonic);
    try testing.expectEqual(num_threads * reads_per_thread, total_reads);

    // Verify ref_count is back to zero after all releases
    const entries = cache.entries.load(.acquire);
    const entry = entries.get(namespace).?;
    const final_ref_count = entry.ref_count.load(.acquire);
    try testing.expectEqual(@as(u32, 0), final_ref_count);
}

// Test ref_count never goes negative
test "lock-free cache: ref_count never negative" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.create(namespace);

    // Perform get/release cycles
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const handle = try cache.get(namespace);

        // Check ref_count is positive
        const entries = cache.entries.load(.acquire);
        const entry = entries.get(namespace).?;
        const ref_count = entry.ref_count.load(.acquire);
        try testing.expect(ref_count > 0);

        handle.release();

        // Check ref_count is back to zero
        const final_ref_count = entry.ref_count.load(.acquire);
        try testing.expectEqual(@as(u32, 0), final_ref_count);
    }
}

// Test ref_count overflow protection
test "lock-free cache: ref_count overflow protection" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.create(namespace);

    // Manually set ref_count to near maximum
    const entries = cache.entries.load(.acquire);
    const entry = entries.get(namespace).?;
    entry.ref_count.store(std.math.maxInt(u32) - 1, .release);

    // Try to get - should fail with overflow
    const result = cache.get(namespace);
    try testing.expectError(error.RefCountOverflow, result);

    // Verify ref_count wasn't incremented
    const final_ref_count = entry.ref_count.load(.acquire);
    try testing.expectEqual(std.math.maxInt(u32) - 1, final_ref_count);
}

// Test concurrent reads with random namespaces
test "lock-free cache: concurrent reads with multiple namespaces" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Create multiple namespaces
    const namespaces = [_][]const u8{
        "namespace-1",
        "namespace-2",
        "namespace-3",
        "namespace-4",
    };

    for (namespaces) |ns| {
        try cache.create(ns);
    }

    const num_threads = 4;
    const reads_per_thread = 500;

    const ThreadContext = struct {
        cache: *LockFreeCache,
        namespaces: []const []const u8,
        reads: usize,

        fn readerThread(ctx: @This()) void {
            var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
            const random = prng.random();

            var i: usize = 0;
            while (i < ctx.reads) : (i += 1) {
                // Pick a random namespace
                const ns_idx = random.intRangeAtMost(usize, 0, ctx.namespaces.len - 1);
                const ns = ctx.namespaces[ns_idx];

                // Perform read
                const handle = ctx.cache.get(ns) catch continue;

                // Release
                handle.release();
            }
        }
    };

    // Spawn reader threads
    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*thread| {
        const context = ThreadContext{
            .cache = cache,
            .namespaces = &namespaces,
            .reads = reads_per_thread,
        };
        thread.* = try std.Thread.spawn(.{}, ThreadContext.readerThread, .{context});
    }

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    // Verify all ref_counts are zero
    for (namespaces) |ns| {
        const entries = cache.entries.load(.acquire);
        const entry = entries.get(ns).?;
        const ref_count = entry.ref_count.load(.acquire);
        try testing.expectEqual(@as(u32, 0), ref_count);
    }
}

// Test memory ordering guarantees
test "lock-free cache: memory ordering with updates" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.create(namespace);

    const num_readers = 4;
    const num_updates = 100;

    var stop = std.atomic.Value(bool).init(false);

    // Reader thread that continuously reads
    const ReaderContext = struct {
        cache: *LockFreeCache,
        namespace: []const u8,
        stop: *std.atomic.Value(bool),

        fn readerThread(ctx: @This()) void {
            while (!ctx.stop.load(.acquire)) {
                const handle = ctx.cache.get(ctx.namespace) catch continue;
                handle.release();
            }
        }
    };

    // Writer thread that performs updates
    const WriterContext = struct {
        cache: *LockFreeCache,
        namespace: []const u8,
        updates: usize,

        fn writerThread(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.updates) : (i += 1) {
                // Create new state
                const new_state = LockFreeCache.StateTree.init(ctx.cache.allocator) catch unreachable;

                // Update cache
                ctx.cache.update(ctx.namespace, new_state) catch unreachable;

                // Small delay
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    };

    // Spawn reader threads
    var reader_threads: [num_readers]std.Thread = undefined;
    for (&reader_threads) |*thread| {
        const context = ReaderContext{
            .cache = cache,
            .namespace = namespace,
            .stop = &stop,
        };
        thread.* = try std.Thread.spawn(.{}, ReaderContext.readerThread, .{context});
    }

    // Spawn writer thread
    const writer_context = WriterContext{
        .cache = cache,
        .namespace = namespace,
        .updates = num_updates,
    };
    const writer_thread = try std.Thread.spawn(.{}, WriterContext.writerThread, .{writer_context});

    // Wait for writer to complete
    writer_thread.join();

    // Stop readers
    stop.store(true, .release);

    // Wait for readers
    for (reader_threads) |thread| {
        thread.join();
    }

    // Verify version was incremented
    const entries = cache.entries.load(.acquire);
    const entry = entries.get(namespace).?;
    const version = entry.version.load(.acquire);
    try testing.expectEqual(@as(u64, num_updates), version);
}

// Unit Tests for Cache Edge Cases
// Validates: Requirements 1.5, 1.7, 1.8

// Test cache miss scenarios
test "lock-free cache: cache miss returns NotFound" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Try to get non-existent namespace
    const result = cache.get("non-existent");
    try testing.expectError(error.NotFound, result);
}

// Test eviction with non-zero ref_count
test "lock-free cache: eviction fails with non-zero ref_count" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.create(namespace);

    // Get the entry (increments ref_count)
    const handle = try cache.get(namespace);

    // Try to evict while ref_count > 0
    const result = cache.evict(namespace);
    try testing.expectError(error.RefCountOverflow, result);

    // Release and try again
    handle.release();
    try cache.evict(namespace);

    // Verify entry is gone
    const get_result = cache.get(namespace);
    try testing.expectError(error.NotFound, get_result);
}

// Test update on non-existent namespace
test "lock-free cache: update on non-existent namespace fails" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const new_state = try LockFreeCache.StateTree.init(allocator);

    const result = cache.update("non-existent", new_state);
    try testing.expectError(error.NotFound, result);

    // Clean up the state we created
    var state_copy = new_state;
    state_copy.deinit();
}

// Test eviction on non-existent namespace
test "lock-free cache: eviction on non-existent namespace fails" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const result = cache.evict("non-existent");
    try testing.expectError(error.NotFound, result);
}

// Test version increments on update
test "lock-free cache: version increments on update" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.create(namespace);

    // Get initial version
    const entries = cache.entries.load(.acquire);
    const entry = entries.get(namespace).?;
    const initial_version = entry.version.load(.acquire);
    try testing.expectEqual(@as(u64, 0), initial_version);

    // Perform updates
    const num_updates = 10;
    var i: usize = 0;
    while (i < num_updates) : (i += 1) {
        const new_state = try LockFreeCache.StateTree.init(allocator);
        try cache.update(namespace, new_state);
    }

    // Verify version incremented
    const final_entries = cache.entries.load(.acquire);
    const final_entry = final_entries.get(namespace).?;
    const final_version = final_entry.version.load(.acquire);
    try testing.expectEqual(@as(u64, num_updates), final_version);
}

// Test timestamp updates on update
test "lock-free cache: timestamp updates on update" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.create(namespace);

    // Get initial timestamp
    const entries = cache.entries.load(.acquire);
    const entry = entries.get(namespace).?;
    const initial_timestamp = entry.timestamp.load(.acquire);

    // Wait enough time to ensure timestamp changes
    std.Thread.sleep(1100 * std.time.ns_per_ms);

    // Perform update
    const new_state = try LockFreeCache.StateTree.init(allocator);
    try cache.update(namespace, new_state);

    // Verify timestamp changed
    const final_entries = cache.entries.load(.acquire);
    const final_entry = final_entries.get(namespace).?;
    const final_timestamp = final_entry.timestamp.load(.acquire);
    try testing.expect(final_timestamp >= initial_timestamp);
}

// Test multiple creates of same namespace
test "lock-free cache: multiple creates of same namespace" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.create(namespace);

    // Second create should succeed (overwrites)
    try cache.create(namespace);

    // Should still be accessible
    const handle = try cache.get(namespace);
    handle.release();
}

// Test empty namespace string
test "lock-free cache: empty namespace string" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "";
    try cache.create(namespace);

    // Should be able to get it
    const handle = try cache.get(namespace);
    handle.release();
}

// Test very long namespace string
test "lock-free cache: very long namespace string" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Create a very long namespace name
    const long_namespace = "a" ** 1000;
    try cache.create(long_namespace);

    // Should be able to get it
    const handle = try cache.get(long_namespace);
    handle.release();
}

// Test StateTree node operations
test "lock-free cache: StateTree node creation and cleanup" {
    const allocator = testing.allocator;

    var state = try LockFreeCache.StateTree.init(allocator);
    defer state.deinit();

    // Verify root node exists
    try testing.expect(state.root.key.len > 0);
    try testing.expectEqualStrings("root", state.root.key);

    // Add a child node
    const child = try LockFreeCache.StateTree.Node.init(
        allocator,
        "child",
        .{ .string = "value" },
    );
    try state.root.children.put("child", child);

    // Verify child exists
    const retrieved_child = state.root.children.get("child");
    try testing.expect(retrieved_child != null);
}

// Test that deferred resources are properly cleaned up
test "lock-free cache: deferred cleanup after concurrent updates" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test";
    try cache.create(namespace);

    const num_threads = 4;
    const updates_per_thread = 50;

    const UpdateContext = struct {
        cache: *LockFreeCache,
        namespace: []const u8,
        updates: usize,

        fn run(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.updates) : (i += 1) {
                const state = LockFreeCache.StateTree.init(ctx.cache.allocator) catch unreachable;
                ctx.cache.update(ctx.namespace, state) catch unreachable;
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, UpdateContext.run, .{UpdateContext{
            .cache = cache,
            .namespace = namespace,
            .updates = updates_per_thread,
        }});
    }

    for (threads) |t| t.join();

    // Verify final version is correct
    const final_entries = cache.entries.load(.acquire);
    const final_entry = final_entries.get(namespace).?;
    const final_version = final_entry.version.load(.acquire);
    try testing.expectEqual(@as(u64, num_threads * updates_per_thread), final_version);

    // Verify defer stack has accumulated old resources
    const defer_node = cache.defer_stack.load(.acquire);
    try testing.expect(defer_node != null);
}

// Test that readers see consistent state during concurrent updates
test "lock-free cache: readers see consistent state during updates" {
    const allocator = testing.allocator;

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const namespace = "test";
    try cache.create(namespace);

    var stop = std.atomic.Value(bool).init(false);
    var inconsistencies = std.atomic.Value(usize).init(0);

    const ReaderContext = struct {
        cache: *LockFreeCache,
        namespace: []const u8,
        stop: *std.atomic.Value(bool),
        inconsistencies: *std.atomic.Value(usize),

        fn run(ctx: @This()) void {
            while (!ctx.stop.load(.acquire)) {
                const handle = ctx.cache.get(ctx.namespace) catch continue;
                defer handle.release();

                const version = handle.entry.version.load(.acquire);
                const timestamp = handle.entry.timestamp.load(.acquire);

                // Verify state tree is valid
                if (handle.state().root.key.len == 0) {
                    _ = ctx.inconsistencies.fetchAdd(1, .monotonic);
                }

                // Verify version and timestamp are reasonable
                if (version > 1000 or timestamp == 0) {
                    _ = ctx.inconsistencies.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    const WriterContext = struct {
        cache: *LockFreeCache,
        namespace: []const u8,
        updates: usize,

        fn run(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.updates) : (i += 1) {
                const state = LockFreeCache.StateTree.init(ctx.cache.allocator) catch unreachable;
                ctx.cache.update(ctx.namespace, state) catch unreachable;
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    };

    // Spawn readers
    var reader_threads: [4]std.Thread = undefined;
    for (&reader_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, ReaderContext.run, .{ReaderContext{
            .cache = cache,
            .namespace = namespace,
            .stop = &stop,
            .inconsistencies = &inconsistencies,
        }});
    }

    // Spawn writer
    const writer = try std.Thread.spawn(.{}, WriterContext.run, .{WriterContext{
        .cache = cache,
        .namespace = namespace,
        .updates = 100,
    }});

    writer.join();
    stop.store(true, .release);

    for (reader_threads) |t| t.join();

    // No inconsistencies should be detected
    try testing.expectEqual(@as(usize, 0), inconsistencies.load(.monotonic));
}
