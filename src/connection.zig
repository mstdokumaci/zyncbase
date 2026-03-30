const std = @import("std");
const Allocator = std.mem.Allocator;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

/// Connection represents a single client session.
/// It is ref-counted and decoupled from the network/storage infrastructure.
pub const Connection = struct {
    /// Allocator used for internal metadata (user_id, subscription_ids)
    allocator: Allocator,

    /// Unique identifier for this connection
    id: u64,

    /// Optional user identity after authentication
    user_id: ?[]const u8,

    /// Namespace this connection is currently operating in
    namespace: []const u8,

    /// List of active subscription IDs for this connection
    subscription_ids: std.ArrayListUnmanaged(u64),

    /// Low-level WebSocket handle
    ws: WebSocket,

    /// Reference count for thread-safe memory management
    ref_count: std.atomic.Value(usize),

    /// Mutex for protecting connection metadata during concurrent access
    mutex: std.Thread.Mutex,

    /// Timestamp of when the connection was established
    created_at: i64,

    /// Rate limiting: Current available tokens
    request_tokens: f64,

    /// Rate limiting: Last time tokens were replenished
    last_request_time: ?i64,

    /// One-time initialization for a connection object in a pool.
    /// Sets up stable infrastructure (mutex, allocator).
    pub fn initPool(self: *Connection, allocator: Allocator) void {
        self.allocator = allocator;
        self.user_id = null;
        self.subscription_ids = .empty;
        self.mutex = .{};
        self.ref_count = std.atomic.Value(usize).init(0);
    }

    /// Activate a pooled connection for a new client session.
    /// Resets dynamic fields and preserves allocated capacities for reuse.
    pub fn activate(self: *Connection, id: u64, ws: WebSocket) void {
        self.resetSession();
        self.id = id;
        self.ws = ws;
        self.ref_count.store(1, .release);
        self.created_at = std.time.timestamp();
        self.request_tokens = 0.0;
        self.last_request_time = null;
    }

    /// Reset session-specific state and free dynamic memory (user_id).
    /// Retains capacity in subscription_ids for future reuse.
    pub fn resetSession(self: *Connection) void {
        if (self.user_id) |uid| self.allocator.free(uid);
        self.user_id = null;
        self.namespace = "default";
        self.subscription_ids.clearRetainingCapacity();
    }

    /// Increment the reference count.
    pub fn acquire(self: *Connection) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    /// Decrement the reference count.
    /// Returns true if the count reached zero and the connection should be returned to the pool.
    pub fn release(self: *Connection) bool {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            return true;
        }
        return false;
    }

    /// Fully deinitialize the connection (for heap-allocated or app shutdown).
    /// Full cleanup of connection-owned resources.
    /// Note: This is safe to call after resetSession() (e.g. during pool shutdown)
    /// because resetSession() nullifies user_id and subscription_ids is a standard list.
    pub fn deinit(self: *Connection) void {
        if (self.user_id) |uid| self.allocator.free(uid);
        self.subscription_ids.deinit(self.allocator);
    }
};
