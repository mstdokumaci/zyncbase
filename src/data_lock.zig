const std = @import("std");

/// Advisory lock on a data directory.
///
/// The server holds this for its lifetime; `zyncbase restore` acquires it
/// before replacing the database so a restore cannot race a running server.
/// It also prevents two servers from opening the same data directory.
pub const DataLock = struct {
    file: std.Io.File,

    pub fn acquire(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !DataLock {
        try std.Io.Dir.cwd().createDirPath(io, data_dir);

        const path = try std.fmt.allocPrint(allocator, "{s}/zyncbase.lock", .{data_dir});
        defer allocator.free(path);

        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.DataDirLocked,
            else => return err,
        };

        return .{ .file = file };
    }

    pub fn release(self: *DataLock, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};
