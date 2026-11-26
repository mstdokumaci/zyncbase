# Threading Model

ZyncBase runs a **deterministic thread budget** built around two uWebSockets
network reactors, one serialized SQLite writer, one checkpoint worker, one
presence worker, a reader pool, and a notification pool. Thread counts are
computed from the CPU core count with a hardcoded formula; there are no runtime
overrides.

## Overview

- Every connection is owned by exactly one reactor for its lifetime.
- All WebSocket I/O and sends for a connection happen on its owning reactor.
- The two reactors are the main thread (loop 0) and one spawned thread (loop 1).
- Cross-thread work is delivered through per-loop send queues.
- The writer, readers, presence worker, and notification workers never call
  uWebSockets send APIs directly.
- The server refuses to start on machines with fewer than 2 CPU cores.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       ZyncBase Thread Domains                           │
│                                                                         │
│   ┌────────────────┐                 ┌────────────────┐                 │
│   │  Event Loop 0  │                 │  Event Loop 1  │                 │
│   │  (main thread) │                 │  (spawned)     │                 │
│   └─┬────┬────┬────┘                 └─┬────┬────┬────┘                 │
│     │    │    │                        │    │    │                      │
│  presence write read                presence write read                 │
│     │    │    │                        │    │    │                      │
│  ┌──▼────▼────▼──┐                  ┌──▼────▼────▼──┐                   │
│  │  SendQueue 0   │                  │  SendQueue 1   │                   │
│  └──────┬────────┘                  └──────┬────────┘                   │
│         │                                  │                            │
│   ┌─────▼──────┐   ┌──────────────┐   ┌────▼─────────┐                  │
│   │  Presence  │   │    Writer    │   │ Reader Pool  │                  │
│   │  (1 fixed) │   │  (1 fixed)   │   │ (variable)   │                  │
│   └─────┬──────┘   └──────┬───────┘   └──────┬───────┘                  │
│         │                 │ change fan-out     │                         │
│         │          ┌──────▼────────┐           │                         │
│         │          │ Notification  │           │                         │
│         │          │  Workers      │           │                         │
│         │          │  (variable)   │           │                         │
│         │          └──────┬────────┘           │                         │
│         └─────────────────┼────────────────────┘                         │
│                           ▼                                              │
│                 per-loop SendQueue queues                                 │
│                                                                         │
│  Checkpoint (1 fixed) runs independently and flushes WAL.                │
└─────────────────────────────────────────────────────────────────────────┘
```

## Thread Budget Formula

```
if cpu_count < 2 → server refuses to start
fixed:
  event_loops = 2
  writer      = 1
  checkpoint  = 1
  presence    = 1

variable:
  fixed_used   = event_loops + writer + checkpoint + presence
  remaining    = max(cpu_count, fixed_used + 2) - fixed_used
  readers      = min(4, max(1, remaining / 2))
  notification = max(1, remaining - readers)
