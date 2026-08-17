const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn spmcBlockingQueue(comptime T: type) type {
    _ = @typeName(T);
    return struct {
        const Self = @This();

        const Node = struct {
            data: T,
            next: ?*Node,
        };

        head: ?*Node,
        tail: ?*Node,
        io: std.Io,
        mutex: std.Io.Mutex,
        event: std.Io.Event,
        count: usize,
        shutdown_requested: std.atomic.Value(bool),
        allocator: Allocator,

        pub fn init(io: std.Io, allocator: Allocator) Self {
            return .{
                .head = null,
                .tail = null,
                .io = io,
                .mutex = .init,
                .event = .unset,
                .count = 0,
                .shutdown_requested = std.atomic.Value(bool).init(false),
                .allocator = allocator,
            };
        }

        pub fn push(self: *Self, item: T) !void {
            const node = try self.allocator.create(Node);
            node.* = .{
                .data = item,
                .next = null,
            };

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.tail) |t| {
                t.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.count += 1;
            self.event.set(self.io);
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);

            while (self.head == null and !self.shutdown_requested.load(.acquire)) {
                self.event.reset();
                self.mutex.unlock(self.io);
                self.event.waitUncancelable(self.io);
                self.mutex.lockUncancelable(self.io);
            }
            defer self.mutex.unlock(self.io);

            if (self.head) |node| {
                const data = node.data;
                self.head = node.next;
                if (self.head == null) {
                    self.tail = null;
                }
                self.count -= 1;
                self.allocator.destroy(node);
                return data;
            }
            return null;
        }

        pub fn popTimed(self: *Self, timeout_ns: u64) ?T {
            self.mutex.lockUncancelable(self.io);

            if (self.head == null and !self.shutdown_requested.load(.acquire) and timeout_ns > 0) {
                self.event.reset();
                self.mutex.unlock(self.io);
                _ = self.event.waitTimeout(self.io, .{ .duration = .{
                    .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => return null,
                };
                self.mutex.lockUncancelable(self.io);
            }
            defer self.mutex.unlock(self.io);

            if (self.head) |node| {
                const data = node.data;
                self.head = node.next;
                if (self.head == null) {
                    self.tail = null;
                }
                self.count -= 1;
                self.allocator.destroy(node);
                return data;
            }
            return null;
        }

        pub fn shutdown(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.shutdown_requested.store(true, .release);
            self.event.set(self.io);
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var current = self.head;
            while (current) |node| {
                const next = node.next;
                if (comptime @typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union" or @typeInfo(T) == .@"enum") {
                    if (@hasDecl(T, "deinit")) {
                        node.data.deinit(self.allocator);
                    }
                }
                self.allocator.destroy(node);
                current = next;
            }
            self.head = null;
            self.tail = null;
            self.count = 0;
        }
    };
}
