const std = @import("std");

const fs_utils = @import("fs_utils.zig");

/// Advisory lock on a data directory.
///
/// The server holds an exclusive lock through startup and then downgrades it to
/// shared for its lifetime. Backups hold a shared lock so they can coexist with
/// the server, while `zyncbase restore` acquires the exclusive lock before
/// replacing the database. The startup exclusive lock also prevents two
/// servers from opening the same data directory.
pub const DataLock = struct {
    file: std.Io.File,

    pub fn acquire(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !DataLock {
        return acquireMode(io, allocator, data_dir, .exclusive);
    }

    /// Shared locks coexist with the server and each other, but block restore.
    pub fn acquireShared(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !DataLock {
        return acquireMode(io, allocator, data_dir, .shared);
    }

    fn acquireMode(
        io: std.Io,
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        mode: std.Io.File.Lock,
    ) !DataLock {
        try fs_utils.createDirPathBounded(io, data_dir);

        const path = try std.fmt.allocPrint(allocator, "{s}/zyncbase.lock", .{data_dir});
        defer allocator.free(path);

        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
            .lock = mode,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.DataDirLocked,
            else => return err,
        };

        return .{ .file = file };
    }

    pub fn downgradeToShared(self: *DataLock, io: std.Io) !void {
        try self.file.downgradeLock(io);
    }

    pub fn release(self: *DataLock, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};
