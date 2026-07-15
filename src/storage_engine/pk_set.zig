const std = @import("std");
const Allocator = std.mem.Allocator;
const DocId = @import("../typed/doc_id.zig").DocId;

pub const PkSet = struct {
    set: std.AutoHashMapUnmanaged(DocId, void),
    lock: std.Thread.RwLock,

    pub const empty: PkSet = .{
        .set = .empty,
        .lock = .{},
    };

    pub fn deinit(self: *PkSet, allocator: Allocator) void {
        self.set.deinit(allocator);
    }

    pub fn contains(self: *PkSet, id: DocId) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.set.contains(id);
    }

    pub fn insert(self: *PkSet, allocator: Allocator, id: DocId) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.set.put(allocator, id, {}) catch |err| {
            std.log.warn("Failed to insert into pk_set (OOM): {}", .{err});
        };
    }

    pub fn remove(self: *PkSet, id: DocId) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = self.set.remove(id);
    }
};
