const std = @import("std");

const DataLock = @import("data_lock.zig").DataLock;

test "data lock: second acquisition fails until released" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..] });
    defer allocator.free(base);

    var first = try DataLock.acquire(std.testing.io, allocator, base);
    try std.testing.expectError(
        error.DataDirLocked,
        DataLock.acquire(std.testing.io, allocator, base),
    );
    first.release(std.testing.io);

    var second = try DataLock.acquire(std.testing.io, allocator, base);
    second.release(std.testing.io);
}
