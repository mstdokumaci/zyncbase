const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed.zig");
const msgpack = @import("../msgpack_utils.zig");
const PresenceManager = @import("manager.zig").PresenceManager;
const wire = @import("../wire.zig");
const send_queue_type = @import("../send_queue.zig").send_queue;
const spscQueue = @import("../queues/spsc_queue.zig").spscQueue;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const managedThread = @import("../threading/managed_thread.zig").managedThread;
const Notifier = @import("../threading/notifier.zig").Notifier;

/// A presence operation enqueued by the event loop for the dispatcher thread.
/// The `allocator` field owns any heap-allocated data inside `op` (e.g. cloned
/// patches) so that `deinit` can free them without external context.
pub const PresenceOp = struct {
    op: Op,
    allocator: Allocator,

    pub const Op = union(enum) {
        set_user: struct {
            namespace_id: i64,
            user_id: typed.DocId,
            patch: msgpack.Payload,
        },
        set_shared: struct {
            namespace_id: i64,
            patch: msgpack.Payload,
            source_conn: u64,
        },
        remove_user: struct {
            namespace_id: i64,
            user_id: typed.DocId,
        },
        subscribe_user: struct {
            namespace_id: i64,
            conn_id: u64,
            sub_id: u64,
            msg_id: u64,
        },
        subscribe_shared: struct {
            namespace_id: i64,
            conn_id: u64,
            sub_id: u64,
            msg_id: u64,
        },
        unsubscribe_user: struct {
            namespace_id: i64,
            conn_id: u64,
        },
        unsubscribe_shared: struct {
            namespace_id: i64,
            conn_id: u64,
        },
        remove_all_for_connection: struct {
            namespace_id: i64,
            user_id: typed.DocId,
            conn_id: u64,
        },
    };

    pub fn deinit(self: *PresenceOp) void {
        switch (self.op) {
            .set_user => |*su| su.patch.free(self.allocator),
            .set_shared => |*ss| ss.patch.free(self.allocator),
            else => {},
        }
    }
};

pub const work_queue_type = spscQueue(PresenceOp, MemoryStrategy.AllocPool);

