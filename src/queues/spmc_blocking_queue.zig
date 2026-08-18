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
        condition: std.Io.Condition,
        count: usize,
        shutdown_requested: std.atomic.Value(bool),
        allocator: Allocator,

        pub fn init(io: std.Io, allocator: Allocator) Self {
            return .{
                .head = null,
                .tail = null,
                .io = io,
                .mutex = .init,
                .condition = .init,
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
            self.condition.signal(self.io);
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (self.head == null and !self.shutdown_requested.load(.acquire)) {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }

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
            defer self.mutex.unlock(self.io);

            // timed popTimed is only exercised by the thread-safety test (prod passes 0).
            var remaining: u64 = timeout_ns;
            while (self.head == null and !self.shutdown_requested.load(.acquire) and remaining > 0) {
                const sleep_ns = @min(remaining, std.time.ns_per_ms);
                remaining -= sleep_ns;
                self.mutex.unlock(self.io);
                std.Io.sleep(self.io, .fromNanoseconds(@intCast(sleep_ns)), .awake) catch |err| switch (err) { // zwanzig-disable-line: swallowed-error
                    error.Canceled => remaining = 0, // shutdown: stop waiting, fall through to head check
                };
                self.mutex.lockUncancelable(self.io);
            }

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
            self.condition.broadcast(self.io);
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
