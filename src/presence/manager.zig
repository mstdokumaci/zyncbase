const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const PresenceRecord = @import("record.zig").PresenceRecord;
const Subscriber = @import("subscriber.zig").Subscriber;
const SubscriberTable = @import("subscriber.zig").SubscriberTable;

const Allocator = std.mem.Allocator;

/// Owns presence state, pending batches, and subscription tracking.
/// Thread-safe; does not know about networking.
pub const PresenceManager = struct {
    io: std.Io,
    allocator: Allocator,

    data_mutex: std.Io.Mutex,

    // Typed schema built at startup (names + declared types)
    user_fields: []const schema_types.PresenceField,
    shared_fields: []const schema_types.PresenceField,

    // User state: namespace_id → (users.id → PresenceRecord)
    user_state: std.AutoHashMapUnmanaged(i64, std.AutoHashMapUnmanaged(typed_doc_id.DocId, PresenceRecord)),

    // User join timestamps: namespace_id → (users.id → joined_at_ms)
    user_joined_at: std.AutoHashMapUnmanaged(i64, std.AutoHashMapUnmanaged(typed_doc_id.DocId, i64)),

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
        user_id: typed_doc_id.DocId,
        patch: msgpack.Payload, // .nil = leave (or transferred to batch)
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
        io: std.Io,
        allocator: Allocator,
        user_fields: []const schema_types.PresenceField,
        shared_fields: []const schema_types.PresenceField,
    ) void {
        self.* = .{
            .io = io,
            .allocator = allocator,
            .data_mutex = .init,
            .user_fields = user_fields,
            .shared_fields = shared_fields,
            .user_state = .{},
            .user_joined_at = .{},
            .shared_state = .{},
            .namespace_empty_at = .{},
            .pending_user_updates = .empty,
            .pending_shared_updates = .empty,
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
            update.patch.free(self.allocator);
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
        user_id: typed_doc_id.DocId,
        patch: msgpack.Payload,
    ) !void {
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

        // Get or create namespace map
        const ns_result = try self.user_state.getOrPut(self.allocator, namespace_id);
        const ns_created = !ns_result.found_existing;
        if (ns_created) {
            ns_result.value_ptr.* = .{};
        }

        // Get or create user record
        const user_result = try ns_result.value_ptr.getOrPut(self.allocator, user_id);
        const is_new_user = !user_result.found_existing;

        // Function-level rollback for late failures (after initNewUserRecord's scoped errdefers exit).
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

        const now = std.Io.Clock.real.now(self.io).toMilliseconds();

        if (is_new_user) {
            try self.initNewUserRecord(ns_result, user_result, namespace_id, user_id, ns_created, now);
            user_cleanup = true;
        }

        // Merge patch into record
        try user_result.value_ptr.mergeFromPayload(self.allocator, self.user_fields, patch);

        // Cancel grace period if it was set
        _ = self.namespace_empty_at.fetchRemove(namespace_id);

        // Coalesce with any pending update for this user in the current batch.
        if (self.findPendingUserUpdateIndex(namespace_id, user_id)) |idx| {
            try self.coalescePendingUpdate(&self.pending_user_updates.items[idx], patch, is_new_user, now);
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

    fn initNewUserRecord(
        self: *PresenceManager,
        ns_result: anytype,
        user_result: anytype,
        namespace_id: i64,
        user_id: typed_doc_id.DocId,
        ns_created: bool,
        now: i64,
    ) !void {
        errdefer {
            _ = ns_result.value_ptr.fetchRemove(user_id);
            if (ns_created and ns_result.value_ptr.count() == 0) {
                ns_result.value_ptr.deinit(self.allocator);
                _ = self.user_state.remove(namespace_id);
            }
        }

        user_result.value_ptr.* = try PresenceRecord.init(self.allocator, self.user_fields.len);
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
    }

    fn coalescePendingUpdate(
        self: *PresenceManager,
        existing: *PendingUserUpdate,
        patch: msgpack.Payload,
        is_new_user: bool,
        now: i64,
    ) !void {
        if (existing.patch != .nil) {
            try self.mergePayloadArrays(&existing.patch, patch);
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
    }

    /// Set shared presence data. Merges the patch into the namespace record.
    pub fn setShared(
        self: *PresenceManager,
        namespace_id: i64,
        patch: msgpack.Payload,
        source_conn: u64,
    ) !void {
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

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
        user_id: typed_doc_id.DocId,
    ) !void {
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

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
                self.namespace_empty_at.put(self.allocator, namespace_id, std.Io.Clock.real.now(self.io).toMilliseconds()) catch |err| {
                    std.log.err("Failed to record grace period for namespace {}: {}", .{ namespace_id, err });
                };
            };

            if (self.findPendingUserUpdateIndex(namespace_id, user_id)) |idx| {
                var existing = &self.pending_user_updates.items[idx];
                if (existing.patch == .nil and existing.is_leave) {
                    return;
                }
                if (existing.is_new_user) {
                    existing.patch.free(self.allocator);
                    _ = self.pending_user_updates.orderedRemove(idx);
                    return;
                }

                existing.patch.free(self.allocator);
                existing.patch = .nil;
                existing.is_new_user = false;
                existing.is_leave = true;
                return;
            }

            // Queue leave broadcast
            try self.pending_user_updates.append(self.allocator, .{
                .namespace_id = namespace_id,
                .user_id = user_id,
                .patch = .nil, // .nil signals leave
                .is_new_user = false,
                .joined_at = 0,
                .is_leave = true,
            });
        }
    }

    fn findPendingUserUpdateIndex(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: typed_doc_id.DocId,
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

    fn findPendingSharedUpdate(
        self: *PresenceManager,
        namespace_id: i64,
    ) ?*PendingSharedUpdate {
        for (self.pending_shared_updates.items) |*update| {
            if (update.namespace_id == namespace_id) return update;
        }
        return null;
    }

    inline fn findPayloadValue(
        pairs: []msgpack.Payload,
        index: msgpack.Payload,
    ) ?*msgpack.Payload {
        for (pairs) |*pair| {
            if (pair.* != .arr or pair.*.arr.len != 2) continue;
            if (payloadUintEqual(index, pair.*.arr[0])) return &pair.*.arr[1];
        }
        return null;
    }

    fn mergePayloadArrays(
        self: *PresenceManager,
        target: *msgpack.Payload,
        source: msgpack.Payload,
    ) !void {
        if (target.* != .arr or source != .arr) return;

        var new_pairs = std.ArrayListUnmanaged(msgpack.Payload).empty;
        defer {
            for (new_pairs.items) |pair| pair.free(self.allocator);
            new_pairs.deinit(self.allocator);
        }

        for (source.arr) |source_pair| {
            if (source_pair != .arr or source_pair.arr.len != 2) continue;
            const source_idx = source_pair.arr[0];

            if (findPayloadValue(target.*.arr, source_idx)) |target_value| {
                const cloned_val = try source_pair.arr[1].deepClone(self.allocator);
                target_value.free(self.allocator);
                target_value.* = cloned_val;
            } else {
                const cloned_pair = try source_pair.deepClone(self.allocator);
                try new_pairs.append(self.allocator, cloned_pair);
            }
        }

        if (new_pairs.items.len > 0) {
            const old_len = target.*.arr.len;
            const new_slice = try self.allocator.realloc(target.*.arr, old_len + new_pairs.items.len);
            @memcpy(new_slice[old_len..], new_pairs.items);
            target.*.arr = new_slice;
            new_pairs.clearRetainingCapacity();
        }
    }

    fn payloadUintEqual(a: msgpack.Payload, b: msgpack.Payload) bool {
        const a_uint = msgpack.extractPayloadUsize(a) orelse return false;
        const b_uint = msgpack.extractPayloadUsize(b) orelse return false;
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
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

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
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

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
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

        self.user_subscribers.unsubscribe(self.allocator, namespace_id, conn_id);
    }

    /// Unsubscribe from shared state updates.
    pub fn onUnsubscribeShared(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
    ) void {
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

        self.shared_subscribers.unsubscribe(self.allocator, namespace_id, conn_id);
    }

    /// Remove all presence data for a connection (called on disconnect).
    pub fn removeAllForConnection(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: typed_doc_id.DocId,
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
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

        compactPending(PendingUserUpdate, &self.pending_user_updates, isDroppableUser);
        compactPending(PendingSharedUpdate, &self.pending_shared_updates, isDroppableShared);

        var success = false;
        defer {
            if (success) {
                for (self.pending_user_updates.items) |*update| {
                    update.patch.free(self.allocator);
                }
                for (self.pending_shared_updates.items) |*update| {
                    update.patch.free(self.allocator);
                }
                self.pending_user_updates.clearRetainingCapacity();
                self.pending_shared_updates.clearRetainingCapacity();
            }
        }

        // Sort by namespace_id to ensure contiguous grouping
        std.mem.sort(PendingUserUpdate, self.pending_user_updates.items, {}, lessNamespace(PendingUserUpdate));
        std.mem.sort(PendingSharedUpdate, self.pending_shared_updates.items, {}, lessNamespace(PendingSharedUpdate));

        try groupIntoBatches(PendingUserUpdate, UserUpdateBatch, self.allocator, &self.pending_user_updates, &self.user_subscribers, user_batches);
        try groupIntoBatches(PendingSharedUpdate, SharedUpdateBatch, self.allocator, &self.pending_shared_updates, &self.shared_subscribers, shared_batches);

        success = true;
    }

    fn isDroppableUser(u: *const PresenceManager.PendingUserUpdate) bool {
        return u.patch == .nil and !u.is_leave;
    }

    fn isDroppableShared(u: *const PresenceManager.PendingSharedUpdate) bool {
        return u.patch == .nil;
    }

    fn compactPending(comptime T: type, items: *std.ArrayListUnmanaged(T), comptime is_drop: fn (*const T) bool) void {
        var write: usize = 0;
        for (items.items, 0..) |_, read_idx| {
            const u = &items.items[read_idx];
            if (is_drop(u)) continue;
            if (write != read_idx) items.items[write] = items.items[read_idx];
            write += 1;
        }
        items.shrinkRetainingCapacity(write);
    }

    fn groupIntoBatches(
        comptime T: type,
        comptime BatchT: type,
        allocator: Allocator,
        pending: *std.ArrayListUnmanaged(T),
        subscribers: *const SubscriberTable,
        out: *std.ArrayListUnmanaged(BatchT),
    ) !void {
        var i: usize = 0;
        while (i < pending.items.len) {
            const namespace_id = pending.items[i].namespace_id;
            const range_start = i;

            while (i < pending.items.len and pending.items[i].namespace_id == namespace_id) : (i += 1) {}

            const ns_updates = pending.items[range_start..i];

            var batch = BatchT{
                .namespace_id = namespace_id,
                .updates = std.ArrayListUnmanaged(T).empty,
                .subscribers = std.ArrayListUnmanaged(Subscriber).empty,
            };
            errdefer {
                batch.updates.deinit(allocator);
                batch.subscribers.deinit(allocator);
            }

            try batch.updates.appendSlice(allocator, ns_updates);
            if (subscribers.get(namespace_id)) |subs| {
                try batch.subscribers.appendSlice(allocator, subs);
            }
            try out.append(allocator, batch);
            // Transfer ownership: batch now owns the patches.
            for (pending.items[range_start..i]) |*update| update.patch = .nil;
        }
    }

    pub fn evictExpiredGracePeriods(self: *PresenceManager) void {
        self.data_mutex.lockUncancelable(self.io);
        defer self.data_mutex.unlock(self.io);

        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        const grace_ms: i64 = 5_000;

        // Collect expired keys first — modifying the map while iterating is UB.
        var to_remove = std.ArrayListUnmanaged(i64).empty;
        defer to_remove.deinit(self.allocator);
        to_remove.ensureTotalCapacity(self.allocator, self.namespace_empty_at.count()) catch return;
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

fn lessNamespace(comptime T: type) fn (void, T, T) bool { // zwanzig-disable-line: unused-parameter
    return struct {
        pub fn inner(_: void, a: T, b: T) bool {
            return a.namespace_id < b.namespace_id;
        }
    }.inner;
}

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
    user_id: typed_doc_id.DocId,
    data: PresenceRecord,
    joined_at: i64,
};
