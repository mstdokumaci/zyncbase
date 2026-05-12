const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const uws = @import("uwebsockets_wrapper.zig");
const WebSocket = uws.WebSocket;

/// Capacity of the per-connection outbox ring buffer (max queued messages).
/// One slot is always reserved as the sentinel, so effective capacity is
/// outbox_capacity - 1 = 15 messages.
const outbox_capacity = 16;

/// Result returned by Outbox.flush().
pub const FlushResult = enum {
    /// All queued messages were sent successfully.
    success,
    /// uWS accepted the last frame but its internal buffer is now full.
    /// The drain callback will fire when space is available; call flush() again then.
    backpressure,
    /// uWS dropped a frame — the connection is dead. Close it.
    dropped,
};

/// Per-connection bounded ring buffer for outgoing subscription deltas.
///
/// Design contract:
///   - On SUCCESS  → frame delivered; advance tail, continue.
///   - On BACKPRESSURE → uWS already owns the frame internally; free our copy,
///                       advance tail, then STOP sending more until drain fires.
///   - On DROPPED  → connection is dead; drain the queue (free memory) and
///                   signal the caller to close the connection.
pub const Outbox = struct {
    entries: [outbox_capacity][]u8,
    head: usize, // index of next write slot
    tail: usize, // index of next read slot

    /// Zero-initialized empty outbox. All entry slots are zeroed so the struct
    /// is safe to copy and inspect regardless of head/tail state.
    pub const empty: Outbox = .{
        .entries = std.mem.zeroes([outbox_capacity][]u8),
        .head = 0,
        .tail = 0,
    };

    pub fn enqueue(self: *Outbox, allocator: Allocator, data: []const u8) !void {
        const next = (self.head + 1) % outbox_capacity;
        if (next == self.tail) return error.Full;
        self.entries[self.head] = try allocator.dupe(u8, data);
        self.head = next;
    }

    /// Flush as many queued messages as possible.
    /// Stops early on BACKPRESSURE (uWS will call drain when ready) or DROPPED
    /// (connection dead — caller must close).
    pub fn flush(self: *Outbox, ws: *WebSocket, allocator: Allocator) FlushResult {
        while (self.tail != self.head) {
            const data = self.entries[self.tail];
            const status = ws.send(data, .binary);
            // Always free our copy — uWS owns the frame from this point on
            // regardless of status (it either delivered it, buffered it, or dropped it).
            allocator.free(data);
            self.tail = (self.tail + 1) % outbox_capacity;
            switch (status) {
                .success => {}, // continue sending
                .backpressure => return .backpressure, // stop; drain callback will resume
                .dropped => {
                    // Free remaining queued entries and signal close.
                    self.deinit(allocator);
                    return .dropped;
                },
            }
        }
        return .success;
    }

    /// Free all queued entries without sending. Used on connection close/reset.
    pub fn deinit(self: *Outbox, allocator: Allocator) void {
        while (self.tail != self.head) {
            allocator.free(self.entries[self.tail]);
            self.tail = (self.tail + 1) % outbox_capacity;
        }
    }

    pub fn isEmpty(self: Outbox) bool {
        return self.tail == self.head;
    }

    pub fn isFull(self: Outbox) bool {
        return (self.head + 1) % outbox_capacity == self.tail;
    }
};

pub const unset_namespace_id: i64 = -1;

