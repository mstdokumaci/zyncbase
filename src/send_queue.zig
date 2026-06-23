const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    conn_id: u64,
    data: []u8,
};

pub const SendQueue = struct {
    const Node = struct {
        conn_id: u64,
        data: []u8,
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

    /// Must only be called after every producer has stopped and a final drain
    /// has completed. Concurrent push() during deinit() is a data race.
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

    pub fn pop(self: *SendQueue) ?Entry {
        const head = self.head;
        const next = head.next.load(.acquire) orelse return null;

        const conn_id: u64 = next.conn_id;
        const data: []u8 = next.data;
        self.head = next;
        self.allocator.destroy(head);
        return .{ .conn_id = conn_id, .data = data };
    }

    pub fn hasItems(self: *SendQueue) bool {
        return self.head.next.load(.acquire) != null;
    }
};
