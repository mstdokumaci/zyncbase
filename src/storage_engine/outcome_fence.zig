const std = @import("std");

const wire_encode = @import("../wire/encode.zig");
const wire_errors = @import("../wire/errors.zig");
const send_queue_type = @import("../connection/send_queue.zig").send_queue;
const ArenaHandle = @import("../memory/strategy.zig").ArenaHandle;
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const Notifier = @import("../threading/notifier.zig").Notifier;
const WriteAck = @import("write_queue.zig").WriteAck;

/// Holds one writer transaction's outcomes until every change it pushed to
/// the subscription workers has been processed, so a client always receives
/// a transaction's deltas before its `WriteCommitted`/`WriteError`.
///
/// `pending` counts the writer's hold plus one per change job carrying the
/// fence. Whoever drops it to zero publishes. The fence lives in its own
/// deferred arena, which also backs the encoded outcomes and their
/// send-queue nodes; the send-queue entries keep the arena alive after that.
pub const OutcomeFence = struct {
    handle: ArenaHandle,
    pending: std.atomic.Value(u32),
    entries: std.ArrayListUnmanaged(Outcome),
    send_queue: *send_queue_type,
    notifier: Notifier,

    const Outcome = struct {
        conn_id: u64,
        loop_id: u8,
        data: []const u8,
    };

    /// Returns a fence holding the writer's reference.
    pub fn create(ms: *MemoryStrategy, send_queue: *send_queue_type, notifier: Notifier) !*OutcomeFence {
        const handle = try ms.acquireArenaDeferred();
        errdefer handle.release();
        const self = try handle.allocator().create(OutcomeFence);
        self.* = .{
            .handle = handle,
            .pending = .init(1),
            .entries = .empty,
            .send_queue = send_queue,
            .notifier = notifier,
        };
        return self;
    }

    /// Records one outcome. Writer only, before its `release`.
    pub fn add(self: *OutcomeFence, ack: WriteAck, err: ?anyerror, batch_index: ?usize) void {
        const alloc = self.handle.allocator();
        const data = if (err) |e|
            wire_encode.encodeWriteError(alloc, ack.msg_id, wire_errors.getWireError(e), batch_index)
        else
            wire_encode.encodeWriteCommitted(alloc, ack.msg_id);
        const encoded = data catch |encode_err| {
            std.log.err("OutcomeFence: failed to encode outcome for conn_id={d}: {}", .{ ack.conn_id, encode_err });
            return;
        };
        self.entries.append(alloc, .{ .conn_id = ack.conn_id, .loop_id = ack.loop_id, .data = encoded }) catch |append_err| {
            std.log.err("OutcomeFence: failed to record outcome for conn_id={d}: {}", .{ ack.conn_id, append_err });
        };
    }

    /// Call before handing the fence to a change job.
    pub fn retain(self: *OutcomeFence) void {
        _ = self.pending.fetchAdd(1, .monotonic);
    }

    /// Drop one reference; the last one publishes the outcomes. The acq_rel
    /// chain orders every earlier releaser's delta pushes before that publish.
    pub fn release(self: *OutcomeFence) void {
        const prev = self.pending.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        if (prev == 1) self.publish();
    }

    fn publish(self: *OutcomeFence) void {
        // `self` lives in the arena; the final release below may recycle it.
        const handle = self.handle;
        const send_queue = self.send_queue;
        const notifier = self.notifier;
        var pushed = false;
        for (self.entries.items) |entry| {
            handle.retain();
            send_queue.push(entry.loop_id, .{ .conn_id = entry.conn_id, .data = entry.data, .arena = handle }) catch |err| {
                std.log.err("OutcomeFence: failed to push outcome for conn_id={d}: {}", .{ entry.conn_id, err });
                handle.release();
                continue;
            };
            pushed = true;
        }
        if (pushed) notifier.notify();
        handle.release();
    }
};
