const std = @import("std");
const Allocator = std.mem.Allocator;

/// MemoryStrategy provides different allocator strategies for different use cases in ZyncBase.
/// It combines GeneralPurposeAllocator for long-lived allocations, ArenaAllocator for
/// per-request temporary allocations, and object pools for high-churn objects.
pub const MemoryStrategy = struct {
    /// General-purpose allocator for long-lived allocations (server lifetime)
    /// Used for: State tree, subscriptions, cache entries
    gpa: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }),

    /// Arena allocator for per-request temporary allocations (freed in bulk)
    /// Used for: Request parsing, response building, temporary buffers
    arena: std.heap.ArenaAllocator,

    /// Object pools for high-churn objects to avoid allocation overhead
    message_pool: Pool(Message),
    buffer_pool: Pool(Buffer),
    connection_pool: Pool(Connection),

    /// Initialize the memory strategy with all allocators and pools
    pub fn init() !MemoryStrategy {
        // Use page allocator for pools to avoid mutex deadlock with GPA
        const pool_allocator = std.heap.page_allocator;

        var self = MemoryStrategy{
            .gpa = .{},
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .message_pool = undefined,
            .buffer_pool = undefined,
            .connection_pool = undefined,
        };

        // Initialize pools with the instance being created to avoid copies
        self.message_pool = try Pool(Message).init(pool_allocator, 1000);
        self.buffer_pool = try Pool(Buffer).init(pool_allocator, 1000);
        self.connection_pool = try Pool(Connection).init(pool_allocator, 100_000);

        return self;
    }

    /// Deinitialize the memory strategy and free all resources
    pub fn deinit(self: *MemoryStrategy) void {
        self.message_pool.deinit();
        self.buffer_pool.deinit();
        self.connection_pool.deinit();
        self.arena.deinit();
        _ = self.gpa.deinit();
    }

    /// Get the general-purpose allocator for long-lived allocations
    pub fn generalAllocator(self: *MemoryStrategy) Allocator {
        return self.gpa.allocator();
    }

    /// Get the arena allocator for per-request temporary allocations
    /// Note: Caller must call resetArena() after request completes
    pub fn arenaAllocator(self: *MemoryStrategy) Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena allocator to free all temporary memory in bulk
    /// Should be called after each request completes
    pub fn resetArena(self: *MemoryStrategy) void {
        _ = self.arena.reset(.free_all);
    }

    /// Acquire a message from the pool
    pub fn acquireMessage(self: *MemoryStrategy) !*Message {
        return self.message_pool.acquire();
    }

    /// Release a message back to the pool
    pub fn releaseMessage(self: *MemoryStrategy, message: *Message) void {
        self.message_pool.release(message);
    }

    /// Acquire a buffer from the pool
    pub fn acquireBuffer(self: *MemoryStrategy) !*Buffer {
        return self.buffer_pool.acquire();
    }

    /// Release a buffer back to the pool
    pub fn releaseBuffer(self: *MemoryStrategy, buffer: *Buffer) void {
        self.buffer_pool.release(buffer);
    }

    /// Acquire a connection from the pool
    pub fn acquireConnection(self: *MemoryStrategy) !*Connection {
        return self.connection_pool.acquire();
    }

    /// Release a connection back to the pool
    pub fn releaseConnection(self: *MemoryStrategy, connection: *Connection) void {
        self.connection_pool.release(connection);
    }
};

/// Generic object pool for reusing fixed-size objects.
/// Uses a lock-free atomic stack to avoid mutex contention.
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Node structure for the intrusive linked list
        const Node = struct {
            next: std.atomic.Value(?*Node),
            data: T,
        };

        /// Tagged pointer to handle ABA problem
        const TaggedPtr = packed struct {
            ptr: ?*Node,
            gen: usize,
        };

        allocator: Allocator,
        head: std.atomic.Value(u128) align(16),
        capacity: usize,
        count: std.atomic.Value(usize),

        /// Initialize a pool with the given capacity
        pub fn init(allocator: Allocator, capacity: usize) !Self {
            const initial_tagged = TaggedPtr{ .ptr = null, .gen = 0 };
            return Self{
                .allocator = allocator,
                .head = std.atomic.Value(u128).init(@bitCast(initial_tagged)),
                .capacity = capacity,
                .count = std.atomic.Value(usize).init(0),
            };
        }

        /// Deinitialize the pool and free all objects
        pub fn deinit(self: *Self) void {
            // Swap out the head to prevent any concurrent access during deinit
            var ptr = @as(TaggedPtr, @bitCast(self.head.swap(0, .acquire))).ptr;
            while (ptr) |node| {
                const next = node.next.load(.monotonic);
                self.allocator.destroy(node);
                ptr = next;
            }
        }

        /// Acquire an object from the pool, or allocate a new one if pool is empty
        pub fn acquire(self: *Self) !*T {
            var current_raw = self.head.load(.acquire);
            while (true) {
                const current: TaggedPtr = @bitCast(current_raw);
                const node = current.ptr orelse break;
                const next_node = node.next.load(.acquire);
                const next_tagged = TaggedPtr{ .ptr = next_node, .gen = current.gen + 1 };
                if (self.head.cmpxchgStrong(current_raw, @bitCast(next_tagged), .acq_rel, .acquire)) |actual| {
                    current_raw = actual;
                } else {
                    _ = self.count.fetchSub(1, .release);
                    return &node.data;
                }
            }

            // Pool is empty, allocate a new object
            const node = try self.allocator.create(Node);
            node.next = std.atomic.Value(?*Node).init(null);

            // Initialize the object ONLY if it's new
            const ti = @typeInfo(T);
            if (ti == .@"struct" and @hasDecl(T, "init")) {
                node.data = T.init();
            }

            return &node.data;
        }

        /// Release an object back to the pool
        /// If pool is at capacity, the object is freed instead
        pub fn release(self: *Self, item_ptr: *T) void {
            // Recover Node pointer from data pointer
            const node: *Node = @alignCast(@fieldParentPtr("data", item_ptr));

            if (self.count.load(.acquire) < self.capacity) {
                var current_raw = self.head.load(.acquire);
                while (true) {
                    const current: TaggedPtr = @bitCast(current_raw);
                    node.next.store(current.ptr, .release);
                    const next_tagged = TaggedPtr{ .ptr = node, .gen = current.gen + 1 };
                    if (self.head.cmpxchgStrong(current_raw, @bitCast(next_tagged), .acq_rel, .acquire)) |actual| {
                        current_raw = actual;
                    } else {
                        _ = self.count.fetchAdd(1, .release);
                        return;
                    }
                }
            } else {
                self.allocator.destroy(node);
            }
        }
    };
}

/// Message type for pooling
pub const Message = struct {
    data: [4096]u8,
    len: usize,

    pub fn init() Message {
        return Message{
            .data = undefined,
            .len = 0,
        };
    }

    pub fn reset(self: *Message) void {
        self.len = 0;
    }
};

/// Buffer type for pooling
pub const Buffer = [4096]u8;

/// Connection type for pooling (placeholder)
pub const Connection = struct {
    id: u64,
    active: bool,

    pub fn init() Connection {
        return Connection{
            .id = 0,
            .active = false,
        };
    }

    pub fn reset(self: *Connection) void {
        self.id = 0;
        self.active = false;
    }
};
