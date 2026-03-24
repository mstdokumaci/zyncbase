const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

/// MemoryStrategy provides different allocator strategies for different use cases in ZyncBase.
/// It combines GeneralPurposeAllocator for long-lived allocations, ArenaAllocator for
/// per-request temporary allocations, and object pools for high-churn objects.
pub const MemoryStrategy = struct {
    /// Parent allocator used to allocate the GPA itself
    parent_allocator: Allocator,

    /// General-purpose allocator for long-lived allocations (server lifetime)
    /// Used for: State tree, subscriptions, cache entries
    gpa: *std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }),

    /// Pool of Arena allocators for per-request temporary allocations (freed in bulk).
    arena_pool: IndexPool(std.heap.ArenaAllocator),

    /// Object pools for high-churn objects to avoid allocation overhead
    message_pool: DynamicPool(Message),
    buffer_pool: DynamicPool(Buffer),
    connection_pool: IndexPool(Connection),

    /// Memory Strategy configuration for pools
    pub const Config = struct {
        arena_pool: PoolConfig = .{ .pre_allocate = 1024, .max_capacity = 1024 },
        message_pool: PoolConfig = .{ .pre_allocate = 0, .max_capacity = 1024 },
        buffer_pool: PoolConfig = .{ .pre_allocate = 0, .max_capacity = 16 },
        connection_pool: PoolConfig = .{ .pre_allocate = 0, .max_capacity = 100_000 },

        pub const PoolConfig = struct {
            pre_allocate: u32,
            max_capacity: u32,
        };

        /// Standard production configuration
        pub const default_config = Config{};

        /// Minimal configuration for tests to reduce overhead
        pub const minimal_config = Config{
            .arena_pool = .{ .pre_allocate = 16, .max_capacity = 1024 },
        };
    };

    /// Initialize the memory strategy with standard defaults.
    /// Automatically optimizes for tests if builtin.is_test is true.
    pub fn init(self: *MemoryStrategy, allocator: Allocator) !void {
        const current_config = if (builtin.is_test) Config.minimal_config else Config.default_config;
        try self.initWithConfig(allocator, current_config);
    }

    /// Initialize the memory strategy with specific configuration.
    pub fn initWithConfig(self: *MemoryStrategy, allocator: Allocator, config: Config) !void {
        const gpa_ptr = try allocator.create(std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }));
        errdefer allocator.destroy(gpa_ptr);
        gpa_ptr.* = .{};

        const gpa_alloc = gpa_ptr.allocator();
        self.* = .{
            .parent_allocator = allocator,
            .gpa = gpa_ptr,
            .arena_pool = undefined,
            .message_pool = undefined,
            .buffer_pool = undefined,
            .connection_pool = undefined,
        };

        // Initialize pools
        try self.arena_pool.init(
            gpa_alloc,
            config.arena_pool.max_capacity,
            deinitArena,
            initArena,
        );
        errdefer self.arena_pool.deinit();

        try self.message_pool.init(
            gpa_alloc,
            config.message_pool.max_capacity,
            deinitMessage,
            Message.init,
        );
        errdefer self.message_pool.deinit();

        try self.buffer_pool.init(
            gpa_alloc,
            config.buffer_pool.max_capacity,
            null,
            null,
        );
        errdefer self.buffer_pool.deinit();

        try self.connection_pool.init(
            gpa_alloc,
            config.connection_pool.max_capacity,
            deinitConnection,
            initConnection,
        );
        errdefer self.connection_pool.deinit();

        // Pre-allocate arenas based on configuration
        for (0..config.arena_pool.pre_allocate) |_| {
            try self.arena_pool.pushInitial();
        }

        // Pre-allocate connections
        for (0..config.connection_pool.pre_allocate) |_| {
            try self.connection_pool.pushInitial();
        }

        // Pre-allocate messages
        try self.message_pool.preAllocate(config.message_pool.pre_allocate);
    }

    /// Deinitialize the memory strategy and free all resources
    pub fn deinit(self: *MemoryStrategy) void {

        // Deinit pools (this frees the Nodes and cleans up contents via deinitData callbacks)
        self.arena_pool.deinit();
        self.message_pool.deinit();
        self.buffer_pool.deinit();
        self.connection_pool.deinit();

        _ = self.gpa.deinit();
        self.parent_allocator.destroy(self.gpa);
    }

    fn initArena(arena: *std.heap.ArenaAllocator, allocator: Allocator) void {
        arena.* = std.heap.ArenaAllocator.init(allocator);
    }

    fn deinitArena(arena: *std.heap.ArenaAllocator, _: Allocator) void {
        arena.deinit();
    }

    fn deinitMessage(msg: *Message, allocator: Allocator) void {
        _ = allocator;
        msg.reset();
    }

    fn deinitConnection(conn: *Connection, allocator: Allocator) void {
        conn.deinit(allocator);
    }

    fn initConnection(conn: *Connection, allocator: Allocator) void {
        conn.init(allocator);
    }

    /// Access the general-purpose allocator
    pub fn generalAllocator(self: *MemoryStrategy) Allocator {
        return self.gpa.allocator();
    }

    /// Acquire an arena from the pool
    pub fn acquireArena(self: *MemoryStrategy) !*std.heap.ArenaAllocator {
        return self.arena_pool.acquire();
    }

    /// Release an arena back to the pool after resetting it
    pub fn releaseArena(self: *MemoryStrategy, arena: *std.heap.ArenaAllocator) void {
        _ = arena.reset(.retain_capacity);
        self.arena_pool.release(arena);
    }

    /// Acquire a message from the pool
    pub fn acquireMessage(self: *MemoryStrategy) !*Message {
        const msg = try self.message_pool.acquire();
        msg.reset();
        return msg;
    }

    /// Release a message back to the pool
    pub fn releaseMessage(self: *MemoryStrategy, msg: *Message) void {
        self.message_pool.release(msg);
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

    pub fn createConnection(self: *MemoryStrategy, id: u64, ws: WebSocket) !*Connection {
        var conn = try self.acquireConnection();
        conn.reset();
        conn.memory_strategy = self;
        conn.id = id;
        conn.ws = ws;
        conn.created_at = std.time.timestamp();
        return conn;
    }

    /// Generic object pool for reusing fixed-size objects.
    /// Uses a lock-free atomic stack to avoid mutex contention.
    /// Prefers DynamicPool for large objects, or IndexPool for performance-critical small objects.
    pub fn DynamicPool(comptime T: type) type { // zwanzig-disable-line: unused-parameter identifier-style
        return struct {
            const Self = @This();

            /// Node structure for the intrusive linked list
            const Node = struct {
                next: std.atomic.Value(?*Node),
                data: T,
            };

            /// Combined state for atomic head and count
            const CombinedState = packed struct {
                ptr: ?*Node,
                gen: u32,
                count: u32,
            };

            /// List head
            head: ?*Node,
            mutex: std.Thread.Mutex,
            count: u32,
            active_count: u32,
            allocator: Allocator,
            maxCapacity: u32,
            deinitData: ?*const fn (*T, Allocator) void,
            initData: ?*const fn (*T, Allocator) void,

            /// Initialize the pool
            pub fn init(
                self: *Self,
                allocator: Allocator,
                maxCapacity: u32,
                deinitData: ?*const fn (*T, Allocator) void,
                initData: ?*const fn (*T, Allocator) void,
            ) !void {
                self.* = .{
                    .head = null,
                    .mutex = .{},
                    .count = 0,
                    .active_count = 0,
                    .allocator = allocator,
                    .maxCapacity = maxCapacity,
                    .deinitData = deinitData,
                    .initData = initData,
                };
            }

            /// Deinitialize the pool and free all memory
            pub fn deinit(self: *Self) void {
                self.mutex.lock();
                defer self.mutex.unlock();

                // Assert no active objects are leaked
                std.debug.assert(self.active_count == 0);

                var current_node = self.head;
                while (current_node) |node| {
                    const next_node = node.next.load(.monotonic);
                    if (self.deinitData) |deinit_fn| {
                        deinit_fn(&node.data, self.allocator);
                    }
                    self.allocator.destroy(node);
                    current_node = next_node;
                }
                self.head = null;
                self.count = 0;
            }

            /// Internal method to push initial nodes
            pub fn pushInitial(self: *Self, data: T) !void {
                const node = try self.allocator.create(Node);
                node.next = std.atomic.Value(?*Node).init(null);
                node.data = data;
                self.release(&node.data);
            }

            /// Pre-allocate nodes in the pool
            pub fn preAllocate(self: *Self, count: usize) !void {
                for (0..count) |_| {
                    const node = try self.allocator.create(Node);
                    node.next = std.atomic.Value(?*Node).init(null);
                    if (self.initData) |initData| {
                        initData(&node.data, self.allocator);
                    } else {
                        if (comptime @typeInfo(T) != .pointer) {
                            @memset(std.mem.asBytes(&node.data), 0);
                        }
                    }
                    self.release(&node.data);
                }
            }

            /// Pop an object from the pool without allocating new ones
            pub fn pop(self: *Self) ?T {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.head) |node| {
                    self.head = node.next.load(.monotonic);
                    self.count -= 1;
                    const data = node.data;
                    self.allocator.destroy(node);
                    return data;
                }
                return null;
            }

            /// Acquire an object from the pool
            pub fn acquire(self: *Self) !*T {
                self.mutex.lock();
                if (self.head) |node| {
                    self.head = node.next.load(.monotonic);
                    self.count -= 1;
                    self.active_count += 1;
                    self.mutex.unlock();
                    return &node.data;
                }
                self.mutex.unlock();

                // Allocate new node
                const node = try self.allocator.create(Node);
                node.next = std.atomic.Value(?*Node).init(null);
                if (self.initData) |initData| {
                    initData(&node.data, self.allocator);
                } else {
                    if (comptime @typeInfo(T) != .pointer) {
                        @memset(std.mem.asBytes(&node.data), 0);
                    }
                }

                self.mutex.lock();
                self.active_count += 1;
                self.mutex.unlock();

                return &node.data;
            }

            /// Release an object back to the pool
            pub fn release(self: *Self, data: *T) void {
                const node: *Node = @alignCast(@fieldParentPtr("data", data));

                self.mutex.lock();
                defer self.mutex.unlock();

                self.active_count -= 1;

                if (self.count >= self.maxCapacity) {
                    if (self.deinitData) |deinit_fn| {
                        deinit_fn(&node.data, self.allocator);
                    }
                    self.allocator.destroy(node);
                    return;
                }

                node.next.store(self.head, .monotonic);
                self.head = node;
                self.count += 1;
            }
        };
    }

    /// Fixed-size contiguous block pool using 64-bit array indices.
    /// Provides zero-allocation fast path with graceful heap-overflow fallback.
    pub fn IndexPool(comptime T: type) type { // zwanzig-disable-line: unused-parameter identifier-style
        return struct {
            const Self = @This();

            const Node = struct {
                data: T,
                next_index: std.atomic.Value(u32),
            };

            const TaggedIndex = packed struct {
                index: u32,
                tag: u32,
            };

            const null_index = std.math.maxInt(u32);

            nodes: []Node,
            free_stack: std.atomic.Value(u64),
            initialized_count: std.atomic.Value(u32),
            active_count: std.atomic.Value(u32),
            allocator: Allocator,
            deinitData: ?*const fn (*T, Allocator) void,
            initData: ?*const fn (*T, Allocator) void,

            pub fn init(
                self: *Self,
                allocator: Allocator,
                capacity: u32,
                deinitData: ?*const fn (*T, Allocator) void,
                initData: ?*const fn (*T, Allocator) void,
            ) !void {
                const nodes = try allocator.alloc(Node, capacity);
                const head = TaggedIndex{ .index = null_index, .tag = 0 };
                self.* = .{
                    .nodes = nodes,
                    .free_stack = std.atomic.Value(u64).init(@bitCast(head)),
                    .initialized_count = std.atomic.Value(u32).init(0),
                    .active_count = std.atomic.Value(u32).init(0),
                    .allocator = allocator,
                    .deinitData = deinitData,
                    .initData = initData,
                };
            }

            pub fn deinit(self: *Self) void {
                // Assert no active objects are leaked
                std.debug.assert(self.active_count.load(.acquire) == 0);

                if (self.deinitData) |deinit_fn| {
                    // Note: This only cleans up items currently in the pool.
                    // Active handles are expected to be released back to the pool before deinit.
                    const current = self.free_stack.load(.acquire);
                    const head: TaggedIndex = @bitCast(current);
                    var idx = head.index;
                    while (idx != null_index) {
                        const node = &self.nodes[idx];
                        idx = node.next_index.load(.monotonic);
                        deinit_fn(&node.data, self.allocator);
                    }
                }
                self.allocator.free(self.nodes);
            }

            pub fn pushInitial(self: *Self) !void {
                const idx = self.initialized_count.fetchAdd(1, .monotonic);
                if (idx >= self.nodes.len) return error.OutOfMemory;
                if (self.initData) |initData| {
                    initData(&self.nodes[idx].data, self.allocator);
                } else {
                    if (comptime @typeInfo(T) != .pointer) {
                        @memset(std.mem.asBytes(&self.nodes[idx].data), 0);
                    }
                }
                // Directly release to free stack without count check (init phase)
                var current = self.free_stack.load(.acquire);
                while (true) {
                    const head: TaggedIndex = @bitCast(current);
                    self.nodes[idx].next_index.store(head.index, .unordered);
                    const next_head = TaggedIndex{ .index = idx, .tag = head.tag +% 1 };
                    if (self.free_stack.cmpxchgWeak(current, @bitCast(next_head), .acq_rel, .acquire)) |actual| {
                        current = actual;
                        continue;
                    }
                    break;
                }
            }

            pub fn pop(self: *Self) ?*T {
                var current = self.free_stack.load(.acquire);
                while (true) {
                    const head: TaggedIndex = @bitCast(current);
                    if (head.index == null_index) return null;

                    const node = &self.nodes[head.index];
                    const next_head = TaggedIndex{ .index = node.next_index.load(.monotonic), .tag = head.tag +% 1 };

                    if (self.free_stack.cmpxchgWeak(current, @bitCast(next_head), .acq_rel, .acquire)) |actual| {
                        current = actual;
                        continue;
                    }
                    _ = self.active_count.fetchAdd(1, .release);
                    return &node.data;
                }
            }

            pub fn acquire(self: *Self) !*T {
                if (self.pop()) |data| return data;

                // Overflow path: dynamic allocation if pool is exhausted
                const node = try self.allocator.create(Node);
                if (self.initData) |initData| {
                    initData(&node.data, self.allocator);
                } else {
                    node.data = undefined;
                    if (comptime @typeInfo(T) != .pointer) {
                        @memset(std.mem.asBytes(&node.data), 0);
                    }
                }
                return &node.data;
            }

            pub fn release(self: *Self, data: *T) void {
                const node: *Node = @alignCast(@fieldParentPtr("data", data));

                const ptr = @intFromPtr(node);
                const start = @intFromPtr(self.nodes.ptr);
                const end = start + self.nodes.len * @sizeOf(Node);

                if (ptr >= start and ptr < end) {
                    // Fast path: push back to array stack
                    const node_index = @as(u32, @intCast((ptr - start) / @sizeOf(Node)));
                    var current = self.free_stack.load(.acquire);
                    while (true) {
                        const head: TaggedIndex = @bitCast(current);
                        node.next_index.store(head.index, .release);
                        const next_head = TaggedIndex{ .index = node_index, .tag = head.tag +% 1 };
                        if (self.free_stack.cmpxchgWeak(current, @bitCast(next_head), .acq_rel, .acquire)) |actual| {
                            current = actual;
                            continue;
                        }
                        _ = self.active_count.fetchSub(1, .release);
                        break;
                    }
                } else {
                    // Overflow path: destroy heap-allocated node
                    if (self.deinitData) |deinit_fn| deinit_fn(data, self.allocator);
                    self.allocator.destroy(node);
                }
            }

            pub fn activeCount(self: *Self) usize {
                return self.active_count.load(.acquire);
            }
        };
    }
};

