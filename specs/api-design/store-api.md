# Store API Reference

The Store API handles durable, synchronized data. Everything in this namespace is validated against your [Schema](./configuration.md#schemajson), persisted to SQLite, and synchronized across all connected clients.

## Table of Contents

1.  [Direct Path Access](#direct-path-access-crud)
2.  [Query API (Path Filtering)](#query-api-path-filtering)
3.  [Batch Operations](#batch-operations)
4.  [Path Syntax](#path-syntax-strings-vs-arrays)

---

## Direct Path Access (CRUD)

Target specific items or properties using dot-notation or arrays.

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
Write a value. **Optimistic by default**: applied locally first, then synced. Reverted if the server rejects it.
**Conflict Resolution**: Server-Time Last-Write-Wins (LWW) at the Path level.
```typescript
client.store.set('user.name', 'Alice')
```

**Error Handling**: Since `set()` is fire-and-forget, errors are reported via `client.on('error', ...)`. See [Error Handling](./error-handling.md#error-propagation).

**ID Extraction**: When calling `set()` on a document path (e.g., `elements.rect-1`), the SDK automatically extracts the ID (`rect-1`) from the path and merges it into the stored object. You do not need to include `id` in the value.

**Returns**: `void`

### `store.remove(path)`
Removes a value at the specified path.
```typescript
client.store.remove('elements.rect-1')
```

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
  - `limit` (number) - Max results to return
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
If *any* operation in the batch fails, the *entire* batch is rejected (locally reverted).
```typescript
await client.store.batch([
  { op: 'set', path: 'tasks.123', value: { status: 'assigned' } },
  { op: 'remove', path: 'temporary_locks.123' }
])
```
**Limits**: 
- Max 500 operations per batch.
- Only `set` and `remove` allowed.

---

## Path Syntax (Strings vs Arrays)

All methods accept both dot-notation strings and Arrays of strings. **The Array is the canonical format.**

### Addressing Data
Paths are variadic and follow a logical progression from collections to documents to specific fields:

| Target | Pattern | Array Example | Dot Example |
| :--- | :--- | :--- | :--- |
| **Collection** | `[collection]` | `['users']` | `'users'` |
| **Document** | `[collection, id]` | `['users', 'u1']` | `'users.u1'` |
| **Field** | `[collection, id, field]` | `['users', 'u1', 'name']` | `'users.u1.name'` |
| **Nested Field** | `[collection, id, ...fields]` | `['users', 'u1', 'address', 'city']` | `'users.u1.address.city'` |

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
- [Error Handling](./error-handling.md) - Error types and optimistic revert behavior