pub const PresenceWorker = struct {
    allocator: Allocator,
    presence_manager: *PresenceManager,
    send_queue: *send_queue_type,
    notifier: Notifier,
    thread: managedThread(PresenceWorker),
    pool: MemoryStrategy.AllocPool(work_queue_type.Node),
    work_queue: work_queue_type,

    pub fn init(
        self: *PresenceWorker,
        allocator: Allocator,
        presence_manager: *PresenceManager,
        send_queue: *send_queue_type,
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .presence_manager = presence_manager,
            .send_queue = send_queue,
            .notifier = Notifier.init(notifier_fn, notifier_ctx),
            .thread = managedThread(PresenceWorker).init(),
            .pool = MemoryStrategy.AllocPool(work_queue_type.Node).init(allocator),
            // SAFETY: work_queue is initialized inline below via init()
            .work_queue = undefined,
        };
        self.work_queue = try work_queue_type.init(&self.pool);
    }

    pub fn deinit(self: *PresenceWorker) void {
        while (self.work_queue.pop()) |op| {
            var op_mut = op;
            op_mut.deinit();
        }
        self.work_queue.deinit();
    }

    /// Enqueue a presence operation and wake the dispatcher thread.
    pub fn enqueue(self: *PresenceWorker, op: PresenceOp) !void {
        try self.work_queue.push(op);
        self.thread.signal();
    }

    pub fn spawn(self: *PresenceWorker) !void {
        try self.thread.spawn(workerLoop, self);
    }

    pub fn stop(self: *PresenceWorker) void {
        self.thread.stop();
    }

    fn workerLoop(self: *PresenceWorker) void {
        while (!self.thread.isRequested()) {
            // Drain all available ops (non-blocking) — natural batching.
            var processed = false;
            while (self.work_queue.pop()) |op| {
                self.processOp(op);
                processed = true;
            }
            if (processed) self.flush();

            // Wait for more work (blocking via condvar).
            self.thread.mutex.lock();
            if (!self.thread.isRequested() and !self.work_queue.hasItems()) {
                self.thread.cond.wait(&self.thread.mutex);
            }
            self.thread.mutex.unlock();
        }

        // Final drain + flush on shutdown.
        var processed = false;
        while (self.work_queue.pop()) |op| {
            self.processOp(op);
            processed = true;
        }
        if (processed) self.flush();
    }

    fn processOp(self: *PresenceWorker, op: PresenceOp) void {
        var op_mut = op;
        defer op_mut.deinit();

        switch (op_mut.op) {
            .set_user => |su| {
                self.presence_manager.setUser(su.namespace_id, su.user_id, su.patch) catch |err| {
                    std.log.err("PresenceWorker setUser failed: {}", .{err});
                };
            },
            .set_shared => |ss| {
                self.presence_manager.setShared(ss.namespace_id, ss.patch, ss.source_conn) catch |err| {
                    std.log.err("PresenceWorker setShared failed: {}", .{err});
                };
            },
            .remove_user => |ru| {
                self.presence_manager.removeUser(ru.namespace_id, ru.user_id) catch |err| {
                    std.log.err("PresenceWorker removeUser failed: {}", .{err});
                };
            },
            .subscribe_user => |sub| {
                self.processSubscribeUser(sub);
            },
            .subscribe_shared => |sub| {
                self.processSubscribeShared(sub);
            },
            .unsubscribe_user => |unsub| {
                self.presence_manager.onUnsubscribeUser(unsub.namespace_id, unsub.conn_id);
            },
            .unsubscribe_shared => |unsub| {
                self.presence_manager.onUnsubscribeShared(unsub.namespace_id, unsub.conn_id);
            },
            .remove_all_for_connection => |rac| {
                self.presence_manager.removeAllForConnection(rac.namespace_id, rac.user_id, rac.conn_id) catch |err| {
                    std.log.err("PresenceWorker removeAllForConnection failed: {}", .{err});
                };
            },
        }
    }

    fn processSubscribeUser(self: *PresenceWorker, sub: anytype) void {
        var snapshot = self.presence_manager.onSubscribeUser(sub.namespace_id, sub.conn_id, sub.sub_id) catch |err| {
            std.log.err("PresenceWorker onSubscribeUser failed: {}", .{err});
            self.sendError(sub.conn_id, sub.msg_id, "PRESENCE_SUBSCRIBE", "subscribe failed");
            return;
        };
        defer snapshot.deinit(self.allocator);

        const msg = wire.encodePresenceUserSnapshot(self.allocator, sub.msg_id, sub.sub_id, snapshot.users.items) catch |err| {
            std.log.err("PresenceWorker encodePresenceUserSnapshot failed: {}", .{err});
            self.sendError(sub.conn_id, sub.msg_id, "PRESENCE_SUBSCRIBE", "encode failed");
            return;
        };
        self.pushToSendQueue(sub.conn_id, msg);
    }

    fn processSubscribeShared(self: *PresenceWorker, sub: anytype) void {
        var shared = self.presence_manager.onSubscribeShared(sub.namespace_id, sub.conn_id, sub.sub_id) catch |err| {
            std.log.err("PresenceWorker onSubscribeShared failed: {}", .{err});
            self.sendError(sub.conn_id, sub.msg_id, "PRESENCE_SUBSCRIBE_SHARED", "subscribe failed");
            return;
        };
        defer if (shared) |*s| s.deinit(self.allocator);

        const msg = wire.encodePresenceSharedSnapshot(
            self.allocator,
            sub.msg_id,
            sub.sub_id,
            if (shared) |*s| s else null,
        ) catch |err| {
            std.log.err("PresenceWorker encodePresenceSharedSnapshot failed: {}", .{err});
            self.sendError(sub.conn_id, sub.msg_id, "PRESENCE_SUBSCRIBE_SHARED", "encode failed");
            return;
        };
        self.pushToSendQueue(sub.conn_id, msg);
    }

    fn pushToSendQueue(self: *PresenceWorker, conn_id: u64, msg: []const u8) void {
        self.send_queue.push(.{ .conn_id = conn_id, .data = msg }) catch |err| {
            std.log.err("PresenceWorker send_queue push failed: {}", .{err});
            self.allocator.free(msg);
            return;
        };
        self.notifier.notify();
    }

    fn sendError(self: *PresenceWorker, conn_id: u64, msg_id: u64, code: []const u8, message: []const u8) void {
        const err_msg = wire.encodeError(self.allocator, msg_id, .{
            .code = code,
            .message = message,
        }) catch return;
        self.pushToSendQueue(conn_id, err_msg);
    }

    fn flush(self: *PresenceWorker) void {
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
            std.log.err("PresenceWorker drain failed: {}", .{err});
            return;
        };

        if (user_batches.items.len == 0 and shared_batches.items.len == 0) return;

        const gpa = self.allocator;
        var pushed_any = false;

        for (user_batches.items) |batch| {
            if (batch.subscribers.items.len == 0) continue;
            for (batch.subscribers.items) |subscriber| {
                const msg = wire.encodePresenceBroadcast(gpa, subscriber.sub_id, batch.updates.items) catch |err| {
                    std.log.err("PresenceWorker encode user broadcast failed: {}", .{err});
                    continue;
                };
                self.send_queue.push(.{ .conn_id = subscriber.conn_id, .data = msg }) catch |err| {
                    std.log.err("PresenceWorker push user broadcast failed: {}", .{err});
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
                    std.log.err("PresenceWorker encode shared broadcast failed: {}", .{err});
                    continue;
                };
                self.send_queue.push(.{ .conn_id = subscriber.conn_id, .data = msg }) catch |err| {
                    std.log.err("PresenceWorker push shared broadcast failed: {}", .{err});
                    gpa.free(msg);
                    continue;
                };
                pushed_any = true;
            }
        }

        if (pushed_any) {
            self.notifier.notify();
        }
    }
};
