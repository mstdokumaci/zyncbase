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
    const allocator = std.heap.smp_allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
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
    const allocator = std.heap.smp_allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
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
    const allocator = std.heap.smp_allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    const key: i64 = 1;
    try cache.update(key, .{ .value = 1 });
    try cache.update(key, .{ .value = 2 });

    const handle = try cache.get(key);
    defer handle.release();
    try testing.expectEqual(@as(u32, 2), handle.data().value);
}

test "cache: batch applies ordered updates and evictions" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    try cache.update(1, .{ .value = 1 });
    try cache.update(2, .{ .value = 2 });

    const old_handle = try cache.get(1);
    defer old_handle.release();

    const mutations = [_]u32_cache.Mutation{
        .{ .update = .{ .key = 1, .data = .{ .value = 10 } } },
        .{ .update = .{ .key = 1, .data = .{ .value = 11 } } },
        .{ .evict = 2 },
        .{ .evict = 3 },
        .{ .update = .{ .key = 3, .data = .{ .value = 30 } } },
    };
    try cache.applyBatch(&mutations);

    try testing.expectEqual(@as(u32, 1), old_handle.data().value);

    const first = try cache.get(1);
    defer first.release();
    try testing.expectEqual(@as(u32, 11), first.data().value);
    try testing.expectEqual(@as(u64, 2), first.entry.version.load(.acquire));

    try testing.expectError(error.NotFound, cache.get(2));

    const third = try cache.get(3);
    defer third.release();
    try testing.expectEqual(@as(u32, 30), third.data().value);
}

test "cache: batch retries concurrent mutations" {
    const allocator = std.heap.smp_allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    const Context = struct {
        cache: *u32_cache,

        fn batchWriter(ctx: @This()) void {
            for (0..200) |i| {
                const value: u32 = @intCast(i);
                const mutations = [_]u32_cache.Mutation{
                    .{ .update = .{ .key = 1, .data = .{ .value = value } } },
                    .{ .update = .{ .key = 3, .data = .{ .value = value } } },
                };
                ctx.cache.applyBatch(&mutations) catch unreachable;
            }
        }

        fn singleWriter(ctx: @This()) void {
            for (0..200) |i| {
                ctx.cache.update(2, .{ .value = @intCast(i) }) catch unreachable;
            }
        }
    };

    const ctx = Context{ .cache = &cache };
    const batch_thread = try std.Thread.spawn(.{}, Context.batchWriter, .{ctx});
    const single_thread = try std.Thread.spawn(.{}, Context.singleWriter, .{ctx});
    batch_thread.join();
    single_thread.join();

    for ([_]i64{ 1, 2, 3 }) |key| {
        const handle = try cache.get(key);
        defer handle.release();
        try testing.expectEqual(@as(u32, 199), handle.data().value);
    }
}

test "cache: eviction" {
    const allocator = std.heap.smp_allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    const key: i64 = 777;
    try cache.update(key, .{ .value = 99 });
    _ = try cache.evict(key);

    const result = cache.get(key);
    try testing.expectError(error.NotFound, result);
}

test "cache: eviction distinguishes misses from allocation failures" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    try cache.update(1, .{ .value = 99 });

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.allocator = failing.allocator();
    defer cache.allocator = allocator;

    try testing.expect(!try cache.evict(2));
    const mutation = [_]u32_cache.Mutation{.{ .evict = 1 }};
    try testing.expectError(error.OutOfMemory, cache.applyBatch(&mutation));

    const handle = try cache.get(1);
    handle.release();
}

test "cache: deep free via value deinit" {
    const allocator = std.heap.smp_allocator;
    const string_cache = lockFreeCache(OwnedString, i64);

    var cache: string_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    const val = try allocator.dupe(u8, "hello world");
    try cache.update(42, .{ .value = val });

    // Evict should trigger deinit eventually (during reclaim).
    _ = try cache.evict(42);
    cache.reclaim(true); // Force reclaim to run deinit.
}

test "cache: applyBatch failure fallback keeps unreadable during evictions then restores on success" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    // Seed cache with stale entries that a batch would have updated/evicted.
    try cache.update(1, .{ .value = 10 });
    try cache.update(2, .{ .value = 20 });
    try cache.update(42, .{ .value = 99 });

    const mutations = [_]u32_cache.Mutation{
        .{ .update = .{ .key = 3, .data = .{ .value = 30 } } },
        .{ .evict = 42 },
        .{ .update = .{ .key = 1, .data = .{ .value = 11 } } },
    };

    // Force allocation failure in applyBatch (fail_index 0 covers the initial CacheEntry.init allocation;
    // later fail_index values would exercise cloneEntries and acquireDeferNode paths).
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, cache.applyBatch(&mutations));
    cache.allocator = allocator;

    // Fallback path as in write_worker commitBatchAndApply: invalidate, evict each key while unreadable, restore only after all succeed.
    cache.invalidate();
    try testing.expectError(error.NotFound, cache.get(1));
    try testing.expectError(error.NotFound, cache.get(2));

    var evict_failed = false;
    for (mutations) |op| {
        const key = switch (op) {
            .update => |u| u.key,
            .evict => |k| k,
        };
        _ = cache.evict(key) catch {
            evict_failed = true;
            break;
        };
    }
    if (!evict_failed) cache.setReadable(true) else try cache.clear();

    try testing.expect(!evict_failed);
    try testing.expect(cache.readable.load(.acquire));
    try testing.expectError(error.NotFound, cache.get(42));
    // 2 was not in mutation set, so it should still be readable after restore.
    {
        const h = try cache.get(2);
        defer h.release();
        try testing.expectEqual(@as(u32, 20), h.data().value);
    }
    try testing.expectError(error.NotFound, cache.get(3));

    // Subsequent document-cache hit must succeed after successful cleanup.
    try cache.update(3, .{ .value = 30 });
    {
        const h = try cache.get(3);
        defer h.release();
        try testing.expectEqual(@as(u32, 30), h.data().value);
    }
    try cache.update(1, .{ .value = 11 });
    {
        const h = try cache.get(1);
        defer h.release();
        try testing.expectEqual(@as(u32, 11), h.data().value);
    }
}

