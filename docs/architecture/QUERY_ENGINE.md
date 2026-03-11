# Query Engine

**Last Updated**: 2026-03-09

---

## Overview

The query engine handles filtering, sorting, and real-time subscriptions. It executes queries against the in-memory cache and SQLite storage, then tracks subscriptions to notify clients of changes.

**Key Innovation**: Fine-grained change detection + in-memory subscriptions = efficient real-time updates

---

## Query AST

### Query Structure

```zig
const Query = struct {
    path: []const u8,
    filters: []Filter,
    sort: ?Sort,
    limit: ?usize,
    offset: ?usize,
};

const Filter = struct {
    field: []const u8,
    op: FilterOp,
    value: json.Value,
};

const FilterOp = enum {
    eq,         // ==
    ne,         // !=
    gt,         // >
    gte,        // >=
    lt,         // <
    lte,        // <=
    in,         // IN
    contains,   // LIKE %value%
    startsWith, // LIKE value%
    endsWith,   // LIKE %value
    isNull,     // IS NULL
    isNotNull,  // IS NOT NULL
};

const Sort = struct {
    field: []const u8,
    direction: enum { asc, desc },
};
```

---

## Query Execution

### Execution Flow

```
┌─────────────────────────────────────────────────┐
│  1. Parse Query                                 │
│     - Validate syntax                           │
│     - Build AST                                 │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  2. Check Cache                                 │
│     - Look for cached results                   │
│     - Check if cache is fresh                   │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  3. Execute Query                               │
│     - Build SQL (if needed)                     │
│     - Execute on SQLite reader                  │
│     - Or filter in-memory cache                 │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  4. Apply Filters                               │
│     - Filter results                            │
│     - Sort results                              │
│     - Apply limit/offset                        │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  5. Return Results                              │
│     - Serialize to MessagePack                  │
│     - Send to client                            │
└─────────────────────────────────────────────────┘
```

### Implementation

```zig
const QueryEngine = struct {
    storage: *StorageLayer,
    cache: *LockFreeCache,
    
    pub fn execute(self: *QueryEngine, query: Query) ![]json.Value {
        // Try cache first
        if (try self.executeFromCache(query)) |results| {
            return results;
        }
        
        // Build SQL
        const sql = try self.buildSQL(query);
        
        // Execute on SQLite reader (parallel)
        const reader = self.storage.getReader();
        const rows = try reader.query(sql);
        
        // Parse results
        return try self.parseResults(rows);
    }
    
    fn buildSQL(self: *QueryEngine, query: Query) ![]const u8 {
        var buf = ArrayList(u8).init(self.allocator);
        
        // Query the path's table directly
        try buf.appendSlice("SELECT * FROM ");
        try buf.appendSlice(query.path);  // e.g., 'tasks'
        try buf.appendSlice(" WHERE namespace_id = ?");
        
        for (query.filters) |filter| {
            try buf.appendSlice(" AND ");
            try self.appendFilter(&buf, filter);
        }
        
        if (query.sort) |sort| {
            try buf.appendSlice(" ORDER BY ");
            try buf.appendSlice(sort.field);
            try buf.appendSlice(if (sort.direction == .asc) " ASC" else " DESC");
        }
        
        if (query.limit) |limit| {
            try std.fmt.format(buf.writer(), " LIMIT {}", .{limit});
        }
        
        if (query.offset) |offset| {
            try std.fmt.format(buf.writer(), " OFFSET {}", .{offset});
        }
        
        return buf.toOwnedSlice();
    }
};
```

---

## Real-time Subscriptions

### Subscription Tracking

