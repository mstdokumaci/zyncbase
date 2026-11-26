const std = @import("std");

const uws_timer = @import("../uws_timer.zig");
const wire_encode = @import("../wire/encode.zig");
const wire_errors = @import("../wire/errors.zig");
const ArenaHandle = @import("../memory/strategy.zig").ArenaHandle;
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const MessageHandler = @import("../message_handler.zig").MessageHandler;
const ServerMetrics = @import("../observability/metrics.zig").ServerMetrics;
const Schema = @import("../schema/types.zig").Schema;
const event_loop_count = @import("../thread_budget.zig").event_loop_count;
const Notifier = @import("../threading/notifier.zig").Notifier;
const MessageType = @import("../uwebsockets_wrapper.zig").MessageType;
const WebSocket = @import("../uwebsockets_wrapper.zig").WebSocket;
const c = @import("../uwebsockets_wrapper.zig").c;
const SendQueueType = @import("send_queue.zig").SendQueue;
const Connection = @import("state.zig").Connection;

const Allocator = std.mem.Allocator;

/// Max bytes a single connection may accumulate in one drain pass before it is
/// closed with BACKPRESSURE_LIMIT. A lone entry larger than the cap is a single
/// message, so it is delivered as-is; an oversized entry alongside any other
/// entry is a backlog and closes the connection.
pub const max_pending_group_bytes: usize = 4 * 1024 * 1024;

/// Per-connection drain accumulator for one drain pass.
const Group = struct {
    entries: std.ArrayListUnmanaged([]const u8) = .empty,
    bytes: usize = 0,
    dropped: usize = 0,
    over: bool = false,
};

fn appendToGroup(
    alloc: Allocator,
    groups: *std.AutoHashMapUnmanaged(u64, Group),
    conn_id: u64,
    data: []const u8,
) void {
    const g = groups.getOrPut(alloc, conn_id) catch {
        std.log.warn("drainSendQueue: group alloc failed for conn {}, dropping {} byte entry", .{ conn_id, data.len });
        return;
    };
    if (!g.found_existing) g.value_ptr.* = .{};
    if (g.value_ptr.over) {
        // Cap already crossed: drop further deliveries instead of accumulating
        // so this pass stays bounded no matter how far behind the client is.
        g.value_ptr.dropped += 1;
        return;
    }
    g.value_ptr.entries.append(alloc, data) catch {
        std.log.warn("drainSendQueue: group append failed for conn {}, dropping {} byte entry", .{ conn_id, data.len });
        return;
    };
    g.value_ptr.bytes += data.len;
    const lone_oversized = g.value_ptr.entries.items.len == 1 and data.len > max_pending_group_bytes;
    if (!lone_oversized and g.value_ptr.bytes > max_pending_group_bytes) g.value_ptr.over = true;
}

