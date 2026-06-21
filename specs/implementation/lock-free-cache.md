# Lock-Free Cache

**Drivers**: [ADR-006](../architecture/adrs.md#adr-006-multi-threaded-core-engine), [Threading](./threading.md), [Memory Strategy](./memory-strategy.md)

The lock-free cache is a reusable read-mostly cache primitive. It is used where concurrent readers need stable handles without taking a global lock while writers replace or retire entries through controlled ownership rules.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/lock_free_cache.zig` | Generic `lockFreeCache` type factory and handle/ref-count contract. |
| `src/storage_engine/cache.zig` | Storage metadata cache key/value types built on the cache primitive. |
| `src/jwt_validator.zig` | JWKS/cache usage for authentication. |
| `src/*lock_free_cache*_test.zig` | Concurrency, lifetime, and leak coverage. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `lockFreeCache(...)` | allocator, key/value/hash/eql functions | Produces a typed cache implementation for one key/value domain. |
| Cache entry | atomic ref count, key/value | Stores one value and tracks active readers. |
| Cache handle | cache entry pointer | Keeps a value alive for a reader until release. |
| Storage cache keys | namespace/identity typed ids | Avoid repeated namespace/user metadata lookup. |
| JWKS cache state | JWT validator | Avoid repeated key fetch/parse while respecting refresh policy. |

## Contract

- Readers acquire a handle and must release it exactly once.
- Values read through a handle remain valid until the handle is released.
- Writers may replace entries, but retired entries are freed only after active readers release.
- Cache users own key/value clone/deinit behavior for their domain.
- Cache internals are not a public error-code source; unexpected overflow or allocator failure maps through the owning subsystem.

## Invariants

- No reader observes freed memory.
- Reference counts cannot wrap silently.
- Entry retirement must not block unrelated readers.
- Deinit requires no leaked active handles.
- Cache value types must not contain arena-owned pointers unless the arena outlives every cache handle, which request arenas never do.

## Performance Contract

| Property | Value | Notes |
|----------|-------|-------|
| Max deferred nodes | 100,000 | Maximum COW map snapshots + old entries before pool exhaustion. |
| Reclamation interval | 100 ms | Background thread wake interval for freeing old snapshots. |
| Thread epoch slots | 128 | Maximum concurrent thread readers (limits parallel cache access). |

### Performance Targets (from ADR-004)

| Metric | Target |
|--------|--------|
| Cache throughput | > 100,000 reads/sec on 16-core |
| Cache latency | Sub-millisecond retrieval |

**Overflow policy**: If `max_deferred_nodes` is reached, cache updates block until reclamation catches up. This is a backpressure mechanism to prevent unbounded memory growth.

## See Also

- [Threading](./threading.md)
- [Memory Strategy](./memory-strategy.md)
- [Storage](./storage.md)
