# Storage

**Drivers**: [ADR-005](../architecture/adrs.md#adr-005-sqlite-as-the-storage-engine), [ADR-010](../architecture/adrs.md#adr-010-conflict-resolution--last-write-wins), [ADR-018](../architecture/adrs.md#adr-018-mutation-acknowledgement-and-consistency-semantics), [Threading](./threading.md), [Query Engine](./query-engine.md)

The storage layer persists store data in SQLite with WAL mode. It owns schema-to-DDL generation, migration execution, reader/writer connection roles, typed value encoding, write serialization, query execution, and committed change production.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/storage_engine.zig` | Public storage facade and re-exports for storage submodules. |
| `src/storage_engine/connection.zig` | SQLite configuration, WAL/checkpoint helpers, and reconnect behavior. |
| `src/storage_engine/write_worker.zig` | `WriteWorker` type: dedicated writer OS thread, SPSC write queue, WaitGroup flush backpressure, Notifier, mutation methods, and committed change production. |
| `src/storage_engine/write_queue.zig` | `WriteOp` union, `write_queue_type` alias (`spscQueue(WriteOp, IndexPool)`), `BatchEntry`, checkpoint types, and `ReconnectionConfig`. |
| `src/storage_engine/reader.zig` | Select/query execution, record decoding, and query result ownership. |
| `src/storage_engine/read_worker_pool.zig` | `ReadWorkerPool` and `ReadWorker`: dedicated reader OS threads using `managedThread` and `workerPool`. Consume `ReadRequest`, encode responses, push to `SendQueue`. |
| `src/storage_engine/read_buffer.zig` | `ReadRequest`, `ReadResponse` types and `read_request_queue` alias (`spmcBlockingQueue(ReadRequest)`). |
| `src/storage_engine/sql.zig` | SQL construction and SQLite binding helpers. |
| `src/storage_engine/filter_sql.zig` | Query predicate lowering to SQL fragments and bound values. |
| `src/storage_engine/cache.zig` | Namespace/identity metadata cache keys and values. |
| `src/storage_engine/errors.zig` | SQLite error classification into internal storage errors. |
| `src/ddl_generator.zig` | Schema-to-DDL translation. |
| `src/migration_detector.zig`, `src/migration_executor.zig` | Schema change detection and migration execution. |
| `src/store_service.zig` | Application-facing store API on top of storage. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `StorageEngine` | SQLite, schema, memory strategy, write worker | Main persistence API for store service and server lifecycle. |
| `WriteWorker` | `managedThread`, `spscQueue(WriteOp, IndexPool)`, `WaitGroup`, `Notifier`, SQLite writer connection, schema, caches | Sole writer thread; executes mutations, emits `ChangeJob` entries to `ChangeQueue`, encodes write outcomes to `SendQueue`. |
| `write_queue_type` | `spscQueue(WriteOp, IndexPool)` | Type alias for the SPSC write op queue. `IndexPool` provides zero-allocation pooled nodes. |
| `ReadWorkerPool` / `ReadWorker` | `workerPool`, `managedThread`, `read_request_queue`, `SendQueue`, `Notifier` | Pool of dedicated reader threads; each `ReadWorker` owns an exclusive `ReaderNode` (SQLite connection + statement cache). |
| `ChangeJob` | `OwnedRecordChange`, `Allocator` | Ownership wrapper bundling a committed record change with its writer allocator for safe cross-thread handoff to notification workers. |
| `PkSet` | typed doc ids | Tracks primary keys for set/delete/query helper paths. |
| `ColumnValue` | typed values | Represents values bound into SQLite statements. |
| `DDLGenerator` | `Schema` | Produces table/index DDL from loaded schema. |
| `MigrationPlan` | old/new schema metadata | Describes required schema changes before execution. |

## SQLite Contract

- WAL mode is mandatory so readers are not blocked by the writer in normal operation.
- Durable mutations enter through the write queue; bypassing it breaks acknowledgement ordering.
- Tables include system columns needed for namespace, identity, timestamps, and LWW semantics.
- Store record values are encoded/decoded through typed value helpers; docs should not duplicate codec internals.
- Schema changes must go through migration detection/execution rather than ad hoc DDL.
- SQLite error details remain internal unless they map to a public code in [Error Taxonomy](./error-taxonomy.md).

## Read Path

1. Store/query API validates table, path, projection, authorization, and query filter.
2. Query filter is lowered through `filter_sql.zig`.
3. Reader code builds the SELECT using `sql.zig` helpers.
4. SQLite rows are decoded into typed records owned by the caller allocator.
5. Cursor state is returned when pagination is active.

## Write Path

1. Store service validates payload shape and authorization.
2. Mutation is enqueued through the single-writer path (SPSC write queue).
3. `WriteWorker` applies schema validation, ownership checks, and conflict semantics.
4. Commit produces `ChangeJob` entries pushed to `ChangeQueue` for notification workers.
5. Write acknowledgement/error encoding happens on the writer thread after the transaction outcome is known; the writer encodes `WriteCommitted` or `WriteError`, pushes owned bytes to `SendQueue`, and wakes the event loop.
6. Immediate and committed acknowledgements follow ADR-018 semantics.

## Invariants

- `users.namespaced` and namespace ownership rules must match authorization/session decisions.
- Same-row authorization guards should be expressed in the write SQL path when possible.
- Reader statements/results are owned by their reader connection and allocator.
- Batch writes are atomic at the storage boundary: either the accepted batch commits consistently or returns a failure.
- Checkpoint/reconnect behavior must not reorder committed write outcomes.

## Performance Contract

### SQLite Configuration

| Property | Value | Notes |
|----------|-------|-------|
| WAL autocheckpoint | 1,000 pages | SQLite-level threshold for automatic checkpointing. |
| Busy timeout | 5,000 ms | How long to wait on a locked database before failing. |
| Page cache | 64 MB | Hot pages cached in RAM (`cache_size = -64000`). |
| Memory-mapped I/O | 256 MB | Reduces syscall overhead for reads (`mmap_size = 268435456`). |

### Checkpoint Management

| Property | Value | Notes |
|----------|-------|-------|
| WAL size threshold | 10 MB | Triggers checkpoint when WAL exceeds this size. |
| Time threshold | 300 sec | Triggers checkpoint if 5 minutes since last checkpoint. |
| Check interval | 10 sec | Background loop interval for checking checkpoint need. |
| Max retry attempts | 3 | Exponential backoff on transient checkpoint failures. |
| Escalation threshold | < 10% reduction | If passive checkpoint reduces WAL by less than 10%, escalates to full mode. |

### Write Batching

| Property | Value | Notes |
|----------|-------|-------|
| Batch size | 200 ops | Maximum writes per transaction. |
| Batch timeout | 10 ms | Maximum time to wait before flushing an incomplete batch. |
| Statement cache | 100 per connection | LRU eviction for prepared statements. |

### Reader Pool

Actual reader OS threads consuming from an SPMC blocking work queue. Each reader thread owns its SQLite connection and statement cache exclusively.

| Property | Value | Notes |
|----------|-------|-------|
| Thread count | `ThreadBudget.readers` (1–4) | Formula: `remaining = max(cpu_count, 4) - 4`; `min(4, max(1, remaining / 2))`. |
| Work queue | SPMC blocking (mutex + CV) | Event loop (single producer) enqueues `ReadRequest`. Reader threads (multiple consumers) pop and execute. |
| Response delivery | Lock-free MPSC (atomic tail swap) | Reader threads encode responses to MessagePack, push owned `{conn_id, encoded_bytes}` to `SendQueue`, then wake the event loop. Event loop drains in post-handler. |
| Statement cache | 100 per connection | LRU eviction for prepared statements. |

### Reconnection

| Property | Value | Notes |
|----------|-------|-------|
| Max attempts | 5 | After database failure. |
| Initial backoff | 100 ms | Exponential backoff start. |
| Max backoff | 5,000 ms | Exponential backoff cap. |
| Backoff multiplier | 2.0 | Doubles delay each retry. |

### Buffer Capacities

| Buffer | Capacity | Notes |
|--------|----------|-------|
| Change buffer | 8,192 | Ring buffer for record changes (power of 2 for cheap modulo). |
| Session resolution buffer | 256 + 512 overflow | Ring buffer for namespace/user resolutions. |
| Read request queue | Unbounded (linked list) | SPMC blocking queue for async read requests. |

## Threading Model

| Subsystem | Thread | Synchronization | Ownership Boundary |
|-----------|--------|-----------------|-------------------|
| `WriteWorker` | Dedicated writer thread | `managedThread` mutex/condvar + `WaitGroup` (`flush_wg`) + atomics | Sole consumer of SPSC write queue; produces `ChangeJob` entries, session resolutions, and `SendQueue` outcome messages. |
| Write queue | SPSC: uWS event loop (producer) + writer thread (consumer) | Lock-free (atomic tail swap, Vyukov linked-list); pool-allocated nodes | Thread-safe by construction; one producer, one consumer. |
| `ReadWorkerPool` | Dedicated reader threads (1–4) | SPMC blocking queue (mutex + CV) for requests; lock-free MPSC `SendQueue` for owned encoded responses | Each `ReadWorker` owns its `ReaderNode` (SQLite conn + stmt cache) exclusively. |
| `ChangeQueue` | Writer thread (producer) → `SubscriptionWorkerPool` (consumers) | Sharded SPMC blocking queue (mutex + CV per shard); shard selected by `(namespace_id, table_index, doc_id)` hash | Writer pushes non-blocking; each notification worker blocks on its own shard. |
| Session resolution buffer | Writer thread (producer) → uWS event loop (consumer) | Atomic ring buffer with overflow mutex | SPSC ring buffer with overflow. |
| Write outcome delivery | Writer thread (producer) → uWS event loop (consumer) | Lock-free MPSC `SendQueue` | Writer encodes `WriteCommitted`/`WriteError` and pushes owned bytes to `SendQueue`. |
| `SendQueue` drain | uWS event loop (consumer) | Event loop drains `SendQueue` and delivers encoded messages to connections via `ConnectionManager.drainSendQueue()`. | Runs in post-handler on event loop. |

**Key invariants**:
- All durable writes enter through the single-writer path; bypassing it breaks acknowledgement ordering.
- Write acknowledgement/error encoding happens on the writer thread after the transaction outcome is known. The writer pushes owned byte slices to `SendQueue` and wakes the event loop.
- Background producers call `us_wakeup_loop()` after successful enqueue so the event loop processes queued work promptly.
- Reader threads execute SQLite queries on dedicated connections; no contention with the event loop or writer thread.
- StoreSubscribe registration happens in `MessageHandler` before the read request is enqueued to the reader pool.
- Metadata cache is lock-free and safe for concurrent reads from reader threads and the writer thread. Cache population uses writer version snapshot for race protection.

## See Also

- [Schema Grammar](./schema-grammar.md)
- [Query Engine](./query-engine.md)
- [Cursor Pagination](./cursor-pagination.md)
- [Error Taxonomy](./error-taxonomy.md)
