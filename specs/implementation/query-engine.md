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
    after: ?[]const u8, // Opaque token (base64 encoded cursor)
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
│     - Apply limit and cursor (after)            │
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
        
        if (query.after) |after| {
            // Implementation detail: Decode after token and apply WHERE filters
            try self.appendCursorFilters(&buf, after);
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
```

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

```zig
fn affectsSubscription(self: *SubscriptionManager, sub: *Subscription, changed_ids: []const []const u8) !bool {
    // If subscription has no filters, any change affects it
    if (sub.query.filters.len == 0) {
        return true;
    }
    
    // Check if any changed ID matches the subscription's filters
    for (changed_ids) |id| {
        const handle = try self.cache.get(id);
        defer handle.release();
        if (try self.matchesFilters(handle.state(), sub.query.filters)) {
            return true;
        }
    }
    
    return false;
}
```

---

## Presence Awareness

ZyncBase's presence system tracks ephemeral user state (cursors, typing indicators, online status) in real-time. All presence data is stored in-memory only. For the internal implementation details of state management, batching, and history buffers, see [Presence Internals](./presence-internals.md).

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

## See Also

- [Core Principles](../architecture/core-principles.md) - Design philosophy
- [Threading Model](../architecture/threading-model.md) - Parallel query execution
- [Storage Layer](../architecture/storage-layer.md) - SQLite optimization
- [Network Layer](./networking.md) - WebSocket protocol
- [Query Language](../api-design/query-language.md) - Query syntax reference
- [Research](../architecture/research.md) - Performance validation
