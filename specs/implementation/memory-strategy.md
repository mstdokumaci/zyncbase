# Memory Management Implementation

**Drivers**: [Threading Model Architecture](../../architecture/threading-model.md), [ADR-001: Zig as Core Language](../architecture/adrs.md#adr-001-zig-as-core-system-language)

This document contains technical implementation details for ZyncBase's memory management, focusing on the object pool strategy, request-scoped lifetimes, and object lifecycle maintenance.

---

## Logical Architecture

ZyncBase avoids a global garbage collector. Instead, it uses a tiered allocator strategy where memory is managed based on its lifecycle and locality requirements.

```
[System Memory]
      |
      +--- [GPA (General Purpose)] -> Long-lived State (Subscriptions, Server Shell)
      |
      +--- [Arena Allocator]      -> Request-scoped data (Message parsing, temporary buffers)
      |
      +--- [IndexPool]            -> High-churn objects (Connections, Arenas, DeferNodes)
```

## Implementation Artifacts

### Tiered Allocator Strategy
ZyncBase uses specialized allocators for different memory lifetimes to minimize fragmentation and overhead.

```zig
const MemoryStrategy = struct {
    // IndexPool: High-churn/Small objects (Contiguous pre-allocated memory)
    connection_pool: IndexPool(Connection),
    arena_pool: IndexPool(std.heap.ArenaAllocator),
};
```

### Object Pooling

#### IndexPool(T)
Optimized for high-concurrency, high-churn objects where fragmentation and cache locality are critical.
- **Backing**: Contiguous slice of `Node(T)`.
- **Logic**: Uses 64-bit atomics to pack a 32-bit array index and a 32-bit ABA tag.
- **Concurrency**: Metadata (such as `next_index`) MUST be stored using `std.atomic.Value` to prevent TSAN-detected data races during concurrent `pop/release` cycles, even when protected by a tagged stack.
- **Overflow**: If the pool is exhausted, it falls back to dynamic heap allocation.
- **Use Case**: `Connection`, `ArenaAllocator`, `lockFreeCache.DeferNode`.

```zig
// IndexPool core logic snippet
pub fn release(self: *Self, data: *T) void {
    const node: *Node = @alignCast(@fieldParentPtr("data", data));
    const ptr = @intFromPtr(node);
    const start = @intFromPtr(self.nodes.ptr);
    const end = start + self.nodes.len * @sizeOf(Node);

    if (ptr >= start and ptr < end) {
        // Fast path: push back to contiguous array stack
        // ... index bit-packing logic ...
    } else {
        // Overflow path: destroy heap-allocated node (self-healing)
        if (self.deinitData) |deinit_fn| deinit_fn(self.allocator, data);
        self.allocator.destroy(node);
    }
}
```

## Operational Logic

### Pool Selection Matrix

| Pool Type | Backing | Sync Type | Locality | Best For |
|-----------|---------|-------------|----------|----------|
| **IndexPool** | Contiguous | 64-bit Atomic Index | Excellent | Frequent/Small objects |

### Memory Safety Best Practices
- **No Unbounded Allocations**: All parsers (MessagePack) enforce strict depth and size limits to prevent OOM attacks.
- **Self-Healing Pools**: `IndexPool` returns dynamic memory to the OS immediately upon release to avoid footprint bloat.
- **In-Place Initialization**: Types containing `std.Thread.Mutex` or `std.atomic.Value` MUST be initialized in-place (e.g., `initInPlace(self: *T, ...)`). Returning such types by value is illegal as it leads to memory corruption in synchronized components.
- **Fail-Fast on OOM**: ZyncBase treats allocation failure as a fatal request error.

## Invariants & Error Conditions

| Condition | Invariant |
|-----------|-----------|
| Arena reset | Must happen via `defer` before the request handler returns |
| Pool exhaustion | `IndexPool.pop()` returns `null`; `IndexPool.acquire()` falls back to heap |
| OOM | Returns `error.OutOfMemory` which maps to `INTERNAL_ERROR` |
| Index Overflow | `IndexPool` capacity is capped at `u32.max` to ensure 64-bit packing |

## Validation & Success Criteria

### Success Metrics
- [x] Zero heap allocation for `Connection` and `Arena` cycles under steady state
- [x] Leak-free execution under GPA safety checks
- [x] Race-free atomic operations verified via `TSAN`

### Verification Commands
```bash
# Verify naming and basic consistency
bun run lint

# Verify pool stability under concurrency
bun run test:tsan

# Full integration verification
bun run test:e2e
```

---

## See Also
- [Threading Model Architecture](../../architecture/threading-model.md)
- [Lock-Free Cache Implementation](./lock-free-cache.md)
