const std = @import("std");
const Allocator = std.mem.Allocator;
const doc_id = @import("doc_id.zig");
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

pub const unset_namespace_id: i64 = -1;

/// Connection represents a single client session.
/// It is ref-counted and decoupled from the network/storage infrastructure.
pub const Connection = struct {
    pub const StoreSession = struct {
        namespace_id: i64,
        user_doc_id: doc_id.DocId,
        ready: bool,
    };

    /// Allocator used for internal metadata (user_id, subscription_ids)
    allocator: Allocator,

    /// Unique identifier for this connection
    id: u64,

    /// External identity string from auth or the SDK anonymous client id.
    user_id: ?[]const u8,

    /// Resolved namespace ID for this connection's active store scope.
    namespace_id: i64,

    /// Resolved users.id for writes in the active store scope.
    user_doc_id: doc_id.DocId,

    /// True only after namespace and scoped users.id resolution completed.
    store_ready: bool,

    /// Incremented whenever the active store scope is reset.
    scope_seq: u64,

    /// List of active subscription IDs for this connection
    subscription_ids: std.ArrayListUnmanaged(u64),

    /// Monotonic subscription ID generator (per active session)
    next_subscription_id: u64,

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
        self.namespace_id = unset_namespace_id;
        self.user_doc_id = doc_id.zero;
        self.store_ready = false;
        self.scope_seq = 0;
        self.subscription_ids = .empty;
        self.next_subscription_id = 1;
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

    /// Reset session-specific state and free dynamic memory.
    /// Retains capacity in subscription_ids for future reuse.
    pub fn resetSession(self: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.resetSessionLocked();
    }

    /// Reset session-specific state while the caller already holds mutex.
    pub fn resetSessionLocked(self: *Connection) void {
        if (self.user_id) |uid| self.allocator.free(uid);
        self.user_id = null;
        self.resetStoreScopeLocked();
        self.subscription_ids.clearRetainingCapacity();
        self.next_subscription_id = 1;
    }

    /// Set the transport external identity. Scoped users.id resolution happens later.
    pub fn setExternalUserId(self: *Connection, external_user_id: []const u8) !void {
        if (external_user_id.len == 0) return error.MissingExternalIdentity;

        const owned = try self.allocator.dupe(u8, external_user_id);
        errdefer self.allocator.free(owned);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.user_id) |old| self.allocator.free(old);
        self.user_id = owned;
        self.resetStoreScopeLocked();
    }

    pub fn dupeExternalUserId(self: *Connection, allocator: Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const external_user_id = self.user_id orelse return error.MissingExternalIdentity;
        return allocator.dupe(u8, external_user_id);
    }

    pub fn resetStoreScopeLocked(self: *Connection) void {
        self.namespace_id = unset_namespace_id;
        self.user_doc_id = doc_id.zero;
        self.store_ready = false;
        self.scope_seq +%= 1;
    }

    pub fn resetStoreScope(self: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.resetStoreScopeLocked();
    }

    /// Replace the active store scope after namespace and users.id resolution.
    pub fn setStoreScope(self: *Connection, namespace_id: i64, user_doc_id: doc_id.DocId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.namespace_id = namespace_id;
        self.user_doc_id = user_doc_id;
        self.store_ready = true;
    }

    pub fn setStoreScopeIfSeq(self: *Connection, expected_scope_seq: u64, namespace_id: i64, user_doc_id: doc_id.DocId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.scope_seq != expected_scope_seq) return false;
        self.namespace_id = namespace_id;
        self.user_doc_id = user_doc_id;
        self.store_ready = true;
        return true;
    }

    pub fn isScopeSeqCurrent(self: *Connection, expected_scope_seq: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.scope_seq == expected_scope_seq;
    }

    pub fn getStoreSession(self: *Connection) StoreSession {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .namespace_id = self.namespace_id,
            .user_doc_id = self.user_doc_id,
            .ready = self.store_ready,
        };
    }

    /// Allocate the next subscription ID in O(1) time.
    /// Thread-safe: Acquires connection's internal mutex.
    /// Returns error.SubscriptionIdExhausted if the counter wraps.
    pub fn allocateSubscriptionId(self: *Connection) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next_subscription_id == 0) return error.SubscriptionIdExhausted;

        const id = self.next_subscription_id;
        self.next_subscription_id +%= 1;
        return id;
    }

    /// Thread-safe: Acquires connection's internal mutex to append a subscription ID.
    pub fn addSubscription(self: *Connection, sub_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.subscription_ids.append(self.allocator, sub_id);
    }

    /// Thread-safe: Acquires connection's internal mutex to remove a subscription ID.
    pub fn removeSubscription(self: *Connection, sub_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscription_ids.items, 0..) |tracked_id, i| {
            if (tracked_id == sub_id) {
                _ = self.subscription_ids.swapRemove(i);
                break;
            }
        }
    }

    /// Result of detaching subscription IDs from a connection.
    /// `ids` is the valid slice; `allocated` is the full allocated buffer used for freeing.
    pub const DetachedSubscriptions = struct {
        ids: []u64,
        allocated: []u64,

        pub fn deinit(self: DetachedSubscriptions, allocator: Allocator) void {
            allocator.free(self.allocated);
        }
    };

    /// Transfer ownership of the subscription IDs buffer to the caller,
    /// leaving the connection with an empty list. Zero-allocation.
    /// Caller must hold self.mutex.
    pub fn detachSubscriptionsLocked(self: *Connection) DetachedSubscriptions {
        const result = DetachedSubscriptions{
            .ids = self.subscription_ids.items,
            .allocated = self.subscription_ids.allocatedSlice(),
        };
        self.subscription_ids = .empty;
        return result;
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
