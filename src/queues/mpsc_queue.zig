const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn mpscQueue(comptime T: type) type {
    _ = @typeName(T);
    return struct {
        const Self = @This();

        const Node = struct {
            data: T,
            next: std.atomic.Value(?*Node),
        };

        head: *Node,
        tail: std.atomic.Value(*Node),
        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {
            const stub = try allocator.create(Node);
            // SAFETY: Sentinel node — data is never read, only next pointer is used.
            stub.* = .{
                .data = undefined,
                .next = std.atomic.Value(?*Node).init(null),
            };
            return .{
                .head = stub,
                .tail = std.atomic.Value(*Node).init(stub),
                .allocator = allocator,
            };
        }

        pub fn push(self: *Self, item: T) !void {
            const node = try self.allocator.create(Node);
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
            self.allocator.destroy(head);
            return data;
        }

        pub fn hasItems(self: *const Self) bool {
            return self.head.next.load(.acquire) != null;
        }

        pub fn deinit(self: *Self) void {
            while (true) {
                const head = self.head;
                const next = head.next.load(.acquire) orelse {
                    self.allocator.destroy(head);
                    return;
                };
                if (comptime @typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union" or @typeInfo(T) == .@"enum") {
                    if (@hasDecl(T, "deinit")) next.data.deinit(self.allocator);
                }
                self.allocator.destroy(head);
                self.head = next;
            }
        }
    };
}
