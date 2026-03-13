# Lock-Free Cache Implementation

**Drivers**: [Lock-Free Cache Architecture](../../architecture/lock-free-cache.md), [Threading Implementation](./threading.md)

This document contains the implementation specifics for the ZyncBase lock-free cache, which enables parallel read access across all CPU cores without global locks.

---

## Logical Architecture

The lock-free cache uses atomic reference counting and a single-writer-multiple-reader (SWMR) model. Writes are serialized by a mutex, while reads are entirely wait-free.

```
[Reader Thread A] --+
[Reader Thread B] --+--> [Atomic Value: Hash Map Pointer]
[Reader Thread C] --+           |
                                v
                       [Current Hash Map]
                        /       |       \
               [Entry 1]    [Entry 2]    [Entry 3]
```

## Implementation Artifacts

### Core Structure

```zig
pub const LockFreeCache = struct {
    // Atomic pointer to the current hash map
    entries: std.atomic.Value(*std.StringHashMap(*CacheEntry)),
    allocator: Allocator,
    write_mutex: std.Thread.Mutex,
};

pub const CacheEntry = struct {
    state: StateTree,
    version: std.atomic.Value(u64),
    ref_count: std.atomic.Value(u32),
    timestamp: std.atomic.Value(i64),
};
```

### Wait-Free Read Path

```zig
pub fn get(self: *LockFreeCache, namespace: []const u8) !*StateTree {
    // Acquire the current map pointer
    const map = self.entries.load(.Acquire);
    const entry = map.get(namespace) orelse return error.NotFound;
    
    // Safely increment reference count before return
    _ = entry.ref_count.fetchAdd(1, .AcqRel);
    
    return &entry.state;
}
```

## Operational Logic

### Memory Ordering guarantees
- **Acquire/Release**: Used for map pointer synchronization to ensure a reader never sees a partially updated map.
- **AcqRel**: Used for reference counting to ensure visibility across all cores.

### Writer Serialization
While reads are lock-free, all mutations (`update`, `evict`, `create`) must acquire the `write_mutex`. This ensures that only one thread is re-building the map at a time, preventing race conditions during map rotation.

## Validation & Success Criteria

### Performance Targets
- [ ] Concurrent Read Scaling: Linear scaling up to 64 cores.
- [ ] Read Latency: < 500ns for hot entries.
- [ ] Zero Lock Contention on the read path.

### Verification Commands
```bash
# Run stress tests with thread sanitizer
zig test src/cache_stress_test.zig -fsanitize=thread
```

---

## See Also
- [Threading Implementation](./threading.md)
- [Storage Implementation](./storage.md)
- [Memory Management](./memory-management.md)
