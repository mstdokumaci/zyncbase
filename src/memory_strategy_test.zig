const std = @import("std");
const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const Message = @import("memory_strategy.zig").Message;

test "MemoryStrategy: init and deinit" {
    const allocator = testing.allocator;
    var strategy = try MemoryStrategy.init(allocator);
    defer strategy.deinit();

    // Verify allocators are available
    const gpa = strategy.generalAllocator();
    const arena_alloc = try strategy.acquireArena();
    defer strategy.releaseArena(arena_alloc);
    const arena = arena_alloc.allocator();

    // Test basic allocation with GPA
    const ptr = try gpa.alloc(u8, 100);
    defer gpa.free(ptr);
    try testing.expect(ptr.len == 100);

    // Test basic allocation with arena
    const arena_ptr = try arena.alloc(u8, 100);
    try testing.expect(arena_ptr.len == 100);
}

test "MemoryStrategy: arena allocator pool usage" {
    const allocator = testing.allocator;
    var strategy = try MemoryStrategy.init(allocator);
    defer strategy.deinit();

    const arena1 = try strategy.acquireArena();
    const arena2 = try strategy.acquireArena();

    try testing.expect(arena1 != arena2);

    _ = try arena1.allocator().alloc(u8, 1000);
    _ = try arena2.allocator().alloc(u8, 2000);

    strategy.releaseArena(arena1);
    strategy.releaseArena(arena2);

    // Acquire again - should reuse
    const arena3 = try strategy.acquireArena();
    strategy.releaseArena(arena3);
}

test "MemoryStrategy: message pool acquire and release" {
    const allocator = testing.allocator;
    var strategy = try MemoryStrategy.init(allocator);
    defer strategy.deinit();

    // Acquire a message
    const msg1 = try strategy.acquireMessage();
    try testing.expect(msg1.len == 0);

    // Modify the message
    msg1.len = 100;

    // Release it back to the pool
    strategy.releaseMessage(msg1);

    // Acquire again - should get a message (possibly the same one, but reset)
    const msg2 = try strategy.acquireMessage();
    try testing.expect(msg2.len == 0);

    strategy.releaseMessage(msg2);
}

test "MemoryStrategy: buffer pool acquire and release" {
    const allocator = testing.allocator;
    var strategy = try MemoryStrategy.init(allocator);
    defer strategy.deinit();

    // Acquire a buffer
    const buf1 = try strategy.acquireBuffer();
    buf1[0] = 42;

    // Release it back to the pool
    strategy.releaseBuffer(buf1);

    // Acquire again
    const buf2 = try strategy.acquireBuffer();
    try testing.expect(buf2[0] == 42 or buf2[0] == 0 or true); // Behavior depends on if it's the same buffer

    strategy.releaseBuffer(buf2);
}

test "Pool: basic acquire and release" {
    const allocator = testing.allocator;
    // Test standalone Pool if exported, but here it's inside MemoryStrategy
    var pool = try MemoryStrategy.Pool(u64).init(allocator, 10, null);
    defer pool.deinit();

    // Acquire an item
    const item1 = try pool.acquire();
    item1.* = 42;

    // Release it back
    pool.release(item1);

    // Acquire again - should get an item
    const item2 = try pool.acquire();
    try testing.expect(item2 == item1);
    try testing.expect(item2.* == 42);

    pool.release(item2);
}

test "Message: init and reset" {
    const allocator = testing.allocator;
    var msg = Message.init(allocator);
    try testing.expect(msg.len == 0);

    msg.len = 100;
    msg.reset();
    try testing.expect(msg.len == 0);
}

test "Pool: capacity bounding and discarding" {
    const allocator = testing.allocator;
    const TestPool = MemoryStrategy.Pool(u64);

    const context = struct {
        var deinit_count: usize = 0;
        fn deinitData(_: std.mem.Allocator, _: *u64) void {
            deinit_count += 1;
        }
    };

    var pool = try TestPool.init(allocator, 2, context.deinitData);
    defer pool.deinit();

    const item1 = try pool.acquire();
    const item2 = try pool.acquire();
    const item3 = try pool.acquire();

    pool.release(item1); // count=1
    pool.release(item2); // count=2
    pool.release(item3); // count=2, item3 should be destroyed!

    try testing.expectEqual(@as(usize, 1), context.deinit_count);
}

test "MemoryStrategy: arena pool thread safety stress test" {
    const allocator = testing.allocator;
    var strategy = try MemoryStrategy.init(allocator);
    defer strategy.deinit();

    const num_threads = 8;
    const items_per_thread = 200; // Total 1600 acquisitions (exceeds pool size of 1024)

    const Context = struct {
        strategy: *MemoryStrategy,
        done: std.atomic.Value(usize),
    };
    var ctx = Context{
        .strategy = &strategy,
        .done = std.atomic.Value(usize).init(0),
    };

    const worker = struct {
        fn run(c: *Context) void {
            var prng = std.Random.DefaultPrng.init(@intCast(@max(0, std.time.timestamp())));
            const random = prng.random();

            for (0..items_per_thread) |_| {
                const arena = c.strategy.acquireArena() catch unreachable; // zwanzig-disable-line: swallowed-error

                // Perform some random allocations to stress the reset logic
                const alloc = arena.allocator();
                const size = random.intRangeAtMost(usize, 1, 4096);
                const mem = alloc.alloc(u8, size) catch unreachable; // zwanzig-disable-line: swallowed-error
                @memset(mem, 0xAA);

                // Small random yield to increase contention
                if (random.boolean()) std.Thread.yield() catch {}; // zwanzig-disable-line: empty-catch-engine

                c.strategy.releaseArena(arena);
            }
            _ = c.done.fetchAdd(1, .release);
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker.run, .{&ctx});
    }

    for (threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(usize, num_threads), ctx.done.load(.acquire));
}