```

### Thread Count by CPU Cores

| CPU Cores | Event Loops | Writer | Checkpoint | Presence | Readers | Notification | Total |
|-----------|-------------|--------|------------|----------|---------|--------------|-------|
| 2         | 2           | 1      | 1          | 1        | 1       | 1            | 7     |
| 3         | 2           | 1      | 1          | 1        | 1       | 1            | 7     |
| 4         | 2           | 1      | 1          | 1        | 1       | 1            | 7     |
| 8         | 2           | 1      | 1          | 1        | 1       | 2            | 8     |
| 12        | 2           | 1      | 1          | 1        | 3       | 4            | 12    |
| 16        | 2           | 1      | 1          | 1        | 4       | 7            | 16    |
| 32        | 2           | 1      | 1          | 1        | 4       | 23           | 32    |

On 2-4 CPU hosts the minimum worker set oversubscribes the machine.

## Thread Domain Responsibilities

### Event Loops (2, fixed)

- Each reactor accepts and owns a shard of the WebSocket connections.
- Handles connect, message, and disconnect for its connections.
- Dispatches incoming messages to the write or read path without blocking.
- Drains its own `SendQueue` in the post-handler and delivers outbound frames.
- Owns its per-loop timers: token-expiry sweep and connection cleanup.
- Must never block; all I/O is non-blocking.

### Writer (1, fixed)

- Receives mutations through the dedicated write queue.
- Commits to SQLite in serialized order.
- After each commit, fans committed changes out to subscription workers.
- Routes write outcomes to the connection's owning loop.
- Preserves the single-writer ordering guarantee of SQLite.

### Checkpoint (1, fixed)

- Background WAL→main database flush.
- Periodic full checkpoints.
- Decoupled from the write path to avoid blocking mutations.

### Presence (1, fixed)

- Accepts presence operations from both reactors through a synchronized input
  queue.
- Processes operations serially, updates in-memory presence state, and encodes
  outbound broadcasts.
- Routes each encoded broadcast to the subscriber's owning loop.

### Reader Pool (variable, max 4)

- Each reader thread holds its own SQLite connection in WAL read mode.
- Reads requests from a shared work queue.
- Each request carries its target loop; responses are pushed to that loop's
  `SendQueue`.
- Scales with CPU cores up to 4 workers.

### Notification (variable)

- A pool of workers; committed changes are distributed across shards so each
  worker owns one shard.
- Each worker blocks on its shard until a change arrives, then evaluates
  subscription filters (CPU-heavy).
- Encodes deltas and routes each connection's delivery to its owning loop.
- Subscription fanout is batched per change and split by owning loop; it is not
  pushed one queue entry per subscriber.

## How It Works

### 1. Message Arrival

- A WebSocket message arrives on the reactor that owns the connection.
- The message handler parses and routes it to the read or write path.
- No blocking; operations are dispatched asynchronously.

### 2. Write Path (Serialized)

- The mutation is enqueued to the write queue with its origin loop and ack.
- The writer commits it to SQLite in serialized order.
- After commit, the change is distributed to subscription workers.
- `WriteCommitted` / `WriteError` outcomes are pushed to the origin loop's
  `SendQueue` after the transaction's deltas.

### 3. Read Path (Parallel)

- Warm reads evaluate in-memory through the Subscription Engine.
- Cold reads and pagination are dispatched to the reader pool.
- Readers execute SQLite queries in parallel on their own connections.
- Responses are encoded and pushed to the requesting connection's loop.

### 4. Presence Path

- Each reactor enqueues presence operations into the presence worker's input
  queue.
- The presence worker processes them serially, updates in-memory state, and
  encodes snapshots and broadcasts.
- Each delivery is routed to the subscriber's owning loop.

### 5. Connection and Subscription Fanout

- A subscription records the owning loop at registration.
- A change's matches include the loop for each subscriber.
- The worker splits a change batch by loop and pushes one batch entry per loop.
- The owning reactor groups deliveries by connection and sends one frame per
  connection, preserving per-connection order.

## Thread Safety Strategy

A connection belongs to one reactor. That ownership is the primary
synchronization boundary; cross-loop delivery is explicit.

**Invariants:**

- Every `Connection.send` runs on the connection's owning reactor.
- A `SendQueue` has exactly one consumer: its reactor.
- Producers push to a queue with the target loop id; there is no global
  connection-to-loop lookup on the worker-to-connection delivery path. The
  low-rate actions control path resolves the owner through the registry once
  per send.
- Batched subscription fanout stays batched and is split only at the loop
  boundary.
- Each reactor has its own drain arena; drain state is never shared.
- Per-loop token and action sweeps only touch and send to their own shard.
- Write outcomes and session-resolution results route to the origin loop.
- Cross-loop control sends are copied into the owning loop's queue and that
  reactor is woken; they are never sent from the caller's loop.
- Shared registries use their documented lock or ownership model:
  - connection registry: one mutex-protected map with an immutable owning-loop id per
    connection; per-loop drain arenas and sweep selectors;
  - subscription engine: thread-safe registration/matching;
  - lock-free metadata cache: atomic reference counting and copy-on-write;
  - presence: sole mutator is the presence worker;
  - actions: shared state guarded by its mutex and delivered through the
    target loop's queue.
- Shutdown stops both listeners, has each reactor flush staged action forwards,
  drain its own queue and send its disconnects, joins both reactors, then stops
  workers and checkpoints.

**Ordering:**

- Per-connection order is preserved by loop affinity.
- A transaction's deltas for a connection are pushed before that connection's
  write outcome (ADR-018).
- The single writer defines the commit order. Global arrival order across the
  two reactors is not part of the contract.

## Memory Management Strategy

- Arena allocation for request-scoped data, one drain arena per reactor.
- Object pooling for connections and queue nodes.
- Send-queue entries carry one arena reference per queue entry; a split fanout
  batch retains the arena once per target loop.
- Allocator strategies: arena, pool, general allocator.

## Performance Characteristics

The network reactor is the only component that cannot be parallelized within a
single uWebSockets instance. Two reactors shard connections and their outbound
work; the writer, readers, and notification pool remain shared.

- Warm reads evaluate in memory.
- Cold reads use the parallel SQLite reader pool.
- Writes are serialized by SQLite.
- Notification evaluation is parallelized across shards.
- Fanout is batched per connection per reactor drain.

## Pros and Cons

### Pros

- Uses both reactors for network I/O and fanout delivery.
- Deterministic thread allocation; no runtime knobs.
- Warm reads are in-memory.
- SQLite parallel reads are fully used.
- Lock-free metadata lookups.
- Connection-local ordering with explicit cross-loop routing.

### Cons

- Minimum 2 cores; small hosts run seven threads with two reactors.
- Writes remain serialized by SQLite.
- Two reactors require strict connection ownership and cross-loop discipline.
- Cold queries still hit SQLite.
- Two reactors are required on every supported host.

### Mitigation

- Most workloads are read-heavy; writes are batched.
- Cold reads become warm after the first subscription.
- Unit tests cover per-loop routing, the fanout split and per-loop sweeps;
  TSAN is required for every threading change.

## Rejected Alternatives

### One Shared Send Queue With Two Consumers

Rejected: the queue is single-consumer, and a consumer must never send on a
socket it does not own.

### Namespace or Tenant Pinning

Rejected: it does not split fanout within a namespace and would require
connection migration. Connections are sharded by connection, not by namespace.

### Configuration-Driven Thread Counts

Rejected: deterministic allocation avoids configuration-induced cliffs and
support burden. The reactor count is fixed at two.

### More Than Two Reactors Now

Deferred: two reactors cover the current target; additional reactors add
port-sharing, shutdown, and shared-registry complexity without proven headroom.

### Thread-per-Namespace (Future)

Could provide tenant isolation, but it is more complex than connection sharding
and requires more sophisticated scheduling.

## Related Specifications

- [ADRs](./adrs.md) - Architectural Decision Records
- [Storage Layer](./storage-layer.md) - Parallel disk access
- [Core Principles](./core-principles.md) - Design philosophy
- [Threading](../implementation/threading.md) - Source files, types, queues, and
  synchronization invariants
