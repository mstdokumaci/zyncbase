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
        patch: ?msgpack.Payload, // null = leave
        is_new_user: bool, // true = join event, false = update event
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
            try joined_ns_result.value_ptr.put(self.allocator, user_id, std.time.milliTimestamp());

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
                try self.mergePayloadMaps(&existing.patch.?, patch);
            } else {
                const cloned_patch = try patch.deepClone(self.allocator);
                existing.patch = cloned_patch;
            }
            if (!existing.is_new_user) existing.is_new_user = is_new_user;
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
            result.value_ptr.* = try PresenceRecord.init(self.allocator, self.shared_fields.len);
            errdefer {
                result.value_ptr.deinit(self.allocator);
                _ = self.shared_state.remove(namespace_id);
            }
            shared_cleanup = true;
        }

        // Merge patch into record
        try result.value_ptr.mergeFromPayload(self.allocator, self.shared_fields, patch);

        // Coalesce pending shared updates for the namespace.
        if (self.findPendingSharedUpdate(namespace_id)) |existing| {
            try self.mergePayloadMaps(&existing.patch, patch);
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

            // If namespace is now empty, deinit the empty map and record grace period
            if (ns_ptr.count() == 0) {
                ns_ptr.deinit(self.allocator);
                _ = self.user_state.remove(namespace_id);
                try self.namespace_empty_at.put(self.allocator, namespace_id, std.time.milliTimestamp());
            }

            if (self.findPendingUserUpdateIndex(namespace_id, user_id)) |idx| {
                var existing = &self.pending_user_updates.items[idx];
                if (existing.patch == null) {
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
                return;
            }

            // Queue leave broadcast
            try self.pending_user_updates.append(self.allocator, .{
                .namespace_id = namespace_id,
                .user_id = user_id,
                .patch = null, // null signals leave
                .is_new_user = false,
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

    fn mergePayloadMaps(
        self: *PresenceManager,
        target: *msgpack.Payload,
        source: msgpack.Payload,
    ) !void {
        if (target.* != .map or source != .map) return;

        var it = source.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const new_value = try entry.value_ptr.*.deepClone(self.allocator);
            errdefer new_value.free(self.allocator);

            if (target.map.getPtr(key)) |existing_value| {
                existing_value.*.free(self.allocator);
                existing_value.* = new_value;
            } else {
                var owned_key = try key.deepClone(self.allocator);
                defer if (owned_key != .nil) owned_key.free(self.allocator);
                try target.mapPutGeneric(owned_key, new_value);
                owned_key = .nil;
            }
        }
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
        allocator: Allocator,
        user_batches: *std.ArrayListUnmanaged(UserUpdateBatch),
        shared_batches: *std.ArrayListUnmanaged(SharedUpdateBatch),
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();
        defer {
            // Free any patches that were not transferred to batches.
            // After a successful appendSlice, the originals' patches are
            // cleared (ownership transferred to the batch): user updates
            // are set to null (optional), shared updates are set to .nil.
            // Any remaining non-null/non-nil patches belong to items that
            // were never processed.
            for (self.pending_user_updates.items) |*update| {
                if (update.patch) |p| p.free(self.allocator);
            }
            for (self.pending_shared_updates.items) |*update| {
                // free(.nil) is a no-op; real patches get freed here.
                update.patch.free(self.allocator);
            }
            self.pending_user_updates.clearRetainingCapacity();
            self.pending_shared_updates.clearRetainingCapacity();
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
                for (batch.updates.items) |*u| if (u.patch) |p| p.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }

            try batch.updates.appendSlice(allocator, ns_updates);
            // Null originals' patches — ownership transferred to batch
            for (self.pending_user_updates.items[range_start..i]) |*update| update.patch = null;
            if (self.user_subscribers.get(namespace_id)) |subs| {
                try batch.subscribers.appendSlice(allocator, subs);
            }

            try user_batches.append(allocator, batch);
        }

        i = 0;
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
                for (batch.updates.items) |*u| u.patch.free(allocator);
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }

            try batch.updates.appendSlice(allocator, ns_updates);
            // Clear originals' patches — ownership transferred to batch
            for (self.pending_shared_updates.items[range_start..i]) |*update| update.patch = .nil;
            if (self.shared_subscribers.get(namespace_id)) |subs| {
                try batch.subscribers.appendSlice(allocator, subs);
            }

            try shared_batches.append(allocator, batch);
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
