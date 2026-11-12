const std = @import("std");

/// Same component walk as `std.Io.Dir.createDirPath`, but with a hard
/// iteration bound. The stdlib version loops forever when an existing
/// parent's child cannot be created (e.g. `/proc/...` on Linux: mkdir EEXIST
/// on `/proc` → walk down → ENOENT on child → walk up → EEXIST → ...).
pub fn createDirPathBounded(io: std.Io, path: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    var it = std.fs.path.componentIterator(path);
    var component = it.last() orelse return error.InvalidDataDir;
    var budget: usize = 256;
    while (true) {
        budget -= 1;
        if (budget == 0) return error.InvalidDataDir;
        if (dir.createDir(io, component.path, .default_dir)) |_| {
            component = it.next() orelse return;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                const st = try dir.statFile(io, component.path, .{ .follow_symlinks = false });
                if (st.kind != .directory) return error.NotDir;
                component = it.next() orelse return;
            },
            error.FileNotFound => {
                component = it.previous() orelse return err;
            },
            else => return err,
        }
    }
}
