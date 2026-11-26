# Threading

ZyncBase runs two uWebSockets reactors. Every connection is owned by exactly one
reactor for its lifetime; all WebSocket sends for that connection happen on its
owning reactor.

## Source Files

| File | Role |
|---|---|
| `src/thread_budget.zig` | Fixed two-reactor budget and variable reader/notification split. |
| `src/server.zig` | `EventLoopContext`, reactor startup/shutdown, post handlers, per-loop timers. |
| `src/uwebsockets_wrapper.zig` | App/listen/run/destroy per reactor; loop id on sockets. |
| `src/connection/send_queue.zig` | Two per-loop send queues; one consumer each. |
| `src/connection/manager.zig` | Connection registry, per-loop drains, token sweeps, queued cross-loop control sends, loop wake registry. |
| `src/connection/state.zig` | Connection-local state and immutable owning loop id. |
| `src/storage_engine/read_buffer.zig` | Read request/response with target loop. |
| `src/storage_engine/write_queue.zig` | `WriteAck` with target loop. |
| `src/storage_engine/outcome_fence.zig` | Per-transaction outcomes routed to owning loops. |
| `src/subscription/engine.zig` | Subscription records carry owning loop. |
| `src/subscription/worker_pool.zig` | Batched fanout split by owning loop. |
| `src/presence/worker.zig` | Presence deliveries routed to owning loop. |
| `src/actions/service.zig` | Shared action state guarded by a mutex; deliveries routed by loop. |
| `src/threading/notifier.zig` | Wake callback used by background producers. |

## Important Types

| Type | Fields / role |
|---|---|
| `EventLoopContext` | Reactor id, `WebSocketServer`, thread handle, ready/closed state, shutdown timer. |
| `SendQueue` | Two MPSC queues of `Entry`; one consumer per queue; per-loop arena drain. |
| `Entry` | `conn_id`, encoded bytes, arena handle, optional batched `Delivery` items, owning loop. |
| `Delivery` | One subscriber delivery inside a batched fanout entry: `conn_id`, bytes, loop id. |
| `Connection` | Immutable owning loop, connection-local scope/subscription state. |
| `ReadRequest` / `ReadResponse` | Query/pagination work and response with target loop. |
| `WriteAck` / `OutcomeFence` | Write outcome target loop and fence ordering. |
| `SubscriptionEngine.Match` | Subscriber connection, subscription id, operation, owning loop. |
| `PresenceOp` / `Subscriber` | Presence work and subscriber owning loop. |
| `Notifier` | Callback/context pair for waking the reactors from worker threads. |

## Concurrency Model

Thread domains:

- **Event loops (2):** main thread runs loop 0; one spawned thread runs loop 1.
  Each accepts and owns a shard of connections, runs its own post handler,
  drains its own send queue, and owns its token/cleanup timers.
- **Writer (1):** serializes SQLite commits and routes outcomes to origin loops.
- **Checkpoint (1):** background WAL flush.
- **Presence (1):** serializes presence state and encodes broadcasts.
- **Readers (variable, max 4):** parallel SQLite reads on dedicated connections.
- **Notification (variable):** sharded subscription evaluation and delta
  encoding.

The server starts both reactors before opening the listening port and stops
both before final checkpoint/deinit.

## Queues and Ownership

| Queue / resource | Producers | Consumer | Notes |
|---|---|---|---|
| Send queue 0 | reader, writer, subscription, presence, actions | reactor 0 | MPSC; target loop explicit; per-loop drain arena |
| Send queue 1 | reader, writer, subscription, presence, actions | reactor 1 | MPSC; target loop explicit; per-loop drain arena |
| Write queue | reactors 0 and 1 | writer | Producer push is serialized by the writer's work mutex |
| `read_request_queue` | reactors 0 and 1 | reader pool | SPMC blocking queue; push is mutex-guarded; requests carry target loop |
| `ChangeQueue` | writer | subscription workers | Sharded SPMC; one worker per shard |
| Presence input queue | reactors 0 and 1 | presence worker | Producers serialized by the worker's work mutex |
| Actions state | reactors 0 and 1 | shared | One mutex around external entry points; deliveries go through target send queues |

Subscription fanout:

- A change is evaluated once.
- `Match` entries carry the subscriber's loop.
- The worker builds one batched delivery slice per loop and pushes one queue
  entry per loop. It never pushes one entry per subscriber.
- The owning reactor groups entries by connection and sends one frame per
  connection, preserving per-connection order.

## Synchronization Boundaries

| Operation | Rule |
|---|---|
| Connection state | Mutated through connection/loop-owned methods; owning loop id is immutable. |
| WebSocket sends | Only on the connection's owning reactor via its send queue or same-loop direct send. |
| Cross-loop send | Copied into the target loop's queue and that reactor is woken; never send from the caller's reactor. |
| Storage writes | Serialized through the writer; do not bypass it. |
| Storage reads | Reader owns its SQLite connection; request/response carries target loop. |
| Notification fanout | Sharded by change; each worker evaluates its shard; deltas route by loop. |
| Subscriptions | Thread-safe registration/matching; disconnect detaches all connection-owned subscriptions. |
| Presence | Presence worker is sole mutator; reactors only enqueue operations. |
| Actions | External entry points lock the ActionsService mutex; replies/forwards route to target loops. |
| Shutdown | Each reactor flushes staged action forwards, drains its queue, disconnects its connections and closes; the supervisor joins both. |

## Invariants

- Every `Connection.send()` call runs on the connection's owning reactor.
- Each send queue has exactly one consumer: its reactor.
- A producer passes the target loop explicitly; there is no global
  connection-to-loop lookup on the push path.
- Batched fanout remains batched and is split only at the loop boundary.
- `drainSendQueue(loop_id)` uses only that loop's queue and drain arena.
- Per-loop token/action sweeps only inspect and send to their own shard.
- Write outcomes and session-resolution outcomes route to the origin loop.
- No shared service calls `Connection.send()` directly from a background
  thread or a non-owning reactor; it pushes to the target send queue and wakes
  the owning reactor.
- Background producers encode into general-allocator-owned bytes; after a
  successful push, the queue owns the bytes and the reactor frees them after
  send.
- A transaction's deltas for a connection are pushed before that connection's
  write outcome (ADR-018); each connection's queue preserves push order.
- `SendQueue.deinit()` runs only after both reactors and all producers have
  stopped and both queues are drained.
- Threading changes require the loop-routing unit tests, TSAN, and safe-mode coverage.
- Thread counts are deterministic; the reactor count is fixed at two.

## Related Specifications

- [Message Handler](./message-handler.md)
- [Storage](./storage.md)
- [Lock-Free Cache](./lock-free-cache.md)
- [Presence Internals](./presence-internals.md)
- [Threading Model](../architecture/threading-model.md)
