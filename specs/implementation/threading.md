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
| `src/send_queue.zig` | Wrapper around lock-free `MpscQueue` for cross-thread WebSocket message delivery. Uses `pushOwned` for zero-copy ownership transfer. |
| `src/queues/mpsc_queue.zig` | Generic lock-free MPSC queue (linked list, atomic tail swap). |
| `src/queues/spmc_blocking_queue.zig` | Generic SPMC blocking queue (mutex + CV + linked list). |
| `src/notification_dispatcher.zig` | Converts committed record changes into subscription pushes. |
| `src/write_outcome_dispatcher.zig` | Sends deferred committed write acknowledgements/errors. |
| `src/subscription_engine.zig` | Shared subscription registry and record-change matching. |
| `src/storage_engine/reader_pool.zig` | Dedicated reader OS threads that consume from ReadRequestQueue, encode responses, and push to SendQueue. |
| `src/storage_engine/read_buffer.zig` | `ReadRequest`, `ReadResponse` types and queue aliases. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `ThreadBudget` | CPU count | Computes deterministic thread allocation from CPU core count. |
| `ZyncBaseServer` | `WebSocketServer`, `StorageEngine`, `MessageHandler`, dispatchers | Owns subsystem wiring and start/stop lifecycle. |
| `ConnectionManager` | `Connection`, uWebSockets wrapper | Tracks live connections and supports targeted sends. |
| `Connection` | `Outbox`, `Session`, `WebSocket` | Serializes connection-local scope/subscription state and buffers outbound messages. |
| `SendQueue` | `Allocator` | Lock-free MPSC queue for cross-thread message delivery to connections. |
| `WriteQueue` | SQLite writer connection, `MemoryStrategy` | Serializes durable writes and emits outcomes/changes. |
| `MpscQueue` | `Allocator` | Generic lock-free MPSC linked list queue (atomic tail swap pattern). |
| `SpmcBlockingQueue` | `Allocator`, `Mutex`, `Condition` | Generic SPMC blocking queue with mutex + CV; consumers sleep when empty. |
| `ReaderPool` | `ReaderNode`, `ReadRequestQueue`, `SendQueue` | Owns N reader threads, each with exclusive SQLite connection. Threads consume requests, encode responses, and push encoded messages to `SendQueue`. |
| `ReadRequestQueue` | `Allocator`, `Mutex`, `Condition` | SPMC blocking queue; event loop (single producer) enqueues read requests, reader threads (multiple consumers) pop and execute. |
| `NotificationDispatcher` | `ConnectionManager`, `SubscriptionEngine` | Fans committed store changes out to subscribers. |
| `WriteOutcomeDispatcher` | `ConnectionManager`, `WriteOutcomeBuffer` | Sends `WriteCommitted`/`WriteError` events to the origin connection. |
| `SubscriptionEngine` | `QueryFilter`, `RecordChange` | Maintains subscription groups shared across network workers. |

## Concurrency Model

- The server runs six thread domains: event loop (1), writer (1), checkpoint (1), presence (1), readers (variable, max 4), notification (variable).
- Reader threads are actual OS threads that consume read requests from an SPMC blocking queue. Each reader thread owns its SQLite connection exclusively — no round-robin mutex contention on the event loop.
- Store queries, subscribes, and load_more messages are handled asynchronously: the event loop enqueues a `ReadRequest` and returns immediately; reader threads execute the query, encode the response to MessagePack, and push `{conn_id, encoded_bytes}` into `SendQueue`. The event loop drains `SendQueue` and sends via `Connection.send()` in the post-handler.
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
| Storage reads | Enqueue a `ReadRequest` into `ReadRequestQueue` (SPMC blocking). Reader threads execute queries on dedicated SQLite connections, encode responses to MessagePack, and push `{conn_id, encoded_bytes}` into `SendQueue`. The event loop drains `SendQueue` in `notifyPostHandler`. |
| ReadRequestQueue | SPMC blocking queue (mutex + CV). Single producer: event loop via `StorageEngine.enqueueRead()`. Multiple consumers: reader threads via `pop()` / `popTimed()`. Readers sleep on CV when empty. |
| SendQueue (read responses) | Lock-free MPSC queue (atomic tail swap). Multiple producers: reader threads push `{conn_id, encoded_bytes}`. Single consumer: event loop drains in `notifyPostHandler` via `ConnectionManager.drainSendQueue()`. |
| Subscriptions | Register/unregister through `SubscriptionEngine`; disconnect must detach connection-owned subscription ids. For async StoreSubscribe, registration occurs in `MessageHandler` before the read request is enqueued. |
| WebSocket sends | Same-thread sends use `ConnectionManager.sendToConnection()` directly. Cross-thread sends push to `SendQueue`; the event loop drains in `notifyPostHandler`. `Connection.send()` is always called from the event loop thread. |
| SendQueue | Lock-free MPSC queue of `{ conn_id, encoded_message }`. Producers (push) may be any thread. Consumer (pop/drain) must be the event loop thread only. `deinit()` requires all producers stopped. |
| Background scope resolution | Commit only if `scope_seq` still matches the active pending request. |
| Thread budget | Computed once at startup; no runtime mutation or configuration override. |

## Invariants

- All WebSocket sends via `Connection.send()` occur on the event loop thread; cross-thread producers use `SendQueue` to marshal messages.
- No request may publish subscription or write acknowledgements before the corresponding storage commit.
- StoreSubscribe registration happens only after the initial query completes successfully (in `MessageHandler` before the read request is enqueued).
- Read response records are allocated by reader threads; after encoding to MessagePack bytes, reader threads free records and push owned bytes to `SendQueue`. The event loop frees encoded bytes after sending.
- Namespace resolution results must be ignored when superseded by a newer namespace request.
- Connection teardown must be idempotent enough to tolerate concurrent disconnect and background completion.
- Shared registries must define one owner for allocation and deallocation of ids, buffers, and snapshots.
- Threading changes require sanitizer coverage; data-race freedom is part of the API contract.
- Thread counts are deterministic — derived from CPU count, not configuration.
- `send_queue.deinit()` must only run after every producer thread has been stopped and joined; it will automatically free any remaining unconsumed entry data.
- Reader threads share-read the metadata cache (lock-free); cache population uses writer version snapshot for race protection.

## See Also

- [Message Handler](./message-handler.md)
- [Storage](./storage.md)
- [Lock-Free Cache](./lock-free-cache.md)
- [Presence Internals](./presence-internals.md)
