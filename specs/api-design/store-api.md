# Store API Reference

The Store API handles durable, synchronized data. Everything in this namespace is validated against your [Schema](./configuration.md#schemajson), persisted to SQLite, and synchronized across all connected clients.

Store methods require a ready store scope. `client.connect()` and `client.setStoreNamespace(namespace)` resolve only after the server has resolved the namespace and internal `users.id`; calling store methods before that point fails with `SESSION_NOT_READY`.

Mutating methods use subscription-first eventual state propagation (ADR-018). By default, `store.set`, `store.remove`, and `store.batch` resolve when the server accepts the mutation into the write pipeline. They do not optimistically update local subscription state, and they do not wait for writer commit unless `confirm: "committed"` is requested. Subscription callbacks are the authoritative source of committed observable state.

## Table of Contents

1.  [Direct Path Access](#direct-path-access-crud)
2.  [Query API (Path Filtering)](#query-api-path-filtering)
3.  [Batch Operations](#batch-operations)
4.  [Path Syntax](#path-syntax-strings-vs-arrays)

---

## Direct Path Access (CRUD)

Target specific items or properties using dot-notation or arrays.

There are strict rules on what you can write based on the depth of the path:

| Path Target | Depth | Allowed Operations | Behavior |
| :--- | :--- | :--- | :--- |
| **Collection** (`'users'`) | `1` | `create`, `query`, `listen`, `subscribe` | **Append-only for writes**. You cannot `set` or `remove` an entire collection. |
| **Document** (`'users.u1'`) | `2` | `get`, `set`, `remove`, `listen` | **Full CRUD**. `set` upserts the document, `remove` deletes it. |
| **Field** (`'users.u1.name'`) | `3+` | `get`, `set`, `listen` | **Updates only**. To clear a field, `set` it to `null`. `remove` is forbidden. |

### `store.create(collection, value)`
Creates a new document within a collection. The SDK generates a canonical lowercase UUIDv7 string and calls `set` under the hood.

```typescript
const id = await client.store.create('elements', { type: 'rect', x: 10 })
```

**Required Field Validation**: The SDK performs early validation before sending the request. If any required fields (as defined in the schema) are missing from `value`, the call throws `SCHEMA_VALIDATION_FAILED` with `details: { missingFields: [...] }`. Field names in the error use dot notation (e.g., `address.city`) for readability. Note: `store.set` does not perform this validation since it supports partial updates.

**Returns**: `Promise<string>` resolving to the generated ID after the create is accepted. Use `confirm: "committed"` when the caller needs writer-thread confirmation.

Custom document IDs are also supported when supplied in the path directly, but they must match the strict short-ID grammar: `[a-z0-9_-]{1,24}`.

### `store.get(path)`
Read a value from the state tree.
```typescript
const element = client.store.get('elements.rect-1')
```
**Returns** (varies by path depth):
- **Array of Objects**: If the path points to a collection (e.g., `client.store.get('users')` -> `Array<User>`)
- **Single Object**: If the path points to a specific document (e.g., `client.store.get('users.u1')` -> `User`)
- **Scalar value**: If the path points to a specific field (e.g., `client.store.get('users.u1.name')` -> `string`)
- `undefined`: If the path is not found

### `store.set(path, value)`
Write a value or upsert a document.

**Path Constraints**: Must target a **Document** (depth 2) or a **Field** (depth 3+). Targeting a collection (depth 1) throws an error.
**Clearing Fields**: To remove a field, `set` it to `null`. This triggers schema validation to ensure the field is not required.
**Typed Arrays**: For schema fields with `type: "array"`, values are normalized to canonical sorted unique form before persistence and returned in canonical form on reads.

```typescript
// Upsert a full document. ID is extracted from path if needed.
await client.store.set('users.u1', { name: 'Alice', status: 'active' })

// Update a specific field
await client.store.set('users.u1.status', 'offline')

// Clear an optional field (instead of remove)
await client.store.set('users.u1.address', null)

// Typed array field is canonicalized as sorted set
await client.store.set('tasks.t1.tags', ['backend', 'urgent', 'backend'])
// Stored/read as: ['backend', 'urgent']

// UI-critical write that needs writer-thread confirmation
await client.store.set('tasks.t1.status', 'done', { confirm: 'committed' })
```

**Conflict Resolution**: Server-Time Last-Write-Wins (LWW) at the Path level.

**Confirmation**:
- `confirm: "accepted"` (default): resolves when the server accepts the mutation into the write pipeline.
- `confirm: "committed"`: resolves when the writer commits the mutation or an accepted no-op; rejects if the writer reports failure.

**State Propagation**: Local subscription data changes only when the server emits subscription updates. A successful mutation promise is not a substitute for subscription state.

**Error Handling**: Immediate request errors reject the promise. Confirmed write failures reject the promise with `ZyncBaseError`. Default accepted writes do not receive guaranteed per-operation async error delivery after acceptance. See [Error Handling](./error-handling.md#error-propagation).

**Returns**: `Promise<void>`

### `store.remove(path)`
Deletes an entire document.

**Path Constraints**: Must target a **Document** (exactly depth 2). Targeting a collection (depth 1) or a field (depth 3+) throws an error. To remove a field, use `store.set(path, null)`.

```typescript
await client.store.remove('elements.rect-1')
```

**Confirmation**: Same as `store.set`. Deleting a missing document is success/no-op.

**Error Handling**: Same as `store.set`.

**Returns**: `Promise<void>`


### `store.listen(path, callback)`
Listen to real-time updates at a specific path.
```typescript
const unlisten = client.store.listen('elements.rect-1', (element) => {
  render(element)
})
```

**Callback receives** (same shape as `store.get()` return values):
- **Array** when listening to a collection
- **Object** when listening to a document
- **Scalar** when listening to a field

**Returns**: An unlisten function.

---

## Query API (Path Filtering)

For filtering, sorting, and searching through data collections.

### When to use
- Form validation (checking existence)
- Server-side rendering (initial load)
- Filtered real-time subscriptions

### `store.query(collection, options)`
Execute a one-off query (non-real-time).

```typescript
const users = await client.store.query('users', {
  where: { age: { gte: 18 }, status: { eq: 'active' } },
  orderBy: { created_at: 'desc' },
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
  - `orderBy` (object) - Sort order
  - `limit` (number) - Max results to return (must be > 0)
  - `after` (string) - Opaque token for the next page (cursor)

**Returns**: `Promise<Array & { nextCursor: string | null }>` - A standard JavaScript Array with an additional `nextCursor` property.

### `store.subscribe(collection, options, callback)`
Subscribe to filtered query results (real-time).

```typescript
const { unsubscribe, loadMore, hasMore } = client.store.subscribe('tasks', {
  where: { status: { eq: 'active' } },
  limit: 50
}, (tasks) => {
  renderTaskList(tasks)
})

// Load older history into the live view
if (hasMore) await loadMore()
```

**Parameters:**
- `collection` (string) - Name of the collection to query
- `options` (object) - Query options (same as `query()`)
- `callback` (function) - Called when results change

**Returns**: `{ unsubscribe: () => void, loadMore: () => Promise<void>, hasMore: boolean }`

**Full Syntax**: See [Query Language Reference](./query-language.md) for all operators (`eq`, `gte`, `contains`, `in`, etc.).

---

## Batch Operations

Perform multiple write operations (`set` and `remove`) atomically.

### `store.batch(operations)`
Performs all operations atomically.
```typescript
await client.store.batch([
  { op: 'set', path: 'tasks.123', value: { status: 'assigned' } },
  { op: 'remove', path: 'temporary_locks.123' }
])
```

With default confirmation, the promise resolves when the batch is accepted into the write pipeline. With `confirm: "committed"`, the promise resolves only if the full batch commits or produces accepted no-op outcomes. If any operation fails, the entire confirmed batch rejects and no partial writes are committed.

```typescript
await client.store.batch([
  { op: 'set', path: 'tasks.123', value: { status: 'assigned' } },
  { op: 'remove', path: 'temporary_locks.123' }
], { confirm: 'committed' })
```

**Limits**: 
- Max 500 operations per batch.
- Only `set` and `remove` allowed.

**Error Details**: Confirmed batch failures include `details.batchIndex` when the failing operation can be identified.

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

All methods accept both dot-notation strings and Arrays of strings. **The Array is the canonical format.**

### Logical vs. Wire-Format Paths

Paths follow a logical progression from collections to documents to specific fields. While the SDK supports variadic segments for developer convenience, the **wire protocol** (socket) enforces a compact structure using schema index dictionaries. The SDK automatically resolves nested strings and translates them into mapped `table_index` and `field_index` integers internally.

| Target | Logical Path (SDK) | Flattened (SDK Internal) | Wire-Format Path (Socket) | Pattern |
| :--- | :--- | :--- | :--- | :--- |
| **Collection** | `['users']` | `['users']` | `[0]` | `[table_index]` |
| **Document** | `['users', 'u1']` | `['users', 'u1']` | `[0, <bin16('u1')>]` | `[table_index, id_bin16]` |
| **Field** | `['users', 'u1', 'name']` | `['users', 'u1', 'name']` | `[0, <bin16('u1')>, 2]` | `[table_index, id_bin16, field_index]` |
| **Nested Field** | `['users', 'u1', 'address', 'city']` | `['users', 'u1', 'address__city']` | `[0, <bin16('u1')>, 5]` | `[table_index, id_bin16, field_index]` |

### Why use Arrays?
Arrays are preferred when dealing with variables or IDs that might contain dots:
```typescript
const userId = 'alice.smith' // Dot in ID!

// ❌ Dot-notation breaks (ambiguous)
client.store.get(`users.${userId}.name`) 

// ✅ Array handles it safely
client.store.get(['users', userId, 'name'])
```

---

## See Also
- [Presence API](./presence-api.md) - For user awareness features
- [Query Language Reference](./query-language.md) - Detailed query syntax
- [Configuration & Schema](./configuration.md) - For schema definitions
- [Connection Management](./connection-management.md) - Client lifecycle and events
- [Error Handling](./error-handling.md) - Error types and write failure reporting
