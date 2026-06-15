const std = @import("std");
const Allocator = std.mem.Allocator;
const ConnectionManager = @import("../connection_manager.zig").ConnectionManager;
const PresenceManager = @import("manager.zig").PresenceManager;
const wire = @import("../wire.zig");

/// Drains pending batches from PresenceManager, encodes, and sends via ConnectionManager.
/// Polled from the event loop; batches every 50ms via timestamp check.
pub const PresenceDispatcher = struct {
    allocator: Allocator,
    presence_manager: *PresenceManager,

    last_flush_ms: i64,
    flush_interval_ms: i64,

    pub fn init(
        self: *PresenceDispatcher,
        allocator: Allocator,
        presence_manager: *PresenceManager,
    ) void {
        self.allocator = allocator;
        self.presence_manager = presence_manager;
        self.last_flush_ms = 0;
        self.flush_interval_ms = 50;
    }

    pub fn deinit(self: *PresenceDispatcher) void {
        _ = self;
    }

    pub fn poll(self: *PresenceDispatcher, cm: *ConnectionManager) void {
        self.presence_manager.evictExpiredGracePeriods();

        const now = std.time.milliTimestamp();
        if (now - self.last_flush_ms < self.flush_interval_ms) return;
        self.last_flush_ms = now;

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
};
