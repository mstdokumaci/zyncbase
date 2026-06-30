const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed.zig");
const schema_mod = @import("../schema.zig");
const msgpack = @import("../msgpack_utils.zig");
const PresenceRecord = @import("record.zig").PresenceRecord;
const Subscriber = @import("subscriber.zig").Subscriber;
const SubscriberTable = @import("subscriber.zig").SubscriberTable;

/// Owns presence state, pending batches, and subscription tracking.
/// Thread-safe; does not know about networking.
pub const PresenceManager = struct {
    allocator: Allocator,

    data_mutex: std.Thread.Mutex,

    // Typed schema built at startup (names + declared types)
    user_fields: []const schema_mod.PresenceField,
    shared_fields: []const schema_mod.PresenceField,

    // User state: namespace_id → (users.id → PresenceRecord)
    user_state: std.AutoHashMapUnmanaged(i64, std.AutoHashMapUnmanaged(typed.DocId, PresenceRecord)),

    // User join timestamps: namespace_id → (users.id → joined_at_ms)
    user_joined_at: std.AutoHashMapUnmanaged(i64, std.AutoHashMapUnmanaged(typed.DocId, i64)),

    // Shared state: namespace_id → PresenceRecord
    shared_state: std.AutoHashMapUnmanaged(i64, PresenceRecord),

    // Grace period tracking: namespace_id → timestamp_ms when it became empty
    namespace_empty_at: std.AutoHashMapUnmanaged(i64, i64),

    // Batch pending: user presence updates queued for the 50ms flush
    pending_user_updates: std.ArrayListUnmanaged(PendingUserUpdate),
    pending_shared_updates: std.ArrayListUnmanaged(PendingSharedUpdate),

    user_subscribers: SubscriberTable,
    shared_subscribers: SubscriberTable,

    pub const PendingUserUpdate = struct {
        namespace_id: i64,
        user_id: typed.DocId,
        patch: ?msgpack.Payload, // null = leave (or transferred to batch)
        is_new_user: bool, // true = join event, false = update event
        joined_at: i64, // actual join timestamp (0 for non-join)
        is_leave: bool = false, // true = explicit leave event (not a transferred update)
    };

    pub const PendingSharedUpdate = struct {
        namespace_id: i64,
        patch: msgpack.Payload,
        source_conn: u64,
    };

    pub fn init(
        self: *PresenceManager,
        allocator: Allocator,
        user_fields: []const schema_mod.PresenceField,
        shared_fields: []const schema_mod.PresenceField,
    ) void {
        self.* = .{
            .allocator = allocator,
            .data_mutex = .{},
            .user_fields = user_fields,
            .shared_fields = shared_fields,
            .user_state = .{},
            .user_joined_at = .{},
            .shared_state = .{},
            .namespace_empty_at = .{},
            .pending_user_updates = .{},
            .pending_shared_updates = .{},
            .user_subscribers = .{},
            .shared_subscribers = .{},
        };
    }

    pub fn deinit(self: *PresenceManager) void {
        var user_iter = self.user_state.iterator();
        while (user_iter.next()) |entry| {
            var ns_map = entry.value_ptr.*;
            var ns_iter = ns_map.iterator();
            while (ns_iter.next()) |user_entry| {
                var record = user_entry.value_ptr.*;
                record.deinit(self.allocator);
            }
            ns_map.deinit(self.allocator);
        }
        self.user_state.deinit(self.allocator);

        // Clean up user_joined_at
        var joined_iter = self.user_joined_at.iterator();
        while (joined_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.user_joined_at.deinit(self.allocator);

        // Clean up shared_state
        var shared_iter = self.shared_state.iterator();
        while (shared_iter.next()) |entry| {
            var record = entry.value_ptr.*;
            record.deinit(self.allocator);
        }
        self.shared_state.deinit(self.allocator);

        self.namespace_empty_at.deinit(self.allocator);

        for (self.pending_user_updates.items) |*update| {
            if (update.patch) |patch| {
                patch.free(self.allocator);
            }
        }
        self.pending_user_updates.deinit(self.allocator);

        for (self.pending_shared_updates.items) |*update| {
            update.patch.free(self.allocator);
        }
        self.pending_shared_updates.deinit(self.allocator);

        self.user_subscribers.deinit(self.allocator);
        self.shared_subscribers.deinit(self.allocator);
    }

    /// Set user presence data. Merges the patch into the existing record.
    pub fn setUser(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: typed.DocId,
        patch: msgpack.Payload,
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Get or create namespace map
        const ns_result = try self.user_state.getOrPut(self.allocator, namespace_id);
        const ns_created = !ns_result.found_existing;
        if (ns_created) {
            ns_result.value_ptr.* = .{};
        }

        // Get or create user record
        const user_result = try ns_result.value_ptr.getOrPut(self.allocator, user_id);
        const is_new_user = !user_result.found_existing;

        // Function-level rollback for late failures (after the if-block's scoped errdefers exit).
        // Block-scoped errdefers inside `if (is_new_user)` handle early failures within that block.
        var user_cleanup = false;
        errdefer if (user_cleanup) {
            user_result.value_ptr.deinit(self.allocator);
            _ = ns_result.value_ptr.fetchRemove(user_id);
            if (ns_created and ns_result.value_ptr.count() == 0) {
                ns_result.value_ptr.deinit(self.allocator);
                _ = self.user_state.remove(namespace_id);
            }
            if (self.user_joined_at.getPtr(namespace_id)) |joined_map| {
                _ = joined_map.fetchRemove(user_id);
                if (joined_map.count() == 0) {
                    joined_map.deinit(self.allocator);
                    _ = self.user_joined_at.remove(namespace_id);
                }
            }
        };

        const now = std.time.milliTimestamp();

        if (is_new_user) {
            // getOrPut inserted user_id with undefined value — register cleanup
            // before any try that might fail.
            errdefer {
                _ = ns_result.value_ptr.fetchRemove(user_id);
                if (ns_created and ns_result.value_ptr.count() == 0) {
                    ns_result.value_ptr.deinit(self.allocator);
                    _ = self.user_state.remove(namespace_id);
                }
            }

            user_result.value_ptr.* = try PresenceRecord.init(self.allocator, self.user_fields.len);
            // Record is initialized — register deinit (fires before fetchRemove, LIFO)
            errdefer {
                user_result.value_ptr.deinit(self.allocator);
            }

            // Record join timestamp
            const joined_ns_result = try self.user_joined_at.getOrPut(self.allocator, namespace_id);
            const joined_ns_created = !joined_ns_result.found_existing;
            if (joined_ns_created) {
                joined_ns_result.value_ptr.* = .{};
            }
            errdefer {
                if (joined_ns_created) {
                    joined_ns_result.value_ptr.deinit(self.allocator);
                    _ = self.user_joined_at.remove(namespace_id);
                }
            }
            try joined_ns_result.value_ptr.put(self.allocator, user_id, now);

            user_cleanup = true;
        }

        // Merge patch into record
        try user_result.value_ptr.mergeFromPayload(self.allocator, self.user_fields, patch);

        // Cancel grace period if it was set
        _ = self.namespace_empty_at.fetchRemove(namespace_id);

        // Coalesce with any pending update for this user in the current batch.
        const maybe_existing = self.findPendingUserUpdate(namespace_id, user_id);
        if (maybe_existing) |existing| {
            if (existing.patch != null) {
                try self.mergePayloadArrays(&existing.patch.?, patch);
            } else {
                const cloned_patch = try patch.deepClone(self.allocator);
                existing.patch = cloned_patch;
            }
            existing.is_leave = false;
            if (!existing.is_new_user) {
                existing.is_new_user = is_new_user;
                if (is_new_user) {
                    existing.joined_at = now;
                }
            }
            return;
        }

        // No pending update for this user; clone once and append.
        const cloned_patch = try patch.deepClone(self.allocator);
        errdefer cloned_patch.free(self.allocator);
        try self.pending_user_updates.append(self.allocator, .{
            .namespace_id = namespace_id,
            .user_id = user_id,
            .patch = cloned_patch,
            .is_new_user = is_new_user,
            .joined_at = if (is_new_user) now else 0,
        });
    }

    /// Set shared presence data. Merges the patch into the namespace record.
    pub fn setShared(
        self: *PresenceManager,
        namespace_id: i64,
        patch: msgpack.Payload,
        source_conn: u64,
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Get or create shared record
        const result = try self.shared_state.getOrPut(self.allocator, namespace_id);
        const is_new = !result.found_existing;

        var shared_cleanup = false;
        errdefer if (shared_cleanup) {
            result.value_ptr.deinit(self.allocator);
            _ = self.shared_state.remove(namespace_id);
        };

        if (is_new) {
            errdefer _ = self.shared_state.remove(namespace_id);
            result.value_ptr.* = try PresenceRecord.init(self.allocator, self.shared_fields.len);
            shared_cleanup = true;
        }

        // Merge patch into record
        try result.value_ptr.mergeFromPayload(self.allocator, self.shared_fields, patch);

        // Coalesce pending shared updates for the namespace.
        if (self.findPendingSharedUpdate(namespace_id)) |existing| {
            try self.mergePayloadArrays(&existing.patch, patch);
            existing.source_conn = source_conn;
            return;
        }

        // No pending shared update; clone once and append.
        const cloned_patch = try patch.deepClone(self.allocator);
        errdefer cloned_patch.free(self.allocator);
        try self.pending_shared_updates.append(self.allocator, .{
            .namespace_id = namespace_id,
            .patch = cloned_patch,
            .source_conn = source_conn,
        });
    }

    /// Remove user presence and queue leave broadcast.
    pub fn removeUser(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: typed.DocId,
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        const ns_ptr = self.user_state.getPtr(namespace_id) orelse return;
        const removed = ns_ptr.fetchRemove(user_id);
        if (removed) |entry| {
            var record = entry.value;
            record.deinit(self.allocator);

            // Clean up join timestamp
            if (self.user_joined_at.getPtr(namespace_id)) |joined_map| {
                _ = joined_map.fetchRemove(user_id);
                if (joined_map.count() == 0) {
                    joined_map.deinit(self.allocator);
                    _ = self.user_joined_at.remove(namespace_id);
                }
            }

            // If namespace is now empty, deinit the empty map
            const ns_was_emptied = ns_ptr.count() == 0;
            if (ns_was_emptied) {
                ns_ptr.deinit(self.allocator);
                _ = self.user_state.remove(namespace_id);
            }
            // Non-critical: record grace period after critical leave broadcast work.
            defer if (ns_was_emptied) {
                self.namespace_empty_at.put(self.allocator, namespace_id, std.time.milliTimestamp()) catch |err| {
                    std.log.err("Failed to record grace period for namespace {}: {}", .{ namespace_id, err });
                };
            };

            if (self.findPendingUserUpdateIndex(namespace_id, user_id)) |idx| {
                var existing = &self.pending_user_updates.items[idx];
                if (existing.patch == null and existing.is_leave) {
                    return;
                }
                if (existing.is_new_user) {
                    if (existing.patch) |patch| patch.free(self.allocator);
                    _ = self.pending_user_updates.orderedRemove(idx);
                    return;
                }

                if (existing.patch) |patch| patch.free(self.allocator);
                existing.patch = null;
                existing.is_new_user = false;
                existing.is_leave = true;
                return;
            }

            // Queue leave broadcast
            try self.pending_user_updates.append(self.allocator, .{
                .namespace_id = namespace_id,
                .user_id = user_id,
                .patch = null, // null signals leave
                .is_new_user = false,
                .joined_at = 0,
                .is_leave = true,
            });
        }
    }

    fn findPendingUserUpdateIndex(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: typed.DocId,
    ) ?usize {
        var i: usize = 0;
        while (i < self.pending_user_updates.items.len) {
            if (self.pending_user_updates.items[i].namespace_id == namespace_id and self.pending_user_updates.items[i].user_id == user_id) {
                return i;
            }
            i += 1;
        }
        return null;
    }

    fn findPendingUserUpdate(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: typed.DocId,
    ) ?*PendingUserUpdate {
        for (self.pending_user_updates.items) |*update| {
            if (update.namespace_id == namespace_id and update.user_id == user_id) return update;
        }
        return null;
    }

    fn findPendingSharedUpdate(
        self: *PresenceManager,
        namespace_id: i64,
    ) ?*PendingSharedUpdate {
        for (self.pending_shared_updates.items) |*update| {
            if (update.namespace_id == namespace_id) return update;
        }
        return null;
    }

    fn mergePayloadArrays(
        self: *PresenceManager,
        target: *msgpack.Payload,
        source: msgpack.Payload,
    ) !void {
        if (target.* != .arr or source != .arr) return;

        for (source.arr) |source_pair| {
            if (source_pair != .arr or source_pair.arr.len != 2) continue;
            const source_idx = source_pair.arr[0];

            var found = false;
            for (target.*.arr) |*target_pair| {
                if (target_pair.* != .arr or target_pair.*.arr.len != 2) continue;
                const target_idx = target_pair.*.arr[0];
                if (payloadUintEqual(source_idx, target_idx)) {
                    const cloned_val = try source_pair.arr[1].deepClone(self.allocator);
                    target_pair.*.arr[1].free(self.allocator);
                    target_pair.*.arr[1] = cloned_val;
                    found = true;
                    break;
                }
            }

            if (!found) {
                const cloned_pair = try source_pair.deepClone(self.allocator);
                errdefer cloned_pair.free(self.allocator);
                const old_len = target.*.arr.len;
                const new_slice = try self.allocator.realloc(target.*.arr, old_len + 1);
                new_slice[old_len] = cloned_pair;
                target.*.arr = new_slice;
            }
        }
    }

    fn payloadUintEqual(a: msgpack.Payload, b: msgpack.Payload) bool {
        const a_uint = msgpack.extractPayloadUint(a) orelse return false;
        const b_uint = msgpack.extractPayloadUint(b) orelse return false;
        return a_uint == b_uint;
    }

    /// Subscribe to user presence updates in a namespace.
    /// Returns a snapshot of current users.
    pub fn onSubscribeUser(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
        sub_id: u64,
    ) !UserSnapshot {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Build snapshot before registering subscriber — any failure here
        // must not leave a subscriber registered with no snapshot delivered.
        var snapshot = UserSnapshot{
            .users = std.ArrayListUnmanaged(UserEntry).empty,
        };
        errdefer {
            for (snapshot.users.items) |*entry|
                entry.data.deinit(self.allocator);
            snapshot.users.deinit(self.allocator);
        }

        if (self.user_state.get(namespace_id)) |ns_map| {
            const joined_map = self.user_joined_at.get(namespace_id);
            var iter = ns_map.iterator();
            while (iter.next()) |entry| {
                var cloned = try entry.value_ptr.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);

                const joined_at = if (joined_map) |jm| jm.get(entry.key_ptr.*) orelse 0 else 0;
                try snapshot.users.append(self.allocator, .{
                    .user_id = entry.key_ptr.*,
                    .data = cloned,
                    .joined_at = joined_at,
                });
            }
        }

        try self.user_subscribers.subscribe(self.allocator, namespace_id, conn_id, sub_id);

        return snapshot;
    }

    /// Subscribe to shared state updates in a namespace.
    /// Returns the current shared state (may be null).
    pub fn onSubscribeShared(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
        sub_id: u64,
    ) !?PresenceRecord {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Clone before registering subscriber.
        var cloned_record = if (self.shared_state.get(namespace_id)) |record|
            try record.clone(self.allocator)
        else
            null;
        errdefer if (cloned_record) |*r| r.deinit(self.allocator);

        try self.shared_subscribers.subscribe(self.allocator, namespace_id, conn_id, sub_id);

        return cloned_record;
    }

    /// Unsubscribe from user presence updates.
    pub fn onUnsubscribeUser(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
    ) void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        self.user_subscribers.unsubscribe(self.allocator, namespace_id, conn_id);
    }

    /// Unsubscribe from shared state updates.
    pub fn onUnsubscribeShared(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
    ) void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        self.shared_subscribers.unsubscribe(self.allocator, namespace_id, conn_id);
    }

    /// Remove all presence data for a connection (called on disconnect).
    pub fn removeAllForConnection(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: typed.DocId,
        conn_id: u64,
    ) !void {
        try self.removeUser(namespace_id, user_id);
        self.onUnsubscribeUser(namespace_id, conn_id);
        self.onUnsubscribeShared(namespace_id, conn_id);
    }

    // --- Public API for Dispatcher ---

    /// Batch of user presence updates for a single namespace.
    pub const UserUpdateBatch = struct {
        namespace_id: i64,
        updates: std.ArrayListUnmanaged(PendingUserUpdate),
        subscribers: std.ArrayListUnmanaged(Subscriber),
    };

    /// Batch of shared state updates for a single namespace.
    pub const SharedUpdateBatch = struct {
        namespace_id: i64,
        updates: std.ArrayListUnmanaged(PendingSharedUpdate),
        subscribers: std.ArrayListUnmanaged(Subscriber),
    };

    /// Drains pending updates and returns them grouped by namespace with their subscribers.
    /// Caller owns the returned batches and must deinit them.
    pub fn drainPendingBatches(
        self: *PresenceManager,
        user_batches: *std.ArrayListUnmanaged(UserUpdateBatch),
        shared_batches: *std.ArrayListUnmanaged(SharedUpdateBatch),
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        compactPendingUserUpdates(self);
        compactPendingSharedUpdates(self);

        var success = false;
        defer {
            if (success) {
                for (self.pending_user_updates.items) |*update| {
                    if (update.patch) |p| p.free(self.allocator);
                }
                for (self.pending_shared_updates.items) |*update| {
                    update.patch.free(self.allocator);
                }
                self.pending_user_updates.clearRetainingCapacity();
                self.pending_shared_updates.clearRetainingCapacity();
            }
        }

        // Sort by namespace_id to ensure contiguous grouping
        const SortHelpers = struct {
            fn compareUser(ctx: void, a: PendingUserUpdate, b: PendingUserUpdate) bool {
                _ = ctx;
                return a.namespace_id < b.namespace_id;
            }
            fn compareShared(ctx: void, a: PendingSharedUpdate, b: PendingSharedUpdate) bool {
                _ = ctx;
                return a.namespace_id < b.namespace_id;
            }
        };

        std.mem.sort(PendingUserUpdate, self.pending_user_updates.items, {}, SortHelpers.compareUser);
        std.mem.sort(PendingSharedUpdate, self.pending_shared_updates.items, {}, SortHelpers.compareShared);

        try groupUserUpdatesIntoBatches(self, user_batches);
        try groupSharedUpdatesIntoBatches(self, shared_batches);

        success = true;
    }

    fn compactPendingUserUpdates(self: *PresenceManager) void {
        var write: usize = 0;
        for (self.pending_user_updates.items, 0..) |_, read_idx| {
            const u = &self.pending_user_updates.items[read_idx];
            if (u.patch == null and !u.is_leave) continue;
            if (write != read_idx)
                self.pending_user_updates.items[write] = self.pending_user_updates.items[read_idx];
            write += 1;
        }
        self.pending_user_updates.shrinkRetainingCapacity(write);
    }

    fn compactPendingSharedUpdates(self: *PresenceManager) void {
        var write: usize = 0;
        for (self.pending_shared_updates.items, 0..) |_, read_idx| {
            const u = &self.pending_shared_updates.items[read_idx];
            if (u.patch == .nil) continue;
            if (write != read_idx)
                self.pending_shared_updates.items[write] = self.pending_shared_updates.items[read_idx];
            write += 1;
        }
        self.pending_shared_updates.shrinkRetainingCapacity(write);
    }

    fn groupUserUpdatesIntoBatches(
        self: *PresenceManager,
        user_batches: *std.ArrayListUnmanaged(UserUpdateBatch),
    ) !void {
        var i: usize = 0;
        while (i < self.pending_user_updates.items.len) {
            const namespace_id = self.pending_user_updates.items[i].namespace_id;
            const range_start = i;

            while (i < self.pending_user_updates.items.len and self.pending_user_updates.items[i].namespace_id == namespace_id) : (i += 1) {}

            const ns_updates = self.pending_user_updates.items[range_start..i];

            var batch = UserUpdateBatch{
                .namespace_id = namespace_id,
                .updates = std.ArrayListUnmanaged(PendingUserUpdate).empty,
                .subscribers = std.ArrayListUnmanaged(Subscriber).empty,
            };
            errdefer {
                batch.updates.deinit(self.allocator);
                batch.subscribers.deinit(self.allocator);
            }

            try batch.updates.appendSlice(self.allocator, ns_updates);
            if (self.user_subscribers.get(namespace_id)) |subs| {
                try batch.subscribers.appendSlice(self.allocator, subs);
            }
            try user_batches.append(self.allocator, batch);
            // Transfer ownership: batch now owns the patches.
            for (self.pending_user_updates.items[range_start..i]) |*update| update.patch = null;
        }
    }

    fn groupSharedUpdatesIntoBatches(
        self: *PresenceManager,
        shared_batches: *std.ArrayListUnmanaged(SharedUpdateBatch),
    ) !void {
        var i: usize = 0;
        while (i < self.pending_shared_updates.items.len) {
            const namespace_id = self.pending_shared_updates.items[i].namespace_id;
            const range_start = i;

            while (i < self.pending_shared_updates.items.len and self.pending_shared_updates.items[i].namespace_id == namespace_id) : (i += 1) {}

            const ns_updates = self.pending_shared_updates.items[range_start..i];

            var batch = SharedUpdateBatch{
                .namespace_id = namespace_id,
                .updates = std.ArrayListUnmanaged(PendingSharedUpdate).empty,
                .subscribers = std.ArrayListUnmanaged(Subscriber).empty,
            };
            errdefer {
                batch.updates.deinit(self.allocator);
                batch.subscribers.deinit(self.allocator);
            }

            try batch.updates.appendSlice(self.allocator, ns_updates);
            if (self.shared_subscribers.get(namespace_id)) |subs| {
                try batch.subscribers.appendSlice(self.allocator, subs);
            }
            try shared_batches.append(self.allocator, batch);
            // Transfer ownership: batch now owns the patches.
            for (self.pending_shared_updates.items[range_start..i]) |*update| update.patch = .nil;
        }
    }

    pub fn evictExpiredGracePeriods(self: *PresenceManager) void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        const now = std.time.milliTimestamp();
        const grace_ms: i64 = 5_000;

        // Collect expired keys first — modifying the map while iterating is UB.
        var to_remove = std.ArrayListUnmanaged(i64).empty;
        defer to_remove.deinit(self.allocator);
        {
            var grace_iter = self.namespace_empty_at.iterator();
            while (grace_iter.next()) |entry| {
                if (now - entry.value_ptr.* >= grace_ms) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch return;
                }
            }
        }

        for (to_remove.items) |ns_id| {
            if (self.shared_state.fetchRemove(ns_id)) |removed| {
                var record = removed.value;
                record.deinit(self.allocator);
            }
            _ = self.namespace_empty_at.remove(ns_id);
        }
    }
};

pub const UserSnapshot = struct {
    users: std.ArrayListUnmanaged(UserEntry),

    pub fn deinit(self: *UserSnapshot, allocator: Allocator) void {
        for (self.users.items) |*entry| {
            entry.data.deinit(allocator);
        }
        self.users.deinit(allocator);
    }
};

pub const UserEntry = struct {
    user_id: typed.DocId,
    data: PresenceRecord,
    joined_at: i64,
};
