# Message Handler

**Drivers**: [Memory Management](./memory-management.md), [Threading Implementation](./threading.md), [Wire Protocol](./wire-protocol.md)

The `MessageHandler` is the primary component for processing incoming WebSocket messages. It implements the MessagePack wire protocol, handles the per-connection memory lifecycle, and routes operations to the storage engine.

---

## Interface / Contract

```zig
pub const MessageHandler = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    storage_engine: *StorageEngine,
    subscription_manager: *SubscriptionManager,
    connection_registry: ConnectionRegistry,

    /// Process one WebSocket message.
    ///
    /// Guarantees:
    ///   - All temporary allocations (parse buffers, intermediate results) are 
    ///     allocated from a pooled arena via MemoryStrategy.
    ///   - Arena is acquired and released per message.
    ///   - Message processing is synchronized per connection via a mutex in Connection state.
    ///   - Operations are routed to StorageEngine after MessagePack decoding.
    pub fn handleMessage(
        self: *MessageHandler, 
        ws: *WebSocket, 
        message: []const u8, 
        msg_type: MessageType
    ) !void {
        // ... acquisition and mutex locking ...
        const arena = try self.memory_strategy.acquireArena();
        defer self.memory_strategy.releaseArena(arena);
        const arena_allocator = arena.allocator();

        var reader: std.Io.Reader = .fixed(message);
        const payload = try msgpack.decode(arena_allocator, &reader);
        try self.routeMessage(ws, arena_allocator, payload);
    }
};
```

### Memory Management Strategy

| Allocation | Allocator | Lifecycle |
|------------|-----------|-----------|
| Parse buffers, temp strings | Pooled Arena | Released to pool at end of `handleMessage` |
| Persistent state (subscriptions) | GPA | Until connection close |
| Response buffers | GPA | Allocated in `buildSuccessResponse` etc.; Caller sends via `ws.send()` then frees |

### Thread Safety & Concurrency
The `MessageHandler` is shared across all worker threads. Thread safety is achieved through:
1. **Per-Connection Locking**: Each `Connection` struct in the `ConnectionRegistry` has a mutex. `handleMessage` locks this mutex to ensure sequential message processing for a single client.
2. **Atomic Reference Counting**: Connections are ref-counted to ensure safety during concurrent `handleOpen` and `handleClose` events.
3. **Thread-Safe Component Access**: `StorageEngine` and `SubscriptionManager` handle their own internal synchronization.

---

## Invariants & Error Conditions

| Invariant | Description |
|-----------|-------------|
| Arena always released | `defer releaseArena(arena)` ensures cleanup even on error paths |
| Processed under mutex | Messages for the same connection never run concurrently |
| No leak on invalid MsgPack | Faulty payloads are caught by the decoder; arena is still released |

| Error | Cause | Behaviour |
|-------|-------|-----------|
| `error.OutOfMemory` | ArenaPool or GPA exhausted | `INTERNAL_ERROR` sent; connection may be throttled |
| `error.InvalidMessage` | MessagePack parse failure | `INVALID_MESSAGE` sent; violation tracked |
| `error.Unauthorized` | Permission check failed | `UNAUTHORIZED` sent |

---

## Validation & Success Criteria

- [x] Arena is released after every message (checked via pooled arena stats)
- [x] Correct routing for all wire protocol operations (`StoreSet`, `StoreGet`, etc.)
- [x] ThreadSanitizer passes for concurrent message processing across multiple connections

---

## See Also
- [Memory Management](./memory-management.md) — Arena and GPA strategy
- [Threading Implementation](./threading.md) — Per-thread memory isolation
- [Wire Protocol](./wire-protocol.md) — Message format handled by this handler
