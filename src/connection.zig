const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const uws = @import("uwebsockets_wrapper.zig");
const WebSocket = uws.WebSocket;

// Effective capacity is outbox_capacity - 1 = 15 (one slot reserved as sentinel).
const outbox_capacity = 16;

pub const FlushResult = enum { success, backpressure, dropped };

/// Per-connection bounded ring buffer for outgoing messages.
///
/// Send contract:
///   SUCCESS     → frame delivered; advance and continue.
///   BACKPRESSURE → uWS owns the frame; advance and stop until drain fires.
///   DROPPED     → connection dead; free remaining entries and signal close.
pub const Outbox = struct {
    entries: [outbox_capacity][]u8,
    head: usize,
    tail: usize,

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

    pub fn flush(self: *Outbox, ws: *WebSocket, allocator: Allocator) FlushResult {
        while (self.tail != self.head) {
            const data = self.entries[self.tail];
            const status = ws.send(data, .binary);
            allocator.free(data);
            self.tail = (self.tail + 1) % outbox_capacity;
            switch (status) {
                .success => {},
                .backpressure => return .backpressure,
                .dropped => {
                    self.deinit(allocator);
                    return .dropped;
                },
            }
        }
        return .success;
    }

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

pub const Connection = struct {
    pub const StoreSession = struct {
        namespace_id: i64,
        user_doc_id: typed.DocId,
        ready: bool,
    };

    allocator: Allocator,
    id: u64,
    user_id: ?[]const u8,
    namespace_id: i64,
    store_namespace: ?[]const u8,
    pending_store_namespace: ?[]const u8,
    user_doc_id: typed.DocId,
    store_ready: bool,
    scope_seq: u64,
    subscription_ids: std.ArrayListUnmanaged(u64),
    next_subscription_id: u64,
    ws: WebSocket,
    outbox: Outbox = Outbox.empty,
    /// True while uWS backpressure is active. All sends are queued until drain clears it.
    is_backpressured: bool = false,
    ref_count: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,
    created_at: i64,
    request_tokens: f64,
    last_request_time: ?i64,

    /// One-time initialization for a connection object in a pool.
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

    /// Allocate the next subscription ID in O(1) time. Caller must hold no locks.
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

    pub const DetachedSubscriptions = struct {
        ids: []u64,
        allocated: []u64,

        pub fn deinit(self: DetachedSubscriptions, allocator: Allocator) void {
            allocator.free(self.allocated);
        }
    };

    /// Transfer ownership of the subscription IDs buffer to the caller. Caller must hold mutex.
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

    /// Decrement the reference count. Returns true if it reached zero.
    pub fn release(self: *Connection) bool {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            return true;
        }
        return false;
    }

    pub fn deinit(self: *Connection) void {
        if (self.user_id) |uid| self.allocator.free(uid);
        self.subscription_ids.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
    }

    /// Send a response or handshake message. Must be called from the event loop thread.
    ///
    /// When backpressured, enqueues to preserve ordering with queued deltas.
    /// Returns error.Dropped (connection dead) or error.Full (slow client) — both require close.
    pub fn sendDirect(self: *Connection, data: []const u8) !void {
        if (!self.is_backpressured) {
            switch (self.ws.send(data, .binary)) {
                .success => return,
                .backpressure => {
                    self.is_backpressured = true;
                    return;
                },
                .dropped => return error.Dropped,
            }
        }
        if (self.outbox.isFull()) return error.Full;
        try self.outbox.enqueue(self.allocator, data);
    }

    /// Send a subscription delta. Must be called from the event loop thread.
    ///
    /// Fast path: direct send when not backpressured. On BACKPRESSURE, sets the flag
    /// and queues subsequent messages until the drain callback clears it.
    /// Returns error.Dropped (connection dead) or error.Full (slow client) — both require close.
    pub fn trySendDelta(self: *Connection, data: []const u8) !void {
        if (!self.is_backpressured) {
            switch (self.ws.send(data, .binary)) {
                .success => return,
                .backpressure => {
                    self.is_backpressured = true;
                    return;
                },
                .dropped => return error.Dropped,
            }
        }
        if (self.outbox.isFull()) return error.Full;
        try self.outbox.enqueue(self.allocator, data);
    }

    /// Flush queued messages after uWS signals the send buffer has cleared.
    /// Must be called from the event loop thread. Clears is_backpressured on full drain.
    pub fn flushOutbox(self: *Connection) FlushResult {
        const result = self.outbox.flush(&self.ws, self.allocator);
        if (result == .success) self.is_backpressured = false;
        return result;
    }
};
