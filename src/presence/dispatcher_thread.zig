const std = @import("std");
const Allocator = std.mem.Allocator;
const PresenceManager = @import("manager.zig").PresenceManager;
const wire = @import("../wire.zig");
const send_queue_type = @import("../send_queue.zig").send_queue;

pub const PresenceDispatcherThread = struct {
    allocator: Allocator,
    presence_manager: *PresenceManager,
    send_queue: *send_queue_type,
    notifier_fn: ?*const fn (?*anyopaque) void,
    notifier_ctx: ?*anyopaque,
    thread: ?std.Thread,
    shutdown_requested: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    is_ready: std.atomic.Value(bool),
    ready_mutex: std.Thread.Mutex,
    ready_cond: std.Thread.Condition,
    pending_work: std.atomic.Value(bool),

    pub fn init(
        self: *PresenceDispatcherThread,
        allocator: Allocator,
        presence_manager: *PresenceManager,
        send_queue: *send_queue_type,
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) void {
        self.* = .{
            .allocator = allocator,
            .presence_manager = presence_manager,
            .send_queue = send_queue,
            .notifier_fn = notifier_fn,
            .notifier_ctx = notifier_ctx,
            .thread = null,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .cond = .{},
            .is_ready = std.atomic.Value(bool).init(false),
            .ready_mutex = .{},
            .ready_cond = .{},
            .pending_work = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *PresenceDispatcherThread) void {
        _ = self;
    }

    pub fn signal(self: *PresenceDispatcherThread) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending_work.store(true, .release);
        self.cond.signal();
    }

    pub fn start(self: *PresenceDispatcherThread) !void {
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        errdefer self.stop();
        self.waitUntilReady();
    }

    pub fn stop(self: *PresenceDispatcherThread) void {
        self.shutdown_requested.store(true, .release);
        self.mutex.lock();
        self.cond.signal();
        self.mutex.unlock();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn waitUntilReady(self: *PresenceDispatcherThread) void {
        self.ready_mutex.lock();
        defer self.ready_mutex.unlock();
        while (!self.is_ready.load(.acquire)) {
            self.ready_cond.wait(&self.ready_mutex);
        }
    }

    fn workerLoop(self: *PresenceDispatcherThread) void {
        self.is_ready.store(true, .release);
        self.ready_mutex.lock();
        self.ready_cond.broadcast();
        self.ready_mutex.unlock();

        const flush_interval_ns: u64 = 50 * std.time.ns_per_ms;

        while (!self.shutdown_requested.load(.acquire)) {
            self.mutex.lock();
            var needs_unlock = true;
            if (!self.pending_work.load(.acquire) and !self.shutdown_requested.load(.acquire)) {
                self.cond.timedWait(&self.mutex, flush_interval_ns) catch |err| {
                    if (err != error.Timeout) {
                        std.log.err("PresenceDispatcherThread timedWait failed: {}", .{err});
                        needs_unlock = false;
                    }
                };
            }
            self.pending_work.store(false, .release);
            if (needs_unlock) {
                self.mutex.unlock();
            }

            if (self.shutdown_requested.load(.acquire)) break;

            self.flush();
        }

        self.flush();
    }

    fn flush(self: *PresenceDispatcherThread) void {
        if (self.shutdown_requested.load(.acquire)) return;
        const pm = self.presence_manager;

        pm.evictExpiredGracePeriods();

        var user_batches = std.ArrayListUnmanaged(PresenceManager.UserUpdateBatch).empty;
        defer {
            for (user_batches.items) |*batch| {
                for (batch.updates.items) |*update| {
                    if (update.patch) |patch| patch.free(pm.allocator);
                }
                batch.updates.deinit(pm.allocator);
                batch.subscribers.deinit(pm.allocator);
            }
            user_batches.deinit(pm.allocator);
        }

        var shared_batches = std.ArrayListUnmanaged(PresenceManager.SharedUpdateBatch).empty;
        defer {
            for (shared_batches.items) |*batch| {
                for (batch.updates.items) |*update| {
                    update.patch.free(pm.allocator);
                }
                batch.updates.deinit(pm.allocator);
                batch.subscribers.deinit(pm.allocator);
            }
            shared_batches.deinit(pm.allocator);
        }

        pm.drainPendingBatches(&user_batches, &shared_batches) catch |err| {
            std.log.err("PresenceDispatcherThread drain failed: {}", .{err});
            return;
        };

        if (user_batches.items.len == 0 and shared_batches.items.len == 0) return;

        const gpa = self.allocator;
        var pushed_any = false;

        for (user_batches.items) |batch| {
            if (batch.subscribers.items.len == 0) continue;
            for (batch.subscribers.items) |subscriber| {
                const msg = wire.encodePresenceBroadcast(gpa, subscriber.sub_id, batch.updates.items) catch |err| {
                    std.log.err("PresenceDispatcherThread encode user broadcast failed: {}", .{err});
                    continue;
                };
                self.send_queue.push(.{ .conn_id = subscriber.conn_id, .data = msg }) catch |err| {
                    std.log.err("PresenceDispatcherThread push user broadcast failed: {}", .{err});
                    gpa.free(msg);
                    continue;
                };
                pushed_any = true;
            }
        }

        for (shared_batches.items) |batch| {
            if (batch.subscribers.items.len == 0) continue;
            for (batch.subscribers.items) |subscriber| {
                const msg = wire.encodeSharedStateBroadcast(gpa, subscriber.sub_id, batch.updates.items) catch |err| {
                    std.log.err("PresenceDispatcherThread encode shared broadcast failed: {}", .{err});
                    continue;
                };
                self.send_queue.push(.{ .conn_id = subscriber.conn_id, .data = msg }) catch |err| {
                    std.log.err("PresenceDispatcherThread push shared broadcast failed: {}", .{err});
                    gpa.free(msg);
                    continue;
                };
                pushed_any = true;
            }
        }

        if (pushed_any) {
            if (self.notifier_fn) |n| n(self.notifier_ctx);
        }
    }
};
