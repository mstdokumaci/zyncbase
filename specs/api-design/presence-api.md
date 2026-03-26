# Presence API Reference

The Presence API tracks ephemeral user state in real-time, such as cursor positions, selections, and typing indicators. This data is stored in-memory, is schemaless (not validated against `schema.json`), and automatically cleaned up on disconnect.

## Table of Contents
1. [Methods](#presence-methods)
2. [Namespaces](#presence-namespaces)
3. [Use Cases & Examples](#use-cases--examples)
4. [Best Practices](#best-practices)

---

## Presence Methods

### `presence.set(data)`
Set your presence data. Automatically broadcast to all users in the same namespace.
```typescript
client.presence.set({ cursor: { x: 100, y: 200 }, status: 'active' })
```

### `presence.subscribe(callback)`
Subscribe to real-time changes (joins, leaves, updates) for all users in the namespace.
```typescript
const unsubscribe = client.presence.subscribe((users) => {
  renderCursors(users)
})
```

**Callback receives**: `Array<PresenceEntry>` where each entry contains:
```typescript
{
  userId: string,        // Authenticated user ID
  data: object,          // User's presence data (cursor, status, etc.)
  joinedAt: number       // Unix timestamp of when the user joined
}
```

**Returns**: An unsubscribe function.

### `presence.get(userId)`
Get a specific user's current presence data.

> [!NOTE]
> This is a **synchronous local lookup** in the SDK's internal cache. It only returns values if you have an active [Subscription](#presence-subscribe) to the namespace.
```typescript
const alice = client.presence.get('user-123')
```

### `presence.getAll(options?)`
Returns all users' presence data in the namespace. Excludes self by default.

> [!NOTE]
> Like `get()`, this is a **synchronous local lookup**. It returns an empty array if no active subscription exists.
```typescript
const everyone = client.presence.getAll({ includeSelf: true })
```

### `presence.remove()`
Remove your presence data. Called automatically on disconnect, but can be called manually.
```typescript
client.presence.remove()
```

---

## Presence Namespaces

Presence is scoped to the `presenceNamespace` set during [Client Initialization](./configuration.md). Only users in the same namespace see each other.

**Example: Document-Scoped Presence**
```typescript
const client = createClient({
  presenceNamespace: 'workspace:acme:doc:123'
})
// Users in doc:123 only see each other's cursors.
```

---

## Use Cases & Examples

### Collaborative Editor (Cursors)
```typescript
document.addEventListener('mousemove', (e) => {
  client.presence.set({ cursor: { x: e.clientX, y: e.clientY }, name: 'Alice' })
})

client.presence.subscribe((users) => {
  users.forEach(u => renderCursor(u.userId, u.data.cursor, u.data.name))
})
```

### Typing Indicators
```typescript
input.addEventListener('input', () => {
  client.presence.set({ typing: true })
  setTimeout(() => client.presence.set({ typing: false }), 3000)
})
```

---

## Throttling

- **Client-side**: The SDK automatically throttles high-frequency `presence.set()` calls to ~60fps
- **Server-side**: The server batches presence broadcasts every 50ms for efficiency

---

---

## Best Practices

1. **Keep Data Minimal**: Presence updates are frequent (~60fps). Only include essential transient state.
2. **Namespace Granularity**: Use specific namespaces (e.g., `doc:123`) rather than broad ones (e.g., `tenant:acme`) to reduce unneeded broadcasts.
3. **Handle Late Joiners**: When joining a namespace, you'll receive the last 5s of updates automatically.

---

## See Also
- [Store API Reference](./store-api.md) - For persistent state management
- [Configuration](./configuration.md) - Defining presence fields in schema
- [Connection Management](./connection-management.md) - Client lifecycle and namespace switching
- [Error Handling](./error-handling.md) - Error types and handling
