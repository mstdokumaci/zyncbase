const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed.zig");
const uws = @import("../uwebsockets_wrapper.zig");
const Session = @import("session.zig").Session;
const WebSocket = uws.WebSocket;

const empty_claims: std.StringHashMapUnmanaged(typed.Value) = .{};

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
    session: ?Session,
    namespace_id: i64,
    store_namespace: ?[]const u8,
    pending_store_namespace: ?[]const u8,
    user_doc_id: typed.DocId,
    store_ready: bool,
    scope_seq: u64,
    presence_namespace: ?[]const u8,
    pending_presence_namespace: ?[]const u8,
    presence_namespace_id: i64,
    presence_ready: bool,
    presence_scope_seq: u64,
    subscription_ids: std.ArrayListUnmanaged(u64),
    next_subscription_id: u64,
    ws: WebSocket,
    outbox: Outbox = Outbox.empty,
    is_backpressured: bool = false,
    ref_count: std.atomic.Value(usize),
    created_at: i64,
    request_tokens: u64,
    last_request_time: ?i64,

    pub fn initPool(self: *Connection, allocator: Allocator) void {
        self.allocator = allocator;
        self.session = null;
        self.namespace_id = unset_namespace_id;
        self.store_namespace = null;
        self.pending_store_namespace = null;
        self.user_doc_id = typed.zeroDocId;
        self.store_ready = false;
        self.scope_seq = 0;
        self.presence_namespace = null;
        self.pending_presence_namespace = null;
        self.presence_namespace_id = unset_namespace_id;
        self.presence_ready = false;
        self.presence_scope_seq = 0;
        self.subscription_ids = .empty;
        self.next_subscription_id = 1;
        self.ref_count = std.atomic.Value(usize).init(0);
        self.outbox = Outbox.empty;
        self.is_backpressured = false;
    }

    /// One-time initialization for a connection object in a pool, with pre-allocated
    /// subscription capacity to avoid per-subscription heap allocations on the event
    /// loop thread. Propagates OutOfMemory if pre-allocation fails.
    pub fn initPoolWithCapacity(self: *Connection, allocator: Allocator) !void {
        self.initPool(allocator);
        // Pre-allocate a small initial capacity so the first few addSubscription
        // calls on the event loop thread don't trigger heap allocations.
        try self.subscription_ids.ensureTotalCapacity(allocator, 16);
    }

    /// Activate a pooled connection for a new client session.
    pub fn activate(self: *Connection, id: u64, ws: WebSocket) void {
        self.resetSession();
        self.id = id;
        self.ws = ws;
        self.ref_count.store(1, .release);
        self.created_at = std.time.timestamp();
        self.request_tokens = 0;
        self.last_request_time = null;
    }

    /// Reset session-specific state and free dynamic memory.
    pub fn resetSession(self: *Connection) void {
        self.resetSessionLocked();
    }

    pub fn resetSessionLocked(self: *Connection) void {
        if (self.session) |*sess| sess.deinit(self.allocator);
        self.session = null;
        self.resetStoreScopeLocked();
        self.resetPresenceScopeLocked();
        self.subscription_ids.clearRetainingCapacity();
        self.next_subscription_id = 1;
        self.outbox.deinit(self.allocator);
        self.is_backpressured = false;
    }

    pub fn setSession(self: *Connection, sess: Session) void {
        if (self.session) |*old| {
            old.deinit(self.allocator);
        }
        self.session = sess;
        self.resetStoreScopeLocked();
        self.resetPresenceScopeLocked();
    }

    pub fn updateSessionClaims(self: *Connection, new_claims: std.StringHashMapUnmanaged(typed.Value), token_expires_at: i64) void {
        std.debug.assert(self.session != null);
        const sess = &self.session.?;
        var it = sess.claims.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        sess.claims.deinit(self.allocator);
        sess.claims = new_claims;
        sess.token_expires_at = token_expires_at;
    }

    pub fn dupeExternalUserId(self: *Connection, allocator: Allocator) ![]const u8 {
        const sess = self.session orelse return error.MissingExternalIdentity;
        return allocator.dupe(u8, sess.external_id);
    }

    pub fn getExternalUserId(self: *Connection) ?[]const u8 {
        if (self.session) |sess| return sess.external_id;
        return null;
    }

    pub fn getSessionClaimsPtr(self: *Connection) *const std.StringHashMapUnmanaged(typed.Value) {
        if (self.session) |*sess| return &sess.claims;
        return &empty_claims;
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

    pub fn resetPresenceScopeLocked(self: *Connection) void {
        if (self.presence_namespace) |ns| self.allocator.free(ns);
        if (self.pending_presence_namespace) |ns| self.allocator.free(ns);
        self.presence_namespace_id = unset_namespace_id;
        self.presence_namespace = null;
        self.pending_presence_namespace = null;
        self.presence_ready = false;
        self.presence_scope_seq +%= 1;
    }

    pub fn beginStoreScopeResolutionLocked(self: *Connection, namespace: []const u8) void {
        self.resetStoreScopeLocked();
        self.pending_store_namespace = namespace;
    }

    pub fn beginPresenceScopeResolutionLocked(self: *Connection, namespace: []const u8) void {
        self.resetPresenceScopeLocked();
        self.pending_presence_namespace = namespace;
    }

    pub fn resetStoreScope(self: *Connection) void {
        self.resetStoreScopeLocked();
    }

    /// Replace the active store scope after namespace and users.id resolution.
    pub fn setStoreScope(self: *Connection, namespace_id: i64, user_doc_id: typed.DocId) void {
        self.namespace_id = namespace_id;
        self.user_doc_id = user_doc_id;
        self.store_ready = true;
    }

    pub fn setStoreScopeForNamespace(self: *Connection, namespace: []const u8, namespace_id: i64, user_doc_id: typed.DocId) !void {
        const namespace_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(namespace_owned);

        if (self.store_namespace) |ns| self.allocator.free(ns);
        if (self.pending_store_namespace) |ns| self.allocator.free(ns);
        self.store_namespace = namespace_owned;
        self.pending_store_namespace = null;
        self.namespace_id = namespace_id;
        self.user_doc_id = user_doc_id;
        self.store_ready = true;
    }

    pub fn setScopeIfSeq(self: *Connection, expected_scope_seq: u64, namespace_id: i64, user_doc_id: typed.DocId, is_presence: bool) bool {
        if (is_presence) {
            if (self.presence_scope_seq != expected_scope_seq) return false;
            if (self.presence_namespace) |ns| self.allocator.free(ns);
            self.presence_namespace = self.pending_presence_namespace;
            self.pending_presence_namespace = null;
            self.presence_namespace_id = namespace_id;
            self.user_doc_id = user_doc_id;
            self.presence_ready = true;
        } else {
            if (self.scope_seq != expected_scope_seq) return false;
            if (self.store_namespace) |ns| self.allocator.free(ns);
            self.store_namespace = self.pending_store_namespace;
            self.pending_store_namespace = null;
            self.namespace_id = namespace_id;
            self.user_doc_id = user_doc_id;
            self.store_ready = true;
        }
        return true;
    }

    pub fn resetScopeIfSeq(self: *Connection, expected_scope_seq: u64, is_presence: bool) bool {
        if (is_presence) {
            if (self.presence_scope_seq != expected_scope_seq) return false;
            self.resetPresenceScopeLocked();
        } else {
            if (self.scope_seq != expected_scope_seq) return false;
            self.resetStoreScopeLocked();
        }
        return true;
    }

    pub fn isScopeSeqCurrentFor(self: *Connection, expected_scope_seq: u64, is_presence: bool) bool {
        if (is_presence) return self.presence_scope_seq == expected_scope_seq;
        return self.scope_seq == expected_scope_seq;
    }

    pub fn getStoreNamespace(self: *Connection) ?[]const u8 {
        return self.store_namespace;
    }

    pub fn dupeStoreNamespace(self: *Connection, allocator: Allocator) !?[]const u8 {
        const namespace = self.store_namespace orelse return null;
        return @as(?[]const u8, try allocator.dupe(u8, namespace));
    }

    pub fn dupePendingNamespaceIfSeq(self: *Connection, allocator: Allocator, expected_scope_seq: u64, is_presence: bool) !?[]const u8 {
        if (is_presence) {
            if (self.presence_scope_seq != expected_scope_seq) return null;
            const namespace = self.pending_presence_namespace orelse return null;
            return @as(?[]const u8, try allocator.dupe(u8, namespace));
        } else {
            if (self.scope_seq != expected_scope_seq) return null;
            const namespace = self.pending_store_namespace orelse return null;
            return @as(?[]const u8, try allocator.dupe(u8, namespace));
        }
    }

    pub fn getStoreSession(self: *Connection) StoreSession {
        return .{
            .namespace_id = self.namespace_id,
            .user_doc_id = self.user_doc_id,
            .ready = self.store_ready,
        };
    }

    pub fn resetPresenceScope(self: *Connection) void {
        self.resetPresenceScopeLocked();
    }

    pub fn getPresenceNamespace(self: *Connection) ?[]const u8 {
        return self.presence_namespace;
    }

    pub fn dupePresenceNamespace(self: *Connection, allocator: Allocator) !?[]const u8 {
        const namespace = self.presence_namespace orelse return null;
        return @as(?[]const u8, try allocator.dupe(u8, namespace));
    }

    /// Allocate the next subscription ID in O(1) time.
    pub fn allocateSubscriptionId(self: *Connection) !u64 {
        if (self.next_subscription_id == 0) return error.SubscriptionIdExhausted;

        const id = self.next_subscription_id;
        self.next_subscription_id +%= 1;
        return id;
    }

    /// Append a subscription ID.
    pub fn addSubscription(self: *Connection, sub_id: u64) !void {
        try self.subscription_ids.append(self.allocator, sub_id);
    }

    /// Remove a subscription ID.
    pub fn removeSubscription(self: *Connection, sub_id: u64) void {
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
        if (self.session) |*sess| sess.deinit(self.allocator);
        if (self.store_namespace) |ns| self.allocator.free(ns);
        if (self.pending_store_namespace) |ns| self.allocator.free(ns);
        if (self.presence_namespace) |ns| self.allocator.free(ns);
        if (self.pending_presence_namespace) |ns| self.allocator.free(ns);
        self.subscription_ids.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
    }

    /// Send a message to the client. Must be called from the event loop thread.
    ///
    /// Fast path: direct send when not backpressured. On BACKPRESSURE, sets the flag
    /// and enqueues subsequent messages to preserve ordering until drain clears it.
    /// Returns error.Dropped (connection dead) or error.Full (slow client) — both require close.
    pub fn send(self: *Connection, data: []const u8) !void {
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
