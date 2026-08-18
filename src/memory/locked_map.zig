const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn lockedMap(comptime K: type, comptime V: type, comptime lock_type: type) type { // zwanzig-disable-line: unused-parameter
    return struct {
        const Self = @This();

        io: std.Io,
        map: std.AutoHashMapUnmanaged(K, V),
        lock: lock_type,

        pub fn init(io: std.Io) Self {
            return .{ .io = io, .map = .empty, .lock = .init };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.map.deinit(allocator);
        }

        fn readLock(self: *Self) void {
            if (lock_type == std.Io.RwLock) {
                self.lock.lockSharedUncancelable(self.io);
            } else {
                self.lock.lockUncancelable(self.io);
            }
        }

        fn readUnlock(self: *Self) void {
            if (lock_type == std.Io.RwLock) {
                self.lock.unlockShared(self.io);
            } else {
                self.lock.unlock(self.io);
            }
        }

        fn writeLock(self: *Self) void {
            self.lock.lockUncancelable(self.io);
        }

        fn writeUnlock(self: *Self) void {
            self.lock.unlock(self.io);
        }

        pub fn get(self: *Self, key: K) ?V {
            self.readLock();
            defer self.readUnlock();
            return self.map.get(key);
        }

        pub fn put(self: *Self, allocator: Allocator, key: K, value: V) !void {
            self.writeLock();
            defer self.writeUnlock();
            try self.map.put(allocator, key, value);
        }

        pub fn remove(self: *Self, key: K) void {
            self.writeLock();
            defer self.writeUnlock();
            _ = self.map.remove(key);
        }

        pub fn contains(self: *Self, key: K) bool {
            self.readLock();
            defer self.readUnlock();
            return self.map.contains(key);
        }
    };
}
