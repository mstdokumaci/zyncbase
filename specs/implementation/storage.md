# Storage

**Drivers**: [ADR-005](../architecture/adrs.md#adr-005-sqlite-as-the-storage-engine), [ADR-010](../architecture/adrs.md#adr-010-conflict-resolution--last-write-wins), [ADR-018](../architecture/adrs.md#adr-018-mutation-outcomes-and-optimistic-local-state), [Threading](./threading.md), [Query Engine](./query-engine.md)

The storage layer persists store data in SQLite with WAL mode. It owns schema-to-DDL generation, reader/writer connection roles, typed value encoding, write serialization, query execution, and committed change production. Migration execution runs on the storage engine's setup connection. Its contract lives in [Schema Migrations](./schema-migrations.md).

## Source Files

| File | Responsibility |
|------|----------------|
| `src/storage_engine.zig` | Public storage facade and re-exports for storage submodules. |
| `src/storage_engine/connection.zig` | SQLite configuration, WAL/checkpoint helpers, and reconnect behavior. |
| `src/storage_engine/write_worker.zig` | `WriteWorker` type: dedicated writer OS thread, SPSC write queue, WaitGroup flush backpressure, Notifier, mutation methods, and committed change production. |
| `src/storage_engine/write_queue.zig` | `WriteOp` union, `write_queue_type` alias (`spscQueue(WriteOp, IndexPool)`), `getOpTarget` helper, checkpoint types, and `ReconnectionConfig`. |
| `src/storage_engine/reader.zig` | Select/query execution, record decoding, and query result ownership. |
| `src/storage_engine/read_worker_pool.zig` | `ReadWorkerPool` and `ReadWorker`: dedicated reader OS threads using `managedThread` and `workerPool`. Consume `ReadRequest`, encode responses, push to the target send queue. |
| `src/storage_engine/read_buffer.zig` | `ReadRequest`, `ReadResponse` types and `read_request_queue` alias (`spmcBlockingQueue(ReadRequest)`). |
| `src/sql/build.zig` | SQL construction helpers for SELECT, cursor predicates, ordering, and DML fragments. |
| `src/sql/buf.zig` | SQL buffer and identifier quoting helpers. |
| `src/sql/ddl.zig` | Schema-to-DDL translation. |
| `src/storage_engine/filter_sql.zig` | Query predicate lowering to SQL fragments and bound values. |
| `src/storage_engine/cache.zig` | Namespace/identity metadata cache keys and values. |
| `src/storage_engine/errors.zig` | SQLite error classification into internal storage errors. |
| `src/typed/types.zig`, `src/typed/codec.zig`, `src/typed/doc_id.zig` | Runtime typed values, binary codecs, and 16-byte document id support. |
| `src/checkpoint_worker.zig` | Background WAL checkpoint scheduling and execution. |
| `src/migration/*.zig` | Schema snapshot, change classification, and migration execution. See [Schema Migrations](./schema-migrations.md). |
| `src/store_service.zig` | Application-facing store API on top of storage. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `StorageEngine` | SQLite, schema, memory strategy, write worker | Main persistence API for store service and server lifecycle. |
| `WriteWorker` | `managedThread`, `spscQueue(WriteOp, IndexPool)`, `WaitGroup`, `Notifier`, SQLite writer connection, schema, caches | Sole writer thread; executes mutations, emits `ChangeJob` entries to `ChangeQueue`, encodes write outcomes into an `OutcomeFence`. |
| `write_queue_type` | `spscQueue(WriteOp, IndexPool)` | Type alias for the SPSC write op queue. `IndexPool` provides zero-allocation pooled nodes. |
| `ReadWorkerPool` / `ReadWorker` | `workerPool`, `managedThread`, `read_request_queue`, per-loop send queue, `Notifier` | Pool of dedicated reader threads; each `ReadWorker` owns an exclusive `ReaderNode` (SQLite connection + statement cache). |
| `ChangeJob` | `OwnedRecordChange`, `Allocator` | Ownership wrapper bundling a committed record change with its writer allocator for safe cross-thread handoff to subscription workers. |
| `ColumnValue` | typed values | Represents values bound into SQLite statements. |
| `DDLGenerator` | `Schema` | Produces table/index DDL from loaded schema. |

## SQLite Contract

- WAL mode is mandatory so readers are not blocked by the writer in normal operation.
- Durable mutations enter through the write queue; bypassing it breaks write ordering.
- Tables include system columns needed for namespace, identity, timestamps, and LWW semantics.
- Store record values are encoded/decoded through typed value helpers; docs should not duplicate codec internals.
- Every ZyncBase-managed table, including `_zync_*` system tables, is a SQLite `STRICT` table. A value that cannot be stored losslessly in a column's declared type fails the statement.
- Schema changes go through the migration run ([Schema Migrations](./schema-migrations.md)), never through ad hoc DDL.
- SQLite error details remain internal unless they map to a public code in [Error Taxonomy](./error-taxonomy.md).
- Every writer and reader connection enables `PRAGMA foreign_keys`. `StorageEngine.start()` runs `foreign_key_check` after DDL/migrations and rejects startup when legacy orphaned rows exist.
- Reference fields target the referenced table's `id`, use immediate constraints, and always receive a child-key index.
- Migration runs disable foreign-key enforcement and enable `legacy_alter_table` before the run transaction, then restore both on every path. A run verifies `foreign_key_check` before commit; it never repairs orphaned data silently.
- User-defined unique constraints compile to managed SQLite unique indexes whose first column is always `namespace_id`. Managed names are globally unambiguous: ordinary indexes use `"idx__<table>__<kind>..."`, the users identity index is `"uidx__users__identity"`, and user constraints use `"uidx__<table>__constraint__<ordinal>"` (zero-based, schema order). Both prefixes are reserved per table.
- Upserts target only `ON CONFLICT("id")`. A conflict on a user unique index aborts the write (classified as `UniqueConstraintViolation` via SQLite extended result codes); it never updates or overwrites another row. An explicit batch then rolls back as a whole; in a coalesced flush only that write fails. There is no application-side uniqueness preflight or cache — SQLite is the sole authority.
- The catalog check compares every managed index with the target schema through `PRAGMA index_list` and `PRAGMA index_info`. Managed indexes are namespace, owner, users identity, indexed and reference fields, and user unique indexes. The name, unique flag, non-partial status, and exact ordered column list must all match. Drift is repaired by reconciling that table's indexes.
- Index reconciliation runs inside the run transaction. It drops every reserved-prefix managed index on the table, then creates the full target set one statement at a time. A failed unique-index creation reports the table, the dotted field list, and sample duplicates, and the rollback restores the previous index set. Rebuilt and created tables receive their complete index set after their data is loaded.
- Startup applies schema DDL only through the migration run. Fresh databases are created inside a transaction. A run with no changes writes nothing.

## Read Path

1. Store/query API validates table, path, projection, authorization, and query filter.
2. Query filter is lowered through `filter_sql.zig`.
3. Reader code builds the SELECT using `sql.zig` helpers.
4. SQLite rows are decoded into typed records owned by the caller allocator.
5. Cursor state is returned when pagination is active.

## Write Path

Document timestamps are server-generated Unix microseconds. Before worker threads start, storage loads one `last_created_at` per table using the covering `UNIQUE(created_at)` index. Every create path, including implicit `users` creation, claims `max(physical_time_us, last_created_at + 1)` on the sole writer and binds the result to both `created_at` and `updated_at`. Updates preserve `created_at` and update only `updated_at`. Rolled-back writes may leave sequence gaps; clocks are never rewound. Tables have independent clocks and may share timestamp values.

1. Store service validates payload shape and authorization.
2. Mutation is enqueued through the single-writer path (SPSC write queue).
3. `WriteWorker` applies schema validation, ownership checks, and conflict semantics. An unconditional set reads its row inside the transaction, so it sees every earlier write. An existing row takes the UPDATE path. A missing row fails with the set's create denial (missing required fields, or a write rule that rejects the candidate) when it has one, and otherwise INSERTs. An INSERT that returns no row hit the id in another namespace and fails with `UNIQUE_CONSTRAINT_VIOLATED`.
4. SQLite enforces referenced-row existence and `restrict`, `cascade`, or `set_null` actions. Cascades are database integrity operations and do not run child authorization checks.
5. Before a parent delete, `WriteWorker` snapshots rows reachable through cascade/set-null edges. After SQLite applies the actions, those rows flow through the normal `ChangeJob` bookkeeping; all effects remain invisible until commit. SQLite-driven `set_null` does not modify `updated_at`.
6. During the transaction, successful row effects accumulate by canonical `(namespace_id, table_index, doc_id)`, retaining the first old record and last new record. After commit, the writer pushes at most one endpoint `ChangeJob` per key to `ChangeQueue`; an absent-to-absent endpoint is suppressed.
7. Every client write carries a `WriteAck` (`conn_id`, request `msg_id`); internal writes carry none. After the transaction outcome is known, the writer encodes `WriteCommitted` or `WriteError` with the request id into the transaction's `OutcomeFence`. Every `ChangeJob` the commit pushes holds a fence reference, released after its deltas are pushed. The thread that drops the last reference, a subscription worker or the writer, pushes the outcomes to the origin loop's send queue and wakes the owning reactor, so a connection gets the transaction's deltas first (ADR-018). Without active subscriptions no job holds the fence.

### Conditional Writes and Increments

Conditional writes and atomic increments reuse the writer transaction and the same-row guard machinery (ADR-023).

- A conditional write adds the client predicate as a second SQL fragment after the authorization guard. The guard for these writes is the AND of the collection's write rule and read rule; a row the session cannot read is `PERMISSION_DENIED` before the client predicate is evaluated.
- Update SQL shape: `SET <columns>, <increments>, updated_at = ? WHERE id = ? AND namespace_id = ? [AND auth] [AND if] [AND increment guards] RETURNING <cols>`.
- Bind order is: absolute column values, increment deltas, `updated_at`, `id`, `namespace_id`, auth guard values, `if` values, then per increment: delta (typeof), delta again when a bound exists, minimum, maximum.
- Increment guards are `typeof(field) = 'integer' AND typeof(field + delta) = 'integer'` plus the declared `minimum`/`maximum`. SQLite integer addition overflows to REAL, which the `typeof` check rejects. A NULL field fails the first check.
- Delete SQL shape: `DELETE ... WHERE id = ? AND namespace_id = ? [AND auth] [AND if] RETURNING <cols>`.
- A zero-row write is classified by probing the writer's own SQL view, in this order: existence, auth/read guard, client precondition, then increment bounds. Auth is classified first so a client cannot use `if` as a value oracle.
- A rejected operation affects no row, pushes no change-queue entry, and is reported per operation. In the coalesced flush path the transaction continues and other operations commit; in an explicit batch the first rejection aborts the transaction and `batchIndex` identifies it.
- Increment eligibility is validated before enqueue: integer storage, no `enum`, not in a unique constraint, non-zero delta. Unique constraint indexes are relative to `userFields()`, not global field indexes.
- Conditional writes do not add a version column and do not change last-write-wins for unconditional writes.

## Invariants

- `users.namespaced` and namespace ownership rules must match authorization/session decisions.
- Same-row authorization guards should be expressed in the write SQL path when possible.
- Reader statements/results are owned by their reader connection and allocator.
- Batch writes are atomic at the storage boundary: either the batch commits consistently or returns a failure.
- Guard, precondition, increment, and constraint rejections are per-operation in the coalesced flush path and abort the whole transaction in an explicit batch. A constraint failure (unique, foreign key, check, not null) undoes only its own statement under SQLite's ABORT resolution and is raised before any change-queue bookkeeping, so the flush transaction stays open for the remaining operations. Failures that are not statement-local (I/O, disk full, allocation, `BEGIN`/`COMMIT`, or an auto-rolled-back transaction) fail every operation in the flush. A rejection never drops an unrelated write.
- `created_at` is required, immutable, JavaScript-safe, strictly increasing in writer order within one table, and enforced unique by SQLite.
- Startup rejects persisted `created_at` values outside `0..Number.MAX_SAFE_INTEGER`; no global cross-table clock exists.
- Transaction-local delta coalescing changes only subscription publication. Every SQL operation, guard, referential action, and write outcome still executes in its original order.
- Immediate foreign keys require parent-before-child ordering inside a batch. Optional references accept `null`; non-null values must resolve to a global row or to a row in the writer's namespace. SQLite's foreign key matches by id only, so before an INSERT or UPDATE the writer probes each namespaced-to-namespaced reference with `id = ? AND namespace_id = ?`. A miss is `ConstraintViolation`, the same as a missing parent, and is statement-local. Cascade and set-null lookups still match by parent id only, because a global parent has children in every namespace; a delete that removes no row discards what they captured.
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
| Batch size | 500 ops (default) | Maximum writes per transaction. Configured by `performance.batchSize`. |
| Batch timeout | 8 ms (default) | Maximum time to wait before flushing an incomplete batch. Configured by `performance.batchTimeout`. |
| Statement cache | 100 per connection | LRU eviction for prepared statements. |

### Reader Pool

Actual reader OS threads consuming from an SPMC blocking work queue. Each reader thread owns its SQLite connection and statement cache exclusively.

| Property | Value | Notes |
|----------|-------|-------|
| Thread count | `ThreadBudget.readers` (1–4) | Formula: `remaining = max(cpu_count, fixed_used + 2) - fixed_used`; `min(4, max(1, remaining / 2))`. |
| Work queue | SPMC blocking (mutex + CV) | Reactors (producers) enqueues `ReadRequest`. Reader threads (multiple consumers) pop and execute. |
| Response delivery | Lock-free MPSC (atomic tail swap) | Reader threads encode responses to MessagePack, push owned `{conn_id, encoded_bytes}` to the target loop's send queue, then wake the owning reactor. The owning reactor drains in its post-handler. |
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
| Change queue | Sharded linked-list SPMC | Writer pushes committed record changes by `(namespace_id, table_index, doc_id)` shard for subscription workers. |
| Session resolution buffer | 256 + 512 overflow | Ring buffer for namespace/user resolutions. |
| Read request queue | Unbounded (linked list) | SPMC blocking queue for async read requests. |

## Threading Model

| Subsystem | Thread | Synchronization | Ownership Boundary |
|-----------|--------|-----------------|-------------------|
| `WriteWorker` | Dedicated writer thread | `managedThread` mutex/condvar + `WaitGroup` (`flush_wg`) + atomics | Sole consumer of the write queue; produces `ChangeJob` entries, session resolutions, and per-loop outcome messages. |
| Write queue | Reactors 0 and 1 (producers) + writer thread (consumer) | Lock-free SPSC queue whose producer push is serialized by the writer's work mutex | One producer at a time; total write order is the serialized commit order. |
| `ReadWorkerPool` | Dedicated reader threads (1–4) | SPMC blocking queue (mutex + CV) for requests; per-loop send queue for owned encoded responses | Each `ReadWorker` owns its `ReaderNode` (SQLite conn + stmt cache) exclusively; requests/responses carry the target loop. |
| `ChangeQueue` | Writer thread (producer) → `SubscriptionWorkerPool` (consumers) | Sharded SPMC blocking queue (mutex + CV per shard); shard selected by `(namespace_id, table_index, doc_id)` hash | Writer pushes non-blocking; each subscription worker blocks on its own shard. |
| Session resolution delivery | Writer thread (producer) → connection's owning reactor (consumer) | Per-loop send queue; resolution carries target loop | Outcomes route directly to the origin reactor. |
| Write outcome delivery | Writer or subscription worker (producer) → connection's owning reactor (consumer) | `OutcomeFence` + per-loop MPSC send queue | Writer encodes `WriteCommitted`/`WriteError` into the fence; the thread that drops its last reference pushes them to the target loop. |
| Send queue drain | Each uWS reactor (one consumer per queue) | Reactor drains its own queue and delivers encoded messages via `ConnectionManager.drainSendQueue(loop_id)`. | Runs in the owning reactor's post-handler. |

**Key invariants**:
- All durable writes enter through the single-writer path; bypassing it breaks write ordering.
- Write outcome encoding happens on the writer thread after the transaction outcome is known. Outcomes reach the origin loop's send queue only after every delta of the transaction's change jobs.
- Background producers call `us_wakeup_loop()` after successful enqueue so the owning reactor processes queued work promptly.
- Reader threads execute SQLite queries on dedicated connections; no contention with the owning reactor or writer thread.
- StoreSubscribe registration happens in `MessageHandler` before the read request is enqueued to the reader pool.
- Documents are never cached in memory; every read goes to SQLite. The namespace and identity maps are mutex-guarded, and only the writer inserts into them, after commit.

## Related Specifications

- [Schema Grammar](./schema-grammar.md)
- [Query Engine](./query-engine.md)
- [Cursor Pagination](./cursor-pagination.md)
- [Error Taxonomy](./error-taxonomy.md)
