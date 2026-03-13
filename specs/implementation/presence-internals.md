# Presence Internals

**Drivers**: [Presence API Design](../api-design/presence-api.md) - Formal requirements for user awareness and ephemeral state.

This document covers the architectural details, performance optimizations, and internal implementation of ZyncBase's presence system.

---

## Logical Architecture

Presence is strictly scoped to `presenceNamespace`. The server manages a hash map of namespaces, each containing a map of active users. This ensures that a user's presence updates only affect others in the same logical context.

```
[WebSocket Client] -> [PresenceManager (In-Memory)]
                           |
            +--------------+--------------+
            |                             |
      [State Map]                 [History Buffer]
  (User -> Presence)             (Last 5 Seconds)
```

## Implementation Artifacts

### Presence Manager
The core state management is handled by `PresenceManager`, which keeps all data in RAM for sub-100ms latency.

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

### History Ring Buffer
Used to provide immediate context (like cursor trails) to late joiners.

```zig
const RingBuffer = struct {
    items: []PresenceSnapshot,
    head: usize,
    tail: usize,
    
    pub fn getLastNSeconds(self: *RingBuffer, seconds: i64) []PresenceSnapshot {
        const now = std.time.milliTimestamp();
        const cutoff = now - (seconds * 1000);
        
        var result = ArrayList(PresenceSnapshot).init(allocator);
        // ... filtering logic ...
        return result.toOwnedSlice();
    }
};
```

## Operational Logic

### Client-Side Throttling
High-frequency updates (e.g., cursor moves) are automatically throttled by the client SDK to ~60fps (16ms) to prevent overwhelming the network and server.

### Server-Side Batching
The server batches presence updates every 50ms. If multiple users update their state within the same window, they are broadcast in a single message.

### Automatic Cleanup
When a WebSocket connection is closed (manual disconnect or heartbeats fail), the server automatically removes the associated presence data using `PresenceManager.remove()` and broadcasts a removal message.

## Validation & Success Criteria

### Success Metrics
- [ ] Latency (Set): < 1ms
- [ ] Latency (Get): < 100μs
- [ ] Broadcast Interval: 50ms (+/- 5ms)

### Verification Commands
```bash
zig test src/presence_manager_test.zig
```

---

## See Also
- [Presence API Design](../api-design/presence-api.md)
- [Query Engine Implementation](./query-engine.md)
- [Store API Reference](../api-design/store-api.md)