```zig
const Subscription = struct {
    id: u64,
    connection_id: u64,
    namespace: []const u8,
    query: Query,
    last_result: []json.Value,
    last_version: u64,
};

const SubscriptionManager = struct {
    subscriptions: HashMap(u64, *Subscription),
    namespace_index: HashMap([]const u8, ArrayList(u64)),
    
    pub fn add(self: *SubscriptionManager, sub: Subscription) !void {
        try self.subscriptions.put(sub.id, &sub);
        
        // Index by namespace for efficient lookup
        var list = try self.namespace_index.getOrPut(sub.namespace);
        try list.value_ptr.append(sub.id);
    }
    
    pub fn remove(self: *SubscriptionManager, sub_id: u64) void {
        if (self.subscriptions.fetchRemove(sub_id)) |entry| {
            const sub = entry.value;
            
            // Remove from namespace index
            if (self.namespace_index.get(sub.namespace)) |list| {
                for (list.items, 0..) |id, i| {
                    if (id == sub_id) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
            }
        }
    }
};

### Change Detection

ZyncBase uses a **Fine-Grained Observation** strategy to ensure sub-100ms real-time sync without overloading the SQLite reader pool.

**Strategy: Fine-Grained Observation (ADR-018)**
- The Writer thread emits a change event: `(table, id, operation, old_row, new_row)`.
- The `SubscriptionManager` evaluates the `new_row` against active subscription filters *in memory*.
- **No SQLite queries are re-run** during the broadcast phase for standard filter matches.
- Updates are pushed to clients only if the row specifically matching their query has changed.

### Fine-Grained Implementation

The notification pipeline operates entirely in RAM:

```zig
pub fn notify(self: *SubscriptionManager, table: []const u8, changed_id: []const u8, new_row: json.Value) !void {
    const subs = self.table_index.get(table) orelse return;
    
    for (subs.items) |sub_id| {
        const sub = self.subscriptions.get(sub_id).?;
        
        // Evaluate filters in RAM (no SQLite)
        if (try self.evaluator.matches(new_row, sub.query.filters)) {
            // Push individual delta to client
            try self.sendDelta(sub.connection_id, sub_id, new_row);
        }
    }
}
```
fn affectsSubscription(self: *SubscriptionManager, sub: *Subscription, changed_ids: []const []const u8) !bool {
    // If subscription has no filters, any change affects it
    if (sub.query.filters.len == 0) {
        return true;
    }
    
    // Check if any changed ID matches the subscription's filters
    for (changed_ids) |id| {
        const item = try self.cache.get(id);
        if (try self.matchesFilters(item, sub.query.filters)) {
            return true;
        }
    }
    
    return false;
}
```

---

## Presence Awareness

ZyncBase's presence system tracks ephemeral user state (cursors, typing indicators, online status) in real-time with sub-100ms latency. All presence data is stored in-memory only—never persisted to SQLite.

### Presence Data Structure

```zig
const PresenceManager = struct {
    allocator: Allocator,
    
    // In-memory only (ephemeral)
    // namespace -> user_id -> presence_data
    presence: HashMap([]const u8, HashMap([]const u8, PresenceData)),
    
    // History buffer (last 5 seconds) for late joiners
    // namespace -> RingBuffer of presence snapshots
    history: HashMap([]const u8, RingBuffer(PresenceSnapshot)),
    
    // Batching for efficiency (50ms intervals)
    batch_timer: std.time.Timer,
    pending_updates: ArrayList(PresenceUpdate),
    
    pub fn set(self: *PresenceManager, namespace: []const u8, user_id: []const u8, data: json.Value) !void {
        // Store in memory
        var ns = try self.presence.getOrPut(namespace);
        try ns.value_ptr.put(user_id, data);
        
        // Add to history buffer (last 5 seconds)
        var ns_history = try self.history.getOrPut(namespace);
        try ns_history.value_ptr.push(.{
            .user_id = user_id,
            .data = data,
            .timestamp = std.time.milliTimestamp(),
        });
        
        // Queue for batched broadcast (50ms intervals)
        try self.pending_updates.append(.{
            .namespace = namespace,
            .user_id = user_id,
            .data = data,
        });
    }
    
    pub fn get(self: *PresenceManager, namespace: []const u8, user_id: []const u8) ?json.Value {
        const ns = self.presence.get(namespace) orelse return null;
        return ns.get(user_id);
    }
    
    pub fn getAll(self: *PresenceManager, namespace: []const u8) []PresenceEntry {
        const ns = self.presence.get(namespace) orelse return &.{};
        
        var result = ArrayList(PresenceEntry).init(self.allocator);
        var iter = ns.iterator();
        while (iter.next()) |entry| {
            try result.append(.{
                .user_id = entry.key_ptr.*,
                .data = entry.value_ptr.*,
                .joined_at = entry.value_ptr.joined_at,
            });
        }
        return result.toOwnedSlice();
    }
    
    pub fn onJoin(self: *PresenceManager, namespace: []const u8) !PresenceSnapshot {
        // Return current state + last 5 seconds of history
        const current = self.presence.get(namespace);
        
        const history = if (self.history.get(namespace)) |h|
            h.getLastNSeconds(5)
        else
            &.{};
        
        return .{
            .current = current,
            .history = history,
        };
    }
    
    pub fn remove(self: *PresenceManager, namespace: []const u8, user_id: []const u8) !void {
        // Remove from memory
        if (self.presence.get(namespace)) |ns| {
            _ = ns.remove(user_id);
        }
        
        // Broadcast removal
        try self.broadcastRemoval(namespace, user_id);
    }
    
    // Called every 50ms to batch presence updates
    pub fn flushBatch(self: *PresenceManager) !void {
        if (self.pending_updates.items.len == 0) return;
        
        // Group updates by namespace
        var by_namespace = HashMap([]const u8, ArrayList(PresenceUpdate)).init(self.allocator);
        
        for (self.pending_updates.items) |update| {
            var ns_updates = try by_namespace.getOrPut(update.namespace);
            try ns_updates.value_ptr.append(update);
        }
        
        // Broadcast batched updates to each namespace
        var iter = by_namespace.iterator();
        while (iter.next()) |entry| {
            try self.broadcastBatch(entry.key_ptr.*, entry.value_ptr.items);
        }
        
        // Clear pending updates
        self.pending_updates.clearRetainingCapacity();
    }
};

const PresenceData = struct {
    data: json.Value,
    joined_at: i64,
};

const PresenceSnapshot = struct {
    user_id: []const u8,
    data: json.Value,
    timestamp: i64,
};

const PresenceUpdate = struct {
    namespace: []const u8,
    user_id: []const u8,
    data: json.Value,
};
```

