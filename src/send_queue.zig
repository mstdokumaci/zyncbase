const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    conn_id: u64,
    data: []const u8,
};

pub const SendQueue = struct {
    const Node = struct {
        conn_id: u64,
        data: []const u8,
        next: std.atomic.Value(?*Node),
    };

    head: *Node,
    tail: std.atomic.Value(*Node),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !SendQueue {
        const stub = try allocator.create(Node);
        stub.* = .{
            .conn_id = 0,
            .data = &.{},
            .next = std.atomic.Value(?*Node).init(null),
        };
        return .{
            .head = stub,
            .tail = std.atomic.Value(*Node).init(stub),
            .allocator = allocator,
        };
    }

    /// Must only be called after every producer thread has been stopped and joined.
    /// Deinit frees all remaining unconsumed entry data automatically.
    /// Concurrent push() during deinit() is a data race.
    pub fn deinit(self: *SendQueue) void {
        while (true) {
            const head = self.head;
            const next = head.next.load(.acquire) orelse {
                self.allocator.destroy(head);
                return;
            };
            self.allocator.free(next.data);
            self.allocator.destroy(head);
            self.head = next;
        }
    }

    pub fn push(self: *SendQueue, conn_id: u64, data: []const u8) !void {
        const duped = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(duped);
        const node = try self.allocator.create(Node);
        node.* = .{
            .conn_id = conn_id,
            .data = duped,
            .next = std.atomic.Value(?*Node).init(null),
        };
        const prev = self.tail.swap(node, .acq_rel);
        prev.next.store(node, .release);
    }

    /// Cross-thread safe send: push message to SendQueue for event loop delivery.
    /// Called from background threads. The event loop drains the queue and
    /// calls Connection.send() in notifyPostHandler via drainSendQueue.
    pub fn postToConnection(self: *SendQueue, conn_id: u64, data: []const u8) void {
        self.push(conn_id, data) catch |err| {
            std.log.warn("Failed to post to connection {}: {}", .{ conn_id, err });
        };
    }

    pub fn pop(self: *SendQueue) ?Entry {
        const head = self.head;
        const next = head.next.load(.acquire) orelse return null;

        const conn_id: u64 = next.conn_id;
        const data: []const u8 = next.data;
        self.head = next;
        self.allocator.destroy(head);
        return .{ .conn_id = conn_id, .data = data };
    }

    pub fn hasItems(self: *SendQueue) bool {
        return self.head.next.load(.acquire) != null;
    }
};