/// ConnectionManager handles the lifecycle of client sessions and acts as a relay
/// between the raw network events and the application logic (MessageHandler).
pub const ConnectionManager = struct {
    const TokenSweepCtx = struct {
        manager: *ConnectionManager,
        loop_id: u8,
    };
    io: std.Io,
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    message_handler: *MessageHandler,

    /// Map of connection IDs to Connection objects
    map: std.AutoHashMapUnmanaged(u64, *Connection),

    /// Mutex for protecting the map during concurrent access
    mutex: std.Io.Mutex,

    max_connections: usize,

    /// Pre-encoded SchemaSync message sent to every new connection on open.
    schema_sync_msg: []const u8,

    /// Grace period for expired tokens (seconds), used by the timer sweep.
    token_grace_period_seconds: u32,

    /// uWS timers for periodic token expiry sweeps (one per event loop).
    token_sweep_timers: [event_loop_count]?*c.struct_us_timer_t = .{null} ** event_loop_count,
    token_sweep_ctx: [event_loop_count]TokenSweepCtx,

    /// Wake handles by loop id, used to kick the owning reactor after a queued
    /// cross-loop send. Cleared when the reactor exits so a late send can never
    /// touch a freed loop.
    loop_wakes: [event_loop_count]std.atomic.Value(?*c.struct_us_loop_t),
    /// Atomic connection count for cheap shutdown polling (maintained alongside map count).
    active_connection_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Notifier fired when the last connection closes during shutdown.
    last_conn_notifier: Notifier = .{},

    /// Arena for temporary allocations during drainSendQueue grouping.
    drain_arenas: [event_loop_count]std.heap.ArenaAllocator,

    /// Queue used by sendToConnection to reach a connection owned by another
    /// reactor. Null only before the server wires it.
    send_queue: ?*SendQueueType = null,

    metrics: ?*ServerMetrics = null,

    pub fn setMetrics(self: *ConnectionManager, metrics: ?*ServerMetrics) void {
        self.metrics = metrics;
    }
    pub fn setSendQueue(self: *ConnectionManager, send_queue: *SendQueueType) void {
        self.send_queue = send_queue;
    }
    pub fn setLoopWake(self: *ConnectionManager, loop_id: u8, loop: *c.struct_us_loop_t) void {
        std.debug.assert(loop_id < event_loop_count);
        self.loop_wakes[loop_id].store(loop, .release);
    }
    /// Drop the wake handle before the reactor frees its loop.
    pub fn clearLoopWake(self: *ConnectionManager, loop_id: u8) void {
        std.debug.assert(loop_id < event_loop_count);
        self.loop_wakes[loop_id].store(null, .release);
    }
    fn wakeLoop(self: *ConnectionManager, loop_id: u8) void {
        if (self.loop_wakes[loop_id].load(.acquire)) |loop| c.us_wakeup_loop(loop);
    }

    pub fn init(
        self: *ConnectionManager,
        io: std.Io,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        message_handler: *MessageHandler,
        schema: *const Schema,
        max_connections: usize,
        token_grace_period_seconds: u32,
    ) !void {
        // Pre-build SchemaSync message once at startup
        const schema_sync_msg = try wire_encode.encodeSchemaSync(allocator, schema);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .message_handler = message_handler,
            .map = .empty,
            .mutex = .init,
            .max_connections = max_connections,
            .schema_sync_msg = schema_sync_msg,
            .token_grace_period_seconds = token_grace_period_seconds,
            .drain_arenas = .{
                std.heap.ArenaAllocator.init(allocator),
                std.heap.ArenaAllocator.init(allocator),
            },
            .metrics = null,
            // SAFETY: populated for every loop in the loop below before any timer uses it.
            .token_sweep_ctx = undefined,
            // SAFETY: atomics initialized in the loop below before any producer runs.
            .loop_wakes = undefined,
        };
        for (0..event_loop_count) |i| {
            self.token_sweep_ctx[i] = .{ .manager = self, .loop_id = @intCast(i) };
            self.loop_wakes[i] = std.atomic.Value(?*c.struct_us_loop_t).init(null);
        }
    }

    pub fn deinit(self: *ConnectionManager) void {
        self.stopTokenSweepTimer();
        for (&self.drain_arenas) |*arena| arena.deinit();

        self.mutex.lockUncancelable(self.io);
        var it = self.map.valueIterator();
        while (it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            // Ensure all logical cleanup (unsubscriptions) is performed before manager shuts down
            self.message_handler.teardownSession(conn);
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }
        self.map.deinit(self.allocator);
        self.mutex.unlock(self.io);

        self.allocator.free(self.schema_sync_msg);
    }

    pub fn onOpen(self: *ConnectionManager, ws: *WebSocket) !void {
        const conn_id = ws.getConnId();

        self.message_handler.violation_tracker.clearViolations(conn_id);

        var sess = ws.takeSession() orelse {
            std.log.warn("Rejecting connection {}: missing session", .{conn_id});
            ws.close();
            return error.MissingSession;
        };
        var sess_transferred = false;
        errdefer if (!sess_transferred) sess.deinit(self.allocator);
        if (sess.external_id.len == 0) {
            std.log.warn("Rejecting connection {}: empty external identity", .{conn_id});
            ws.close();
            return error.MissingSession;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.count() >= self.max_connections) {
            std.log.warn("Rejecting connection {}: limit reached", .{conn_id});
            sess.deinit(self.allocator);
            sendDisconnectAndEnd(ws, self.allocator, "MAX_CONNECTIONS", "Server connection limit reached.", 4005, self.metrics);
            return;
        }

        const conn = try self.memory_strategy.acquireConnection();
        var inserted = false;
        errdefer if (!inserted) {
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        };

        conn.activate(self.io, ws.getConnId(), ws.*);
        conn.setSession(sess);
        sess_transferred = true;

        try self.map.put(self.allocator, conn_id, conn);
        inserted = true;
        _ = self.active_connection_count.fetchAdd(1, .acq_rel);
        if (self.metrics) |m| m.recordConnectionOpen();
        std.log.info("Client connected: id={}", .{conn_id});

        conn.send(self.schema_sync_msg) catch {
            std.log.warn("Connection {}: dropped on schema_sync message, closing", .{conn_id});
            self.message_handler.sendServerDisconnectAndClose(conn, "BACKPRESSURE_LIMIT", "Outbound buffer limit exceeded.", 4004);
            return;
        };
        if (self.metrics) |m| m.recordMessageSent();
    }

    /// Entry point for WebSocket message events
    pub fn onMessage(self: *ConnectionManager, ws: *WebSocket, data: []const u8, msg_type: MessageType) void {
        const conn_id = ws.getConnId();

        if (self.metrics) |m| m.recordMessageReceived();

        // 1. Explicitly reject non-binary frames at the entry point.
        // ZyncBase uses binary MessagePack for all communications.
        if (msg_type != .binary) {
            std.log.warn("Rejected non-binary (text) message from connection {}", .{conn_id});
            if (wire_encode.encodeError(self.allocator, null, wire_errors.getWireError(error.InvalidMessageType))) |error_msg| {
                defer self.allocator.free(error_msg);
                switch (ws.send(error_msg, .binary)) {
                    .success, .backpressure => {
                        if (self.metrics) |m| {
                            m.recordErrorSent();
                            m.recordMessageSent();
                        }
                    },
                    .dropped => sendDisconnectAndEnd(ws, self.allocator, "BACKPRESSURE_LIMIT", "Outbound buffer limit exceeded.", 4004, self.metrics),
                }
            } else |err| {
                std.log.err("Failed to encode error response for invalid message type: {}", .{err});
            }
            return;
        }

        // 2. Thread-safe lookup with reference counting
        const conn = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const existing = self.map.get(conn_id) orelse return;
            existing.acquire();
            break :blk existing;
        };

        // 3. Release the connection after message handling
        defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

        self.message_handler.handleMessage(conn, data) catch |err| {
            std.log.debug("MessageHandler error for connection {}: {}", .{ conn_id, err });
        };
    }

    /// Entry point for WebSocket close events
    pub fn onClose(self: *ConnectionManager, ws: *WebSocket, code: i32, reason: []const u8) void {
        const conn_id = ws.getConnId();

        const maybe_conn = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk self.map.fetchRemove(conn_id);
        };

        if (maybe_conn) |entry| {
            const conn = entry.value;

            // Perform full session teardown (unsubscriptions and metadata clearing)
            self.message_handler.teardownSession(conn);

            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
            if (self.active_connection_count.fetchSub(1, .acq_rel) == 1) {
                self.last_conn_notifier.notify();
            }
            std.log.info("Client disconnected: id={} code={} reason={f}", .{ conn_id, code, std.zig.fmtString(reason) });
        }
    }

    /// Helper to get a stable reference to a connection (increments refcount)
    pub fn acquireConnection(self: *ConnectionManager, id: u64) !*Connection {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const conn = self.map.get(id) orelse return error.ConnectionNotFound;
        conn.acquire();
        return conn;
    }

    fn sendOrClose(conn: *Connection, data: []const u8, message_handler: *MessageHandler, metrics: ?*ServerMetrics, count: u64) void {
        conn.send(data) catch |err| {
            std.log.warn("Connection {} send failed ({}), closing", .{ conn.id, err });
            message_handler.sendServerDisconnectAndClose(conn, "BACKPRESSURE_LIMIT", "Outbound buffer limit exceeded.", 4004);
            return;
        };
        if (metrics) |m| m.recordMessagesSent(count);
    }

    /// Queue a message for delivery on the connection's owning reactor. Safe
    /// from any thread: the bytes are copied into an arena and the owning loop
    /// performs the send during its drain. Used for low-rate control messages
    /// (action replies and errors); worker fanout carries the loop id instead.
    pub fn sendToConnection(self: *ConnectionManager, conn_id: u64, data: []const u8) void {
        const send_queue = self.send_queue orelse return;
        const loop_id = blk: {
            const conn = self.acquireConnection(conn_id) catch return;
            defer if (conn.release()) self.memory_strategy.releaseConnection(conn);
            break :blk conn.loop_id;
        };
        const handle = self.memory_strategy.acquireArenaDeferred() catch |err| {
            std.log.warn("sendToConnection: arena acquire failed for conn {}: {}", .{ conn_id, err });
            return;
        };
        defer handle.release();
        const copy = handle.allocator().dupe(u8, data) catch |err| {
            std.log.warn("sendToConnection: copy failed for conn {}: {}", .{ conn_id, err });
            return;
        };
        handle.retain();
        send_queue.push(loop_id, .{ .conn_id = conn_id, .data = copy, .arena = handle }) catch |err| {
            std.log.warn("sendToConnection: queue push failed for conn {}: {}", .{ conn_id, err });
            handle.release();
            return;
        };
        self.wakeLoop(loop_id);
    }
    /// Drain SendQueue and send messages to connections. Must be called from event loop thread.
    /// Called in notifyPostHandler after dispatcher polls.
    /// Groups entries by conn_id and sends each group as ONE concatenated
    /// frame: complete msgpack messages are byte-concatenated in pop order.
    /// The client decodes multiple messages per frame (decodeMulti).
    /// A connection that accumulates more than `max_pending_group_bytes` in one
    /// pass is dropped and closed with BACKPRESSURE_LIMIT.
    pub fn drainSendQueue(self: *ConnectionManager, send_queue: *SendQueueType, loop_id: usize) void {
        std.debug.assert(loop_id < self.drain_arenas.len);
        _ = self.drain_arenas[loop_id].reset(.retain_capacity);
        const alloc = self.drain_arenas[loop_id].allocator();

        // Phase 1: pop all entries, group deliveries by conn_id, capped per connection.
        var groups = std.AutoHashMapUnmanaged(u64, Group).empty;
        // One owner ref per popped queue entry. A batched entry contributes many
        // deliveries but is released exactly once, after all sends complete.
        var owners: std.ArrayListUnmanaged(ArenaHandle) = .empty;
        defer {
            for (owners.items) |owner| owner.release();
            owners.deinit(alloc);
        }

        while (send_queue.popFrom(loop_id)) |entry| {
            owners.append(alloc, entry.arena) catch {
                std.log.warn("drainSendQueue: owner append failed for conn {}, dropping {} byte entry", .{ entry.conn_id, entry.data.len });
                entry.deinit();
                continue;
            };
            if (entry.items) |items| {
                for (items) |delivery| {
                    std.debug.assert(delivery.loop_id == loop_id);
                    appendToGroup(alloc, &groups, delivery.conn_id, delivery.data);
                }
            } else {
                appendToGroup(alloc, &groups, entry.conn_id, entry.data);
            }
        }

        // Phase 2: per connection, concatenate the group into one frame and send.
        var it = groups.iterator();
        while (it.next()) |kv| {
            const conn_id = kv.key_ptr.*;
            const group = kv.value_ptr;

            // Skip empty groups
            if (group.entries.items.len == 0) continue;

            const conn = self.acquireConnection(conn_id) catch |err| {
                // Connection gone — its deliveries are dropped; owners are
                // released by the defer above.
                std.log.debug("drainSendQueue: connection {} unavailable: {}", .{ conn_id, err });
                continue;
            };
            defer if (conn.release()) self.memory_strategy.releaseConnection(conn);

            if (group.over) {
                // The client is not draining fast enough. Drop the backlog
                // rather than writing it to a peer we are about to close: the
                // close is terminal and reconnect resubscribes from scratch.
                std.log.warn("Connection {}: send backlog exceeded {} bytes ({} entries held, {} dropped), closing", .{
                    conn_id,
                    max_pending_group_bytes,
                    group.entries.items.len,
                    group.dropped,
                });
                self.message_handler.sendServerDisconnectAndClose(conn, "BACKPRESSURE_LIMIT", "Outbound buffer limit exceeded.", 4004);
                continue;
            }

            sendConcatenatedOrClose(conn, group.entries.items, alloc, self.message_handler, self.metrics);
        }
    }

    /// Send ServerDisconnect message to all active connections and initiate socket close
    pub fn sendDisconnectToAll(self: *ConnectionManager, code: []const u8, message: []const u8, close_code: u16) void {
        self.sendDisconnectToAllFiltered(null, code, message, close_code);
    }
    /// Send ServerDisconnect only to connections owned by one event loop.
    pub fn sendDisconnectToAllForLoop(self: *ConnectionManager, loop_id: u8, code: []const u8, message: []const u8, close_code: u16) void {
        self.sendDisconnectToAllFiltered(loop_id, code, message, close_code);
    }
    fn sendDisconnectToAllFiltered(self: *ConnectionManager, filter: ?u8, code: []const u8, message: []const u8, close_code: u16) void {
        const msg = wire_encode.encodeServerDisconnect(self.allocator, code, message) catch |err| blk: {
            std.log.err("Failed to encode ServerDisconnect: {}", .{err});
            break :blk null;
        };
        defer if (msg) |bytes| self.allocator.free(bytes);

        var connections = std.ArrayListUnmanaged(*Connection).empty;
        defer connections.deinit(self.allocator);

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var it = self.map.valueIterator();
            while (it.next()) |state| {
                const conn = state.*;
                if (filter) |loop_id| {
                    if (conn.loop_id != loop_id) continue;
                }
                conn.acquire();
                connections.append(self.allocator, conn) catch |err| {
                    std.log.err("Failed to add connection to disconnect list: {}", .{err});
                    if (conn.release()) {
                        self.memory_strategy.releaseConnection(conn);
                    }
                };
            }
        }

        for (connections.items) |conn| {
            if (msg) |bytes| {
                if (conn.send(bytes)) {
                    if (self.metrics) |m| m.recordMessageSent();
                } else |err| {
                    std.log.warn("Failed to send ServerDisconnect to connection {}: {}", .{ conn.id, err });
                }
            }
            conn.ws.end(close_code);
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }
    }

    pub fn countForLoop(self: *ConnectionManager, loop_id: u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        var it = self.map.valueIterator();
        while (it.next()) |state| {
            if (state.*.loop_id == loop_id) count += 1;
        }
        return count;
    }
    pub fn sweepExpiredTokens(self: *ConnectionManager, loop_id: u8) void {
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const grace_period_seconds = self.token_grace_period_seconds;
        const ExpiryAction = struct {
            conn: *Connection,
            notify: bool,
            close: bool,
        };
        var actions: std.ArrayListUnmanaged(ExpiryAction) = .empty;
        defer actions.deinit(self.allocator);
        var should_notify = false;
        var should_close = false;

        self.mutex.lockUncancelable(self.io);

        var it = self.map.valueIterator();
        while (it.next()) |state| {
            const conn = state.*;
            if (conn.loop_id != loop_id) continue;
            if (conn.session) |sess| {
                if (!sess.is_anonymous and now >= sess.token_expires_at) {
                    const close = now >= sess.token_expires_at + @as(i64, @intCast(grace_period_seconds));
                    const notify = !conn.token_expiry_notified;
                    if (!notify and !close) continue;
                    conn.acquire();
                    actions.append(self.allocator, .{ .conn = conn, .notify = notify, .close = close }) catch |err| {
                        std.log.err("Failed to add expired connection to sweep list: {}", .{err});
                        if (conn.release()) {
                            self.memory_strategy.releaseConnection(conn);
                        }
                        continue;
                    };
                    if (notify) conn.token_expiry_notified = true;
                    should_notify = should_notify or notify;
                    should_close = should_close or close;
                }
            }
        }

        self.mutex.unlock(self.io);

        var notify_msg: ?[]const u8 = null;
        var disconnect_msg: ?[]const u8 = null;
        if (should_notify) {
            notify_msg = wire_encode.encodeError(self.allocator, null, wire_errors.getWireError(error.TokenExpired)) catch |err| blk: {
                std.log.err("Failed to encode TOKEN_EXPIRED notification: {}", .{err});
                break :blk null;
            };
        }
        if (should_close) {
            disconnect_msg = wire_encode.encodeServerDisconnect(self.allocator, "TOKEN_EXPIRED", "Your authentication token has expired.") catch |err| blk: {
                std.log.err("Failed to encode TOKEN_EXPIRED disconnect: {}", .{err});
                break :blk null;
            };
        }
        defer if (notify_msg) |bytes| self.allocator.free(bytes);
        defer if (disconnect_msg) |bytes| self.allocator.free(bytes);

        for (actions.items) |action| {
            const conn = action.conn;
            var backpressure_close = false;
            if (action.notify) {
                if (notify_msg) |bytes| {
                    if (conn.send(bytes)) {
                        if (self.metrics) |m| {
                            m.recordErrorSent();
                            m.recordMessageSent();
                        }
                    } else |err| {
                        std.log.warn("Failed to notify connection {} about token expiry: {}", .{ conn.id, err });
                        self.message_handler.sendServerDisconnectAndClose(conn, "BACKPRESSURE_LIMIT", "Outbound buffer limit exceeded.", 4004);
                        backpressure_close = true;
                    }
                } else if (!action.close) {
                    self.mutex.lockUncancelable(self.io);
                    conn.token_expiry_notified = false;
                    self.mutex.unlock(self.io);
                }
            }
            if (action.close and !backpressure_close) {
                if (disconnect_msg) |bytes| {
                    if (conn.send(bytes)) {
                        if (self.metrics) |m| m.recordMessageSent();
                    } else |err| {
                        std.log.warn("Failed to send TOKEN_EXPIRED to connection {}: {}", .{ conn.id, err });
                    }
                }
                conn.ws.end(4006);
            }
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }
    }

    pub fn setLastConnectionNotifier(self: *ConnectionManager, n: Notifier) void {
        self.last_conn_notifier = n;
    }

    pub fn startTokenSweepTimer(self: *ConnectionManager, loop_id: u8, loop: *c.struct_us_loop_t) !void {
        std.debug.assert(loop_id < event_loop_count);
        self.token_sweep_timers[loop_id] = try uws_timer.startTimer(TokenSweepCtx, &self.token_sweep_ctx[loop_id], loop, tokenSweepCallback, 15_000, 15_000);
    }
    pub fn stopTokenSweepTimer(self: *ConnectionManager) void {
        for (&self.token_sweep_timers) |*timer| uws_timer.stopTimer(timer);
    }
    /// Must be called on the owning loop.
    pub fn stopTokenSweepTimerForLoop(self: *ConnectionManager, loop_id: u8) void {
        std.debug.assert(loop_id < event_loop_count);
        uws_timer.stopTimer(&self.token_sweep_timers[loop_id]);
    }
    fn tokenSweepCallback(t: ?*c.struct_us_timer_t) callconv(.c) void {
        const timer = t orelse return;
        const ctx = uws_timer.extractPtr(TokenSweepCtx, timer);
        ctx.manager.sweepExpiredTokens(ctx.loop_id);
    }
};

