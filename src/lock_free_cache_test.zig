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

const OwnedString = struct {
    value: []const u8,

    pub fn deinit(self: OwnedString, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

test "cache: concurrent reads never block" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(allocator, .{});
    defer cache.deinit();

    const key: i64 = 12345;
    try cache.update(key, .{ .value = 42 });

    const num_threads = 8;
    const reads_per_thread = 1000;
    var successful_reads = std.atomic.Value(usize).init(0);

    const ThreadContext = struct {
        cache: *u32_cache,
        key: i64,
        reads: usize,
        counter: *std.atomic.Value(usize),

        fn readerThread(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.reads) : (i += 1) {
                const handle = ctx.cache.get(ctx.key) catch |err| {
                    std.log.debug("Read failed: {}", .{err});
                    continue;
                };
                if (handle.data().value != 42) unreachable;
                handle.release();
                _ = ctx.counter.fetchAdd(1, .monotonic);
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, ThreadContext.readerThread, .{ThreadContext{
            .cache = &cache,
            .key = key,
            .reads = reads_per_thread,
            .counter = &successful_reads,
        }});
    }

    for (threads) |thread| thread.join();

    try testing.expectEqual(num_threads * reads_per_thread, successful_reads.load(.monotonic));
}

test "cache: ref_count lifecycle" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(allocator, .{});
    defer cache.deinit();

    const key: i64 = 999;
    try cache.update(key, .{ .value = 100 });

    const handle = try cache.get(key);
    const entries = cache.entries.load(.acquire);
    const entry = entries.get(key) orelse return error.KeyNotFound;
    try testing.expect(entry.ref_count.load(.acquire) > 0);

    handle.release();
    try testing.expectEqual(@as(usize, 0), entry.ref_count.load(.acquire));
}

test "cache: update increments version" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(allocator, .{});
    defer cache.deinit();

    const key: i64 = 1;
    try cache.update(key, .{ .value = 1 });
    try cache.update(key, .{ .value = 2 });

    const handle = try cache.get(key);
    defer handle.release();
    try testing.expectEqual(@as(u32, 2), handle.data().value);
}

test "cache: eviction" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(allocator, .{});
    defer cache.deinit();

    const key: i64 = 777;
    try cache.update(key, .{ .value = 99 });
    _ = cache.evict(key);

    const result = cache.get(key);
    try testing.expectError(error.NotFound, result);
}

test "cache: deep free via value deinit" {
    const allocator = testing.allocator;
    const string_cache = lockFreeCache(OwnedString, i64);

    var cache: string_cache = undefined;
    try cache.init(allocator, .{});
    defer cache.deinit();

    const val = try allocator.dupe(u8, "hello world");
    try cache.update(42, .{ .value = val });

    // Evict should trigger deinit eventually (during reclaim).
    _ = cache.evict(42);
    cache.reclaim(true); // Force reclaim to run deinit.
}
