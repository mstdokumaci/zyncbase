const std = @import("std");
const Allocator = std.mem.Allocator;

/// MemoryStrategy provides different allocator strategies for different use cases in ZyncBase.
/// It combines GeneralPurposeAllocator for long-lived allocations, ArenaAllocator for
/// per-request temporary allocations, and object pools for high-churn objects.
pub const MemoryStrategy = struct {
    /// General-purpose allocator for long-lived allocations (server lifetime)
    /// Used for: State tree, subscriptions, cache entries
    gpa: std.heap.GeneralPurposeAllocator(.{}),

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

        return MemoryStrategy{
            .gpa = .{},
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .message_pool = try Pool(Message).init(pool_allocator, 1000),
            .buffer_pool = try Pool(Buffer).init(pool_allocator, 1000),
            .connection_pool = try Pool(Connection).init(pool_allocator, 100_000),
        };
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

/// Generic object pool for reusing fixed-size objects
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        available: std.ArrayList(*T),
        mutex: std.Thread.Mutex,
        capacity: usize,

        /// Initialize a pool with the given capacity
        pub fn init(allocator: Allocator, capacity: usize) !Self {
            return Self{
                .allocator = allocator,
                .available = std.ArrayList(*T){},
                .mutex = std.Thread.Mutex{},
                .capacity = capacity,
            };
        }

        /// Deinitialize the pool and free all objects
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.available.items) |item| {
                self.allocator.destroy(item);
            }
            self.available.deinit(self.allocator);
        }

        /// Acquire an object from the pool, or allocate a new one if pool is empty
        pub fn acquire(self: *Self) !*T {
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.available.items.len > 0) {
                    return self.available.pop() orelse unreachable;
                }
            }

            // Pool is empty, allocate a new object (outside mutex to avoid deadlock)
            const item = try self.allocator.create(T);

            // Initialize the object if it has an init method
            const type_info = @typeInfo(T);
            if (type_info == .@"struct" and @hasDecl(T, "init")) {
                item.* = T.init();
            }

            return item;
        }

        /// Release an object back to the pool
        /// If pool is at capacity, the object is freed instead
        pub fn release(self: *Self, item: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.available.items.len < self.capacity) {
                self.available.append(self.allocator, item) catch {
                    // If append fails, just free the object
                    self.allocator.destroy(item);
                    return;
                };
            } else {
                // Pool is at capacity, free the object
                self.allocator.destroy(item);
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