/// Connection state for pooling
pub const Connection = struct {
    allocator: Allocator,
    memory_strategy: ?*MemoryStrategy,
    id: u64,
    user_id: ?[]const u8,
    namespace: []const u8,
    subscription_ids: std.ArrayListUnmanaged(u64),
    ws: WebSocket,
    ref_count: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,
    created_at: i64,

    pub fn create(allocator: Allocator, id: u64, ws: WebSocket) !*Connection {
        const self = try allocator.create(Connection);
        self.init(allocator);
        self.id = id;
        self.ws = ws;
        self.created_at = std.time.timestamp();
        return self;
    }

    pub fn init(self: *Connection, allocator: Allocator) void {
        self.allocator = allocator;
        self.id = 0;
        self.user_id = null;
        self.namespace = "default";
        self.subscription_ids = .empty;
        self.ws = .{ .ws = null, .ssl = false };
        self.ref_count = std.atomic.Value(usize).init(1);
        self.mutex = .{};
        self.memory_strategy = null;
    }

    pub fn deinit(self: *Connection, allocator: Allocator) void {
        _ = allocator;
        if (self.user_id) |uid| self.allocator.free(uid);
        self.subscription_ids.deinit(self.allocator);
    }

    pub fn acquire(self: *Connection) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Connection, allocator: Allocator) void {
        _ = allocator; // ignore passed allocator, use self.allocator
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            if (self.user_id) |uid| self.allocator.free(uid);
            self.user_id = null;
            self.subscription_ids.clearRetainingCapacity();

            if (self.memory_strategy) |ms| {
                ms.releaseConnection(self);
            } else {
                self.deinit(self.allocator);
                self.allocator.destroy(self);
            }
        }
    }

    pub fn reset(self: *Connection) void {
        self.id = 0;
        if (self.user_id) |uid| self.allocator.free(uid);
        self.user_id = null;
        self.namespace = "default";
        self.subscription_ids.clearRetainingCapacity();
        self.ws = .{ .ws = null, .ssl = false };
        self.ref_count.store(1, .monotonic);
        // Mutex remains initialized and doesn't need to be reassigned
    }
};

/// Message type for pooling
pub const Message = struct {
    data: [64 * 1024]u8,
    len: usize,

    pub fn init(self: *Message, _: Allocator) void {
        self.len = 0;
    }

    pub fn reset(self: *Message) void {
        self.len = 0;
    }
};

/// Buffer type for pooling
pub const Buffer = [64 * 1024]u8;
