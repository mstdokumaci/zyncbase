const std = @import("std");
const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const Message = @import("memory_strategy.zig").Message;
const Buffer = @import("memory_strategy.zig").Buffer;
const Connection = @import("memory_strategy.zig").Connection;
const Pool = @import("memory_strategy.zig").Pool;

test "MemoryStrategy: init and deinit" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Verify allocators are available
    const gpa = strategy.generalAllocator();
    const arena = strategy.arenaAllocator();

    // Test basic allocation with GPA
    const ptr = try gpa.alloc(u8, 100);
    defer gpa.free(ptr);
    try testing.expect(ptr.len == 100);

    // Test basic allocation with arena
    const arena_ptr = try arena.alloc(u8, 100);
    try testing.expect(arena_ptr.len == 100);
}

test "MemoryStrategy: arena allocator reset" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    const arena = strategy.arenaAllocator();

    // Allocate some memory
    _ = try arena.alloc(u8, 1000);
    _ = try arena.alloc(u8, 2000);
    _ = try arena.alloc(u8, 3000);

    // Reset arena - all memory should be freed in bulk
    strategy.resetArena();

    // Allocate again after reset
    const ptr = try arena.alloc(u8, 500);
    try testing.expect(ptr.len == 500);
}

test "MemoryStrategy: message pool acquire and release" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Acquire a message
    const msg1 = try strategy.acquireMessage();
    try testing.expect(msg1.len == 0);

    // Modify the message
    msg1.len = 100;

    // Release it back to the pool
    strategy.releaseMessage(msg1);

    // Acquire again - should get the same message from pool
    const msg2 = try strategy.acquireMessage();
    try testing.expect(msg2 == msg1);

    strategy.releaseMessage(msg2);
}

test "MemoryStrategy: buffer pool acquire and release" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Acquire a buffer
    const buf1 = try strategy.acquireBuffer();
    buf1[0] = 42;

    // Release it back to the pool
    strategy.releaseBuffer(buf1);

    // Acquire again - should get the same buffer from pool
    const buf2 = try strategy.acquireBuffer();
    try testing.expect(buf2 == buf1);
    try testing.expect(buf2[0] == 42);

    strategy.releaseBuffer(buf2);
}

test "MemoryStrategy: connection pool acquire and release" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Acquire a connection
    const conn1 = try strategy.acquireConnection();
    conn1.id = 123;
    conn1.active = true;

    // Release it back to the pool
    strategy.releaseConnection(conn1);

    // Acquire again - should get the same connection from pool
    const conn2 = try strategy.acquireConnection();
    try testing.expect(conn2 == conn1);
    try testing.expect(conn2.id == 123);

    strategy.releaseConnection(conn2);
}

test "MemoryStrategy: multiple message acquisitions" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Acquire multiple messages
    var messages: [10]*Message = undefined;
    for (&messages) |*msg| {
        msg.* = try strategy.acquireMessage();
    }

    // Release all messages
    for (messages) |msg| {
        strategy.releaseMessage(msg);
    }

    // Acquire again - should reuse from pool
    const msg = try strategy.acquireMessage();
    strategy.releaseMessage(msg);
}

test "Pool: basic acquire and release" {
    const allocator = testing.allocator;
    var pool = try Pool(u64).init(allocator, 10);
    defer pool.deinit();

    // Acquire an item (pool is empty, so it allocates)
    const item1 = try pool.acquire();
    item1.* = 42;

    // Release it back
    pool.release(item1);

    // Acquire again - should get the same item
    const item2 = try pool.acquire();
    try testing.expect(item2 == item1);
    try testing.expect(item2.* == 42);

    pool.release(item2);
}

test "Pool: capacity limit" {
    const allocator = testing.allocator;
    var pool = try Pool(u64).init(allocator, 2);
    defer pool.deinit();

    // Acquire and release 3 items
    const item1 = try pool.acquire();
    const item2 = try pool.acquire();
    const item3 = try pool.acquire();

    pool.release(item1);
    pool.release(item2);
    pool.release(item3); // This should be freed, not pooled (capacity is 2)

    // Pool should have 2 items
    const reused1 = try pool.acquire();
    const reused2 = try pool.acquire();
    const new_item = try pool.acquire(); // This should be newly allocated

    try testing.expect(reused1 == item2 or reused1 == item1);
    try testing.expect(reused2 == item2 or reused2 == item1);
    try testing.expect(new_item != item1 and new_item != item2);

    pool.release(reused1);
    pool.release(reused2);
    pool.release(new_item);
}

test "Pool: concurrent access" {
    const allocator = testing.allocator;
    var pool = try Pool(u64).init(allocator, 100);
    defer pool.deinit();

    const ThreadContext = struct {
        pool: *Pool(u64),
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: *ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const item = ctx.pool.acquire() catch unreachable;
                item.* = i;
                ctx.pool.release(item);
            }
        }
    }.run;

    // Spawn multiple threads
    var contexts: [4]ThreadContext = undefined;
    var threads: [4]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .pool = &pool, .iterations = 100 };
        threads[i] = try std.Thread.spawn(.{}, worker, .{ctx});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }
}

test "Message: init and reset" {
    var msg = Message.init();
    try testing.expect(msg.len == 0);

    msg.len = 100;
    msg.reset();
    try testing.expect(msg.len == 0);
}

test "Connection: init and reset" {
    var conn = Connection.init();
    try testing.expect(conn.id == 0);
    try testing.expect(conn.active == false);

    conn.id = 123;
    conn.active = true;
    conn.reset();
    try testing.expect(conn.id == 0);
    try testing.expect(conn.active == false);
}

test "MemoryStrategy: arena allocator for request lifecycle" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Simulate request 1
    {
        const arena = strategy.arenaAllocator();
        const request_data = try arena.alloc(u8, 1024);
        @memset(request_data, 0);
        // Process request...
    }
    strategy.resetArena(); // Free all request memory in bulk

    // Simulate request 2
    {
        const arena = strategy.arenaAllocator();
        const request_data = try arena.alloc(u8, 2048);
        @memset(request_data, 0);
        // Process request...
    }
    strategy.resetArena(); // Free all request memory in bulk
}

test "MemoryStrategy: mixed allocator usage" {
    var strategy = try MemoryStrategy.init();
    defer strategy.deinit();

    // Long-lived allocation with GPA
    const gpa = strategy.generalAllocator();
    const long_lived = try gpa.alloc(u8, 100);
    defer gpa.free(long_lived);

    // Temporary allocation with arena
    const arena = strategy.arenaAllocator();
    _ = try arena.alloc(u8, 200);
    strategy.resetArena();

    // Pool allocation
    const msg = try strategy.acquireMessage();
    strategy.releaseMessage(msg);

    // All allocators work together
    try testing.expect(long_lived.len == 100);
}
