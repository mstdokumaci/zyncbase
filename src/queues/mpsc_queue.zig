const std = @import("std");

/// Generic lock-free multi-producer single-consumer queue.
///
/// Uses the Vyukov linked-list algorithm: producers append to `tail` via
/// an atomic swap, the consumer advances `head`. A stub node always sits
/// at `head` so that push and pop never touch the same node concurrently.
///
/// Nodes are allocated from the payload's own owner rather than from a
/// shared pool, so enqueue costs one atomic tail swap instead of a
/// take-node CAS, a tail swap, and a return-node CAS on a single
/// contended cache line. The owner must provide:
///   `allocator() Allocator`, `retain() void`, `release() void`
/// and `T` must provide `owner() Owner` returning that same handle.
///
/// The node lives in the owner's arena, so it is only valid while the
/// owner is retained. That makes `head` a live reference too: `pop`
/// retains the new head's owner before releasing the previous one, since
/// the advance is what keeps the node addressable and nothing else does.
/// Without that hold the head's arena can be recycled while `head` still
/// points into it. A queued entry always holds its own owner reference,
/// so two live nodes sharing an arena keep the refcount above zero
/// regardless of retain/release ordering.
///
/// The queue is not blocking — callers are expected to pair it with a
/// notifier for blocking semantics (see SubscriptionWorkerPool).
///
/// `deinit` only frees the stub node. Callers must drain remaining items
/// (calling `pop` + item `deinit`) before calling `deinit`.
pub fn mpscQueue( // zwanzig-disable-line: unused-parameter identifier-style
    comptime T: type,
    comptime Owner: type,
) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            data: T,
            next: std.atomic.Value(?*Node),
        };

        allocator: std.mem.Allocator,
        /// Owned outright by `allocator`. `head` walks away from it as the
        /// queue is drained, so it is tracked separately from the head node.
        stub: *Node,
        head: *Node,
        tail: std.atomic.Value(*Node),
        /// Keeps the owner of the current `head` alive. Null only while
        /// `head` is the stub, which the queue owns outright via `allocator`.
        head_owner: ?Owner,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const stub = try allocator.create(Node);
            stub.* = .{
                // SAFETY: The stub is only ever the queue's `head`; `data` is
                // read exclusively from `next`, and the stub is never a `next`.
                .data = undefined,
                .next = std.atomic.Value(?*Node).init(null),
            };
            return Self{
                .allocator = allocator,
                .stub = stub,
                .head = stub,
                .tail = std.atomic.Value(*Node).init(stub),
                .head_owner = null,
            };
        }

        /// Free the stub node. Callers must drain remaining items first.
        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.hasItems());
            if (self.head_owner) |owner| owner.release();
            self.allocator.destroy(self.stub);
        }

        pub fn push(self: *Self, item: T) !void {
            const node = try item.owner().allocator().create(Node);
            node.* = .{
                .data = item,
                .next = std.atomic.Value(?*Node).init(null),
            };
            const prev = self.tail.swap(node, .acq_rel);
            prev.next.store(node, .release);
        }

        pub fn pop(self: *Self) ?T {
            const head = self.head;
            const next = head.next.load(.acquire) orelse return null;
            const data: T = next.data;
            self.head = next;
            const prev_owner = self.head_owner;
            self.head_owner = data.owner();
            self.head_owner.?.retain();
            if (prev_owner) |owner| owner.release();
            return data;
        }

        pub fn hasItems(self: *const Self) bool {
            return self.head.next.load(.acquire) != null;
        }
    };
}
