# Presence Internals

**Drivers**: [ADR-017](../architecture/adrs.md#adr-017-strict-sdk-api-surface--store-vs-presence), [ADR-020](../architecture/adrs.md#adr-020-typed-two-tier-presence-system), [Wire Protocol](./wire-protocol.md), [Auth System](./auth-system.md)

Presence is an in-memory, typed, two-tier system. User presence is keyed by resolved namespace/user/connection, while shared presence is keyed by namespace and field. Presence writes are fire-and-forget unless the wire request itself is malformed or unauthorized.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/presence.zig` | Public presence module re-exports. |
| `src/presence/manager.zig` | Presence state, user/shared snapshots, writes, removals, and subscriber tables. |
| `src/presence/record.zig` | Typed presence record encoding/decoding and field validation. |
| `src/presence/subscriber.zig` | Presence subscriber ids and subscriber tables. |
| `src/presence/worker.zig` | Dedicated `PresenceWorker` OS thread; SPSC input queue of `PresenceOp`; drains ops, mutates `PresenceManager`, encodes snapshots and broadcasts, pushes owned bytes to `SendQueue`. |
| `src/message_handler.zig` | Presence route handling and scoped presence session gates. |
| `src/wire/decode.zig` | Presence request extractors. |
| `src/wire/encode.zig` | Presence snapshot and broadcast encoders. |
| `src/schema/*` | Presence schema parsing and field metadata. |
| `src/authorization/evaluate.zig` | Presence namespace/write authorization. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `PresenceManager` | schema, typed values, subscribers | Owns in-memory user/shared presence state and snapshot construction. |
| `PresenceWorker` | `managedThread(PresenceWorker)`, `spscQueue(PresenceOp, AllocPool)`, `PresenceManager`, `SendQueue`, `Notifier` | Dedicated OS thread; drains `PresenceOp` queue, mutates `PresenceManager`, encodes snapshots/broadcasts, pushes owned bytes to `SendQueue`. |
| `PresenceOp` | `Allocator` | Typed union of presence operations: `set_user`, `set_shared`, `remove_user`, `subscribe_user`, `subscribe_shared`, `unsubscribe_user`, `unsubscribe_shared`, `remove_all_for_connection`. Each op carries an allocator for correct teardown. |
| `PresenceRecord` | `Schema.PresenceField`, `typed.Value` | Validates and stores typed presence field values. |
| `Subscriber` | connection id, subscription id | Identifies one presence subscription target. |
| `SubscriberTable` | allocator | Stores subscribers for user/shared presence channels. |
| `PresenceField` | schema parser | Defines allowed presence fields and field ids. |
| `PresenceSetRequest` / `PresenceSetSharedRequest` | wire decoder | Carries user/shared presence patches from clients. |

## Two-Tier Model

| Tier | Key | Writer | Reader |
|------|-----|--------|--------|
| User presence | namespace id + user doc id + connection id | The owning connection writes/removes its own fields. | Subscribers receive user snapshots and join/update/leave broadcasts. |
| Shared presence | namespace id + shared field | Authorized connections write shared fields. | Shared subscribers receive full shared snapshots and update broadcasts. |

## Lifecycle

1. Client resolves a presence namespace through `PresenceSetNamespace`.
2. Server authorizes namespace access and records the scoped presence session.
3. Client may write user fields with `PresenceSet` or shared fields with `PresenceSetShared`.
4. Client subscribes to user or shared presence channels.
5. Server sends snapshots on subscribe and broadcasts subsequent updates.
6. Disconnect or `PresenceRemove` clears connection-owned user presence and emits leave/update broadcasts.

## Wire Contract

- Presence messages and push names are owned by [Wire Protocol](./wire-protocol.md).
- Presence field ids and dictionary shape come from schema sync; do not duplicate the integer encoding catalog here.
- Presence writes use typed field validation from the schema.
- User and shared channels are separate push streams.

## Authorization

- Namespace admission uses the authorization namespace rules.
- User presence writes are scoped to the resolved session user.
- Shared presence writes require explicit shared-presence authorization.
- Authorization is server-side only and fail-closed.
- Public errors are owned by [Error Taxonomy](./error-taxonomy.md).

## Invariants

- Presence state is memory-only; it is not persisted through SQLite.
- Presence writes must not mutate store records or subscription state.
- User presence cleanup on disconnect must be idempotent.
- Subscriptions must be removed during disconnect teardown.
- Snapshots and broadcasts must use schema field ids so SDK dictionaries remain stable.
- Presence implementation must not reuse store APIs for user-facing SDK shape; store and presence stay separate.

## Performance Contract

| Property | Value | Notes |
|----------|-------|-------|
| Flush interval | 50 ms | How often the dispatcher drains pending presence updates. |
| Grace period | 5,000 ms | Time before an empty namespace's shared state is evicted after the last user leaves. |
| Field limit | 500 per tier | Hard limit on flat presence fields per user/shared tier. |
| Latency target | Sub-100 ms | Presence operations should complete within 100 ms end-to-end. |

**Overflow policy**: Presence writes are fire-and-forget. If the dispatcher cannot keep up, updates are dropped rather than queued unboundedly. This is safe because presence is ephemeral and the next update will supersede.

## Threading Model

| Subsystem | Thread | Synchronization | Ownership Boundary |
|-----------|--------|-----------------|-------------------|
| `PresenceManager` | `PresenceWorker` thread | `data_mutex: std.Thread.Mutex` | All mutable presence state is behind a single mutex; `PresenceWorker` is the sole mutator. |
| `PresenceWorker` input queue | `PresenceWorker` thread (consumer) + event loop (producer via `enqueue()`) | `managedThread` mutex + condvar; SPSC queue (`spscQueue(PresenceOp, AllocPool)`) | One producer (event loop), one consumer (`PresenceWorker`). `enqueue()` holds `thread.mutex` while pushing and signals `thread.cond`. |
| Send path | `PresenceWorker` thread (producer) | Lock-free MPSC `SendQueue` | Worker encodes snapshots/broadcasts, pushes owned `{conn_id, encoded_bytes}` to `SendQueue`, calls `Notifier.notify()`. Event loop drains. |

**Key invariants**:
- `PresenceWorker` is the sole consumer of its SPSC work queue and the sole mutator of `PresenceManager` state.
- The event loop enqueues `PresenceOp` values via `PresenceWorker.enqueue()`, which holds `thread.mutex` during push and signals `thread.cond`.
- `PresenceWorker` waits on `thread.cond` when the queue is empty and wakes on signal or shutdown request.
- Presence broadcasts and snapshots are encoded by the `PresenceWorker` thread and delivered through `SendQueue`; the event loop does not directly call any presence send.
- `SubscriberTable` is not thread-safe; `PresenceManager` provides synchronization via `data_mutex`.
- Presence cleanup on disconnect must be idempotent and handled through `PresenceOp.remove_all_for_connection` enqueued by the event loop.

## See Also

- [Wire Protocol](./wire-protocol.md)
- [Auth System](./auth-system.md)
- [Schema Grammar](./schema-grammar.md)
- [TypeScript SDK](./typescript-sdk.md)
