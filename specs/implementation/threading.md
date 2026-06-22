# Threading

**Drivers**: [Threading Model Architecture](../architecture/threading-model.md), [ADR-006](../architecture/adrs.md#adr-006-deterministic-thread-budget-architecture), [ADR-014](../architecture/adrs.md#adr-014-unified-subscription-engine), [ADR-018](../architecture/adrs.md#adr-018-mutation-acknowledgement-and-consistency-semantics)

ZyncBase uses a deterministic thread budget architecture with six thread domains computed from CPU core count. Thread counts are hardcoded via formula — no configuration overrides. The server refuses to start on machines with fewer than 3 CPU cores.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/thread_budget.zig` | Thread budget computation from CPU count — hardcoded formula, no config overrides. |
| `src/server.zig` | Server composition and lifecycle for networking, storage, subscriptions, notifications, and write outcome dispatch. |
| `src/uwebsockets_wrapper.zig` | C ABI wrapper around uWebSockets callbacks and send/close primitives. |
| `src/connection/manager.zig` | Connection registry and cross-thread send helper. |
| `src/connection/state.zig` | Per-connection mutable state, outbox, scoped session fields, and send behavior. |
| `src/message_handler.zig` | Concurrent request entry point and per-request routing. |
| `src/storage_engine/write_queue.zig` | Single-writer queue, checkpoint coordination, and writer health state. |
| `src/notification_dispatcher.zig` | Converts committed record changes into subscription pushes. |
| `src/write_outcome_dispatcher.zig` | Sends deferred committed write acknowledgements/errors. |
| `src/subscription_engine.zig` | Shared subscription registry and record-change matching. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `ThreadBudget` | CPU count | Computes deterministic thread allocation from CPU core count. |
| `ZyncBaseServer` | `WebSocketServer`, `StorageEngine`, `MessageHandler`, dispatchers | Owns subsystem wiring and start/stop lifecycle. |
| `ConnectionManager` | `Connection`, uWebSockets wrapper | Tracks live connections and supports targeted sends. |
| `Connection` | `Outbox`, `Session`, `WebSocket` | Serializes connection-local scope/subscription state and buffers outbound messages. |
| `WriteQueue` | SQLite writer connection, `MemoryStrategy` | Serializes durable writes and emits outcomes/changes. |
| `NotificationDispatcher` | `ConnectionManager`, `SubscriptionEngine` | Fans committed store changes out to subscribers. |
| `WriteOutcomeDispatcher` | `ConnectionManager`, `WriteOutcomeBuffer` | Sends `WriteCommitted`/`WriteError` events to the origin connection. |
| `SubscriptionEngine` | `QueryFilter`, `RecordChange` | Maintains subscription groups shared across network workers. |

## Concurrency Model

- The server runs six thread domains: event loop (1), writer (1), checkpoint (1), presence (1), readers (variable, max 4), notification (variable).
- Thread counts are computed at startup from CPU core count using a hardcoded formula in `ThreadBudget`.
- The server refuses to start on machines with fewer than 3 CPU cores.
- A single connection must observe sequential scope and subscription state changes through `Connection` methods.
- Store writes are serialized through `WriteQueue`; readers and subscribers observe committed results.
- Subscription and write-outcome fanout happen after storage commit, not before durable ordering is known.
- Presence state is in-memory and connection-scoped; disconnect teardown removes the connection's presence records.

## Synchronization Boundaries

| Boundary | Rule |
|----------|------|
| Connection state | Mutate only through `Connection` methods that preserve scope/subscription invariants. |
| Storage writes | Enter through `StorageEngine`/`WriteQueue`; do not bypass the single-writer path. |
| Storage reads | Use reader connections and schema/query helpers; do not share SQLite statements across threads without their owning connection. |
| Subscriptions | Register/unregister through `SubscriptionEngine`; disconnect must detach connection-owned subscription ids. |
| WebSocket sends | Use connection/manager send helpers so close and backpressure behavior stays centralized. |
| Background scope resolution | Commit only if `scope_seq` still matches the active pending request. |
| Thread budget | Computed once at startup; no runtime mutation or configuration override. |

## Invariants

- No request may publish subscription or write acknowledgements before the corresponding storage commit.
- Namespace resolution results must be ignored when superseded by a newer namespace request.
- Connection teardown must be idempotent enough to tolerate concurrent disconnect and background completion.
- Shared registries must define one owner for allocation and deallocation of ids, buffers, and snapshots.
- Threading changes require sanitizer coverage; data-race freedom is part of the API contract.
- Thread counts are deterministic — derived from CPU count, not configuration.

## See Also

- [Message Handler](./message-handler.md)
- [Storage](./storage.md)
- [Lock-Free Cache](./lock-free-cache.md)
- [Presence Internals](./presence-internals.md)
