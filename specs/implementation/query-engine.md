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
const SubscriptionId = u64;

/// Internal representation of a group of subscribers sharing the same Filter AST
const SubscriptionGroup = struct {
    id: u64,
    namespace: []const u8,
    collection: []const u8,
    filter: QueryFilter,
    /// Set of (connection_id, client_subscription_id)
    subscribers: std.AutoHashMapUnmanaged(SubscriberKey, void),

    pub const SubscriberKey = struct {
        connection_id: u64,
        id: SubscriptionId,
    };
};

const SubscriptionEngine = struct {
    /// group_id -> SubscriptionGroup
    groups: std.AutoHashMapUnmanaged(u64, SubscriptionGroup),
    /// collection_key (ns:coll) -> ArrayList(GroupId)
    groups_by_collection: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u64)),
    /// (conn_id, sub_id) -> group_id
    active_subs: std.AutoHashMapUnmanaged(SubscriptionGroup.SubscriberKey, u64),
    
    pub fn handleRowChange(self: *SubscriptionEngine, change: RowChange) ![]Match {
        // Implementation logic...
    }
};
```

### Change Detection

ZyncBase uses a **Fine-Grained Observation** strategy to ensure sub-100ms real-time sync without overloading the SQLite reader pool.

**Strategy: Fine-Grained Observation (ADR-018)**
- The Writer thread or Message Handler emits a `RowChange` event.
- The `SubscriptionEngine` evaluates the change against active `SubscriptionGroups` in memory.
- **No SQLite queries are re-run** for standard filter matching.
- Only clients subscribed to groups that match the before or after state of the record are notified.

### Implementation Details

The notification pipeline operates entirely in RAM:

```zig
pub fn handleRowChange(self: *SubscriptionEngine, change: RowChange, allocator: Allocator) ![]Match {
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ change.namespace, change.collection });
    const group_ids = self.groups_by_collection.get(key) orelse return &.{};

    var matches = std.ArrayList(Match).init(allocator);
    for (group_ids.items) |gid| {
        const group = self.groups.get(gid) orelse continue;

        const matched_before = if (change.old_row) |old| try evaluateFilter(group.filter, old) else false;
        const matches_after = if (change.new_row) |new| try evaluateFilter(group.filter, new) else false;

        if (matched_before or matches_after) {
            // Group-level match means all subscribers in group receive notification
            var it = group.subscribers.keyIterator();
            while (it.next()) |sub| {
                try matches.append(.{ .connection_id = sub.connection_id, .subscription_id = sub.id });
            }
        }
    }
    return matches.toOwnedSlice();
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
