# Threading Model

---

## Overview

ZyncBase uses a **multi-threaded architecture with read/write separation** to maximize vertical scaling. This design allows the system to utilize all CPU cores for read operations while maintaining correctness through serialized writes.

**Key Innovation**: Subscription Engine for parallel application data reads + lock-free cache for metadata + mutex for writes = 17x performance improvement

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
│    │ Subscription      │       │    Write Mutex    │    │
│    │ Engine (warm)     │       │  ┌──────────────┐ │    │
│    │ ┌──┐  ┌──┐  ┌──┐  │       │  │ Single Writer│ │    │
│    │ │T1│  │T2│  │TN│  │       │  └──────────────┘ │    │
│    │ └──┘  └──┘  └──┘  │       │    State Updates  │    │
│    │ Lock-Free Cache   │       └─────────┬─────────┘    │
│    │ (auth/schema/ns)  │                 │              │
│    └─────────┬─────────┘       ┌─────────▼─────────┐    │
│         (cold)                 │   SQLite Writer   │    │
│    ┌─────────▼─────────┐       │  ┌──────────────┐ │    │
│    │ SQLite Read Pool  │       │  │ WAL Batching │ │    │
│    │  ┌──┐  ┌──┐  ┌──┐ │       │  └──────────────┘ │    │
│    │  │R1│  │R2│  │RN│ │       │    (WAL Mode)     │    │
│    │  └──┘  └──┘  └──┘ │       └───────────────────┘    │
│    │    (WAL Mode)     │                                 │
│    └───────────────────┘                                 │
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

Application data reads go through the **Subscription Engine**:
- Warm collections (with active subscribers) are evaluated entirely in memory — O(1) per unique subscription group, no SQLite involvement.
- Cold one-shot queries (`StoreQuery` with no active subscription) hit the SQLite read pool directly.
- The **lock-free cache** serves auth/schema metadata, namespace-to-integer mappings, and user identity mappings — all immutable once set, making them ideal for wait-free reads.
- Multiple threads execute simultaneously with no cross-thread contention on the hot path.
- Scales linearly with CPU cores.

**Write Path (Serialized):**
- Mutex-protected for correctness
- Single writer thread processes batched operations
- Publishes `RecordChange` events to the Subscription Engine after commit
- Notifies subscribers asynchronously via `NotificationDispatcher`

---

## Thread Safety Strategy

The core engine routes incoming messages to either the parallel read path or the serialized write path. The Subscription Engine maintains in-memory collection state updated by the writer thread after each commit. The lock-free cache handles auth/schema/namespace/identity metadata with atomic reference counting and COW map swaps.


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

**Result: 17x performance improvement**

### Why This Works

**1. Warm reads are lock-free and in-memory**
- Subscription Engine evaluates against in-memory state
- No SQLite round-trip for subscribed collections
- No contention, scales with CPU cores

**2. Cold reads use the parallel SQLite read pool**
- One reader connection per CPU core
- WAL mode enables true parallel reads

**3. Writes are serialized**
- Necessary for correctness (ACID)
- SQLite single-writer limitation
- Batching keeps throughput high (10k+ writes/sec)

**4. Read-heavy workloads scale linearly**
- Most real-time apps are 80-95% reads
- Reads use all CPU cores
- Writes don't bottleneck reads

---

## Memory Management Strategy

ZyncBase employs specialized allocation patterns to minimize overhead in a high-concurrency environment:
- **Arena Allocation** for request-scoped data.
- **Object Pooling** for reusing common structures.
- **Allocator Strategies** (Arena, Pool, GPA).

---

## Pros and Cons

### Pros

✅ **Uses all CPU cores** - True vertical scaling
✅ **Warm reads are fully in-memory** - Subscription Engine eliminates SQLite round-trips for active data
✅ **SQLite parallel reads** - Fully utilized for cold queries
✅ **17x better performance** - Than single-threaded
✅ **Lock-free metadata** - Auth/schema/namespace lookups are wait-free

### Cons

⚠️ **Writes are serialized** - SQLite single-writer limitation
⚠️ **Need atomic operations** - For lock-free cache
⚠️ **Cold queries hit SQLite** - First subscribe to a collection incurs a read
⚠️ **More complex** - Than single-threaded approach

### Mitigation

**For serialized writes:**
- Most workloads are read-heavy (90%+)
- 10k writes/sec is sufficient for most apps
- Batching increases effective throughput

**For cold queries:**
- After first subscribe, all subsequent reads for that collection are in-memory
- `loadMore` always hits SQLite by design (historical data, not hot path)

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

---

## See Also

- [ADRs](./adrs.md) - Architectural Decision Records
- [Storage Layer](./storage-layer.md) - Details on parallel disk access
- [Core Principles](./core-principles.md) - Design philosophy
- [Research](./research.md) - Performance validation and benchmarks
