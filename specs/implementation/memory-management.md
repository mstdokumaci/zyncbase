# Memory Management Implementation

**Drivers**: [Threading Model Architecture](../../architecture/threading-model.md), [ADR-001: Zig as Core Language](../architecture/adrs.md#adr-001-zig-as-core-system-language)

This document contains technical implementation details for ZyncBase's memory management, focusing on manual allocation strategies, request-scoped lifetimes, and object pooling.

---

## Logical Architecture

ZyncBase avoids a global garbage collector. Instead, it uses a tiered allocator strategy where memory is managed based on its lifecycle.

```
[System Memory]
      |
      +--- [GPA (General Purpose)] -> Long-lived State (Subscriptions, Connections)
      |
      +--- [Arena Allocator]      -> Request-scoped data (Message parsing, temporary buffers)
      |
      +--- [Object Pools]         -> High-frequency reusable buffers
```

## Implementation Artifacts

### Tiered Allocator Strategy
ZyncBase uses specialized allocators for different memory lifetimes to minimize fragmentation and overhead.

```zig
const Server = struct {
    // Long-lived allocations (Connections, Subscriptions)
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    
    // Per-request arena for bulk freeing
    arena: std.heap.ArenaAllocator,
    
    // Object pools for reusable buffers
    message_pool: Pool(Message),
    
    pub fn handleRequest(self: *Server) !void {
        // Create a scoped allocator for this request
        var request_arena = std.heap.ArenaAllocator.init(self.gpa.allocator());
        defer request_arena.deinit(); // Bulk free all request memory
        
        const allocator = request_arena.allocator();
        
        // All request processing uses this allocator
        const msg = try msgpack.decode(allocator, raw_data);
        // ...
    }
};
```

### Object Pooling
For high-frequency objects like `Message` or `Buffer`, ZyncBase uses a lock-free object pool to avoid repeated allocation churn.

```zig
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        free_stack: std.atomic.Value(usize), // index of top free slot; usize_max = empty

        pub fn acquire(self: *Self) ?*T {
            var top = self.free_stack.load(.Acquire);
            while (top != std.math.maxInt(usize)) {
                const next = self.items[top].next_free; // embedded free-list index
                if (self.free_stack.cmpxchgWeak(top, next, .AcqRel, .Acquire)) |_| {
                    top = self.free_stack.load(.Acquire);
                } else {
                    return &self.items[top];
                }
            }
            return null; // pool exhausted
        }

        pub fn release(self: *Self, item: *T) void {
            const idx = (@intFromPtr(item) - @intFromPtr(self.items.ptr)) / @sizeOf(T);
            var top = self.free_stack.load(.Acquire);
            while (true) {
                item.next_free = top;
                if (self.free_stack.cmpxchgWeak(top, idx, .AcqRel, .Acquire)) |_| {
                    top = self.free_stack.load(.Acquire);
                } else {
                    return;
                }
            }
        }
    };
}
```

`T` must embed a `next_free: usize` field used as the intrusive free-list link. Pool capacity is fixed at init time; `acquire` returns `null` when exhausted — callers must handle this and fall back to the GPA.

## Operational Logic

### Allocator Types & Use Cases

| Allocator | Lifecycle | Characteristic |
|-----------|-----------|----------------|
| **Arena** | Request | Fast allocation, single bulk-deallocation at end of request. |
| **GPA** | System | Manual `alloc`/`free`. Used for state that outlives a single request. |
| **Pool** | Static | Zero allocation at runtime. Pre-allocated memory for hot objects. |

### Memory Safety Best Practices
- **No Unbounded Allocations**: All parsers (MessagePack) enforce strict depth and size limits to prevent OOM attacks.
- **Explicit Freeing**: GPA-backed state must be manually tracked and freed on disconnect.
- **Fail-Fast on OOM**: ZyncBase treats allocation failure as a fatal request error, returning `INTERNAL_ERROR` to the client.

## Invariants & Error Conditions

| Condition | Invariant |
|-----------|-----------|
| Arena reset | Must happen via `defer` before the function that created the arena returns |
| GPA-backed state | Every allocation has a matching `free` on disconnect or eviction |
| Pool exhaustion | `acquire` returns `null`; caller falls back to GPA — never panics |
| OOM | Treated as fatal for the current request; returns `error.OutOfMemory` to caller, which maps to `INTERNAL_ERROR` on the wire |
| Unbounded allocation | All parsers enforce `max_size` before allocating; allocation is refused if limit exceeded |

## Validation & Success Criteria

### Success Metrics
- [ ] Leak-free execution under GPA safety checks
- [ ] Fragmentation < 10% under sustained load (measured via GPA stats)
- [ ] Average arena allocation latency < 5μs

### Verification Commands
```bash
# Run with GPA leak detection (debug build)
zig test src/memory_strategy_test.zig

# Run with thread sanitizer to catch pool race conditions
zig test src/memory_strategy_test.zig -Dsanitize=thread

# Confirm no leaks survive a full request cycle
zig test src/request_handler_test.zig
```

---

## See Also
- [Threading Model Architecture](../../architecture/threading-model.md)
- [MessagePack Parser Implementation](./messagepack-parser.md)
