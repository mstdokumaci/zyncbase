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
        items: []T,
        available: std.atomic.Value(usize),
        
        pub fn acquire(self: *Self) ?*T {
            // Atomic logic to grab an object from the pool
        }
        
        pub fn release(self: *Self, item: *T) void {
            // Atomic logic to return an object to the pool
        }
    };
}
```

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

## Validation & Success Criteria

### Success Metrics
- [ ] Leak-free execution (Sanitizers pass)
- [ ] Fragmentation remains < 10% under load
- [ ] Average allocation latency < 5μs

### Verification Commands
```bash
# Run tests with leak detection enabled
zig test src/memory_management_test.zig
```

---

## See Also
- [Threading Model Architecture](../../architecture/threading-model.md)
- [MessagePack Parser Implementation](./messagepack-parser.md)
