const std = @import("std");
const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const Connection = @import("connection.zig").Connection;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test "memory: safety and pool invariants" {
    // Each test sub-block now uses its own isolated GPA to pinpoint leaks.
    // Test 1: GeneralPurposeAllocator for long-lived allocations
    {
        var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer _ = test_gpa.deinit();
        const alloc = test_gpa.allocator();

        var strategy: MemoryStrategy = undefined;
        try strategy.init(alloc);
        defer strategy.deinit();

        const gpa_alloc = strategy.generalAllocator();

        // Allocate and free multiple times
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const ptr = try gpa_alloc.alloc(u8, 1024);
            @memset(ptr, @intCast(i % 256));
            gpa_alloc.free(ptr);
        }
    }

    // Test 2: ArenaAllocator for per-request temporary allocations
    {
        var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer _ = test_gpa.deinit();
        const alloc = test_gpa.allocator();

        var strategy: MemoryStrategy = undefined;
        try strategy.init(alloc);
        defer strategy.deinit();

        // Simulate multiple requests
        var request_num: usize = 0;
        while (request_num < 50) : (request_num += 1) {
            const arena_ptr = try strategy.acquireArena();
            const arena = arena_ptr.allocator();

            // Allocate memory for this request
            _ = try arena.alloc(u8, 512);
            _ = try arena.alloc(u8, 1024);
            _ = try arena.alloc(u8, 2048);

            // Release arena back to pool (resets it)
            strategy.releaseArena(arena_ptr);
        }
    }

    // Test 3: Object pools for high-churn objects
    {
        var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer _ = test_gpa.deinit();
        const alloc = test_gpa.allocator();

        var strategy: MemoryStrategy = undefined;
        try strategy.init(alloc);
        defer strategy.deinit();

        var connections: [20]*Connection = undefined;
        for (&connections, 0..) |*conn, i| {
            const dummy_ws = WebSocket{ .ws = null, .ssl = false };
            const c = try strategy.acquireConnection();
            c.activate(@intCast(i), dummy_ws);
            conn.* = c;
        }

        for (connections) |conn| {
            if (conn.release()) strategy.releaseConnection(conn);
        }

        // Test connection pool: Verify capacity reuse
        {
            const dummy_ws = WebSocket{ .ws = null, .ssl = false };
            const c1 = try strategy.acquireConnection();
            c1.activate(1, dummy_ws);

            // Add some subscriptions to force allocation
            // IMPORTANT: Must use connection's internal allocator (from the pool)
            // to avoid Invalid Free when the object is eventually deinitialized.
            try c1.subscription_ids.append(c1.allocator, 101);
            try c1.subscription_ids.append(c1.allocator, 102);
            const cap_before = c1.subscription_ids.capacity;
            try testing.expect(cap_before >= 2);

            // Release back to pool
            if (c1.release()) strategy.releaseConnection(c1);

            // Acquire again (should be the same object since it was the last one released)
            const c2 = try strategy.acquireConnection();
            defer if (c2.release()) strategy.releaseConnection(c2);
            c2.activate(2, dummy_ws);

            // Verify capacity is preserved but items are cleared
            try testing.expect(c2.subscription_ids.items.len == 0);
            try testing.expect(c2.subscription_ids.capacity == cap_before);
        }
    }

    // Test 4: Mixed allocator usage
    {
        var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer _ = test_gpa.deinit();
        const alloc = test_gpa.allocator();

        var strategy: MemoryStrategy = undefined;
        try strategy.init(alloc);
        defer strategy.deinit();

        const gpa_alloc = strategy.generalAllocator();
        const arena_ptr = try strategy.acquireArena();
        const arena = arena_ptr.allocator();

        // Long-lived allocation
        const long_lived = try gpa_alloc.alloc(u8, 100);
        defer gpa_alloc.free(long_lived);

        // Temporary allocations
        _ = try arena.alloc(u8, 200);
        _ = try arena.alloc(u8, 300);
        strategy.releaseArena(arena_ptr);

        // Pool allocation
        const dummy_ws = WebSocket{ .ws = null, .ssl = false };
        const conn = try strategy.acquireConnection();
        conn.activate(1, dummy_ws);
        if (conn.release()) strategy.releaseConnection(conn);
    }

    // Test 5: Stress test with many allocations
    {
        var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer _ = test_gpa.deinit();
        const alloc = test_gpa.allocator();

        var strategy: MemoryStrategy = undefined;
        try strategy.init(alloc);
        defer strategy.deinit();

        var iteration: usize = 0;
        while (iteration < 1000) : (iteration += 1) {
            const arena_ptr = try strategy.acquireArena();
            const arena = arena_ptr.allocator();

            // Allocate various sizes
            _ = try arena.alloc(u8, 64);
            _ = try arena.alloc(u8, 128);
            _ = try arena.alloc(u8, 256);

            // Release arena
            strategy.releaseArena(arena_ptr);
        }
    }

    // Test 6: Verify no use-after-free with arena
    {
        var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer _ = test_gpa.deinit();
        const alloc = test_gpa.allocator();

        var strategy: MemoryStrategy = undefined;
        try strategy.init(alloc);
        defer strategy.deinit();

        const arena_ptr = try strategy.acquireArena();
        const arena = arena_ptr.allocator();

        // Allocate memory
        const ptr1 = try arena.alloc(u8, 100);
        @memset(ptr1, 42);

        // Release arena - ptr1 is now invalid
        strategy.releaseArena(arena_ptr);

        // Allocate new memory - should not reuse ptr1's memory in a way that causes issues
        const arena_ptr2 = try strategy.acquireArena();
        const arena2 = arena_ptr2.allocator();
        const ptr2 = try arena2.alloc(u8, 100);
        @memset(ptr2, 99);

        // Verify ptr2 is valid
        try testing.expect(ptr2[0] == 99);

        strategy.releaseArena(arena_ptr2);
    }
}

