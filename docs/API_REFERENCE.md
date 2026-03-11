# zyncBase Client SDK API Reference

**Last Updated**: 2026-03-09

Complete reference for the zyncBase TypeScript/JavaScript client SDK.

---

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Store API](#store-api-path-based-state-access)
3. [Query API](#query-api-path-filtering) - See also: [Query Language Reference](./QUERY_LANGUAGE.md)
4. [Presence API](#presence-api-user-awareness)
5. [Connection Management](#connection-management)
6. [Framework Integrations](#framework-integrations)

---

## Core Concepts

zyncBase provides three complementary APIs for different use cases:

1. **Store API** - Direct path-based access to state tree (80% of use cases)
2. **Query API** - Filter and search data at a path (15% of use cases)
3. **Presence API** - Real-time user presence (5% of use cases)

All data lives in a hierarchical store organized by paths (e.g., `users`, `tasks.task-1`). The Store API accesses specific paths directly, while the Query API filters items at a path.

### Namespaces

zyncBase uses **namespaces** to isolate data and presence:

- **Store namespace** - Controls which data you can access
- **Presence namespace** - Controls which users you see

**Common patterns:**

```typescript
// Simple app (defaults to public namespace)
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token }
})
// Defaults: storeNamespace: 'public', presenceNamespace: 'public'

// Multi-tenant app (tenant isolation)
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme'
})
// Backend can also derive namespace from JWT

// Collaborative editor (fine-grained presence)
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme',
  presenceNamespace: 'tenant:acme:document:doc-123'
})
```

**Hierarchical namespaces** allow granular access control:

```
tenant:acme                                    // Broad access (all data)
  └─ tenant:acme:workspace:ws-1                // Workspace-scoped
      └─ tenant:acme:workspace:ws-1:document:doc-123  // Document-scoped
```

Auth rules determine which namespaces you can access. See [Configuration](./CONFIGURATION.md) for auth setup.

---

## Store API (Path-based State Access)

The Store API is for direct access to known paths in your state tree.

### When to use

- Accessing specific items by ID
- Updating nested properties
- Real-time sync of collaborative state
- Most common use case

### Methods

#### `store.get(path)`

Read a value from the state tree.

```typescript
// Get entire collection
const elements = client.store.get('elements')

// Get specific item
const element = client.store.get('elements.rect-1')

// Get nested property
const userName = client.store.get('user.name')
```

**Parameters:**
- `path` (string) - Dot-notation path to the value

**Returns:** The value at the path, or `undefined` if not found

---

#### `store.set(path, value)`

Write a value to the state tree. Automatically syncs to server and all connected clients.

```typescript
// Set entire object
client.store.set('elements.rect-1', {
  x: 100,
  y: 100,
  width: 200,
  height: 150
})

// Set nested property
client.store.set('user.name', 'Alice')

// Set array
client.store.set('tasks', [
  { id: 1, title: 'Task 1' },
  { id: 2, title: 'Task 2' }
])
```

**Parameters:**
- `path` (string) - Dot-notation path
- `value` (any) - Value to set (must match schema)

**Returns:** `void`

---

#### `store.subscribe(path, callback)`

Subscribe to real-time updates at a path.

```typescript
// Subscribe to collection
const unsubscribe = client.store.subscribe('elements', (elements) => {
  renderCanvas(elements)
})

// Subscribe to specific item
client.store.subscribe('elements.rect-1', (rect) => {
  updateRect(rect)
})

// Subscribe to nested property
client.store.subscribe('user.name', (name) => {
  updateUserName(name)
})

// Cleanup
unsubscribe()
```

**Parameters:**
- `path` (string) - Dot-notation path
- `callback` (function) - Called when value changes

**Returns:** Unsubscribe function

---

## Query API (Path Filtering)

The Query API is for filtering, sorting, and searching through data at a path.

### When to use

- Form validation (check if username exists)
- Server-side rendering (initial data load)
- Export/batch operations (generate CSV)
- One-time checks (non-real-time)
- Filtered real-time subscriptions

### Query Language

zyncBase uses a Prisma-inspired query language with implicit AND, explicit OR, and short operator names.

For complete query language documentation, see [Query Language Reference](./QUERY_LANGUAGE.md).

**Quick example:**

```typescript
const users = await client.query('users', {
  where: {
    age: { gte: 18 },              // Implicit AND
    status: { eq: 'active' },
    role: { in: ['admin', 'editor'] }
  },
  orderBy: { created_at: 'desc' },
  limit: 50
})
```

---

### Methods

#### `client.query(path, options)`

Execute a one-off query (non-real-time).

```typescript
// Simple query on a path
const users = await client.query('users', {
  where: {
    age: { gte: 18 },
    status: { eq: 'active' }
  }
})

// With sorting and pagination
const events = await client.query('events', {
  where: {
    created_at: { gte: startDate, lte: endDate },
    status: { eq: 'active' }
  },
  orderBy: { created_at: 'desc' },
  limit: 50,
  offset: 0
})

// Check if username exists (validation)
const existing = await client.query('users', {
  where: { username: { eq: 'alice' } }
})
const isAvailable = existing.length === 0
```

**Parameters:**
- `path` (string) - Path to query (e.g., 'users', 'events', 'rooms.room-1.messages')
- `options` (object) - Query options
  - `where` (object) - Filter conditions
  - `orderBy` (object) - Sort order
  - `limit` (number) - Max results
  - `offset` (number) - Skip results

**Returns:** `Promise<Array>` - Array of matching items

---

#### `client.subscribe(path, options, callback)`

Subscribe to filtered query results (real-time).

```typescript
// Subscribe to filtered results
const unsubscribe = client.subscribe('tasks', {
  where: { 
    project_id: { eq: currentProject },
    status: { eq: 'active' }
  },
  orderBy: { created_at: 'desc' }
}, (tasks) => {
  renderTaskList(tasks)
})

// Cleanup
unsubscribe()
```

**Parameters:**
- `path` (string) - Path to query
- `options` (object) - Query options (same as `query()`)
- `callback` (function) - Called when results change

**Returns:** Unsubscribe function

---

### Query Language Reference

For detailed documentation on query operators, combining conditions, sorting, and pagination, see the [Query Language Reference](./QUERY_LANGUAGE.md).

**Available operators:**
- Equality: `eq`, `ne`
- Comparison: `gt`, `gte`, `lt`, `lte`
- String: `contains`, `startsWith`, `endsWith`
- Array: `in`, `notIn`
- Null: `isNull`, `isNotNull`

**Combining conditions:**
- Implicit AND at root level
- Explicit `or` for OR conditions

**Sorting and pagination:**
- `orderBy: { field: 'asc' | 'desc' }`
- `limit` and `offset` for pagination

---

## Presence API (User Awareness)

The Presence API tracks who's online and what they're doing in real-time.

### When to use

- Show online users
- Display cursors in collaborative editor
- Show typing indicators
- Real-time user activity

### Presence Namespace

Presence is scoped to the `presenceNamespace` set when creating the client. Only users in the same presence namespace can see each other.

```typescript
// Users in document:doc-123 see each other
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  presenceNamespace: 'tenant:acme:document:doc-123'
})

// Switch to different document
await client.setPresenceNamespace('tenant:acme:document:doc-456')
```

### Schema

Define presence structure in `schema.json`:

```json
{
  "version": "1.0.0",
  "store": { ... },
  "presence": {
    "fields": {
      "cursor": {
        "type": "object",
        "properties": {
          "x": { "type": "number" },
          "y": { "type": "number" }
        }
      },
      "status": {
        "type": "string",
        "enum": ["active", "away", "idle"]
      }
    }
  }
}
```

### Methods

#### `presence.set(data)`

Set your presence data. Automatically broadcast to all users in the presence namespace.

```typescript
// Set cursor position
client.presence.set({
  cursor: { x: 100, y: 200 },
  color: '#ff0000',
  name: 'Alice'
})

// Update typing indicator
client.presence.set({
  typing: true,
  field: 'description'
})

// Partial updates (merge with existing)
client.presence.set({
  status: 'away'
})
```

**Parameters:**
- `data` (object) - Presence data (must match schema)

**Returns:** `void`

**Throttling:**
Client automatically throttles high-frequency updates (e.g., cursor moves) to ~60fps. Server batches updates every 50ms for efficiency.

---

#### `presence.get(userId)`

Get a specific user's presence data.

```typescript
const alicePresence = client.presence.get('user-123')
// Returns: { cursor: { x: 100, y: 200 }, color: '#ff0000', name: 'Alice' }
```

**Parameters:**
- `userId` (string) - User ID

**Returns:** Presence data object or `undefined`

---

#### `presence.getAll()`

Get all users' presence data in the current namespace.

```typescript
const others = client.presence.getAll()
// Returns: [
//   { userId: 'user-123', data: { cursor: {...}, color: '...' } },
//   { userId: 'user-456', data: { cursor: {...}, color: '...' } }
// ]
```

**Returns:** Array of `{ userId, data }` objects

---

#### `presence.subscribe(callback)`

Subscribe to presence changes in the current presence namespace.

```typescript
const unsubscribe = client.presence.subscribe((presenceList) => {
  // Render cursors for all users in this namespace
  renderCursors(presenceList)
})

// Cleanup
unsubscribe()
```

**Parameters:**
- `callback` (function) - Called when presence changes

**Callback receives:**
```typescript
[
  { 
    userId: 'user-123', 
    data: { cursor: { x: 100, y: 200 }, color: '#ff0000' },
    joinedAt: 1234567890
  },
  { 
    userId: 'user-456', 
    data: { cursor: { x: 300, y: 400 }, color: '#00ff00' },
    joinedAt: 1234567891
  }
]
```

**Returns:** Unsubscribe function

**History buffer:**
When you join a presence namespace, you receive the last 5 seconds of presence updates for context (e.g., cursor trails).

---

#### `presence.clear()`

Clear your presence data (called automatically on disconnect).

```typescript
client.presence.clear()
```

---

## Connection Management

### Creating a Client

```typescript
import { createClient } from '@zyncBase/client'

const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token: userJWT },
  storeNamespace: 'tenant:acme',
  presenceNamespace: 'tenant:acme:document:doc-123',
  reconnect: true,
  reconnectDelay: 1000
})
```

**Options:**
- `url` (string, required) - WebSocket server URL
- `auth` (object, required) - Authentication credentials
  - `token` (string) - JWT token
- `storeNamespace` (string, optional) - Namespace for store operations
  - Default: `'public'` or derived from JWT
  - Controls which data you can access
  - Hierarchical: `'tenant:acme:workspace:ws-1'`
- `presenceNamespace` (string, optional) - Namespace for presence
  - Default: Same as `storeNamespace`
  - Controls which users you see
  - Usually more specific: `'tenant:acme:document:doc-123'`
- `reconnect` (boolean, default: true) - Auto-reconnect on disconnect
- `reconnectDelay` (number, default: 1000) - Delay between reconnect attempts (ms)

**Namespace examples:**

```typescript
// Simple app (defaults to public namespace)
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token }
})
// Defaults: storeNamespace: 'public', presenceNamespace: 'public'

// Multi-tenant (JWT-derived)
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token }  // JWT contains tenantId
})
// Backend sets storeNamespace from JWT: 'tenant:acme'

// Explicit namespaces
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme:workspace:ws-1',
  presenceNamespace: 'tenant:acme:workspace:ws-1:document:doc-123'
})

// Same namespace for both
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'room:general',
  presenceNamespace: 'room:general'
})
```

---

### Methods

#### `client.connect()`

Connect to the server.

```typescript
await client.connect()
```

**Returns:** `Promise<void>`

---

#### `client.disconnect()`

Disconnect from the server. Automatically clears presence.

```typescript
client.disconnect()
```

---

#### `client.setStoreNamespace(namespace)`

Switch to a different store namespace.

```typescript
// Switch to different workspace
await client.setStoreNamespace('tenant:acme:workspace:ws-2')

// Switch to different tenant (if authorized)
await client.setStoreNamespace('tenant:globex')
```

**Parameters:**
- `namespace` (string) - New store namespace

**Returns:** `Promise<void>`

**Throws:** Authorization error if not allowed to access namespace

---

#### `client.setPresenceNamespace(namespace)`

Switch to a different presence namespace.

```typescript
// Switch to different document
await client.setPresenceNamespace('tenant:acme:document:doc-456')

// Switch to different room
await client.setPresenceNamespace('room:dev')
```

**Parameters:**
- `namespace` (string) - New presence namespace

**Returns:** `Promise<void>`

**Note:** Automatically clears your presence in the old namespace and joins the new one.

---

### Event Listeners

#### `client.on(event, callback)`

Listen to connection events.

```typescript
client.on('connected', () => {
  console.log('Connected to server')
})

client.on('disconnected', () => {
  console.log('Disconnected from server')
})

client.on('reconnecting', () => {
  console.log('Reconnecting...')
})

client.on('error', (error) => {
  console.error('Connection error:', error)
})
```

**Events:**
- `connected` - Successfully connected
- `disconnected` - Connection closed
- `reconnecting` - Attempting to reconnect
- `error` - Connection error occurred

---

## Framework Integrations

### React

```typescript
import { useStore, useQuery, usePresence } from '@zyncBase/react'

function Canvas() {
  // Store subscription (auto cleanup on unmount)
  const elements = useStore('elements')
  
  // Query subscription
  const tasks = useQuery('tasks', {
    where: { status: { eq: 'active' } }
  })
  
  // Presence subscription
  const others = usePresence()
  
  return (
    <>
      {elements.loading && <Spinner />}
      {elements.error && <Error />}
      {elements.data && <CanvasView elements={elements.data} />}
      <Cursors users={others} />
    </>
  )
}
```

**Hooks:**
- `useStore(path)` - Subscribe to store path
- `useQuery(path, options)` - Subscribe to query results
- `usePresence()` - Subscribe to presence updates

**Return value:**
```typescript
{
  data: any,           // The data
  loading: boolean,    // Loading state
  error: Error | null  // Error if any
}
```

---

### Vue

```typescript
import { useStore, useQuery, usePresence } from '@zyncBase/vue'

export default {
  setup() {
    const { data: elements, loading, error } = useStore('elements')
    
    const { data: tasks } = useQuery('tasks', {
      where: { status: { eq: 'active' } }
    })
    
    const others = usePresence()
    
    return { elements, tasks, others, loading, error }
  }
}
```

---

### Svelte

```typescript
import { store, query, presence } from '@zyncBase/svelte'

// Svelte stores - automatic subscription
const elements = store('elements')
const tasks = query('tasks', {
  where: { status: { eq: 'active' } }
})
const others = presence()

// Use in template: $elements, $tasks, $others
```

```svelte
<script>
  import { store, presence } from '@zyncBase/svelte'
  
  const elements = store('elements')
  const others = presence()
</script>

{#if $elements.loading}
  <Spinner />
{:else if $elements.error}
  <Error error={$elements.error} />
{:else}
  <CanvasView elements={$elements.data} />
  <Cursors users={$others} />
{/if}
```

---

## TypeScript Support

zyncBase is written in TypeScript and provides full type safety.

### Type-safe Schema

```typescript
import { createClient } from '@zyncBase/client'
import type { Schema } from './schema'

const client = createClient<Schema>({
  url: 'ws://localhost:3000',
  auth: { token: userJWT },
  namespace: 'room:abc-123'
})

// TypeScript knows the shape of your data
const elements = client.store.get('elements')
// Type: Record<string, Element>

// Type errors for invalid paths
client.store.get('invalid.path')
// Error: Property 'invalid' does not exist on type 'Schema'
```

---

## Error Handling

```typescript
try {
  await client.connect()
} catch (error) {
  if (error.code === 'AUTH_FAILED') {
    // Handle authentication error
  } else if (error.code === 'NAMESPACE_NOT_FOUND') {
    // Handle namespace error
  } else {
    // Handle other errors
  }
}
```

**Error Codes:**
- `AUTH_FAILED` - Authentication failed
- `NAMESPACE_UNAUTHORIZED` - Not authorized to access namespace
- `PERMISSION_DENIED` - Not authorized for operation
- `SCHEMA_VALIDATION_FAILED` - Data doesn't match schema
- `CONNECTION_FAILED` - Network error
- `TIMEOUT` - Operation timed out

---

## Best Practices

### 1. Always cleanup subscriptions

```typescript
// Bad
client.store.subscribe('elements', callback)

// Good
const unsubscribe = client.store.subscribe('elements', callback)
// Later...
unsubscribe()

// Best (use framework integration)
const elements = useStore('elements') // Auto cleanup
```

### 2. Use framework integrations

Framework integrations handle cleanup automatically and provide better DX.

### 3. Validate on both sides

Even though the server validates, validate on the client too for better UX:

```typescript
// Client-side validation
if (!isValidEmail(email)) {
  showError('Invalid email')
  return
}

// Server validates too (schema.json)
client.store.set('user.email', email)
```

### 4. Handle connection states

```typescript
client.on('disconnected', () => {
  showOfflineBanner()
})

client.on('connected', () => {
  hideOfflineBanner()
})
```

### 5. Use presence sparingly

Presence updates are frequent. Only send what's necessary:

```typescript
// Bad - too much data
client.presence.set({
  cursor: { x, y },
  color,
  name,
  avatar,
  bio,
  preferences,
  // ...
})

// Good - minimal data
client.presence.set({
  cursor: { x, y },
  color
})
```

---

## Examples

See [github.com/zyncBase/examples](https://github.com/zyncBase/examples) for complete examples:

- Collaborative whiteboard
- Real-time chat
- Multi-tenant dashboard
- Multiplayer game
- And more...
