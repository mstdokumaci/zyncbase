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
    arena_pool: Pool(std.heap.ArenaAllocator),

    /// Object pools for high-churn objects to avoid allocation overhead
    message_pool: Pool(Message),
    buffer_pool: Pool(Buffer),
    connection_pool: Pool(Connection),

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
    pub fn init(allocator: Allocator) !MemoryStrategy {
        const current_config = if (builtin.is_test) Config.minimal_config else Config.default_config;
        return initWithConfig(allocator, current_config);
    }

    /// Initialize the memory strategy with specific configuration.
    pub fn initWithConfig(allocator: Allocator, config: Config) !MemoryStrategy {
        const gpa_ptr = try allocator.create(std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }));
        errdefer allocator.destroy(gpa_ptr);
        gpa_ptr.* = .{};

        const gpa_alloc = gpa_ptr.allocator();
        var self = MemoryStrategy{
            .parent_allocator = allocator,
            .gpa = gpa_ptr,
            .arena_pool = try Pool(std.heap.ArenaAllocator).init(
                gpa_alloc,
                config.arena_pool.max_capacity,
                deinitArena,
                initArena,
            ),
            .message_pool = try Pool(Message).init(
                gpa_alloc,
                config.message_pool.max_capacity,
                deinitMessage,
                null,
            ),
            .buffer_pool = try Pool(Buffer).init(
                gpa_alloc,
                config.buffer_pool.max_capacity,
                null,
                null,
            ),
            .connection_pool = try Pool(Connection).init(
                gpa_alloc,
                config.connection_pool.max_capacity,
                deinitConnection,
                null,
            ),
        };

        // Once 'self' and its pools are initialized, we can use deinit() for cleanup
        errdefer self.deinit();

        // Pre-allocate arenas based on configuration
        for (0..config.arena_pool.pre_allocate) |_| {
            try self.arena_pool.pushInitial(std.heap.ArenaAllocator.init(gpa_alloc));
        }

        // Handle other possible pre-allocations if needed by the config
        for (0..config.message_pool.pre_allocate) |_| {
            try self.message_pool.pushInitial(Message.init(gpa_alloc));
        }

        return self;
    }

    /// Deinitialize the memory strategy and free all resources
    pub fn deinit(self: *MemoryStrategy) void {
        const gpa_alloc = self.gpa.allocator();

        // Drain and destroy arenas
        while (self.arena_pool.pop()) |*arena| {
            arena.deinit();
        }

        // Drain and destroy connections
        while (self.connection_pool.pop()) |*conn| {
            var c = conn.*;
            c.deinit(gpa_alloc);
        }

        // Deinit pools (this frees the Nodes themselves)
        self.arena_pool.deinit();
        self.message_pool.deinit();
        self.buffer_pool.deinit();
        self.connection_pool.deinit();

        _ = self.gpa.deinit();
        self.parent_allocator.destroy(self.gpa);
    }

    fn initArena(alloc: Allocator) std.heap.ArenaAllocator {
        return std.heap.ArenaAllocator.init(alloc);
    }

    fn deinitArena(_: Allocator, arena: *std.heap.ArenaAllocator) void {
        arena.deinit();
    }

    fn deinitMessage(_: Allocator, msg: *Message) void {
        msg.reset();
    }

    fn deinitConnection(alloc: Allocator, conn: *Connection) void {
        conn.deinit(alloc);
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
        const conn = try self.acquireConnection();
        conn.reset();
        conn.memory_strategy = self;
        conn.allocator = self.generalAllocator();
        conn.id = id;
        conn.ws = ws;
        conn.created_at = std.time.timestamp();
        return conn;
    }

    /// Generic object pool for reusing fixed-size objects.
    /// Uses a lock-free atomic stack to avoid mutex contention.
    pub fn Pool(comptime T: type) type { // zwanzig-disable-line: unused-parameter identifier-style
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

            /// Atomic head with ABA prevention
            head: std.atomic.Value(u128),
            allocator: Allocator,
            maxCapacity: u32,
            deinitData: ?*const fn (Allocator, *T) void,
            initData: ?*const fn (Allocator) T,

            /// Initialize the pool
            pub fn init(
                allocator: Allocator,
                maxCapacity: u32,
                deinitData: ?*const fn (Allocator, *T) void,
                initData: ?*const fn (Allocator) T,
            ) !Self {
                return Self{
                    .head = std.atomic.Value(u128).init(0),
                    .allocator = allocator,
                    .maxCapacity = maxCapacity,
                    .deinitData = deinitData,
                    .initData = initData,
                };
            }

            /// Deinitialize the pool and free all memory
            pub fn deinit(self: *Self) void {
                const final_head_u128 = self.head.swap(0, .acquire);
                const state: CombinedState = @bitCast(final_head_u128);
                var current_node = state.ptr;
                while (current_node) |node| {
                    const next_node = node.next.load(.acquire);
                    self.allocator.destroy(node);
                    current_node = next_node;
                }
            }

            /// Internal method to push initial nodes
            pub fn pushInitial(self: *Self, data: T) !void {
                const node = try self.allocator.create(Node);
                node.next = std.atomic.Value(?*Node).init(null);
                node.data = data;
                self.release(&node.data);
            }

            /// Pop an object from the pool without allocating new ones
            pub fn pop(self: *Self) ?T {
                var current_head = self.head.load(.acquire);
                while (true) {
                    const state: CombinedState = @bitCast(current_head);
                    if (state.ptr) |node| {
                        const next_node_ptr = node.next.load(.acquire);
                        const next_head = CombinedState{
                            .ptr = next_node_ptr,
                            .gen = state.gen + 1,
                            .count = if (state.count > 0) state.count - 1 else 0,
                        };
                        const next_u128: u128 = @bitCast(next_head);
                        if (self.head.cmpxchgWeak(current_head, next_u128, .acquire, .monotonic)) |latest| {
                            current_head = latest;
                            continue;
                        }
                        const data = node.data;
                        self.allocator.destroy(node);
                        return data;
                    } else return null;
                }
            }

            /// Acquire an object from the pool
            pub fn acquire(self: *Self) !*T { // zwanzig-disable-line: stack-escape-engine
                var current_head = self.head.load(.acquire);
                while (true) {
                    const state: CombinedState = @bitCast(current_head);
                    if (state.ptr) |node| {
                        const next_node_ptr = node.next.load(.acquire);
                        const next_head = CombinedState{
                            .ptr = next_node_ptr,
                            .gen = state.gen + 1,
                            .count = if (state.count > 0) state.count - 1 else 0,
                        };
                        const next_u128: u128 = @bitCast(next_head);
                        if (self.head.cmpxchgWeak(current_head, next_u128, .acquire, .monotonic)) |latest| {
                            current_head = latest;
                            continue;
                        }
                        return &node.data;
                    } else {
                        // Pool empty, allocate new node
                        const node = try self.allocator.create(Node);
                        node.next = std.atomic.Value(?*Node).init(null);

                        // Initialize data using callback or default
                        if (self.initData) |initData| {
                            node.data = initData(self.allocator);
                        } else {
                            node.data = undefined;
                            if (comptime @typeInfo(T) != .pointer) {
                                @memset(std.mem.asBytes(&node.data), 0);
                            }
                        }

                        return &node.data;
                    }
                }
            }

            /// Release an object back to the pool
            pub fn release(self: *Self, data: *T) void {
                const node: *Node = @alignCast(@fieldParentPtr("data", data));
                var current_head = self.head.load(.acquire);
                while (true) {
                    const state: CombinedState = @bitCast(current_head);

                    // Enforce capacity bounding
                    if (state.count >= self.maxCapacity) {
                        if (self.deinitData) |deinitData| {
                            deinitData(self.allocator, &node.data);
                        }
                        self.allocator.destroy(node);
                        return;
                    }

                    node.next.store(state.ptr, .release);
                    const next_head = CombinedState{
                        .ptr = node,
                        .gen = state.gen + 1,
                        .count = state.count + 1,
                    };
                    const next_u128: u128 = @bitCast(next_head);
                    if (self.head.cmpxchgWeak(current_head, next_u128, .release, .monotonic)) |latest| {
                        current_head = latest;
                        continue;
                    }
                    break;
                }
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

    pub fn init(allocator: Allocator, id: u64, ws: WebSocket) !*Connection {
        const self = try allocator.create(Connection);
        self.* = .{
            .allocator = allocator,
            .memory_strategy = null,
            .id = id,
            .user_id = null,
            .namespace = "default",
            .subscription_ids = .empty,
            .ws = ws,
            .ref_count = std.atomic.Value(usize).init(1),
            .mutex = .{},
            .created_at = std.time.timestamp(),
        };
        return self;
    }

    pub fn deinit(self: *Connection, allocator: Allocator) void {
        if (self.user_id) |uid| allocator.free(uid);
        self.subscription_ids.deinit(allocator);
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
        self.user_id = null;
        self.namespace = "default";
        self.subscription_ids.clearRetainingCapacity();
        self.ws = .{ .ws = null, .ssl = false };
        self.ref_count.store(1, .monotonic);
        self.mutex = .{};
    }
};

/// Message type for pooling
pub const Message = struct {
    data: [64 * 1024]u8,
    len: usize,

    pub fn init(_: Allocator) Message {
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
pub const Buffer = [64 * 1024]u8;
