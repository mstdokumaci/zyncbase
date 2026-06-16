const std = @import("std");
const Allocator = std.mem.Allocator;

/// A subscriber to presence notifications for a namespace.
pub const Subscriber = struct {
    conn_id: u64,
    sub_id: u64,
};

/// A namespace-indexed table of subscriber lists.
/// Handles its own lifecycle: empty lists are removed on last unsubscribe.
/// Not thread-safe; the caller (PresenceManager) provides synchronization.
pub const SubscriberTable = struct {
    map: std.AutoHashMapUnmanaged(i64, std.ArrayListUnmanaged(Subscriber)) = .{},

    pub fn deinit(self: *SubscriberTable, allocator: Allocator) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.map.deinit(allocator);
    }

    /// Register a subscriber for the given namespace.
    /// On OOM after creating a new namespace entry, cleans up the empty list.
    pub fn subscribe(
        self: *SubscriberTable,
        allocator: Allocator,
        namespace_id: i64,
        conn_id: u64,
        sub_id: u64,
    ) !void {
        const result = try self.map.getOrPut(allocator, namespace_id);
        const created = !result.found_existing;
        if (created) {
            result.value_ptr.* = .{};
        }
        errdefer {
            if (created) {
                result.value_ptr.deinit(allocator);
                _ = self.map.remove(namespace_id);
            }
        }
        try result.value_ptr.append(allocator, .{ .conn_id = conn_id, .sub_id = sub_id });
    }

    /// Remove the first subscriber matching the given connection.
    /// If the subscriber list becomes empty, removes the namespace entry entirely.
    pub fn unsubscribe(
        self: *SubscriberTable,
        allocator: Allocator,
        namespace_id: i64,
        conn_id: u64,
    ) void {
        const subs = self.map.getPtr(namespace_id) orelse return;
        var i: usize = 0;
        while (i < subs.items.len) {
            if (subs.items[i].conn_id == conn_id) {
                _ = subs.swapRemove(i);
            } else {
                i += 1;
            }
        }
        if (subs.items.len == 0) {
            subs.deinit(allocator);
            _ = self.map.remove(namespace_id);
        }
    }

    /// Returns the subscriber slice for a namespace, if any subscribers exist.
    pub fn get(self: *const SubscriberTable, namespace_id: i64) ?[]const Subscriber {
        if (self.map.get(namespace_id)) |list| {
            return list.items;
        }
        return null;
    }
};
