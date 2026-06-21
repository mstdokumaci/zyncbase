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
    // Atomic pointers to RCU-style snapshots (ADR-006)
    auth_snapshots: std.atomic.Value(*std.StringHashMap(*AuthSnapshotEntry)),
    schema_metadata: std.atomic.Value(*SchemaMetadataEntry),
    namespace_ids: std.atomic.Value(*std.StringHashMap(u32)),
    user_ids: std.atomic.Value(*std.StringHashMap(DocId)),
    document_records: std.atomic.Value(*std.AutoHashMap(DocKey, *DocumentEntry)),
    
    allocator: Allocator,
    write_mutex: std.Thread.Mutex,
};

pub const AuthSnapshotEntry = struct {
    claims: JWTClaims,
    ref_count: std.atomic.Value(u32),
};

pub const DocumentEntry = struct {
    fields: std.AutoHashMap(u16, Value),
    ref_count: std.atomic.Value(u32),
};
```

### Wait-Free Read Path

```zig
pub fn getDocument(self: *LockFreeCache, key: DocKey) !*DocumentEntry {
    // Acquire the current map pointer
    const map = self.document_records.load(.Acquire);
    const entry = map.get(key) orelse return error.NotFound;
    
    // Safely increment reference count before return
    _ = entry.ref_count.fetchAdd(1, .AcqRel);
    
    return entry;
}
```

## Invariants & Error Conditions

### ref_count Overflow
`ref_count` is a `u32`. If it reaches `std.math.maxInt(u32)`, the next `fetchAdd` wraps to 0, causing a use-after-free when the writer evicts the entry while readers still hold it. This must never happen in practice because the number of concurrent reader threads is bounded by the CPU core count (≤ 256 on supported hardware). The invariant is:

```
ref_count ≤ thread_count_max  (always << u32 max)
```

In debug builds, assert this after every `fetchAdd`:
```zig
const prev = entry.ref_count.fetchAdd(1, .AcqRel);
std.debug.assert(prev < 65536); // sanity bound well below u32 max
```

### Eviction Contract
An entry may only be freed by the writer when `ref_count == 0`. The writer must:
1. Remove the entry from the map (under `write_mutex`).
2. Spin-wait or defer until `entry.ref_count.load(.Acquire) == 0`.
3. Only then call `allocator.destroy(entry)`.

Readers that loaded the pointer before the map swap may still hold a reference; the eviction wait ensures they complete before the memory is reclaimed.

### Error Conditions

| Error | Cause | Behaviour |
|-------|-------|-----------|
| `error.NotFound` | Key or record not in cache | Caller falls through to storage/database |
| ref_count overflow | > 65536 concurrent readers on one entry | Debug assert fires; release build: undefined behaviour — must not occur |
| Double-release | `release()` called without matching `get()` | ref_count underflows; debug assert fires |

## Operational Logic

### Memory Ordering Guarantees
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
- [Memory Management](./memory-strategy.md)