test "memory: concurrent pool access" {
    var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true, .thread_safe = true }){};
    defer _ = test_gpa.deinit();
    const alloc = test_gpa.allocator();

    var strategy: MemoryStrategy = undefined;
    try strategy.init(alloc);
    defer strategy.deinit();

    const ThreadContext = struct {
        strategy: *MemoryStrategy,
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: *ThreadContext) !void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                // Acquire and release connections
                const dummy_ws = WebSocket{ .ws = null, .ssl = false };
                const conn = try ctx.strategy.acquireConnection();
                conn.activate(@intCast(i), dummy_ws);
                if (conn.release()) ctx.strategy.releaseConnection(conn);
            }
        }
    }.run;

    // Spawn multiple threads
    var contexts: [4]ThreadContext = undefined;
    var threads: [4]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .strategy = &strategy, .iterations = 100 };
        threads[i] = try std.Thread.spawn(.{}, worker, .{ctx});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }
}

test "memory: arena isolation between requests" {
    var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = test_gpa.deinit();
    const alloc = test_gpa.allocator();

    var strategy: MemoryStrategy = undefined;
    try strategy.init(alloc);
    defer strategy.deinit();

    const arena_ptr = try strategy.acquireArena();
    const arena = arena_ptr.allocator();

    // Request 1
    const req1_data = try arena.alloc(u8, 100);
    @memset(req1_data, 1);
    try testing.expect(req1_data[0] == 1);

    strategy.releaseArena(arena_ptr);

    // Request 2 - should not see request 1's data
    const arena_ptr2 = try strategy.acquireArena();
    const arena2 = arena_ptr2.allocator();
    const req2_data = try arena2.alloc(u8, 100);
    @memset(req2_data, 2);
    try testing.expect(req2_data[0] == 2);

    strategy.releaseArena(arena_ptr2);
}

test "memory: GPA allocation tracking" {
    var test_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = test_gpa.deinit();
    const alloc = test_gpa.allocator();

    var strategy: MemoryStrategy = undefined;
    try strategy.init(alloc);
    defer strategy.deinit();

    const gpa = strategy.generalAllocator();

    // Allocate and track multiple allocations
    var allocations: [10][]u8 = undefined;
    for (&allocations, 0..) |*ptr_ref, i| {
        ptr_ref.* = try gpa.alloc(u8, (i + 1) * 100);
        @memset(ptr_ref.*, @intCast(i));
    }

    // Verify all allocations are valid
    for (allocations, 0..) |alloc_item, i| {
        try testing.expect(alloc_item[0] == @as(u8, @intCast(i)));
    }

    // Free all allocations
    for (allocations) |alloc_item| {
        gpa.free(alloc_item);
    }
}
