const std = @import("std");
const testing = std.testing;
const latch = @import("latch.zig").latch;

const error_latch = latch(void);

test "latch(void): resolve unblocks wait" {
    var l = error_latch{};

    const Runner = struct {
        fn run(l_ptr: *error_latch) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            l_ptr.resolve({});
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.run, .{&l});
    try l.wait();
    t.join();
}

test "latch(void): reject propagates error to wait" {
    var l = error_latch{};

    const Runner = struct {
        fn run(l_ptr: *error_latch) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            l_ptr.reject(error.TestRejection);
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.run, .{&l});
    try testing.expectError(error.TestRejection, l.wait());
    t.join();
}

test "latch(u32): resolve with value, wait receives it" {
    var l = latch(u32){};

    const Runner = struct {
        fn run(l_ptr: *latch(u32)) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            l_ptr.resolve(42);
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.run, .{&l});
    const result = try l.wait();
    try testing.expectEqual(@as(u32, 42), result);
    t.join();
}

test "latch(u32): reject propagates error" {
    var l = latch(u32){};

    const Runner = struct {
        fn run(l_ptr: *latch(u32)) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            l_ptr.reject(error.OutOfMemory);
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.run, .{&l});
    try testing.expectError(error.OutOfMemory, l.wait());
    t.join();
}

test "latch: multiple waiters all unblock on resolve" {
    var l = latch(u64){};
    var results = [_]u64{0} ** 4;
    var done = [_]bool{false} ** 4;

    const Waiter = struct {
        fn run(l_ptr: *latch(u64), out: *u64, flag: *bool) void {
            const v = l_ptr.wait() catch {
                flag.* = true;
                return;
            };
            out.* = v;
            flag.* = true;
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, &results, &done) |*t, *r, *d| {
        t.* = try std.Thread.spawn(.{}, Waiter.run, .{ &l, r, d });
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);
    l.resolve(999);

    for (threads) |t| t.join();

    for (results) |r| {
        try testing.expectEqual(@as(u64, 999), r);
    }
    for (done) |d| {
        try testing.expect(d);
    }
}

test "latch: resolve before wait returns immediately" {
    var l = latch(u32){};
    l.resolve(7);
    const result = try l.wait();
    try testing.expectEqual(@as(u32, 7), result);
}

test "latch: reject before wait returns immediately" {
    var l = error_latch{};
    l.reject(error.AlreadyRejected);
    try testing.expectError(error.AlreadyRejected, l.wait());
}

// Double-resolve/reject panics by design (std.debug.panic in the implementation).
// Zig 0.15.2 has no std.testing.expectPanic, so this cannot be tested in-process.
// The safety check is exercised in all build modes.
