const std = @import("std");

/// Generic lock-free multi-producer single-consumer queue.
///
/// Uses the Vyukov linked-list algorithm: producers append to `tail` via
/// an atomic swap, the consumer advances `head`. A stub node always sits
/// at `head` so that push and pop never touch the same node concurrently.
///
/// Node allocation is parameterized via a pool type function. The pool must
/// provide `acquire(self: *Pool) !*Node` and `release(self: *Pool, node: *Node) void`.
/// Use `MemoryStrategy.IndexPool` for zero-allocation pooled nodes, or
/// `MemoryStrategy.AllocPool` for simple on-demand allocation.
///
/// The queue is not blocking — callers are expected to pair it with a
/// notifier for blocking semantics (see NotificationWorkerPool).
///
/// `deinit` only releases the stub node. Callers must drain remaining items
/// (calling `pop` + item `deinit`) before calling `deinit`.
pub fn mpscQueue( // zwanzig-disable-line: unused-parameter identifier-style
    comptime T: type,
    comptime PoolFn: fn (comptime N: type) type,
) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            data: T,
            next: std.atomic.Value(?*Node),
        };

        const Pool = PoolFn(Node);

        head: *Node,
        tail: std.atomic.Value(*Node),
        pool: *Pool,

        pub fn init(pool: *Pool) !Self {
            const stub = try pool.acquire();
            stub.next = std.atomic.Value(?*Node).init(null);
            return Self{
                .head = stub,
                .tail = std.atomic.Value(*Node).init(stub),
                .pool = pool,
            };
        }

        /// Release the stub node. Callers must drain remaining items first.
        pub fn deinit(self: *Self) void {
            self.pool.release(self.head);
        }

        pub fn push(self: *Self, item: T) !void {
            const node = try self.pool.acquire();
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
            self.pool.release(head);
            return data;
        }

        pub fn hasItems(self: *const Self) bool {
            return self.head.next.load(.acquire) != null;
        }
    };
}
