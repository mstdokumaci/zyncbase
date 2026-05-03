const std = @import("std");
const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

test "MemoryStrategy: init and deinit" {
    const allocator = testing.allocator;
    var strategy: MemoryStrategy = undefined;
    try strategy.init(allocator);
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
    var strategy: MemoryStrategy = undefined;
    try strategy.init(allocator);
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

test "MemoryStrategy: arena pool thread safety stress test" {
    const allocator = testing.allocator;
    const config = MemoryStrategy.Config{
        .arena_pool = .{ .pre_allocate = 1024, .max_capacity = 1024 },
    };
    var strategy: MemoryStrategy = undefined;
    try strategy.initWithConfig(allocator, config);
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
