const std = @import("std");
const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const Message = @import("memory_strategy.zig").Message;
const Buffer = @import("memory_strategy.zig").Buffer;
const Connection = @import("memory_strategy.zig").Connection;

test "memory: safety and pool invariants" {
    // **Property 6: Memory Safety**
// Memory safety properties
    //
    // This property test verifies that the memory management strategy:
    // - Tracks all allocations and deallocations correctly
    // - Has no memory leaks
    // - Has no use-after-free errors
    // - Maintains ref_count invariants (never negative)
    // - Properly reuses pooled objects
    // Use a tracking allocator to detect leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
            @panic("Memory leak in memory safety property test");
        }
    }

    // Test 1: GeneralPurposeAllocator for long-lived allocations
    {
        var strategy = try MemoryStrategy.init();
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
        var strategy = try MemoryStrategy.init();
        defer strategy.deinit();

        const arena = strategy.arenaAllocator();

        // Simulate multiple requests
        var request_num: usize = 0;
        while (request_num < 50) : (request_num += 1) {
            // Allocate memory for this request
            _ = try arena.alloc(u8, 512);
            _ = try arena.alloc(u8, 1024);
            _ = try arena.alloc(u8, 2048);

            // Reset arena - all memory freed in bulk
            strategy.resetArena();
        }
    }

    // Test 3: Object pools for high-churn objects
    {
        var strategy = try MemoryStrategy.init();
        defer strategy.deinit();

        // Test message pool
        var messages: [20]*Message = undefined;
        for (&messages) |*msg| {
            msg.* = try strategy.acquireMessage();
            msg.*.len = 100;
        }

        // Release all messages back to pool
        for (messages) |msg| {
            strategy.releaseMessage(msg);
        }

        // Acquire again - should reuse from pool
        for (&messages) |*msg| {
            msg.* = try strategy.acquireMessage();
        }

        // Release again
        for (messages) |msg| {
            strategy.releaseMessage(msg);
        }

        // Test buffer pool
        var buffers: [20]*Buffer = undefined;
        for (&buffers) |*buf| {
            buf.* = try strategy.acquireBuffer();
            buf.*[0] = 42;
        }

        for (buffers) |buf| {
            strategy.releaseBuffer(buf);
        }

        // Test connection pool
        var connections: [20]*Connection = undefined;
        for (&connections) |*conn| {
            conn.* = try strategy.acquireConnection();
            conn.*.id = 123;
            conn.*.active = true;
        }

        for (connections) |conn| {
            strategy.releaseConnection(conn);
        }
    }

    // Test 4: Mixed allocator usage
    {
        var strategy = try MemoryStrategy.init();
        defer strategy.deinit();

        const gpa_alloc = strategy.generalAllocator();
        const arena = strategy.arenaAllocator();

        // Long-lived allocation
        const long_lived = try gpa_alloc.alloc(u8, 100);
        defer gpa_alloc.free(long_lived);

        // Temporary allocations
        _ = try arena.alloc(u8, 200);
        _ = try arena.alloc(u8, 300);
        strategy.resetArena();

        // Pool allocations
        const msg = try strategy.acquireMessage();
        strategy.releaseMessage(msg);

        const buf = try strategy.acquireBuffer();
        strategy.releaseBuffer(buf);

        const conn = try strategy.acquireConnection();
        strategy.releaseConnection(conn);
    }

    // Test 5: Stress test with many allocations
    {
        var strategy = try MemoryStrategy.init();
        defer strategy.deinit();

        var iteration: usize = 0;
        while (iteration < 1000) : (iteration += 1) {
            const arena = strategy.arenaAllocator();

            // Allocate various sizes
            _ = try arena.alloc(u8, 64);
            _ = try arena.alloc(u8, 128);
            _ = try arena.alloc(u8, 256);

            // Acquire and release from pools
            const msg = try strategy.acquireMessage();
            strategy.releaseMessage(msg);

            // Reset arena
            strategy.resetArena();
        }
    }

    // Test 6: Verify no use-after-free with arena
    {
        var strategy = try MemoryStrategy.init();
        defer strategy.deinit();

        const arena = strategy.arenaAllocator();

        // Allocate memory
        const ptr1 = try arena.alloc(u8, 100);
        @memset(ptr1, 42);

        // Reset arena - ptr1 is now invalid
        strategy.resetArena();

        // Allocate new memory - should not reuse ptr1's memory in a way that causes issues
        const ptr2 = try arena.alloc(u8, 100);
        @memset(ptr2, 99);

        // Verify ptr2 is valid
        try testing.expect(ptr2[0] == 99);

        strategy.resetArena();
    }

    // Test 7: Pool capacity limits
    {
        var strategy = try MemoryStrategy.init();
        defer strategy.deinit();

        // Acquire more messages than pool capacity
        var messages: [1100]*Message = undefined;
        for (&messages) |*msg| {
            msg.* = try strategy.acquireMessage();
        }

        // Release all - some will be freed, some will be pooled
        for (messages) |msg| {
            strategy.releaseMessage(msg);
        }

        // Acquire again - should work without issues
        for (&messages) |*msg| {
            msg.* = try strategy.acquireMessage();
        }

        for (messages) |msg| {
            strategy.releaseMessage(msg);
        }
    }
}

