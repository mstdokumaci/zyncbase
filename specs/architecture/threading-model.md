# Threading Model

**Last Updated**: 2026-03-09

---

## Overview

ZyncBase uses a **multi-threaded architecture with read/write separation** to maximize vertical scaling. This design allows the system to utilize all CPU cores for read operations while maintaining correctness through serialized writes.

**Key Innovation**: Lock-free cache for reads + mutex for writes = 17x performance improvement

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│          uWebSockets Event Loop (Multi-threaded)        │
│       │                    │                    │       │
│    Thread 1             Thread 2             Thread N   │
│   WebSocket            WebSocket            WebSocket   │
│  Connections          Connections          Connections  │
│       │                    │                    │       │
│       └────────────────────┼────────────────────┘       │
│                            │                            │
│                     Callbacks (Zig)                     │
│                            │                            │
│              ┌─────────────▼─────────────┐              │
│              │       Message Router      │              │
│              └─────────────┬─────────────┘              │
│                            │                            │
│              ┌─────────────┴─────────────┐              │
│              │                           │              │
│          READ PATH                   WRITE PATH         │
│    (Parallel, Lock-Free)        (Serialized, Mutex)     │
│              │                           │              │
│    ┌─────────▼─────────┐       ┌─────────▼─────────┐    │
│    │  Lock-Free Cache  │       │    Write Mutex    │    │
│    │  ┌──┐  ┌──┐  ┌──┐ │       │  ┌──────────────┐ │    │
│    │  │T1│  │T2│  │TN│ │       │  │ Single Writer│ │    │
│    │  └──┘  └──┘  └──┘ │       │  └──────────────┘ │    │
│    │  Atomic Ref Count │       │    State Updates  │    │
│    └─────────┬─────────┘       └─────────┬─────────┘    │
│              │                           │              │
│    ┌─────────▼─────────┐       ┌─────────▼─────────┐    │
│    │ SQLite Read Pool  │       │   SQLite Writer   │    │
│    │  ┌──┐  ┌──┐  ┌──┐ │       │  ┌──────────────┐ │    │
│    │  │R1│  │R2│  │RN│ │       │  │ WAL Batching │ │    │
│    │  └──┘  └──┘  └──┘ │       │  └──────────────┘ │    │
│    │    (WAL Mode)     │       │    (WAL Mode)     │    │
│    └───────────────────┘       └───────────────────┘    │
│                                                         │
│  Performance (16-core, 90% reads):                      │
│  - Reads:  16 × 11k = 176k req/sec (parallel)           │
│  - Writes:  1 × 10k =  10k req/sec (serialized)         │
│  - Total: ~170k req/sec average                         │
│  - CPU usage: ~95% (all cores utilized)                 │
└─────────────────────────────────────────────────────────┘
```

---

## How It Works

### 1. uWebSockets Handles Multi-threading

- Event loop runs on multiple threads
- Automatically distributes connections across threads
- Handles all network I/O
- No blocking between threads

### 2. Zig Callbacks Execute in Parallel

- Multiple threads can process messages simultaneously
- Message router directs to read or write path
- No blocking between read operations
- Writes are queued and serialized

### 3. Core Engine Uses Read/Write Separation

**Read Path (Parallel):**
- Lock-free cache access
- Multiple threads execute simultaneously
- SQLite connection pool enables parallel database reads
- Scales linearly with CPU cores

**Write Path (Serialized):**
- Mutex-protected for correctness
- Single writer thread
- Batched writes to SQLite
- Notifies subscribers after write

---

## Thread Safety Strategy

The core engine acts as the orchestrator, routing incoming messages to either the parallel read path or the serialized write path. It ensures that the lock-free cache is kept in sync with the underlying storage.

Detailed synchronization logic and Zig implementation can be found in the [Threading Implementation](../implementation/threading.md).

---

## Performance Characteristics

### Typical Workload (90% reads, 10% writes)

**16-core machine:**
```
Reads:  16 cores × ~11k each = 176k req/sec (parallel)
Writes:  1 core  × ~10k      =  10k req/sec (serialized)
Combined: ~170k req/sec average
CPU usage: ~95% (all cores utilized)
```

**vs Single-threaded approach:**
```
Reads:  1 core × 10k = 10k req/sec
Writes: 1 core × 10k = 10k req/sec
Combined: 10k req/sec
CPU usage: 6% (1/16 cores)
```

**Result: 17x performance improvement!**

### Why This Works

**1. Reads are lock-free**
- Multiple threads read simultaneously
- No contention, scales with CPU cores
- SQLite parallel reads fully utilized

**2. Writes are serialized**
- Necessary for correctness (ACID)
- SQLite single-writer limitation
- Still fast (10k+ writes/sec)

**3. Read-heavy workloads scale linearly**
- Most real-time apps are 80-95% reads
- Reads use all CPU cores
- Writes don't bottleneck reads

---

## Memory Management Strategy

ZyncBase employs specialized allocation patterns to minimize overhead in a high-concurrency environment. See [Memory Management Implementation](../implementation/memory-management.md) for technical specifics on:
- **Arena Allocation** for request-scoped data.
- **Object Pooling** for reusing common structures.
- **Allocator Strategies** (Arena, Pool, GPA).

---

## Pros and Cons

### Pros

✅ **Uses all CPU cores** - True vertical scaling  
✅ **Reads scale linearly** - More cores = more throughput  
✅ **SQLite parallel reads** - Fully utilized  
✅ **17x better performance** - Than single-threaded  
✅ **Still simple** - No complex locking patterns  

### Cons

⚠️ **Writes are serialized** - SQLite single-writer limitation  
⚠️ **Need atomic operations** - For lock-free cache  
⚠️ **More complex** - Than single-threaded approach  

### Mitigation

**For serialized writes:**
- Most workloads are read-heavy (90%+)
- 10k writes/sec is sufficient for most apps
- Can batch writes for higher throughput

**For atomic operations:**
- Zig provides safe atomic primitives
- Compile-time checks prevent race conditions
- Extensive testing validates correctness

---

## Comparison with Alternatives

### Single-threaded Core (Rejected)

**Pros:**
- Simpler implementation
- No race conditions
- Easier to reason about

**Cons:**
- Cannot utilize multiple CPU cores
- Limited to ~10k req/sec total
- Wastes SQLite parallel read capability
- Not competitive with Bun/modern systems

### Thread-per-Namespace (Future)

**Pros:**
- Natural isolation per tenant
- Could scale beyond single-writer limit

**Cons:**
- More complex than read/write separation
- Harder to load balance
- Requires more sophisticated scheduling

**Decision:** Defer to v2.5+ if needed

---

## See Also

- [ADRs](./adrs.md) - Architectural Decision Records
- [Storage Layer](./storage-layer.md) - Details on parallel disk access
- [Core Principles](./core-principles.md) - Design philosophy
- [Research](./research.md) - Performance validation and benchmarks
