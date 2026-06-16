# Presence API Reference

The Presence API tracks ephemeral state in real-time. Presence data is typed against the `presence` schema defined in `schema.json`, stored in-memory only, and never persisted to SQLite.

Two tiers of presence state exist:
- **User state** (`presence.user` fields): one record per connected user, owned by that user, automatically cleaned up on disconnect.
- **Shared state** (`presence.shared` fields): one record per namespace, writable by any authorized user, persists until all users leave (with a 5-second grace period for reconnects).

Presence methods require a ready presence scope. `client.connect()` and `client.setPresenceNamespace(namespace)` resolve only after the server has resolved the namespace string and internal presence `users.id`. Calling presence methods before scope is ready fails with `SESSION_NOT_READY`.

## Table of Contents
1. [Schema Definition](#schema-definition)
2. [User Presence Methods](#user-presence-methods)
   - [`presence.set(data)`](#presencesetdata)
   - [`presence.subscribe(callback)`](#presencesubscribecallback)
   - [`presence.get(userId)`](#presencegetuserid)
   - [`presence.getAll(options?)`](#presencegetalloptions)
   - [`presence.remove()`](#presenceremove)
3. [Shared State Methods](#shared-state-methods)
   - [`presence.setShared(data)`](#presencesetshareddata)
   - [`presence.subscribeShared(callback)`](#presencesubscribesharedcallback)
   - [`presence.getShared()`](#presencegetshared)
4. [Namespaces](#presence-namespaces)
5. [Authorization](#authorization)
6. [Use Cases & Examples](#use-cases--examples)
7. [Best Practices](#best-practices)

---

## Schema Definition

Presence fields are defined in `schema.json` under the top-level `presence` key, parallel to `store`:

```json
{
  "version": "1.0.0",
  "store": { ... },
  "presence": {
    "user": {
      "cursor": {
        "type": "object",
        "fields": {
          "x": { "type": "number" },
          "y": { "type": "number" }
        }
      },
      "status": { "type": "string", "enum": ["active", "idle", "away"] },
      "typing": { "type": "boolean" },
      "name":   { "type": "string", "maxLength": 64 },
      "color":  { "type": "string", "pattern": "^#[0-9a-fA-F]{6}$" }
    },
    "shared": {
      "slide":   { "type": "integer", "minimum": 0 },
      "playing": { "type": "boolean" }
    }
  }
}
```

> [!NOTE]
> **Implicit schema**: If the `presence` key is omitted from `schema.json`, the server synthesizes a minimal default: `{ "user": { "status": { "type": "string", "enum": ["active", "idle", "away"] } }, "shared": {} }`. Presence is always usable — `presence.set({ status: "active" })` works immediately without any schema configuration. Defining an explicit `presence` section is recommended for applications with custom fields (cursor positions, typing indicators, etc.).

**Nesting**: Arbitrary depth of object nesting is supported. `cursor: { x, y }` is flattened to `cursor__x` and `cursor__y` on the wire — the same `__` convention as the store. A hard limit of 500 flat fields is enforced per presence tier. Developers always work with nested objects; the SDK handles flattening and unflattening transparently.

**Field constraints**: All standard schema constraints apply — `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`. Unknown field indices in a `PresenceSet` or `PresenceSetShared` message are rejected with `SCHEMA_VALIDATION_FAILED`.

**Required**: Presence fields are never required. Both tiers use merge semantics — any subset of fields can be sent at any time.

**`presence.shared` may be omitted**: If your application has no room-level shared state, omit the `shared` section. Only user presence is active.

---

## User Presence Methods

### `presence.set(data)`

Set your user presence data. Merges with your existing record — fields not included in the call are preserved unchanged. Automatically broadcasts the changed fields to all subscribers in the namespace.

```typescript
client.presence.set({ cursor: { x: 100, y: 200 } })
// cursor__x and cursor__y update. status, typing, name are untouched.

client.presence.set({ status: 'idle' })
// Only status changes. Cursor position is preserved.
```

Fire-and-forget. Server validates field types at accept time.

> [!NOTE]
> The SDK automatically throttles high-frequency `presence.set()` calls to ~60fps (16ms intervals) to prevent network saturation.

---

### `presence.subscribe(callback)`

Subscribe to real-time user presence changes in the namespace. The initial response includes the current snapshot of all users in the namespace. Pushes updates as users join, update, or leave.

```typescript
const unsubscribe = client.presence.subscribe((users) => {
  renderCursors(users)
})
```

**Callback receives**: `Array<PresenceEntry>`, excluding self by default:
```typescript
interface PresenceEntry {
  userId:   string  // Internal users.id for the active presence scope
  data: {           // User's typed presence data (SDK unflattens nested objects)
    cursor?: { x: number, y: number }
    status?: 'active' | 'idle' | 'away'
    typing?: boolean
    name?:   string
    color?:  string
  }
  joinedAt: number  // Unix timestamp ms of when the user joined
}
```

**Returns**: An unsubscribe function. Calling it sends `PresenceUnsubscribe` to the server.

---

### `presence.get(userId)`

Synchronous local lookup of a specific user's presence. Returns `undefined` if the user is not present or no active `subscribe()` exists.

> [!NOTE]
> Zero-latency — reads from the SDK's in-memory cache populated by `subscribe()`. You must call `subscribe()` before `get()` returns meaningful data.

```typescript
const alice = client.presence.get('018f3a...')
// { cursor: { x: 100, y: 200 }, status: 'active', joinedAt: 1234567890 }
```

---

### `presence.getAll(options?)`

Synchronous local lookup of all users' presence in the namespace. Excludes self by default.

```typescript
const others   = client.presence.getAll()
const everyone = client.presence.getAll({ includeSelf: true })
```

Returns `[]` if no active `subscribe()` exists.

---

### `presence.remove()`

Remove your presence record and broadcast a `leave` event to all subscribers. Called automatically on disconnect, but available to invoke manually — for example, to go "invisible" without disconnecting.

```typescript
client.presence.remove()
```

---

## Shared State Methods

Shared state is a single merged record for the entire namespace. Any authorized user may write it. Last-writer-wins at field granularity. The record persists until all users leave, with a 5-second grace period before it is cleared.

### `presence.setShared(data)`

Merge fields into the namespace-level shared state. Fire-and-forget. Fields not included in the call are preserved unchanged. Broadcasts changed fields to all `subscribeShared` subscribers in the namespace.

```typescript
client.presence.setShared({ slide: 5 })
// Only slide changes. playing is preserved.
```

Server validates field types at accept time. Subject to `presenceSharedWrite` authorization. Rejected with `PERMISSION_DENIED` if the rule is not satisfied.

---

### `presence.subscribeShared(callback)`

Subscribe to changes in the namespace-level shared state. The initial response includes the current shared state (or `null` if no user has called `setShared` yet). Pushes updates whenever any authorized user calls `setShared`.

```typescript
const unsubscribe = client.presence.subscribeShared((shared) => {
  goToSlide(shared.slide)
})
```

**Callback receives**: The typed shared state object with optional fields (SDK unflattens nested objects):
```typescript
{ slide?: number, playing?: boolean }
```

**Returns**: An unsubscribe function. Calling it sends `PresenceUnsubscribeShared` to the server.

> [!NOTE]
> `subscribe()` and `subscribeShared()` are independent calls. You can hold either or both active simultaneously. Neither is a prerequisite for the other.

---

### `presence.getShared()`

Synchronous local lookup of the current shared state. Returns `null` if no active `subscribeShared()` exists or if no shared state has been set yet.

> [!NOTE]
> Zero-latency — reads from the SDK's in-memory cache populated by `subscribeShared()`. You must call `subscribeShared()` before `getShared()` returns meaningful data.

```typescript
const shared = client.presence.getShared()
// { slide: 5, playing: true }
```

---

## Presence Namespaces

Presence is scoped to `presenceNamespace`. Only users in the same namespace see each other and share the same shared state record. When `users.namespaced = true`, the namespace also determines which internal `users.id` is used for presence identity.

```typescript
const client = createClient({
  presenceNamespace: 'workspace:acme:doc:123'
})
```

**Switching namespaces**: `client.setPresenceNamespace(ns)` removes your user presence from the old namespace, clears the local user and shared state caches, resolves the new presence scope, and invalidates all active presence and shared-state subscriptions. The client must re-subscribe.

---

## Authorization

Defined in `authorization.json` under each namespace pattern:

```json
{
  "namespaces": [
    {
      "pattern": "workspace:*",
      "storeFilter":        true,
      "presenceRead":        { "$session.userId": { "ne": null } },
      "presenceWrite":       { "$session.userId": { "ne": null } },
      "presenceSharedWrite": { "$session.role":   { "in": ["host", "presenter"] } }
    }
  ],
  "store": []
}
```

| Rule | Controls |
|---|---|
| `presenceRead` | Who can subscribe to user presence and shared state in this namespace |
| `presenceWrite` | Who can call `presence.set()` and `presence.remove()` |
| `presenceSharedWrite` | Who can call `presence.setShared()` |

**`$data` in rules**: The incoming field values are exposed as `$data` in both `presenceWrite` and `presenceSharedWrite` rules, enabling content-gated authorization:

```json
"presenceSharedWrite": { "$data.slide": { "gte": 0 } }
```

All three rules accept `true` (open to all with presence scope), `false` (closed), or a RAM-only predicate over `$session`, `$namespace`, and `$data`.

**`presenceSharedWrite` default**: When omitted, defaults to the same value as `presenceWrite` — if you can write user presence, you can write shared state, unless explicitly restricted.

---

## Use Cases & Examples

### Collaborative Editor — Cursors and Status

```typescript
// schema.json
{
  "presence": {
    "user": {
      "cursor": {
        "type": "object",
        "fields": {
          "x": { "type": "number" },
          "y": { "type": "number" }
        }
      },
      "name":   { "type": "string", "maxLength": 64 },
      "color":  { "type": "string", "pattern": "^#[0-9a-fA-F]{6}$" },
      "status": { "type": "string", "enum": ["active", "idle"] }
    }
  }
}

// Client
document.addEventListener('mousemove', (e) => {
  client.presence.set({ cursor: { x: e.clientX, y: e.clientY } })
})

client.presence.subscribe((users) => {
  users.forEach(u => renderCursor(u.userId, u.data.cursor, u.data.color))
})
```

### Typing Indicators

```typescript
let typingTimer: ReturnType<typeof setTimeout>

input.addEventListener('input', () => {
  client.presence.set({ typing: true })
  clearTimeout(typingTimer)
  typingTimer = setTimeout(() => client.presence.set({ typing: false }), 3000)
})
```

### Presentation — Shared Slide Navigation

```typescript
// schema.json
{
  "presence": {
    "user": {
      "name": { "type": "string", "maxLength": 64 }
    },
    "shared": {
      "slide": { "type": "integer", "minimum": 0 }
    }
  }
}

// authorization.json — only hosts can advance the slide
{
  "namespaces": [
    {
      "pattern": "presentation:*",
      "storeFilter":        true,
      "presenceRead":        true,
      "presenceWrite":       { "$session.userId": { "ne": null } },
      "presenceSharedWrite": { "$session.role": { "eq": "host" } }
    }
  ],
  "store": []
}

// Host client
nextBtn.addEventListener('click', () => {
  const current = client.presence.getShared()?.slide ?? 0
  client.presence.setShared({ slide: current + 1 })
})

// All clients
client.presence.subscribeShared((shared) => {
  goToSlide(shared.slide)
})
```

### Co-Watch Video Sync

```typescript
// schema.json
{
  "presence": {
    "user": {
      "name": { "type": "string", "maxLength": 64 }
    },
    "shared": {
      "playing":   { "type": "boolean" },
      "timestamp": { "type": "number" }
    }
  }
}

// Any authorized user can control playback
video.addEventListener('play', () => {
  client.presence.setShared({ playing: true, timestamp: video.currentTime })
})
video.addEventListener('pause', () => {
  client.presence.setShared({ playing: false, timestamp: video.currentTime })
})

client.presence.subscribeShared(({ playing, timestamp }) => {
  video.currentTime = timestamp
  playing ? video.play() : video.pause()
})
```

---

## Throttling

| Operation | Layer | Mechanism |
|---|---|---|
| `presence.set()` | Client-side | SDK throttles to ~60fps (16ms intervals). |
| `presence.setShared()` | Client-side | Not throttled — shared state changes are infrequent by design. |
| User presence broadcasts | Server-side | Batched every 50ms. Multiple updates within the window are merged into one `PresenceBroadcast` per subscriber. |
| Shared state broadcasts | Server-side | Batched every 50ms. Multiple `setShared` calls within the window are merged into one `SharedStateBroadcast` per subscriber. |

---

## Best Practices

1. **Keep user fields minimal**: Only include essential transient state. Move stable data like `name` and `color` to the `users` collection in the store, where they persist and can be queried.
2. **Send only what changed**: Merge semantics mean you pay only for what you send. Cursor-only updates should not include status or name.
3. **Namespace granularity**: Use specific namespaces (`doc:123`) rather than broad ones (`tenant:acme`) to reduce fan-out and avoid leaking presence across unrelated contexts.
4. **Use `subscribeShared` for room-level coordination**: Do not use the store for ephemeral room state. The shared tier exists precisely for this — it is faster, never persisted, and cleaned up automatically.
5. **Design shared state for LWW**: If two users write shared state simultaneously, last-writer-wins at the server. Shared state fields should be self-describing values (slide index, boolean flag) that remain meaningful under concurrent writes.

---

## See Also
- [Store API Reference](./store-api.md) — For persistent state management
- [Configuration](./configuration.md) — Defining presence and store schemas in `schema.json`
- [Authorization](./configuration.md#authorizationjson) — Presence auth rules in `authorization.json`
- [Error Handling](./error-handling.md) — Error types and handling strategies