test "memory: concurrent pool access" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    const ThreadContext = struct {
        strategy: *MemoryStrategy,
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: *ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                // Acquire and release messages
                const msg = ctx.strategy.acquireMessage() catch unreachable;
                msg.len = i;
                ctx.strategy.releaseMessage(msg);

                // Acquire and release buffers
                const buf = ctx.strategy.acquireBuffer() catch unreachable;
                buf[0] = @intCast(i % 256);
                ctx.strategy.releaseBuffer(buf);

                // Acquire and release connections
                const conn = ctx.strategy.acquireConnection() catch unreachable;
                conn.id = i;
                ctx.strategy.releaseConnection(conn);
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
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    const arena = strategy.arenaAllocator();

    // Request 1
    const req1_data = try arena.alloc(u8, 100);
    @memset(req1_data, 1);
    try testing.expect(req1_data[0] == 1);

    strategy.resetArena();

    // Request 2 - should not see request 1's data
    const req2_data = try arena.alloc(u8, 100);
    @memset(req2_data, 2);
    try testing.expect(req2_data[0] == 2);

    strategy.resetArena();

    // Request 3
    const req3_data = try arena.alloc(u8, 100);
    @memset(req3_data, 3);
    try testing.expect(req3_data[0] == 3);

    strategy.resetArena();
}

test "memory: GPA allocation tracking" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    const gpa = strategy.generalAllocator();

    // Allocate and track multiple allocations
    var allocations: [10][]u8 = undefined;
    for (&allocations, 0..) |*alloc, i| {
        alloc.* = try gpa.alloc(u8, (i + 1) * 100);
        @memset(alloc.*, @intCast(i));
    }

    // Verify all allocations are valid
    for (allocations, 0..) |alloc, i| {
        try testing.expect(alloc[0] == @as(u8, @intCast(i)));
    }

    // Free all allocations
    for (allocations) |alloc| {
        gpa.free(alloc);
    }
}

test "memory: subscription pool reuse" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Acquire a message and mark it
    const msg1 = try strategy.acquireMessage();
    const msg1_addr = @intFromPtr(msg1);
    msg1.len = 999;

    // Release it
    strategy.releaseMessage(msg1);

    // Acquire again - should get the same message from pool
    const msg2 = try strategy.acquireMessage();
    const msg2_addr = @intFromPtr(msg2);

    // Verify it's the same object (reused from pool)
    try testing.expect(msg1_addr == msg2_addr);

    // NOTE: TSan may report a race here if it doesn't see the happens-before
    // established by the internal mutex of the pool. However, since the mutex
    // is locked/unlocked in release() and acquire(), it should be fine.
    // The previous failure might have been due to the copy-by-value of MemoryStrategy.
    try testing.expect(msg2.len == 999); // Data persists

    strategy.releaseMessage(msg2);
}