fn sendDisconnectAndEnd(ws: *WebSocket, allocator: Allocator, code: []const u8, message: []const u8, close_code: u16, metrics: ?*ServerMetrics) void {
    defer ws.end(close_code);
    const payload = wire_encode.encodeServerDisconnect(allocator, code, message) catch return;
    defer allocator.free(payload);
    switch (ws.send(payload, .binary)) {
        .success, .backpressure => {
            if (metrics) |m| m.recordMessageSent();
        },
        .dropped => {},
    }
}

/// Send a group of send-queue entries as a single frame: complete msgpack
/// messages concatenated in pop order. A lone entry is sent directly without
/// copying. Falls back to per-entry sends if the concat buffer cannot be
/// allocated (graceful degradation). Deinits every entry after sending —
/// uWS copies the payload into its send buffer synchronously, so the concat
/// buffer (drain arena) may be reset on the next drain pass.
fn sendConcatenatedOrClose(conn: *Connection, entries: []const []const u8, alloc: Allocator, message_handler: *MessageHandler, metrics: ?*ServerMetrics) void {
    if (entries.len == 1) {
        ConnectionManager.sendOrClose(conn, entries[0], message_handler, metrics, 1);
        return;
    }

    var total: usize = 0;
    for (entries) |e| total += e.len;

    const buf = alloc.alloc(u8, total) catch {
        for (entries) |e| {
            ConnectionManager.sendOrClose(conn, e, message_handler, metrics, 1);
        }
        return;
    };

    var offset: usize = 0;
    for (entries) |e| {
        @memcpy(buf[offset .. offset + e.len], e);
        offset += e.len;
    }

    ConnectionManager.sendOrClose(conn, buf, message_handler, metrics, @intCast(entries.len));
}