test "cache: fallback clear on eviction failure releases retained entries and restores hit" {
    const allocator = testing.allocator;
    const CountingValue = struct {
        value: u32,
        counter: *std.atomic.Value(usize),
        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            _ = alloc;
            _ = self.counter.fetchAdd(1, .seq_cst);
        }
    };
    const counting_cache = lockFreeCache(CountingValue, i64);

    var deinit_count = std.atomic.Value(usize).init(0);

    var cache: counting_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    try cache.update(1, .{ .value = 1, .counter = &deinit_count });
    try cache.update(2, .{ .value = 2, .counter = &deinit_count });
    cache.reclaim(true);
    try testing.expectEqual(@as(usize, 0), deinit_count.load(.acquire));

    const mutations = [_]counting_cache.Mutation{
        .{ .update = .{ .key = 3, .data = .{ .value = 3, .counter = &deinit_count } } },
        .{ .evict = 1 },
    };

    // Simulate applyBatch failure.
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, cache.applyBatch(&mutations));
    cache.allocator = allocator;

    // Invalidate then force eviction to fail, triggering atomic clear path.
    cache.invalidate();
    try testing.expectError(error.NotFound, cache.get(1));

    var failing2 = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.allocator = failing2.allocator();
    var evict_failed = false;
    for (mutations) |op| {
        const key = switch (op) {
            .update => |u| u.key,
            .evict => |k| k,
        };
        _ = cache.evict(key) catch {
            evict_failed = true;
            break;
        };
    }
    try testing.expect(evict_failed);
    cache.allocator = allocator;

    // Atomic clear must release retained stale entries and restore readability.
    try cache.clear();
    try testing.expect(cache.readable.load(.acquire));
    try testing.expectError(error.NotFound, cache.get(1));
    try testing.expectError(error.NotFound, cache.get(2));

    cache.reclaim(true);
    try testing.expectEqual(@as(usize, 2), deinit_count.load(.acquire));

    // Subsequent hit must succeed after clear.
    try cache.update(99, .{ .value = 99, .counter = &deinit_count });
    {
        const h = try cache.get(99);
        defer h.release();
        try testing.expectEqual(@as(u32, 99), h.data().value);
    }
}

test "cache: recovery clear failure keeps unreadable and skips applyBatch fallback restore leaves unaffected stale hidden" {
    const allocator = testing.allocator;
    const u32_cache = lockFreeCache(U32Value, i64);

    var cache: u32_cache = undefined;
    try cache.init(testing.io, allocator, .{});
    defer cache.deinit();

    // Seed with affected and unaffected stale entries.
    try cache.update(1, .{ .value = 10 });
    try cache.update(2, .{ .value = 20 }); // unaffected — not in mutations
    try cache.update(42, .{ .value = 99 });

    const mutations = [_]u32_cache.Mutation{
        .{ .update = .{ .key = 3, .data = .{ .value = 30 } } },
        .{ .evict = 42 },
        .{ .update = .{ .key = 1, .data = .{ .value = 11 } } },
    };

    // Make cache unreadable as after a prior applyBatch failure.
    cache.invalidate();
    try testing.expect(!cache.readable.load(.acquire));

    // 1) Recovery clear fails (simulate OOM).
    var failing_clear = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.allocator = failing_clear.allocator();
    var recovery_ok = true;
    cache.clear() catch {
        recovery_ok = false;
    };
    cache.allocator = allocator;
    try testing.expect(!recovery_ok);
    try testing.expect(!cache.readable.load(.acquire));
    // Unaffected stale must still be hidden while unreadable.
    try testing.expectError(error.NotFound, cache.get(2));

    // 2) Subsequent applyBatch also fails.
    var failing_batch = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.allocator = failing_batch.allocator();
    try testing.expectError(error.OutOfMemory, cache.applyBatch(&mutations));
    cache.allocator = allocator;

    // 3) Fallback as in write_worker commitBatchAndApply: invalidate, evict affected keys, only restore if recovery_ok.
    cache.invalidate();
    var evict_failed = false;
    for (mutations) |op| {
        const key = switch (op) {
            .update => |u| u.key,
            .evict => |k| k,
        };
        _ = cache.evict(key) catch {
            evict_failed = true;
            break;
        };
    }
    try testing.expect(!evict_failed);
    if (!evict_failed and recovery_ok) cache.setReadable(true) else if (evict_failed) try cache.clear();

    // Must remain unreadable because recovery clear failed; unaffected stale must stay hidden.
    try testing.expect(!recovery_ok);
    try testing.expect(!evict_failed);
    try testing.expect(!cache.readable.load(.acquire));
    try testing.expectError(error.NotFound, cache.get(1));
    try testing.expectError(error.NotFound, cache.get(2));
    try testing.expectError(error.NotFound, cache.get(42));
    try testing.expectError(error.NotFound, cache.get(3));

    // Only a successful clear restores readability and drops all stale entries.
    try cache.clear();
    try testing.expect(cache.readable.load(.acquire));
    try testing.expectError(error.NotFound, cache.get(2));
    try testing.expectError(error.NotFound, cache.get(1));
    // Subsequent hit must succeed after successful recovery clear.
    try cache.update(99, .{ .value = 99 });
    {
        const h = try cache.get(99);
        defer h.release();
        try testing.expectEqual(@as(u32, 99), h.data().value);
    }
}
