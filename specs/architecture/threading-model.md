# Threading Model

---

## Overview

ZyncBase uses a **deterministic thread budget architecture** with six fixed thread domains. Thread counts are computed from CPU core count using a hardcoded formula — there are no configuration overrides. The server refuses to start on machines with fewer than 4 CPU cores.

**Key Innovation**: Deterministic thread allocation ensures predictable resource usage and eliminates configuration-induced performance cliffs.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    ZyncBase Thread Domains                       │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ Event Loop   │  │    Writer    │  │  Checkpoint  │           │
│  │   (1 fixed)  │  │   (1 fixed)  │  │   (1 fixed)  │           │
│  │              │  │              │  │              │           │
│  │  WebSocket   │  │  SQLite WAL  │  │  Background  │           │
│  │  I/O + Msg   │  │  Commit      │  │  WAL→DB      │           │
│  │  Dispatch    │  │  Serialization│ │  Flush       │           │
│  └──────┬───────┘  └──────┬───────┘  └──────────────┘           │
│         │                 │                                      │
│         │          ┌──────▼───────┐  ┌──────────────┐           │
│         │          │  Presence    │  │ Notification │           │
│         │          │   (1 fixed)  │  │  (variable)  │           │
│         │          │              │  │              │           │
│         │          │  Broadcast   │  │  Change      │           │
│         │          │  Encoding    │  │  Evaluation  │           │
│         │          └──────────────┘  │  + Dispatch  │           │
│         │                            └──────────────┘           │
│         │                                                        │
│  ┌──────▼───────────────────────────────────────────────────┐   │
│  │                    Reader Pool                            │   │
│  │              (variable, max 4)                            │   │
│  │   ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐                │   │
│  │   │ R1   │  │ R2   │  │ R3   │  │ R4   │                │   │
│  │   │SQLite│  │SQLite│  │SQLite│  │SQLite│                │   │
│  │   │ WAL  │  │ WAL  │  │ WAL  │  │ WAL  │                │   │
│  │   └──────┘  └──────┘  └──────┘  └──────┘                │   │
│  └───────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Thread Budget Formula

The thread budget is computed at startup from the detected CPU core count:

```
if cpu_count < 4 → server refuses to start

fixed:
  event_loop   = 1
  writer       = 1
  checkpoint   = 1
  presence     = 1

variable:
  readers      = min(4, max(1, (cpu_count - 4) / 2))
  notification = max(1, cpu_count - 4 - readers)
```

### Thread Count by CPU Cores

| CPU Cores | Event Loop | Writer | Checkpoint | Presence | Readers | Notification | Total |
|-----------|------------|--------|------------|----------|---------|--------------|-------|
| 4         | 1          | 1      | 1          | 1        | 1       | 1            | 6     |
| 8         | 1          | 1      | 1          | 1        | 2       | 2            | 8     |
| 16        | 1          | 1      | 1          | 1        | 4       | 8            | 16    |
| 32        | 1          | 1      | 1          | 1        | 4       | 24           | 32    |

---

## Thread Domain Responsibilities

### Event Loop (1 thread, fixed)
- Runs the uWebSockets reactor
- Handles all WebSocket I/O (connect, message, disconnect)
- Dispatches post-handler callbacks (notification poll, presence poll, write outcome poll)
- Must never block — all I/O is non-blocking

### Writer (1 thread, fixed)
- Receives mutations from the write queue
- Commits to SQLite in serialized order
- Publishes `RecordChange` events to the Subscription Engine after commit
- Total write ordering is architecturally guaranteed

### Checkpoint (1 thread, fixed)
- Background WAL→main database flush
- Periodic full checkpoints
- Decoupled from write path to avoid blocking mutations

### Presence (1 thread, fixed)
- Encodes presence broadcasts from batched state
- Pushes encoded messages to the send queue
- Runs on a 50ms tick or condition variable wake

### Reader Pool (variable, max 4)
- Each reader holds its own SQLite connection in WAL read mode
- Serves cold queries (subscriptions with no active warm state)
- Serves `loadMore` operations for pagination
- Scales with CPU cores up to 4 readers

### Notification (variable)
- Drains the change buffer after storage commits
- Evaluates subscription filters (CPU-heavy)
- Encodes delta messages
- Pushes to the send queue for event loop delivery

---

## How It Works

