# Presence API Reference

The Presence API tracks ephemeral user state in real-time, such as cursor positions, selections, and typing indicators. This data is stored in-memory and automatically cleaned up on disconnect.

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

### `presence.get(userId)`
Get a specific user's current presence data.
```typescript
const alice = client.presence.get('user-123')
```

### `presence.getAll(options?)`
Returns all users' presence data in the namespace. Excludes self by default.
```typescript
const everyone = client.presence.getAll({ includeSelf: true })
```

### `presence.subscribe(callback)`
Subscribe to real-time changes (joins, leaves, updates) for all users in the namespace.
```typescript
client.presence.subscribe((users) => {
  renderCursors(users)
})
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

## Best Practices

1. **Keep Data Minimal**: Presence updates are frequent (~60fps). Only include essential transient state.
2. **Namespace Granularity**: Use specific namespaces (e.g., `doc:123`) rather than broad ones (e.g., `tenant:acme`) to reduce unneeded broadcasts.
3. **Handle Late Joiners**: When joining a namespace, you'll receive the last 5s of updates automatically.

---

## See Also
- [Store API Reference](./store-api.md) - For persistent state management.
- [Configuration](./configuration.md) - Defining presence fields in schema.
