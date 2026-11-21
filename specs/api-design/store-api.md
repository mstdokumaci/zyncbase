# Store API Reference

The Store API handles durable, synchronized data. Everything in this namespace is validated against your [Schema](./configuration.md#schemajson), persisted to SQLite, and synchronized across all connected clients.

Store methods require a ready store scope. `client.connect()` and `client.setStoreNamespace(namespace)` resolve only after the server has resolved the namespace and internal `users.id`. Data operations (`get`, `set`, `remove`, `increment`, `create`, `query`, `batch`) issued before that point fail with `SESSION_NOT_READY`. Subscription registrations (`listen`, `subscribe`) are the exception: they are queued and dispatched when the session becomes ready — see [Subscription Lifecycle](#subscription-lifecycle).

Mutating methods (`set`, `remove`, `increment`, `create`, `batch`) resolve when the writer commits the write and reject on any failure (ADR-018). A read issued after a write resolves observes that write only if no later write to the same field has superseded it; when another client has committed a superseding write, the read returns the newer value ([ADR-010](../architecture/adrs.md#adr-010-conflict-resolution--last-write-wins)). Unless a write opts out, the client shows it in its own subscriptions and listens before it commits, marked pending, and reverts it if it fails ([Optimistic Writes](#optimistic-writes)). Subscription callbacks are the authoritative source of committed observable state.

## Table of Contents

1.  [Direct Path Access](#direct-path-access-crud)
2.  [Query API (Path Filtering)](#query-api-path-filtering)
3.  [Batch Operations](#batch-operations)
4.  [Optimistic Writes](#optimistic-writes)
5.  [Subscription Lifecycle](#subscription-lifecycle)
6.  [Path Syntax](#path-syntax-strings-vs-arrays)

---

## Direct Path Access (CRUD)

Target specific items or properties using dot-notation or arrays.

There are strict rules on what you can write based on the depth of the path:

| Path Target | Depth | Allowed Operations | Behavior |
| :--- | :--- | :--- | :--- |
| **Collection** (`'users'`) | `1` | `create`, `query`, `listen`, `subscribe` | **Append-only for writes**. You cannot `set` or `remove` an entire collection. |
| **Document** (`'users.u1'`) | `2` | `get`, `set`, `remove`, `listen` | **Full CRUD**. `set` upserts the document, `remove` deletes it. |
| **Field** (`'users.u1.name'`) | `3` | `get`, `set`, `listen` | **Updates only**. To clear a field, `set` it to `null`. `remove` is forbidden. |

### `store.create(collection, value, options?)`
Creates a new document within a collection. The SDK generates a canonical lowercase UUIDv7 string and calls `set` under the hood.

```typescript
const id = await client.store.create('elements', { type: 'rect', x: 10 })
```

**Required Field Validation**: The SDK performs early validation before sending the request. If any required fields (as defined in the schema) are missing from `value`, the call throws `SCHEMA_VALIDATION_FAILED` with `details: { missingFields: [...] }`. Field names in the error use dot notation (e.g., `address.city`) for readability. Note: `store.set` does not perform this validation since it supports partial updates.

**Returns**: `Promise<string>` resolving to the generated ID after the create commits.

Custom document IDs are also supported when supplied in the path directly, but they must match the strict short-ID grammar: `[a-z0-9_-]{1,24}`.

### `store.get(path)`
Read a committed value from the state tree; the client's pending writes are not applied.
```typescript
const element = client.store.get('elements.rect-1')
```
**Returns** (varies by path depth):
- **Array of Objects**: If the path points to a collection (e.g., `client.store.get('users')` -> `Array<User>`)
- **Single Object**: If the path points to a specific document (e.g., `client.store.get('users.u1')` -> `User`)
- **Scalar value**: If the path points to a specific field (e.g., `client.store.get('users.u1.name')` -> `string`)
- `undefined`: If the path is not found

### `store.set(path, value, options?)`
Write a value or upsert a document.

**Path Constraints**: Must target a **Document** (depth 2) or a **Field** (depth 3). Targeting a collection (depth 1) throws an error.
**Clearing Fields**: To remove a field, `set` it to `null`. This triggers schema validation to ensure the field is not required. `set` at an object namespace (for example `'users.u1.address'`) clears every leaf beneath it in one row update; `set` at a leaf clears only that field. A required leaf anywhere under the namespace rejects the whole write with `SCHEMA_VALIDATION_FAILED`.
**Typed Arrays**: For schema fields with `type: "array"`, values are normalized to canonical sorted unique form before persistence and returned in canonical form on reads.
**Binary Data**: For schema fields with `type: "bytes"`, values are provided and returned as `Uint8Array` in TypeScript, serialized as MessagePack `bin` on the wire, and stored as `BLOB` in SQLite.

```typescript
// Upsert a full document. ID is extracted from path if needed.
await client.store.set('users.u1', { name: 'Alice', status: 'active' })

// Update a specific field
await client.store.set('users.u1.status', 'offline')

// Write binary data
await client.store.set('files.f1', { data: new Uint8Array([1, 2, 3, 4]) })

// Clear an optional field (instead of remove)
await client.store.set('users.u1.address', null)

// Typed array field is canonicalized as sorted set
await client.store.set('tasks.t1.tags', ['backend', 'urgent', 'backend'])
// Stored/read as: ['backend', 'urgent']
```

**Conflict Resolution**: Server-Time Last-Write-Wins (LWW) at the field level.

**Conditional Writes**: Pass `if` to make the write a compare-and-set on the existing row. `if` uses the query `where` grammar and is evaluated against the pre-update value. A conditional `set` is **update-only**: on a missing row it rejects with `PRECONDITION_FAILED` and does not create. The session must be able to read the row.

```typescript
await client.store.set('accounts.a1.balance', 900, {
  if: { balance: { eq: 1000 } },
})
```

**Outcome**: Resolves when the writer commits the write, including a no-op. Rejects with `ZyncBaseError` when the server refuses the write (`details.phase: "accept"`) or the writer rejects it (`details.phase: "write"`). If no outcome arrives within `writeTimeoutMs` (default 30 s), it rejects with `TIMEOUT`; the write may still commit.

**State Propagation**: The write shows in the client's own subscriptions and listens synchronously, marked pending, unless it has `if` or `optimistic: false` ([Optimistic Writes](#optimistic-writes)). Committed state arrives through subscription updates; once the promise resolves, the client's subscriptions show the committed value.

**Error Handling**: Every failure rejects the promise and is also emitted on `client.on('error')`; an un-awaited write does not raise an unhandled rejection. Writes are never retried automatically. See [Error Handling](./error-handling.md#error-propagation). A failed `if` rejects with `PRECONDITION_FAILED` (`state`, non-retryable); the application may retry after re-reading.

**Uniqueness**: Writes that collide with a schema-declared unique constraint (see [Configuration](./configuration.md#unique-constraints)) are rejected by storage with `UNIQUE_CONSTRAINT_VIOLATED` (`validation`, non-retryable).

**Returns**: `Promise<void>`

### `store.remove(path, options?)`
Deletes an entire document.

**Path Constraints**: Must target a **Document** (exactly depth 2). Targeting a collection (depth 1) or a field (depth 3) throws an error. To remove a field, use `store.set(path, null)`.

```typescript
await client.store.remove('elements.rect-1')

// Delete only if the stored row still matches.
await client.store.remove('locks.l1', {
  if: { owner_id: { eq: 'u1' } },
})
```

**Outcome**: Same as `store.set`. Deleting a missing document without `if` is success/no-op; with `if`, a missing document rejects with `PRECONDITION_FAILED`.

**Error Handling**: Same as `store.set`.

**Returns**: `Promise<void>`

### `store.increment(path, by, options?)`
Atomically add `by` to an integer field. Resolves when the increment commits.

**Path Constraints**: Must target a **Field** (depth 3). The field must be an integer, must not be a system field, must not have an `enum` constraint, and must not participate in a unique constraint.

**Semantics**: The server executes `SET field = field + by` as one SQLite statement inside the writer transaction. The result is rejected with `PRECONDITION_FAILED` if the row is missing, the stored value is NULL, the arithmetic overflows, or the result violates the field's `minimum` / `maximum`. Use `if` to make the increment conditional on the current row.

```typescript
// Atomic decrement; fails if the balance would go below 100.
await client.store.increment('accounts.a1.coins', -100, {
  if: { coins: { gte: 100 } },
})
```

**Returns**: `Promise<void>`. The new value is delivered by the subscription; perform a `get` if the caller needs to report the value now.

> [!WARNING]
> Increments are not idempotent. A manual retry after an ambiguous connection failure or `TIMEOUT` may apply twice. The SDK never auto-retries writes; callers must decide whether a retry is safe.

### `store.listen(path, callback)`
Listen to real-time updates at a specific path.
```typescript
const { unlisten, getSnapshot } = await client.store.listen('elements.rect-1', (element, { pending }) => {
  render(element, pending)
})

// Synchronous read of the current value — no round trip
const current = getSnapshot()
```

**Callback receives** (same shape as `store.get()` return values):
- **Array** when listening to a collection
- **Object** when listening to a document
- **Scalar** when listening to a field

The second argument is `{ pending: boolean }`: whether the value shows a write not committed yet ([Optimistic Writes](#optimistic-writes)).

**Returns**: `Promise<ListenHandle>`:

- `unlisten(): Promise<void>` — detaches this consumer; its callback stops firing immediately ([teardown contract](#teardown-and-the-grace-window)).
- `getSnapshot(): JsonValue | undefined` — last value delivered to callbacks for this path ([snapshot contract](#snapshots)).
- `isPending: boolean` — whether that value shows a write not committed yet.

The callback delivers the initial value and each change to the observed value. For a field path, a delta that leaves the projected value deep-equal — for example a write to a sibling field of the listened document — is not delivered. Document-level listens deliver each updated record.

---

## Query API (Path Filtering)

For filtering, sorting, and searching through data collections.

### When to use
- Form validation (checking existence)
- Server-side rendering (initial load)
- Filtered real-time subscriptions

### `store.query(collection, options)`
Execute a one-off query (non-real-time). Like `get`, it returns committed state only; the client's pending writes are not applied.

```typescript
const users = await client.store.query('users', {
  where: { age: { gte: 18 }, status: { eq: 'active' } },
  orderBy: [{ created_at: 'desc' }],
  limit: 50
})

// Load next page using the attached cursor
if (users.nextCursor) {
  const nextPage = await client.store.query('users', {
    after: users.nextCursor,
    limit: 50
  })
}
```

**Parameters:**
- `collection` (string) - Name of the collection to query (e.g., 'users', 'events')
- `options` (object) - Query options:
  - `where` (object) - Filter conditions
  - `orderBy` (array) - Ordered sort clauses, e.g. `[{ created_at: 'desc' }]`; each clause has exactly one field and direction
  - `limit` (number) - Max results to return (must be > 0)
  - `after` (string) - Opaque token for the next page (cursor)

**Returns**: `Promise<Array & { nextCursor: string | null }>` - A standard JavaScript Array with an additional `nextCursor` property.

When `orderBy` is omitted, results use `created_at ASC`. Store `created_at` and `updated_at` values are Unix microseconds; convert to a JavaScript `Date` with `new Date(value / 1_000)`.

### `store.subscribe(collection, options, callback)`
Subscribe to filtered query results (real-time).

```typescript
const { unsubscribe, loadMore, hasMore } = await client.store.subscribe('tasks', {
  where: { status: { eq: 'active' } },
  limit: 50
}, (tasks, { pending }) => {
  renderTaskList(tasks, pending)
})

// Load older history into the live view
if (hasMore) await loadMore()
```

**Parameters:**
- `collection` (string) - Name of the collection to query
- `options` (object) - Query options (same as `query()`)
- `callback` (function) - Called when results change, with `{ pending }`: the ids of delivered rows that show a write not committed yet ([Optimistic Writes](#optimistic-writes))

**Returns**: `Promise<SubscriptionHandle>`:

- `unsubscribe(): Promise<void>` — detaches this consumer; its callback stops firing immediately ([teardown contract](#teardown-and-the-grace-window)).
- `loadMore(): Promise<void>` — appends the next page ([shared per key](#keyed-sharing)).
- `hasMore: boolean` — whether more pages exist ([shared per key](#keyed-sharing)).
- `getSnapshot(): JsonValue[]` — current sorted results ([snapshot contract](#snapshots)).
- `pendingIds: ReadonlySet<string>` — ids of rows in those results that show a write not committed yet.

Initial and subsequent results are delivered through the callback.

**Full Syntax**: See [Query Language Reference](./query-language.md) for all operators (`eq`, `gte`, `contains`, `in`, etc.).

---

## Batch Operations

Perform multiple write operations (`set`, `remove`, and `increment`) atomically.

### `store.batch(operations, options?)`
Performs all operations atomically.
```typescript
await client.store.batch([
  { op: 'set', path: 'tasks.123', value: { status: 'assigned' } },
  { op: 'remove', path: 'temporary_locks.123' }
])
```

The promise resolves only if the full batch commits. If any operation fails, the batch rejects and no partial writes are committed. An empty batch resolves without writing.

Operations execute in declaration order; a later operation sees the uncommitted effects of earlier operations. This makes a batch a multi-document compare-and-set:

```typescript
await client.store.batch([
  {
    op: 'increment',
    path: 'accounts.a1.balance',
    by: -100,
    if: { balance: { gte: 100 } },
  },
  { op: 'increment', path: 'accounts.a2.balance', by: 100 },
])
```

If the first operation's precondition fails, the whole batch rolls back and rejects with `PRECONDITION_FAILED`; the destination is not credited.

**Limits**:
- Max 500 operations per batch.
- Only `set`, `remove`, and `increment` are allowed.

**Error Details**: Batch failures include `details.batchIndex` when the failing operation can be identified.

---

## Optimistic Writes

A write shows in the issuing client's subscriptions and listens before it commits ([ADR-018](../architecture/adrs.md#adr-018-mutation-outcomes-and-optimistic-local-state)). The callbacks fire synchronously inside the write call, so a controlled input sees its own value in the same handler.

```typescript
await client.store.subscribe('tasks', { where: { done: false } }, (tasks, { pending }) => {
  render(tasks, pending) // pending: ids of rows that show an uncommitted write
})

void client.store.set('tasks.t1.done', true) // t1 leaves the view now, not on commit
```

`set`, `remove`, `increment`, `create`, and `batch` accept `optimistic?: boolean` (default `true`).

- **Pending marker**: subscription callbacks receive `{ pending }`, the ids of delivered rows that show an uncommitted write; listen callbacks receive `{ pending: boolean }`. Handles expose the same as `pendingIds` and `isPending`. A change to the marker alone is also delivered.
- **Commit**: the row shows the committed value and leaves the pending set in one delivery.
- **Failure**: any failure (accept phase, write phase, timeout, disconnect) removes only the failed write's overlay before the promise rejects, then recomputes the row from committed state plus any remaining pending writes. The row returns to its committed value only when no pending write remains. A batch removes its whole overlay.
- **Membership**: a pending row is in a filtered view exactly when its local value matches the view's `where` under the server's [matching rules](./query-language.md), at its sorted position. A `create` appears in every matching view. `limit` does not bound pending rows, just as it does not bound live deltas.
- **Shown only when known**: a `set` or `increment` on a document no subscription or listen of this client holds waits for the server, because the document's other fields are unknown.
- **Never shown early**: writes with `if` and batches containing one, writes with `optimistic: false`, and writes issued while the session is not ready or a namespace switch is in flight.
- **Scope**: a disconnect or a store namespace switch drops every pending write.
- **Read rules** run on the server only. A local create that a view's read rule hides shows until it commits, then disappears.
- `get` and `query` return committed state only.

---

## Subscription Lifecycle

`store.listen` and `store.subscribe` share one registration lifecycle: readiness queueing, keyed sharing, reference-counted teardown, and synchronous snapshots.

### Readiness queue

A registration issued before the session is ready — before `connect()` settles, while reconnecting, or during a namespace switch — is queued and dispatched automatically when the session becomes ready. On recovery that is the `synced` point described in [Recovery Complete](./connection-management.md#recovery-complete); on a namespace switch the switch itself flushes the queue before its promise resolves. Registrations never fail with `SESSION_NOT_READY`.

- `client.disconnect()` discards queued registrations: nothing is dispatched and their promises reject with `CONNECTION_FAILED`.
- Writes and one-shot reads are **not** queued. They fail fast on purpose: a `set` landing minutes later against stale state is worse than an error.

### Keyed sharing

Consumers of the same subscription share one server subscription:

| API | Key |
|-----|-----|
| `listen` | normalized path |
| `subscribe` | collection + `where`/`orderBy`/`limit`/`after` in canonical serialization |

The first consumer establishes the server subscription; later consumers of the same key attach locally. A consumer attaching while establishment is in flight shares its outcome — both promises settle together. Attaching to an established subscription fires the callback immediately with the retained snapshot.

`hasMore` and `loadMore()` belong to the key, not the handle: every consumer observes and advances one shared cursor. Consumers wanting different pages of the same collection use different `after` values — and therefore different keys and different server subscriptions.

### Teardown and the grace window

`unlisten()` / `unsubscribe()` remove **this consumer**: its callback stops firing synchronously, and the returned promise resolves once local detachment completes. It is not a server acknowledgement — with sharing, the server subscription usually stays open for other consumers anyway.

When the last consumer of a key detaches, the SDK schedules the server-side unsubscribe after a fixed **300 ms grace window**. A consumer re-attaching inside the window cancels it and reuses the live subscription — the callback fires immediately from the retained snapshot, with no round trip.

- Rapid mount/unmount churn at the same key (virtualized lists, viewport panning, effect re-runs) costs zero wire traffic inside the window.
- The window is fixed SDK behavior, not a configuration knob. If server-side subscription counts ever show pressure from churn, the upgrade path is immediate unsubscribe plus a retained local snapshot for instant re-attach paint — not a knob.

### Snapshots

Each handle exposes `getSnapshot()`: a synchronous read of current state, shared across all consumers of the key.

- `listen`: the last delivered value (array/object/scalar by path depth), `undefined` before the first.
- `subscribe`: the current sorted result array.

Snapshots are new arrays per delivery; unchanged records keep their previous object reference, so consumers can use reference equality to skip work.

Snapshots are read-only. Between deltas, repeated reads return the same state; `getSnapshot` never performs I/O and never rejects.

---

## Utilities

### `client.utils.id()`
Generates a canonical lowercase UUIDv7 string synchronously on the client. Useful for generating IDs for batch operations where `store.create` cannot be used directly because relational keys need to be explicitly set.

```typescript
const userId = client.utils.id();
const profileId = client.utils.id();

client.store.batch([
  { op: 'set', path: `users.${userId}`, value: { name: 'Alice' } },
  { op: 'set', path: `profiles.${profileId}`, value: { user_id: userId } }
])
```

---

## Path Syntax (Strings vs Arrays)

All methods accept both dot-notation strings and Arrays of strings. **The Array is the canonical format.** A path array has at most three elements: `['users']`, `['users', 'u1']`, or `['users', 'u1', 'profile.address.city']`. Nested field segments belong in the third element, joined with dots; a four-or-more element array is rejected with `INVALID_PATH`. String paths may contain any nesting depth and are normalized to the three-element form.

### Logical vs. Wire-Format Paths

Paths follow a logical progression from collections to documents to specific fields. The **wire protocol** (socket) enforces a compact structure using schema index dictionaries. The SDK resolves the dot-joined field path and translates it into mapped `table_index` and `field_index` integers internally.

| Target | Logical Path (SDK) | Flattened (SDK Internal) | Wire-Format Path (Socket) | Pattern |
| :--- | :--- | :--- | :--- | :--- |
| **Collection** | `['users']` | `['users']` | `[0]` | `[table_index]` |
| **Document** | `['users', 'u1']` | `['users', 'u1']` | `[0, <bin16('u1')>]` | `[table_index, id_bin16]` |
| **Field** | `['users', 'u1', 'name']` | `['users', 'u1', 'name']` | `[0, <bin16('u1')>, 2]` | `[table_index, id_bin16, field_index]` |
| **Nested Field** | `['users', 'u1', 'address.city']` | `['users', 'u1', 'address__city']` | `[0, <bin16('u1')>, 5]` | `[table_index, id_bin16, field_index]` |

---

## Static Typing

`createClient<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>(options)` binds the API to types generated from `schema.json` (`bunx @zyncbase/client generate --schema schema.json --out zyncbase-schema.ts`). The action and presence arguments are optional. With types bound:

- `get`, `set`, `remove`, `listen` accept only declared paths — dot strings and three-segment tuples alike — with the field's declared value type.
- `create` and `set` at document depth take the schema document shape; fields listed in `required` are mandatory.
- `get` on a collection and `query`/`subscribe` rows return the generated document shape plus the server-issued `id: string`; subscription handles expose the same row type from `getSnapshot()`.
- `query`/`subscribe` `where` predicates are keyed by leaf field paths (nested objects use dot paths) and restrict operators by value type; `orderBy` clauses name exactly one leaf field and one direction. The implicit system columns `id`, `created_at`, and `updated_at` are filterable and sortable; doc ids accept equality/membership operators only.
- `actions.call`/`actions.handle` check action names, required params, `enum` literal unions, and sync return shapes; async actions (`returns: null` in the schema) resolve `undefined`.
- `presence.set`, `setShared`, `get`, `getAll`, `getShared`, and subscriptions use the declared `presence.user`/`presence.shared` shapes.
- Nested object fields are addressable at any depth; there is no depth limit.
- Without type arguments, the permissive surface applies (`string` paths, `JsonValue` values, dynamic actions/presence).

`batch` operation values and wire-internal message types remain dynamic. Generated files are committed and gated with `--check` in CI; `--watch` regenerates during development. The schema file remains the single source of truth — the server validates all writes at runtime regardless of client types.

---

## Related Specifications
- [Presence API](./presence-api.md) - For user awareness features
- [Query Language Reference](./query-language.md) - Detailed query syntax
- [Configuration & Schema](./configuration.md) - For schema definitions
- [Connection Management](./connection-management.md) - Client lifecycle and events
- [Error Handling](./error-handling.md) - Error types and write failure reporting