### 1. Message Arrival
- WebSocket message arrives on the event loop thread
- Message handler parses and routes to read or write path
- No blocking — all operations are dispatched asynchronously

### 2. Write Path (Serialized)
- Mutation is enqueued to the write queue
- Writer thread dequeues, commits to SQLite
- After commit, `RecordChange` events are published
- Notification threads evaluate subscriptions and encode deltas
- Deltas are pushed to send queue, delivered by event loop

### 3. Read Path (Parallel)
- Warm reads (active subscriptions) evaluate in-memory via Subscription Engine
- Cold reads (no active subscription) use reader pool
- Reader pool threads execute SQLite queries in parallel
- Results are encoded and sent via event loop

### 4. Presence Path (Dedicated)
- Presence updates are batched in PresenceManager
- Presence dispatch thread encodes broadcasts
- Broadcasts are pushed to send queue for event loop delivery

---

## Thread Safety Strategy

The core engine routes incoming messages to either the parallel read path or the serialized write path. The Subscription Engine maintains in-memory collection state updated by the writer thread after each commit. The lock-free cache handles auth/schema/namespace/identity metadata with atomic reference counting and COW map swaps.

**Synchronization boundaries:**
- Connection state: mutated only through Connection methods
- Storage writes: serialized through WriteQueue
- Storage reads: use reader connections, no statement sharing
- Subscriptions: register/unregister through SubscriptionEngine
- WebSocket sends: use connection/manager helpers

---

## Performance Characteristics

### Typical Workload (90% reads, 10% writes)

**16-core machine:**
```
Readers:      4 threads × ~11k each = 44k cold reads/sec
Notification: 8 threads × ~5k each  = 40k change evaluations/sec
Writes:       1 thread  × ~10k      = 10k writes/sec (serialized)
Event Loop:   1 thread  × ~200k     = 200k messages/sec dispatch
Total: ~150k+ req/sec average
CPU usage: ~85% (all cores utilized)
```

**vs Single-threaded approach:**
```
Combined: 10k req/sec
CPU usage: 6% (1/16 cores)
```

**Result: 15x+ performance improvement**

### Why This Works

**1. Deterministic thread allocation**
- No configuration-induced performance cliffs
- Formula ensures balanced resource allocation
- Server refuses to start on underpowered machines

**2. Warm reads are lock-free and in-memory**
- Subscription Engine evaluates against in-memory state
- No SQLite round-trip for subscribed collections
- No contention, scales with CPU cores

**3. Cold reads use the parallel SQLite read pool**
- Up to 4 reader threads
- WAL mode enables true parallel reads

**4. Writes are serialized**
- Necessary for correctness (ACID)
- SQLite single-writer limitation
- Batching keeps throughput high (10k+ writes/sec)

**5. Notification evaluation is parallelized**
- Multiple threads evaluate subscription filters
- CPU-heavy work distributed across cores

---

## Memory Management Strategy

ZyncBase employs specialized allocation patterns to minimize overhead in a high-concurrency environment:
- **Arena Allocation** for request-scoped data.
- **Object Pooling** for reusing common structures.
- **Allocator Strategies** (Arena, Pool, GPA).

---

## Pros and Cons

### Pros

- **Uses all CPU cores** — True vertical scaling
- **Deterministic** — No configuration knobs to misconfigure
- **Warm reads are fully in-memory** — Subscription Engine eliminates SQLite round-trips
- **SQLite parallel reads** — Fully utilized for cold queries
- **Lock-free metadata** — Auth/schema/namespace lookups are wait-free
- **Fail-fast** — Server refuses to start on underpowered machines

### Cons

- **Minimum 4 cores required** — Cannot run on small instances
- **Writes are serialized** — SQLite single-writer limitation
- **Need atomic operations** — For lock-free cache
- **Cold queries hit SQLite** — First subscribe to a collection incurs a read
- **More complex** — Than single-threaded approach

### Mitigation

**For minimum core requirement:**
- Modern servers have 4+ cores
- Small instances are not the target deployment environment
- Clear error message at startup

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

### Configuration-Driven Thread Counts (Rejected)

**Pros:**
- Flexibility for unusual deployments
- Tuning knobs for performance enthusiasts

**Cons:**
- Configuration-induced performance cliffs
- Support burden from misconfiguration
- Most users don't understand thread tuning
- Deterministic formula is sufficient for target workloads

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
