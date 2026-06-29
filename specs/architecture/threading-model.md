# Threading Model

---

## Overview

ZyncBase uses a **deterministic thread budget architecture** with six fixed thread domains. Thread counts are computed from CPU core count using a hardcoded formula — there are no configuration overrides. The server refuses to start on machines with fewer than 3 CPU cores.

**Key Innovation**: Deterministic thread allocation ensures predictable resource usage and eliminates configuration-induced performance cliffs.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       ZyncBase Thread Domains                           │
│                                                                         │
│                           ┌──────────────┐                              │
│                           │  Event Loop  │◄─────────────────────────┐   │
│                           │   (1 fixed)  │                          │   │
│                           └─┬────┬────┬──┘                          │   │
│                             │    │    │                             │   │
│               ┌─────────────┘    │    └──────────────┐              │   │
│          presence ops        write ops         read requests        │   │
│               │                  │                   │              │   │
│       ┌───────▼──────┐    ┌──────▼───────┐    ┌──────▼───────┐      │   │
│       │  Presence    │    │    Writer    │    │  Reader Pool │      │   │
│       │  (1 fixed)   │    │   (1 fixed)  │    │  (var, max 4)│      │   │
│       └──────┬───────┘    └─┬─────────┬──┘    └──────┬───────┘      │   │
│              │              │         │              │              │   │
│              │        change fan-out  │              │              │   │
│              │          (sharded)     │              │              │   │
│              │              │   write outcomes       │              │   │
│              │    ┌─────────▼──┐      │              │              │   │
│              │    │Notification│      │              │              │   │
│              │    │  Workers   │      │              │              │   │
│              │    │ (variable) │      │              │              │   │
│              │    └─────┬──────┘      │              │              │   │
│              │          │             │              │              │   │
│              ▼          ▼             ▼              ▼              │   │
│            ┌───────────────────────────────────────────┐            │   │
│            │                 Send queue                │            │   │
│            │       (cross-thread message queue)        ├────────────┘   │
│            └───────────────────────────────────────────┘                │
│                                                                         │
│  * Note: The Checkpoint thread (1 fixed) runs independently in the      │
│    background to flush WAL to the main SQLite database.                 │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Thread Budget Formula

The thread budget is computed at startup from the detected CPU core count:

```
if cpu_count < 3 → server refuses to start

fixed:
  event_loop   = 1
  writer       = 1
  checkpoint   = 1
  presence     = 1

variable:
  remaining    = max(cpu_count, 4) - 4
  readers      = min(4, max(1, remaining / 2))
  notification = max(1, remaining - readers)
```

### Thread Count by CPU Cores

| CPU Cores | Event Loop | Writer | Checkpoint | Presence | Readers | Notification | Total |
|-----------|------------|--------|------------|----------|---------|--------------|-------|
| 3         | 1          | 1      | 1          | 1        | 1       | 1            | 6     |
| 4         | 1          | 1      | 1          | 1        | 1       | 1            | 6     |
| 8         | 1          | 1      | 1          | 1        | 2       | 2            | 8     |
| 16        | 1          | 1      | 1          | 1        | 4       | 8            | 16    |
| 32        | 1          | 1      | 1          | 1        | 4       | 24           | 32    |

---

## Thread Domain Responsibilities

### Event Loop (1 thread, fixed)
- Runs the network reactor; handles all WebSocket I/O (connect, message, disconnect)
- Dispatches incoming messages to the write or read path without blocking
- Drains the cross-thread message queue in the post-handler and delivers outbound payloads to connections
- Must never block — all I/O is non-blocking

### Writer (1 thread, fixed)
- Receives mutations through a dedicated write queue
- Commits to SQLite in serialized order; total write ordering is architecturally guaranteed
- After each commit, fans committed changes out to notification workers
- Delivers write outcomes (acknowledged or rejected) back to the event loop for client delivery

### Checkpoint (1 thread, fixed)
- Background WAL→main database flush
- Periodic full checkpoints
- Decoupled from the write path to avoid blocking mutations

### Presence (1 thread, fixed)
- Accepts presence operations from the event loop through a dedicated input queue
- Processes operations serially, updates in-memory presence state, and encodes outbound broadcasts
- Delivers encoded presence messages to the event loop through the cross-thread message queue

### Reader Pool (variable, max 4)
- Each reader thread holds its own SQLite connection in WAL read mode
- Accepts read requests from a shared work queue; multiple readers consume concurrently
- Encodes read responses and delivers them to the event loop through the cross-thread message queue
- Scales with CPU cores up to 4 workers

### Notification (variable)
- A pool of workers; committed changes are distributed across shards so each worker owns one shard
- Each worker blocks on its shard until a change arrives, then evaluates subscription filters (CPU-heavy)
- Encodes delta messages and delivers them to the event loop through the cross-thread message queue

---

## How It Works

### 1. Message Arrival
- WebSocket message arrives on the event loop thread
- Message handler parses and routes to the read or write path
- No blocking — all operations are dispatched asynchronously

### 2. Write Path (Serialized)
- Mutation is enqueued to the dedicated write queue and the event loop returns immediately
- Writer thread dequeues and commits to SQLite in serialized order
- After commit, committed changes are distributed to notification workers for subscription fanout
- Write outcomes are delivered back to the event loop for client acknowledgement

### 3. Read Path (Parallel)
- Warm reads (active subscriptions) evaluate in-memory via the Subscription Engine
- Cold reads and pagination requests are dispatched to the reader pool via a shared work queue
- Reader threads execute SQLite queries in parallel on dedicated connections
- Results are encoded and delivered to the event loop through the cross-thread message queue

### 4. Presence Path (Dedicated)
- Presence operations from the event loop are enqueued into the presence worker's input queue
- The presence worker processes operations serially, updates in-memory state, and encodes responses
- Encoded broadcasts and snapshots are delivered to the event loop through the cross-thread message queue

---

## Thread Safety Strategy

The core engine routes incoming messages to either the parallel read path or the serialized write path. The Subscription Engine maintains in-memory collection state updated by the writer thread after each commit. A lock-free cache handles auth/schema/namespace/identity metadata with atomic reference counting and copy-on-write map swaps.

**Synchronization boundaries:**
- Connection state: mutated only through connection management methods; no direct mutation from background threads
- Storage writes: serialized through the single-writer queue; bypassing it breaks acknowledgement ordering
- Storage reads: each reader thread owns its SQLite connection exclusively; no connection sharing
- Notification fanout: committed changes distributed to notification workers via a sharded work queue; each worker owns one shard
- Subscriptions: register/unregister through the subscription registry; disconnects must detach all connection-owned subscriptions
- Presence: event loop enqueues operations into the presence worker's input queue; the presence worker is the sole mutator of presence state
- WebSocket sends: background workers push owned encoded messages to the cross-thread queue; only the event loop drains and delivers to connections

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

- **Minimum 3 cores required** — Cannot run on small instances
- **Writes are serialized** — SQLite single-writer limitation
- **Need atomic operations** — For lock-free cache
- **Cold queries hit SQLite** — First subscribe to a collection incurs a read
- **More complex** — Than single-threaded approach

### Mitigation

**For minimum core requirement:**
- Modern servers have 3+ cores
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
- [Threading](../implementation/threading.md) - Implementation details: source files, types, queue mechanics, and synchronization invariants