/// Connection represents a single client session.
/// It is ref-counted and decoupled from the network/storage infrastructure.
pub const Connection = struct {
    pub const StoreSession = struct {
        namespace_id: i64,
        user_doc_id: typed.DocId,
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

    /// Active store namespace string, promoted after scope resolution succeeds.
    store_namespace: ?[]const u8,

    /// Store namespace string awaiting async scope resolution.
    pending_store_namespace: ?[]const u8,

    /// Resolved users.id for writes in the active store scope.
    user_doc_id: typed.DocId,

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

    /// Per-connection send queue flushed by the drain callback
    outbox: Outbox = Outbox.empty,

    /// Set when uWS returns BACKPRESSURE on a direct send.
    /// While true, all deltas are enqueued rather than sent directly.
    /// Cleared by flushOutbox() after a complete drain.
    is_backpressured: bool = false,

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
        self.store_namespace = null;
        self.pending_store_namespace = null;
        self.user_doc_id = typed.zeroDocId;
        self.store_ready = false;
        self.scope_seq = 0;
        self.subscription_ids = .empty;
        self.next_subscription_id = 1;
        self.mutex = .{};
        self.ref_count = std.atomic.Value(usize).init(0);
        self.outbox = Outbox.empty;
        self.is_backpressured = false;
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
        // Drain any queued outbox entries so a reused pooled connection starts clean.
        self.outbox.deinit(self.allocator);
        self.is_backpressured = false;
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
        if (self.store_namespace) |ns| self.allocator.free(ns);
        if (self.pending_store_namespace) |ns| self.allocator.free(ns);
        self.namespace_id = unset_namespace_id;
        self.store_namespace = null;
        self.pending_store_namespace = null;
        self.user_doc_id = typed.zeroDocId;
        self.store_ready = false;
        self.scope_seq +%= 1;
    }

    pub fn beginStoreScopeResolutionLocked(self: *Connection, namespace: []const u8) void {
        self.resetStoreScopeLocked();
        self.pending_store_namespace = namespace;
    }

    pub fn resetStoreScope(self: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.resetStoreScopeLocked();
    }

    /// Replace the active store scope after namespace and users.id resolution.
    pub fn setStoreScope(self: *Connection, namespace_id: i64, user_doc_id: typed.DocId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.namespace_id = namespace_id;
        self.user_doc_id = user_doc_id;
        self.store_ready = true;
    }

    pub fn setStoreScopeForNamespace(self: *Connection, namespace: []const u8, namespace_id: i64, user_doc_id: typed.DocId) !void {
        const namespace_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(namespace_owned);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.store_namespace) |ns| self.allocator.free(ns);
        if (self.pending_store_namespace) |ns| self.allocator.free(ns);
        self.store_namespace = namespace_owned;
        self.pending_store_namespace = null;
        self.namespace_id = namespace_id;
        self.user_doc_id = user_doc_id;
        self.store_ready = true;
    }

    pub fn setStoreScopeIfSeq(self: *Connection, expected_scope_seq: u64, namespace_id: i64, user_doc_id: typed.DocId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.scope_seq != expected_scope_seq) return false;
        if (self.store_namespace) |ns| self.allocator.free(ns);
        self.store_namespace = self.pending_store_namespace;
        self.pending_store_namespace = null;
        self.namespace_id = namespace_id;
        self.user_doc_id = user_doc_id;
        self.store_ready = true;
        return true;
    }

    pub fn resetStoreScopeIfSeq(self: *Connection, expected_scope_seq: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.scope_seq != expected_scope_seq) return false;
        self.resetStoreScopeLocked();
        return true;
    }

    pub fn isScopeSeqCurrent(self: *Connection, expected_scope_seq: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.scope_seq == expected_scope_seq;
    }

    pub fn dupeStoreNamespace(self: *Connection, allocator: Allocator) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const namespace = self.store_namespace orelse return null;
        return @as(?[]const u8, try allocator.dupe(u8, namespace));
    }

    pub fn dupePendingStoreNamespaceIfSeq(self: *Connection, allocator: Allocator, expected_scope_seq: u64) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.scope_seq != expected_scope_seq) return null;
        const namespace = self.pending_store_namespace orelse return null;
        return @as(?[]const u8, try allocator.dupe(u8, namespace));
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
        self.outbox.deinit(self.allocator);
    }

    /// Send a direct response or handshake message (not a subscription delta).
    /// These messages bypass the outbox — they are one-shot replies to client requests.
    ///
    /// Returns error.Dropped when uWS signals the connection is dead — the caller
    /// should close the connection.
    /// BACKPRESSURE is treated as success here: uWS has buffered the frame and will
    /// deliver it; no further action is needed from the caller.
    pub fn sendDirect(self: *Connection, data: []const u8) error{Dropped}!void {
        return switch (self.ws.send(data, .binary)) {
            .success, .backpressure => {},
            .dropped => error.Dropped,
        };
    }

    /// Send a subscription delta through the outbox.
    ///
    /// When not backpressured, attempts a direct send first to avoid the
    /// allocation cost of enqueue on the common (no-backpressure) case.
    /// On BACKPRESSURE, sets the backpressure flag and enqueues the message
    /// so the drain callback can flush it in order.
    ///
    /// Returns error.Dropped when uWS signals the connection is dead — the caller
    /// must close the connection.
    /// Returns error.Full when the outbox capacity is exhausted — the caller must
    /// close the connection (slow client policy).
    pub fn trySendDelta(self: *Connection, data: []const u8) !void {
        if (!self.is_backpressured) {
            // Fast path: try direct send first.
            switch (self.ws.send(data, .binary)) {
                .success => return,
                .backpressure => {
                    // uWS buffered this frame internally. Mark backpressured so
                    // subsequent deltas are queued until drain fires.
                    self.is_backpressured = true;
                    return;
                },
                .dropped => return error.Dropped,
            }
        }

        // We're in backpressure — enqueue and let the drain callback flush in order.
        if (self.outbox.isFull()) return error.Full;
        try self.outbox.enqueue(self.allocator, data);
    }

    /// Called by the drain callback when the uWS send buffer has cleared.
    /// Returns FlushResult so the caller can close the connection on .dropped.
    /// Clears the backpressure flag on a complete successful flush.
    pub fn flushOutbox(self: *Connection) FlushResult {
        const result = self.outbox.flush(&self.ws, self.allocator);
        if (result == .success) {
            // Buffer fully drained — resume direct sends.
            self.is_backpressured = false;
        }
        return result;
    }
};
