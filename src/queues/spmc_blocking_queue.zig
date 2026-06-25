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
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
        count: usize,
        shutdown_requested: std.atomic.Value(bool),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .head = null,
                .tail = null,
                .mutex = .{},
                .cond = .{},
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

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.tail) |t| {
                t.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.count += 1;
            self.cond.signal();
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head == null and !self.shutdown_requested.load(.acquire)) {
                self.cond.wait(&self.mutex);
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
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head == null and !self.shutdown_requested.load(.acquire) and timeout_ns > 0) {
                var timer = std.time.Timer.start() catch {
                    return null;
                };

                while (self.head == null and !self.shutdown_requested.load(.acquire)) {
                    const elapsed = timer.read();
                    if (elapsed >= timeout_ns) break;
                    const remaining = timeout_ns - elapsed;
                    self.cond.timedWait(&self.mutex, remaining) catch |err| {
                        if (err == error.Timeout) break;
                        std.log.err("SpmcBlockingQueue popTimed: timedWait failed: {}", .{err});
                        break;
                    };
                }
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
            self.mutex.lock();
            defer self.mutex.unlock();
            self.shutdown_requested.store(true, .release);
            self.cond.broadcast();
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count == 0;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var current = self.head;
            while (current) |node| {
                const next = node.next;
                if (comptime @typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union" or @typeInfo(T) == .@"enum") {
                    if (@hasDecl(T, "deinit")) {
                        node.data.deinit();
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
