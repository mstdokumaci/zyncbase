# Presence Internals

**Drivers**: [Presence API Design](../api-design/presence-api.md) — Formal requirements for user awareness and ephemeral state. [ADR-033](../architecture/adrs.md#adr-033-typed-two-tier-presence-system) — Typed two-tier presence architecture.

This document covers the architectural details, performance strategy, and internal implementation of ZyncBase's presence system.

---

## Logical Architecture

Presence is strictly scoped to `presenceNamespace`. The server maintains two in-memory structures per namespace: a user state map (one record per connected user) and a shared state map (one record for the entire namespace). All data is ephemeral — no SQLite involvement.

Presence operations require a ready presence scope: the namespace string has been resolved to `_zync_namespaces.id`, and the external identity has been resolved to a persisted `users.id`. If `users.namespaced = true`, identity resolution uses the presence namespace ID. See ADR-029.

```
[WebSocket Client] ──▶ [PresenceManager (In-Memory)]
                                │
                ┌───────────────┴───────────────┐
                │                               │
        [UserStateMap]                  [SharedStateMap]
    (userId → PresenceRecord)           (PresenceRecord)
```

---

## Schema and Wire Encoding

### Presence schema parsing (server startup)

At startup, the server loads the `presence` section of `schema.json` and produces two flat field arrays (one for `user`, one for `shared`) by flattening nested objects with `__`. Max one level of nesting is enforced; deeper nesting causes startup failure.

```
presence.user:
  cursor.x  → cursor__x  → index 0
  cursor.y  → cursor__y  → index 1
  status    → status     → index 2
  typing    → typing     → index 3
  name      → name       → index 4

presence.shared:
  slide     → slide      → index 0
  playing   → playing    → index 1
```

These arrays are stored on `PresenceManager` as `user_fields: []const PresenceField` and `shared_fields: []const PresenceField`, where each `PresenceField` carries both the flattened name and the declared `FieldType`.

### SchemaSync payload extension

The `SchemaSync` message sent to every connecting client is extended with two flat arrays:

```
{
  "type":               "SchemaSync",
  "tables":             [...],
  "fields":             [...],
  "fieldFlags":         [...],
  "presenceUserFields": ["cursor__x", "cursor__y", "status", "typing", "name"],
  "presenceSharedFields": ["slide", "playing"]
}
```

No flags arrays accompany presence fields. Presence fields have no system-column or doc_id semantics — all indices map to plain typed values.

### SDK dictionary extension

The `SchemaDictionary` in the TypeScript SDK extends its existing index maps to include:
- `presenceUserFieldToIndex: Map<string, number>` — `"cursor__x"` → 0, etc.
- `presenceSharedFieldToIndex: Map<string, number>` — `"slide"` → 0, etc.
- `presenceUserFieldNames: string[]` — reverse map for decoding
- `presenceSharedFieldNames: string[]` — reverse map for decoding

Encode path: `{ cursor: { x: 100, y: 200 } }` → flatten → `{ "cursor__x": 100, "cursor__y": 200 }` → index → `{ 0: 100.0, 1: 200.0 }`.

Decode path: `{ 0: 101.0, 1: 201.0 }` → unflatten via index → `{ cursor__x: 101.0, cursor__y: 201.0 }` → nest → `{ cursor: { x: 101.0, y: 201.0 } }`.

### SchemaSync integration

The presence field arrays are produced at server startup during schema parsing and stored on the `Schema` struct alongside the store table/field arrays. The `encodeSchemaSync()` function in `wire/encode.zig` is extended to conditionally include presence arrays:

1. Schema parser (`schema/parse.zig`) reads `presence.user` / `presence.shared` from `schema.json` (or synthesizes the implicit default if absent), flattens nested objects with `__`, and produces `presence_user_fields: [][]const u8` and `presence_shared_fields: [][]const u8`.
2. `encodeSchemaSync()` dynamically computes the MessagePack map size (4 for store-only, 5 or 6 when presence arrays are present) and conditionally encodes `presenceUserFields` and `presenceSharedFields`.
3. The encoded message is pre-computed once at startup and stored on `ConnectionManager`, then sent verbatim to each connecting client — identical to the store SchemaSync pattern.

When the implicit schema is active, `SchemaSync` carries `presenceUserFields: ["status"]` and `presenceSharedFields: []` (empty array, not omitted).

---

## Implementation Artifacts

### PresenceManager

Core state management. All data lives in RAM for sub-100ms latency. Runs on a dedicated background thread for periodic flush, with a mutex protecting internal state from concurrent uWS message handler access.

```zig
const PresenceManager = struct {
    allocator: Allocator,

    // --- Thread management (modeled on CheckpointManager) ---
    background_thread: ?std.Thread,
    shutdown_requested: std.atomic.Value(bool),
    shutdown_mutex: std.Thread.Mutex,
    shutdown_cond: std.Thread.Condition,

    // --- Data protection ---
    // Guards all mutable state below. Acquired by uWS message handler threads
    // on setUser/setShared/onSubscribeUser/onSubscribeShared/removeUser.
    // Also acquired by the flush loop thread during flushBatch.
    data_mutex: std.Thread.Mutex,

    // Typed schema built at startup (names + declared types)
    user_fields:   []const schema_mod.PresenceField,
    shared_fields: []const schema_mod.PresenceField,

    // User state: namespace_id → (users.id → PresenceRecord)
    // PresenceRecord is []?typed.Value indexed by field index
    user_state: HashMap(i64, HashMap(DocId, PresenceRecord)),

    // Shared state: namespace_id → PresenceRecord
    shared_state: HashMap(i64, PresenceRecord),

    // Grace period tracking: namespace_id → timestamp_ms when it became empty
    // Entries cleared when a user joins; evicted by flush loop after grace_ms
    namespace_empty_at: HashMap(i64, i64),

    // Batch pending: user presence updates queued for the 50ms flush
    pending_user_updates:   ArrayList(PendingUserUpdate),
    pending_shared_updates: ArrayList(PendingSharedUpdate),

    // Subscription tracking: namespace_id → []ConnectionId
    user_subscribers:   HashMap(i64, ArrayList(ConnectionId)),
    shared_subscribers: HashMap(i64, ArrayList(ConnectionId)),

    pub fn setUser(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: DocId,
        patch: msgpack.Payload,  // sparse integer-keyed merge delta from wire
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Validate field indices against user_fields.len
        // Validate value types against schema via typed.valueFromPayload
        // Merge into existing record (patch, not replace)
        var ns = try self.user_state.getOrPut(namespace_id);
        var user_record = try ns.value_ptr.getOrPut(user_id);
        try mergeFromPayload(user_record.value_ptr, self.user_fields, patch);

        // Queue for 50ms batch broadcast
        try self.pending_user_updates.append(.{
            .namespace_id = namespace_id,
            .user_id      = user_id,
            .patch        = patch,
        });
    }

    pub fn setShared(
        self: *PresenceManager,
        namespace_id: i64,
        patch: msgpack.Payload,  // sparse integer-keyed merge delta from wire
        conn_id: ConnectionId,
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Validate field indices against shared_fields.len
        // Validate value types against schema via typed.valueFromPayload
        // Merge into shared record (patch, not replace)
        var record = try self.shared_state.getOrPut(namespace_id);
        try mergeFromPayload(record.value_ptr, self.shared_fields, patch);

        // Queue for broadcast to shared_subscribers
        try self.pending_shared_updates.append(.{
            .namespace_id = namespace_id,
            .patch        = patch,
            .source_conn  = conn_id,
        });
    }

    pub fn onSubscribeUser(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: ConnectionId,
    ) !PresenceSnapshot {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Register subscriber
        var subs = try self.user_subscribers.getOrPut(namespace_id);
        try subs.value_ptr.append(conn_id);

        // Return current user records
        const users = self.user_state.get(namespace_id);
        return .{ .users = users };
    }

    pub fn onSubscribeShared(
        self: *PresenceManager,
        namespace_id: i64,
        conn_id: ConnectionId,
    ) !?*const PresenceRecord {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        // Register subscriber
        var subs = try self.shared_subscribers.getOrPut(namespace_id);
        try subs.value_ptr.append(conn_id);

        // Return current shared state (may be null if no user has called setShared)
        return self.shared_state.get(namespace_id);
    }

    pub fn removeUser(
        self: *PresenceManager,
        namespace_id: i64,
        user_id: DocId,
    ) !void {
        self.data_mutex.lock();
        defer self.data_mutex.unlock();

        const ns = self.user_state.getPtr(namespace_id) orelse return;
        _ = ns.remove(user_id);

        // Also remove from subscriber list
        if (self.user_subscribers.getPtr(namespace_id)) |subs| {
            // Remove this conn_id from subs if it was a subscriber
            // (handled separately by connection cleanup)
        }

        // If namespace is now empty, record empty timestamp for grace period
        if (ns.count() == 0) {
            try self.namespace_empty_at.put(namespace_id, std.time.milliTimestamp());
        }

        // Queue leave broadcast
        try self.pending_user_updates.append(.{
            .namespace_id = namespace_id,
            .user_id      = user_id,
            .patch        = null,  // null signals leave
        });
    }

    // --- Lifecycle ---

    // Spawn the dedicated background flush thread (modeled on CheckpointManager).
    pub fn start(self: *PresenceManager) !void {
        self.shutdown_requested.store(false, .release);
        const thread = try std.Thread.spawn(.{}, flushLoop, .{self});
        self.background_thread = thread;
    }

    // Signal shutdown and join the background thread.
    pub fn stop(self: *PresenceManager) void {
        self.shutdown_requested.store(true, .release);
        self.shutdown_mutex.lock();
        self.shutdown_cond.signal();
        self.shutdown_mutex.unlock();
        if (self.background_thread) |thread| thread.join();
    }

    // Dedicated thread: blocks on timedWait for 50ms, then flushes.
    fn flushLoop(self: *PresenceManager) !void {
        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();
        while (!self.shutdown_requested.load(.acquire)) {
            self.shutdown_cond.timedWait(&self.shutdown_mutex, 50 * std.time.ns_per_ms) catch |err| {
                if (err != error.Timeout) {
                    std.log.err("PresenceManager flush loop error: {}", .{err});
                }
            };
            if (self.shutdown_requested.load(.acquire)) break;
            self.flushBatch();
        }
    }

    // Runs on the dedicated background thread every 50ms.
    // data_mutex is acquired for the duration of the flush to snapshot pending
    // updates, then released before broadcasting (broadcasts don't need the lock).
    pub fn flushBatch(self: *PresenceManager) !void {
        // 1. Evict expired grace-period entries (shared state cleanup)
        const now = std.time.milliTimestamp();
        const grace_ms: i64 = 5_000;
        var grace_iter = self.namespace_empty_at.iterator();
        while (grace_iter.next()) |entry| {
            if (now - entry.value_ptr.* >= grace_ms) {
                _ = self.shared_state.remove(entry.key_ptr.*);
                _ = self.namespace_empty_at.remove(entry.key_ptr.*);
            }
        }

        // 2. Snapshot and clear pending updates under lock, then broadcast unlocked
        self.data_mutex.lock();
        const user_updates   = self.pending_user_updates;
        const shared_updates = self.pending_shared_updates;
        self.pending_user_updates   = ArrayList(PendingUserUpdate).init(self.allocator);
        self.pending_shared_updates = ArrayList(PendingSharedUpdate).init(self.allocator);
        self.data_mutex.unlock();

        if (user_updates.items.len > 0) {
            try self.broadcastUserBatch(user_updates.items);
            user_updates.deinit();
        }

        if (shared_updates.items.len > 0) {
            try self.broadcastSharedBatch(shared_updates.items);
            shared_updates.deinit();
        }
    }
};
```

### PresenceRecord

Accumulated in-memory state for one user or one namespace's shared record. A dense array indexed by field position, mirroring `typed.Record` but with optional slots (`null` = field not yet set). Allocated once when the record is created, mutated in place via merge.

```zig
const PresenceRecord = struct {
    values: []?typed.Value,  // length == schema field count for the tier

    pub fn deinit(self: *PresenceRecord, allocator: Allocator) void {
        for (self.values) |*slot| {
            if (slot.*) |*v| v.deinit(allocator);
        }
        allocator.free(self.values);
    }
};
```

### Merge from wire payload

Iterates only the sparse entries in the wire `Payload` patch. Validates field index bounds and value types against the schema via `typed.valueFromPayload`. Patches the dense `PresenceRecord` in place.

```zig
fn mergeFromPayload(
    record: *PresenceRecord,
    allocator: Allocator,
    fields: []const schema_mod.PresenceField,
    patch: msgpack.Payload,
) !void {
    if (patch != .map) return error.InvalidPayload;
    var it = patch.map.iterator();
    while (it.next()) |entry| {
        const f_idx = msgpack.extractPayloadUint(entry.key_ptr.*)
            orelse return error.InvalidFieldIndex;
        if (f_idx >= fields.len) return error.InvalidFieldIndex;
        const field = fields[f_idx];
        const new_value = try typed.valueFromPayload(
            allocator, field.declared_type, null, entry.value_ptr.*,
        );
        if (record.values[f_idx]) |*old| old.deinit(allocator);
        record.values[f_idx] = new_value;
    }
}
```

---

## Operational Logic

### Merge semantics

`setUser` and `setShared` perform field-level merges. The incoming wire payload is a **sparse** integer-keyed `msgpack.Payload` map — the same representation the store uses for `StoreSet` values. The message handler iterates only the present entries, validates each field index and type against the schema via `typed.valueFromPayload`, and patches the dense `PresenceRecord` in place. Fields absent from the patch (`null` slots in the record) are not touched. This means:

- Sending `{ 0: 101.0 }` updates only `cursor__x`. All other fields unchanged.
- The first `setUser` call for a new user creates a zero-initialized record and applies the patch.
- `setShared` on a namespace with no existing shared record creates it.

### Client-side throttling

High-frequency `presence.set()` calls are throttled at the SDK level to ~60fps (16ms). The server never receives more than ~60 user presence messages per second per connected user. `presence.setShared()` is not throttled — shared state changes are infrequent by design.

### Server-side batching

The `PresenceManager` flushes every 50ms via its batch loop. Multiple user updates and shared state updates within the window are grouped and sent in bulk. User updates are grouped by namespace, then each group triggers one pass over the namespace's subscriber list. This keeps broadcast cost O(subscribers × batch_size), not O(updates × subscribers).

### Automatic user cleanup on disconnect

When a WebSocket connection closes, the connection cleanup path calls `removeUser` for the presence scope. This removes the user's record, queues a `leave` broadcast, and — if the namespace is now empty — records `namespace_empty_at[namespace_id] = now`. The grace period timer starts.

When a namespace switch occurs (`PresenceSetNamespace`), the old presence scope's user record is removed before the new scope resolves.

### Grace period mechanism

When the last user leaves a namespace:
1. `removeUser` records `namespace_empty_at[id] = now_ms`.
2. Shared state remains alive in RAM.
3. The 50ms flush loop checks `namespace_empty_at` on every tick. When `now - empty_at >= 5000ms`, it removes the shared state and the `namespace_empty_at` entry.
4. If a user joins the namespace while it is in grace period (user count goes from 0 → 1), `namespace_empty_at[id]` is deleted — the grace timer is cancelled and shared state is preserved.

This requires zero additional timer infrastructure. The 50ms loop already runs unconditionally; the grace check is O(number of recently-emptied namespaces) — negligible in normal operation.

Shared state is RAM-only. Server restart clears all shared state regardless of grace period state. The grace period only protects against transient client disconnections, not server restarts.

### Authorization at accept time

Before calling `setUser` or `setShared`, the message handler evaluates the relevant authorization rule:
- `presenceWrite` — checked for `PresenceSet` and `PresenceRemove`
- `presenceSharedWrite` — checked for `PresenceSetShared`

The incoming sparse integer-keyed `Payload` map is passed directly to the auth rule evaluator as `value_payload` — no intermediate `FieldMap` decode step. The existing `resolveIncomingValueField` pattern resolves `$data.*` references by iterating the map entries, matching keys by integer value, and decoding via `typed.valueFromPayload` using the presence field's `declared_type`. The decode path is:

1. Wire payload arrives as integer-keyed map: `{ 0: "active", 2: true }`
2. Auth rule evaluator receives `$data.status = "active"`, `$data.typing = true` (resolved from the sparse `Payload` map on demand)
3. Rule is evaluated in RAM against the decoded field values

Field type and index validation also happen at accept time; unknown or mistyped fields are rejected with `SCHEMA_VALIDATION_FAILED` before any state mutation.

---

## Client-Side State Management

### Local caches

The SDK maintains two separate in-memory caches for the active presence namespace:

| Cache | Populated by | Read by |
|---|---|---|
| `userCache: Map<userId, PresenceEntry>` | `PresenceSubscribe` ok response + `PresenceBroadcast` events | `presence.get()`, `presence.getAll()`, `subscribe()` callback |
| `sharedCache: Record \| null` | `PresenceSubscribeShared` ok response + `SharedStateBroadcast` events | `presence.getShared()`, `subscribeShared()` callback |

### Cache update logic

**`PresenceBroadcast` handling:**
- `event: "join"`: insert new entry into `userCache`. The `data` field is the full initial user record (all fields set so far).
- `event: "update"`: merge `data` patch into the existing `userCache` entry for `userId`. Unknown `userId` is treated as join.
- `event: "leave"`: delete entry from `userCache` for `userId`.

The callback registered via `subscribe()` is fired after each cache mutation with the updated full user list.

**`SharedStateBroadcast` handling:**
- Merge `data` patch into `sharedCache`.
- The callback registered via `subscribeShared()` is fired with the updated shared state object (SDK unflattens `cursor__x` / `cursor__y` back to `cursor: { x, y }`).

### Synchronous getters

`presence.get(userId)`, `presence.getAll()`, and `presence.getShared()` perform O(1) local cache lookups. No network round-trip is ever initiated for these calls. They return stale or empty results if no subscription is active — this is by design and documented.

### Subscription invalidation on namespace switch

When `setPresenceNamespace` resolves:
- Both `userCache` and `sharedCache` are cleared.
- All active `subscribe()` and `subscribeShared()` callbacks are deregistered.
- The developer is responsible for re-subscribing in the new namespace.

---

## Validation & Success Criteria

### Performance targets

| Metric | Target |
|---|---|
| `PresenceSet` accept latency | < 1ms |
| `presence.get()` / `getShared()` | < 100μs (local cache) |
| Broadcast batch interval | 50ms ± 5ms |
| Grace period accuracy | 5000ms ± 50ms (one flush tick) |

### Verification

```bash
# Unit tests for PresenceManager (set/merge/remove/shared/grace period)
zig build test -Dtest-filter="presence"

# Thread safety under concurrent updates
bun run test:tsan

# End-to-end: cursors, subscriptions, shared state
bun run test:e2e
```

---

## See Also
- [Presence API Design](../api-design/presence-api.md)
- [Wire Protocol](./wire-protocol.md)
- [Auth System](./auth-system.md)
- [ADR-033: Typed Two-Tier Presence System](../architecture/adrs.md#adr-033-typed-two-tier-presence-system)