### Automatic Cleanup on Disconnect

```zig
fn onDisconnect(conn: *Connection) !void {
    const namespace = conn.presence_namespace;
    const user_id = conn.user_id;
    
    // Remove presence from memory
    try presence_manager.remove(namespace, user_id);
    
    // Notify other users in namespace
    try presence_manager.broadcastRemoval(namespace, user_id);
}
```

### History Buffer (5 Seconds)

When a user joins a presence namespace, they receive:
1. Current presence state of all users
2. Last 5 seconds of presence updates (for context like cursor trails)

```zig
const RingBuffer = struct {
    items: []PresenceSnapshot,
    head: usize,
    tail: usize,
    
    pub fn getLastNSeconds(self: *RingBuffer, seconds: i64) []PresenceSnapshot {
        const now = std.time.milliTimestamp();
        const cutoff = now - (seconds * 1000);
        
        var result = ArrayList(PresenceSnapshot).init(allocator);
        
        var i = self.tail;
        while (i != self.head) {
            const snapshot = self.items[i];
            if (snapshot.timestamp >= cutoff) {
                try result.append(snapshot);
            }
            i = (i + 1) % self.items.len;
        }
        
        return result.toOwnedSlice();
    }
};
```

### Server-Side Batching (50ms)

High-frequency presence updates (cursor moves) are batched every 50ms to reduce network overhead:

```zig
// Background task runs every 50ms
fn presenceBatchLoop(manager: *PresenceManager) !void {
    while (true) {
        std.time.sleep(50 * std.time.ns_per_ms);
        try manager.flushBatch();
    }
}
```

**Result:**
- Client A: cursor update (t=0ms)
- Client B: cursor update (t=10ms)
- Client C: cursor update (t=30ms)
- Server batches all 3 updates
- Broadcasts at t=50ms
- **1 message instead of 3**

### Why In-Memory Only?

**Presence data is ephemeral:**
- Cursor positions change multiple times per second
- Typing indicators are transient
- Online status is reconstructed on reconnect
- No need for historical data beyond 5 seconds

**Persisting to disk would:**
- Exhaust write capacity (10k writes/sec limit)
- Add unnecessary latency (milliseconds vs nanoseconds)
- Waste disk space on transient data
- Complicate cleanup logic

**RAM access is:**
- Nanosecond latency (vs milliseconds for disk)
- Sufficient capacity (100MB for 10k connections)
- Automatically cleaned up on disconnect
- Perfect for high-frequency updates

### Performance Characteristics

| Metric | Value |
|--------|-------|
| Latency (set) | < 1ms |
| Latency (get) | < 100μs |
| Updates/sec per user | ~60 (throttled client-side) |
| Broadcast rate | ~20/sec (batched server-side) |
| Memory per user | ~1KB |
| History buffer | 5 seconds |
| Batch interval | 50ms |

---

## Authorization Optimization

### The Problem

Running SQL queries for authorization on every WebSocket message creates a bottleneck:

```
Cursor movement (100/sec) × SQL query (1ms) = 100ms latency
```

### The Solution: Permission Snapshots

**1. On connection:**
```zig
fn onConnect(conn: *Connection) !void {
    // Execute SQL queries to determine permissions
    const permissions = try db.query(
        "SELECT room_id FROM room_members WHERE user_id = ?",
        .{conn.user_id}
    );
    
    // Cache in memory
    conn.permissions = PermissionSnapshot{
        .rooms = permissions,
        .version = 1,
    };
}
```

**2. Fast path (common case):**
```zig
fn checkPermission(conn: *Connection, room_id: []const u8) bool {
    // Memory lookup (nanoseconds)
    return conn.permissions.rooms.contains(room_id);
}
```

**3. Invalidation (rare case):**
```zig
fn onRoomMembershipChange(user_id: []const u8) !void {
    // Find all connections for this user
    for (connections) |conn| {
        if (conn.user_id == user_id) {
            // Re-query permissions
            conn.permissions = try refreshPermissions(conn);
        }
    }
}
```

