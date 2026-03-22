const std = @import("std");
const lockFreeCache = @import("lock_free_cache.zig").lockFreeCache;
const testing = std.testing;

test "cache: concurrent reads never block" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(u32);

    var cache = try u32_cache.init(allocator, .{}, null);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.update(namespace, 42);

    const num_threads = 8;
    const reads_per_thread = 1000;
    var successful_reads = std.atomic.Value(usize).init(0);

    const ThreadContext = struct {
        cache: *u32_cache,
        namespace: []const u8,
        reads: usize,
        counter: *std.atomic.Value(usize),

        fn readerThread(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.reads) : (i += 1) {
                const handle = ctx.cache.get(ctx.namespace) catch |err| {
                    std.log.debug("Read failed: {}", .{err});
                    continue;
                };
                if (handle.data().* != 42) unreachable;
                handle.release();
                _ = ctx.counter.fetchAdd(1, .monotonic);
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, ThreadContext.readerThread, .{ThreadContext{
            .cache = cache,
            .namespace = namespace,
            .reads = reads_per_thread,
            .counter = &successful_reads,
        }});
    }

    for (threads) |thread| thread.join();

    try testing.expectEqual(num_threads * reads_per_thread, successful_reads.load(.monotonic));
}

test "cache: ref_count lifecycle" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(u32);

    var cache = try u32_cache.init(allocator, .{}, null);
    defer cache.deinit();

    const namespace = "test-namespace";
    try cache.update(namespace, 100);

    const handle = try cache.get(namespace);
    const entries = cache.entries.load(.acquire);
    const entry = entries.get(namespace) orelse return error.KeyNotFound;
    try testing.expect(entry.ref_count.load(.acquire) > 0);

    handle.release();
    try testing.expectEqual(@as(u32, 0), entry.ref_count.load(.acquire));
}

test "cache: update increments version" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(u32);

    var cache = try u32_cache.init(allocator, .{}, null);
    defer cache.deinit();

    const namespace = "test";
    try cache.update(namespace, 1);
    try cache.update(namespace, 2);

    const handle = try cache.get(namespace);
    defer handle.release();
    try testing.expectEqual(@as(u32, 2), handle.data().*);
}

test "cache: eviction" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(u32);

    var cache = try u32_cache.init(allocator, .{}, null);
    defer cache.deinit();

    try cache.update("to-evict", 99);
    _ = cache.evict("to-evict");

    const result = cache.get("to-evict");
    try testing.expectError(error.NotFound, result);
}

test "cache: deep free via hook" {
    const allocator = testing.allocator;
    const string_cache = lockFreeCache([]const u8);

    const context = struct {
        fn deinitString(alloc: std.mem.Allocator, s: *[]const u8) void {
            alloc.free(s.*);
        }
    };

    var cache = try string_cache.init(allocator, .{}, context.deinitString);
    defer cache.deinit();

    const val = try allocator.dupe(u8, "hello world");
    try cache.update("key", val);

    // Evict should trigger the hook eventually (during reclaim)
    _ = cache.evict("key");
    cache.reclaim(true); // Force reclaim to run the hook
}
