# Lock-Free Cache

---

## Overview

The Lock-Free Cache is a critical component of ZyncBase's performance strategy. It provides high-concurrency access to shared metadata and authorization records, enabling thousands of concurrent reads without the bottleneck of a global mutex.

**Key Innovation**: Atomic reference counting + immutable metadata/record snapshots = Parallel read access

---

## Why Lock-Free?

### The Bottleneck: Global Mutex

In a traditional multi-threaded system, shared state is often protected by a global mutex. This means even if you have 16 CPU cores, only one thread can read from the cache at a time. This results in:
- High contention
- Thread stalling
- Poor scalability with CPU cores

### The Solution: Lock-Free Reads

By using atomic operations for reference counting and ensuring that state transitions are handled via immutable snapshots, ZyncBase allows any number of threads to read simultaneously.

- **Reads**: 100% parallel, zero locking.
- **Writes**: Serialized via a single-writer mutex, ensuring consistency.

---

## How It Works

1. **Atomic Reference Counting**: When a thread starts a read, it atomically increments a reference count on the current cache entry.
2. **Thread-Safe Retrieval**: The thread performs its query/read operation on the snapshot.
3. **Graceful Release**: Once finished, it atomically decrements the reference count.
4. **Writes via Mutation**: Writes are always serialized by a mutex. When a write completes, the cache entry's version is updated.


---

## Performance Targets

- **Throughput**: >100,000 read operations per second on a standard 16-core machine.
- **Scaling**: Near-linear scaling of reads with additional CPU cores.
- **Latency**: Sub-millisecond retrieval for cached keys.

See [ADR-004](./adrs.md#adr-004-performance-targets) for more on our performance philosophy.

---

## Use Cases

- **Metadata Caching**: Fast lookup of schemas, validated JWT claims, and namespace ID mappings (ADR-006).
- **User Identity Mapping**: Quick resolution of external IDs to internal `users.id` (ADR-011).
- **Authorization Guard Lookups**: Caching per-document records for `$doc` permission checks on the write path (ADR-006).

---

## Trade-offs

### Advantages
✅ **No Read Contention**: Threads never block each other during reads.
✅ **High Throughput**: Maximizes CPU utilization for read-heavy workloads.
✅ **Linear Scalability**: Performance improves as you add more hardware.

### Disadvantages
⚠️ **Implementation Complexity**: Requires careful use of atomic primitives and memory ordering.
⚠️ **Memory Overhead**: Maintaining snapshots or reference counts add slight memory pressure.

---

## See Also

- [Core Principles](./core-principles.md) - Design philosophy
- [Threading Model](./threading-model.md) - How this integrates with the multi-threaded core
- [ADRs](./adrs.md) - Architectural Decision Records
- [Research](./research.md) - Performance benchmarks