**Result:**
- Common path: Nanosecond memory lookup
- Rare path: SQL query only when permissions change
- Authorization doesn't bottleneck real-time operations

---

## Query Optimization

### Indexes

**Create indexes for common query patterns:**

```sql
-- Index on namespace_id (always created)
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);

-- Index on frequently queried fields
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_assignee ON tasks(assignee);

-- Composite index for common patterns
CREATE INDEX idx_tasks_status_priority ON tasks(status, priority);

-- Index on timestamp fields
CREATE INDEX idx_tasks_created ON tasks(created_at);
```

### Query Planning

**Use EXPLAIN QUERY PLAN to verify indexes are used:**

```sql
EXPLAIN QUERY PLAN
SELECT * FROM tasks 
WHERE namespace_id = ? 
  AND status = 'active'
  AND priority > 5;
```

**Expected output:**
```
SEARCH tasks USING INDEX idx_tasks_status_priority (namespace_id=? AND status=?)
```

### Caching Strategy

**Cache hot queries:**

```zig
const QueryCache = struct {
    cache: HashMap(QueryKey, CachedResult),
    ttl_ms: u64 = 1000, // 1 second
    
    const CachedResult = struct {
        result: []json.Value,
        timestamp: i64,
        version: u64,
    };
    
    pub fn get(self: *QueryCache, query: Query, current_version: u64) ?[]json.Value {
        const key = QueryKey.from(query);
        const cached = self.cache.get(key) orelse return null;
        
        // Check if cache is still valid
        const now = std.time.milliTimestamp();
        if (now - cached.timestamp > self.ttl_ms) {
            return null; // Expired
        }
        
        if (cached.version != current_version) {
            return null; // Stale
        }
        
        return cached.result;
    }
};
```

---

## Performance Characteristics

### Query Execution

| Operation | Latency | Throughput |
|-----------|---------|------------|
| In-memory filter | < 1ms | 100k+ ops/sec |
| SQLite query (indexed) | 1-5ms | 10k+ ops/sec |
| SQLite query (full scan) | 10-100ms | 100 ops/sec |
| Subscription notification | < 1ms | 100k+ ops/sec |

### Subscription Overhead

**Per subscription:**
- Memory: ~1KB (query + last result)
- CPU: Negligible (only on changes)
- Network: Only when results change

**For 10,000 subscriptions:**
- Memory: ~10MB
- CPU: < 1% (with fine-grained detection)
- Network: Scales with change rate

---

## Best Practices

### 1. Use Indexes

Always create indexes for frequently queried fields:

```sql
-- In schema.json, mark fields for indexing
{
  "properties": {
    "tasks": {
      "properties": {
        "status": { 
          "type": "string",
          "index": true  // Auto-creates index
        }
      }
    }
  }
}
```

### 2. Limit Result Sets

Always use `limit` to prevent large result sets:

```typescript
client.store.query('users', {
  where: { status: { eq: 'active' } },
  limit: 100 // Always limit!
})
```

### 3. Denormalize Data

Avoid joins by denormalizing data:

```json
{
  "task": {
    "id": "task-1",
    "title": "Fix bug",
    "project_id": "proj-1",
    "project_name": "ZyncBase" // Denormalized
  }
}
```

### 4. Use Fine-Grained Subscriptions

Subscribe to specific data, not broad queries:

```typescript
// Good - specific
client.store.subscribe('tasks', {
  where: {
    project_id: { eq: currentProject },
    status: { eq: 'active' }
  }
})

// Bad - too broad
client.store.subscribe('tasks', {
  where: {
    status: { ne: 'archived' }
  }
})
```

### 5. Batch Updates

Batch multiple updates into a single transaction (all-or-nothing). See the [Batch Operations Specification](../BATCH_OPERATIONS.md) for full details.

```typescript
// Good - single transaction
await client.store.batch([
  { op: 'set', path: 'tasks.1', value: task1 },
  { op: 'set', path: 'tasks.2', value: task2 },
  { op: 'set', path: 'tasks.3', value: task3 },
])

// Bad - multiple transactions
await client.store.set('tasks.1', task1)
await client.store.set('tasks.2', task2)
await client.store.set('tasks.3', task3)
```

---

## See Also

- [Core Principles](./CORE_PRINCIPLES.md) - Design philosophy
- [Threading Model](./THREADING.md) - Parallel query execution
- [Storage Layer](./STORAGE.md) - SQLite optimization
- [Network Layer](./NETWORKING.md) - WebSocket protocol
- [Query Language](../QUERY_LANGUAGE.md) - Query syntax reference
- [Research](./RESEARCH.md) - Performance validation
