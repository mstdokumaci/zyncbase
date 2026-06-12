const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed.zig");
const schema_mod = @import("../schema.zig");
const msgpack = @import("../msgpack_utils.zig");
const PresenceRecord = @import("record.zig").PresenceRecord;
const wire = @import("../wire.zig");

/// PresenceManager manages ephemeral presence state for connected users.
/// All data lives in RAM for sub-100ms latency. Runs on a dedicated background
/// thread for periodic flush, with a mutex protecting internal state from
/// concurrent uWS message handler access.
pub const PresenceManager = struct {
    allocator: Allocator,

    // --- Thread management (modeled on CheckpointManager) ---
    background_thread: ?std.Thread,
    shutdown_requested: std.atomic.Value(bool),
    shutdown_mutex: std.Thread.Mutex,
    shutdown_cond: std.Thread.Condition,

    // --- Data protection ---
    // Guards all mutable state below. Acquired by uWS message handler threads
    // on setUser/setShared/onSubscribeUser/onSubscribeShared/removeUser.
    // Also acquired by the flush loop thread during flushBatch.
    data_mutex: std.Thread.Mutex,

    // Typed schema built at startup (names + declared types)
    user_fields: []const schema_mod.PresenceField,
    shared_fields: []const schema_mod.PresenceField,

    // User state: namespace_id → (users.id → PresenceRecord)
    user_state: std.AutoHashMapUnmanaged(i64, std.AutoHashMapUnmanaged(typed.DocId, PresenceRecord)),

    // Shared state: namespace_id → PresenceRecord
    shared_state: std.AutoHashMapUnmanaged(i64, PresenceRecord),

    // Grace period tracking: namespace_id → timestamp_ms when it became empty
    namespace_empty_at: std.AutoHashMapUnmanaged(i64, i64),

    // Batch pending: user presence updates queued for the 50ms flush
    pending_user_updates: std.ArrayListUnmanaged(PendingUserUpdate),
    pending_shared_updates: std.ArrayListUnmanaged(PendingSharedUpdate),

    // Subscription tracking: namespace_id → []ConnectionId
    user_subscribers: std.AutoHashMapUnmanaged(i64, std.ArrayListUnmanaged(u64)),
    shared_subscribers: std.AutoHashMapUnmanaged(i64, std.ArrayListUnmanaged(u64)),

    // Connection to PresenceManager reference for sending broadcasts
    connection_manager: ?*anyopaque,
    send_broadcast_fn: ?*const fn (ctx: *anyopaque, conn_id: u64, data: []const u8) void,

    pub const PendingUserUpdate = struct {
        namespace_id: i64,
        user_id: typed.DocId,
        patch: ?msgpack.Payload, // null = leave
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
            .background_thread = null,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .shutdown_mutex = .{},
            .shutdown_cond = .{},
            .data_mutex = .{},
            .user_fields = user_fields,
            .shared_fields = shared_fields,
            .user_state = .{},
            .shared_state = .{},
            .namespace_empty_at = .{},
            .pending_user_updates = .{},
            .pending_shared_updates = .{},
            .user_subscribers = .{},
            .shared_subscribers = .{},
            .connection_manager = null,
            .send_broadcast_fn = null,
        };
    }

    pub fn deinit(self: *PresenceManager) void {
        // Stop background thread if running
        if (self.background_thread) |thread| {
            self.stop();
            thread.join();
            self.background_thread = null;
        }

        // Clean up user_state
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
                _ = patch; // Payload is arena-allocated, no cleanup needed
            }
        }
        self.pending_user_updates.deinit(self.allocator);
        self.pending_shared_updates.deinit(self.allocator);

        var user_sub_iter = self.user_subscribers.iterator();
        while (user_sub_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.user_subscribers.deinit(self.allocator);

        var shared_sub_iter = self.shared_subscribers.iterator();
        while (shared_sub_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
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
        if (!ns_result.found_existing) {
            ns_result.value_ptr.* = .{};
        }

        // Get or create user record
        const user_result = try ns_result.value_ptr.getOrPut(self.allocator, user_id);
        if (!user_result.found_existing) {
            user_result.value_ptr.* = try PresenceRecord.init(self.allocator, self.user_fields.len);
        }

        // Merge patch into record
        try user_result.value_ptr.mergeFromPayload(self.allocator, self.user_fields, patch);

        // Cancel grace period if it was set
        _ = self.namespace_empty_at.fetchRemove(namespace_id);

        // Queue for broadcast
        try self.pending_user_updates.append(self.allocator, .{
            .namespace_id = namespace_id,
            .user_id = user_id,
            .patch = patch,
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
        if (!result.found_existing) {
            result.value_ptr.* = try PresenceRecord.init(self.allocator, self.shared_fields.len);
        }

        // Merge patch into record
        try result.value_ptr.mergeFromPayload(self.allocator, self.shared_fields, patch);

        // Queue for broadcast
        try self.pending_shared_updates.append(self.allocator, .{
            .namespace_id = namespace_id,
            .patch = patch,
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

            // If namespace is now empty, record timestamp for grace period
            if (ns_ptr.count() == 0) {
                try self.namespace_empty_at.put(self.allocator, namespace_id, std.time.milliTimestamp());
            }

            // Queue leave broadcast
            try self.pending_user_updates.append(self.allocator, .{
                .namespace_id = namespace_id,
                .user_id = user_id,
                .patch = null, // null signals leave
            });
        }
    }

    /// Subscribe to user presence updates in a namespace.
    /// Returns a snapshot of current users.
    pub fn onSubscribeUser(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
    ) !UserSnapshot {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Register subscriber
        const sub_result = try self.user_subscribers.getOrPut(self.allocator, namespace_id);
        if (!sub_result.found_existing) {
            sub_result.value_ptr.* = .{};
        }
        try sub_result.value_ptr.append(self.allocator, conn_id);

        // Build snapshot of current users
        var snapshot = UserSnapshot{
            .users = std.ArrayListUnmanaged(UserEntry).empty,
        };
        errdefer {
            for (snapshot.users.items) |*entry| {
                entry.data.deinit(self.allocator);
            }
            snapshot.users.deinit(self.allocator);
        }

        if (self.user_state.get(namespace_id)) |ns_map| {
            var iter = ns_map.iterator();
            while (iter.next()) |entry| {
                const cloned = try entry.value_ptr.clone(self.allocator);
                try snapshot.users.append(self.allocator, .{
                    .user_id = entry.key_ptr.*,
                    .data = cloned,
                });
            }
        }

        return snapshot;
    }

    /// Subscribe to shared state updates in a namespace.
    /// Returns the current shared state (may be null).
    pub fn onSubscribeShared(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
    ) !?PresenceRecord {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Register subscriber
        const sub_result = try self.shared_subscribers.getOrPut(self.allocator, namespace_id);
        if (!sub_result.found_existing) {
            sub_result.value_ptr.* = .{};
        }
        try sub_result.value_ptr.append(self.allocator, conn_id);

        // Return clone of current shared state
        if (self.shared_state.get(namespace_id)) |record| {
            return try record.clone(self.allocator);
        }
        return null;
    }

    /// Unsubscribe from user presence updates.
    pub fn onUnsubscribeUser(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
    ) void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        if (self.user_subscribers.getPtr(namespace_id)) |subs| {
            var i: usize = 0;
            while (i < subs.items.len) {
                if (subs.items[i] == conn_id) {
                    _ = subs.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Unsubscribe from shared state updates.
    pub fn onUnsubscribeShared(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: u64,
    ) void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        if (self.shared_subscribers.getPtr(namespace_id)) |subs| {
            var i: usize = 0;
            while (i < subs.items.len) {
                if (subs.items[i] == conn_id) {
                    _ = subs.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
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

    // --- Lifecycle ---

    /// Spawn the dedicated background flush thread.
    pub fn start(self: *PresenceManager) !void {
        self.shutdown_requested.store(false, .release);
        const thread = try std.Thread.spawn(.{}, flushLoop, .{self});
        self.background_thread = thread;
    }

    /// Signal shutdown and join the background thread.
    pub fn stop(self: *PresenceManager) void {
        self.shutdown_requested.store(true, .release);
        self.shutdown_mutex.lock();
        self.shutdown_cond.signal();
        self.shutdown_mutex.unlock();
    }

    /// Dedicated thread: blocks on timedWait for 50ms, then flushes.
    fn flushLoop(self: *PresenceManager) void {
        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();

        while (!self.shutdown_requested.load(.acquire)) {
            self.shutdown_cond.timedWait(&self.shutdown_mutex, 50 * std.time.ns_per_ms) catch |err| {
                if (err != error.Timeout) {
                    std.log.err("PresenceManager flush loop error: {}", .{err});
                }
            };
            if (self.shutdown_requested.load(.acquire)) break;
            self.flushBatch();
        }
    }

    /// Runs on the dedicated background thread every 50ms.
    fn flushBatch(self: *PresenceManager) void {
        // 1. Evict expired grace-period entries
        const now = std.time.milliTimestamp();
        const grace_ms: i64 = 5_000;
        var grace_iter = self.namespace_empty_at.iterator();
        while (grace_iter.next()) |entry| {
            if (now - entry.value_ptr.* >= grace_ms) {
                if (self.shared_state.fetchRemove(entry.key_ptr.*)) |removed| {
                    var record = removed.value;
                    record.deinit(self.allocator);
                }
                _ = self.namespace_empty_at.remove(entry.key_ptr.*);
            }
        }

        // 2. Snapshot and clear pending updates under lock
        self.data_mutex.lock();
        var user_updates = self.pending_user_updates;
        var shared_updates = self.pending_shared_updates;
        self.pending_user_updates = .{};
        self.pending_shared_updates = .{};
        self.data_mutex.unlock();

        // 3. Broadcast updates (no lock needed)
        if (user_updates.items.len > 0) {
            self.broadcastUserBatch(user_updates.items);
            user_updates.deinit(self.allocator);
        }

        if (shared_updates.items.len > 0) {
            self.broadcastSharedBatch(shared_updates.items);
            shared_updates.deinit(self.allocator);
        }
    }

    fn broadcastUserBatch(self: *PresenceManager, updates: []const PendingUserUpdate) void {
        // Group by namespace and broadcast to subscribers
        var i: usize = 0;
        while (i < updates.len) {
            const namespace_id = updates[i].namespace_id;
            const range_start = i;

            // Find range of updates for this namespace
            while (i < updates.len and updates[i].namespace_id == namespace_id) : (i += 1) {}

            const ns_updates = updates[range_start..i];

            // Get subscribers for this namespace
            const subs = self.user_subscribers.get(namespace_id) orelse continue;
            if (subs.items.len == 0) continue;

            // Build and send broadcast for each subscriber
            for (subs.items) |conn_id| {
                self.sendUserBroadcast(conn_id, ns_updates);
            }
        }
    }

    fn sendUserBroadcast(self: *PresenceManager, conn_id: u64, updates: []const PendingUserUpdate) void {
        if (self.send_broadcast_fn) |send_fn| {
            if (self.connection_manager) |ctx| {
                // Encode broadcast message
                const encoded = wire.encodePresenceBroadcast(self.allocator, conn_id, updates) catch return;
                defer self.allocator.free(encoded);
                send_fn(ctx, conn_id, encoded);
            }
        }
    }

    fn broadcastSharedBatch(self: *PresenceManager, updates: []const PendingSharedUpdate) void {
        // Group by namespace and broadcast to subscribers
        var i: usize = 0;
        while (i < updates.len) {
            const namespace_id = updates[i].namespace_id;
            const range_start = i;

            // Find range of updates for this namespace
            while (i < updates.len and updates[i].namespace_id == namespace_id) : (i += 1) {}

            const ns_updates = updates[range_start..i];

            // Get subscribers for this namespace
            const subs = self.shared_subscribers.get(namespace_id) orelse continue;
            if (subs.items.len == 0) continue;

            // Build and send broadcast for each subscriber
            for (subs.items) |conn_id| {
                self.sendSharedBroadcast(conn_id, ns_updates);
            }
        }
    }

    fn sendSharedBroadcast(self: *PresenceManager, conn_id: u64, updates: []const PendingSharedUpdate) void {
        if (self.send_broadcast_fn) |send_fn| {
            if (self.connection_manager) |ctx| {
                // Encode broadcast message
                const encoded = wire.encodeSharedStateBroadcast(self.allocator, conn_id, updates) catch return;
                defer self.allocator.free(encoded);
                send_fn(ctx, conn_id, encoded);
            }
        }
    }

    /// Set the connection manager and broadcast function for sending updates.
    pub fn setConnectionManager(
        self: *PresenceManager,
        connection_manager: *anyopaque,
        send_fn: *const fn (*anyopaque, u64, []const u8) void,
    ) void {
        self.connection_manager = connection_manager;
        self.send_broadcast_fn = send_fn;
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
};
