const std = @import("std");
const Allocator = std.mem.Allocator;
const ConnectionManager = @import("../connection_manager.zig").ConnectionManager;
const PresenceManager = @import("manager.zig").PresenceManager;
const wire = @import("../wire.zig");

/// Drains pending batches from PresenceManager, encodes, and sends via ConnectionManager.
/// Owns the background flush thread; polled from the event loop for low-latency delivery.
pub const PresenceDispatcher = struct {
    allocator: Allocator,
    presence_manager: *PresenceManager,
    thread_connection_manager: ?*ConnectionManager,

    background_thread: ?std.Thread,
    shutdown_requested: std.atomic.Value(bool),
    shutdown_mutex: std.Thread.Mutex,
    shutdown_cond: std.Thread.Condition,

    pub fn init(
        self: *PresenceDispatcher,
        allocator: Allocator,
        presence_manager: *PresenceManager,
    ) void {
        self.allocator = allocator;
        self.presence_manager = presence_manager;
        self.thread_connection_manager = null;
        self.background_thread = null;
        self.shutdown_requested = std.atomic.Value(bool).init(false);
        self.shutdown_mutex = .{};
        self.shutdown_cond = .{};
    }

    pub fn deinit(self: *PresenceDispatcher) void {
        if (self.background_thread) |thread| {
            self.shutdown_requested.store(true, .release);
            self.shutdown_mutex.lock();
            self.shutdown_cond.signal();
            self.shutdown_mutex.unlock();
            thread.join();
            self.background_thread = null;
        }
    }

    pub fn start(self: *PresenceDispatcher, cm: *ConnectionManager) !void {
        self.thread_connection_manager = cm;
        self.shutdown_requested.store(false, .release);
        const thread = try std.Thread.spawn(.{}, flushLoop, .{self});
        self.background_thread = thread;
    }

    pub fn poll(self: *PresenceDispatcher, cm: *ConnectionManager) void {
        self.presence_manager.evictExpiredGracePeriods();

        var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
        defer {
            for (user_batches.items) |*batch| {
                for (batch.updates.items) |*update| {
                    if (update.patch) |patch| patch.free(self.allocator);
                }
                batch.updates.deinit(self.allocator);
                batch.subscribers.deinit(self.allocator);
            }
            user_batches.deinit(self.allocator);
        }

        var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
        defer {
            for (shared_batches.items) |*batch| {
                for (batch.updates.items) |*update| {
                    update.patch.free(self.allocator);
                }
                batch.updates.deinit(self.allocator);
                batch.subscribers.deinit(self.allocator);
            }
            shared_batches.deinit(self.allocator);
        }

        self.presence_manager.drainPendingBatches(self.allocator, &user_batches, &shared_batches) catch |err| {
            std.log.err("PresenceDispatcher drain failed: {}", .{err});
            return;
        };

        if (user_batches.items.len == 0 and shared_batches.items.len == 0) return;

        for (user_batches.items) |batch| {
            if (batch.subscribers.items.len == 0) continue;
            for (batch.subscribers.items) |subscriber| {
                const msg = wire.encodePresenceBroadcast(self.allocator, subscriber.sub_id, batch.updates.items) catch |err| {
                    std.log.err("PresenceDispatcher encode user broadcast failed: {}", .{err});
                    continue;
                };
                cm.sendToConnection(subscriber.conn_id, msg);
                self.allocator.free(msg);
            }
        }

        for (shared_batches.items) |batch| {
            if (batch.subscribers.items.len == 0) continue;
            for (batch.subscribers.items) |subscriber| {
                const msg = wire.encodeSharedStateBroadcast(self.allocator, subscriber.sub_id, batch.updates.items) catch |err| {
                    std.log.err("PresenceDispatcher encode shared broadcast failed: {}", .{err});
                    continue;
                };
                cm.sendToConnection(subscriber.conn_id, msg);
                self.allocator.free(msg);
            }
        }
    }

    fn flushLoop(self: *PresenceDispatcher) void {
        const cm = self.thread_connection_manager orelse unreachable;

        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();

        while (!self.shutdown_requested.load(.acquire)) {
            self.shutdown_cond.timedWait(&self.shutdown_mutex, 50 * std.time.ns_per_ms) catch |err| {
                if (err != error.Timeout) {
                    std.log.err("PresenceDispatcher flush loop error: {}", .{err});
                }
            };
            if (self.shutdown_requested.load(.acquire)) break;
            self.shutdown_mutex.unlock();
            self.poll(cm);
            self.shutdown_mutex.lock();
        }
    }
};
