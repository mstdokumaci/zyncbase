# Connection Management

SDK client lifecycle: creating clients, connecting, namespace switching, reconnection, and event handling.

---

## Table of Contents

1. [Creating a Client](#creating-a-client)
2. [Connection Lifecycle](#connection-lifecycle)
3. [Namespace Switching](#namespace-switching)
4. [Event Listeners](#event-listeners)
5. [Reconnection Strategy](#reconnection-strategy)
6. [Token Refresh](#token-refresh)

---

## Creating a Client

```typescript
import { createClient } from '@zyncbase/client'

const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token: userJWT },
  storeNamespace: 'tenant:acme',
  presenceNamespace: 'tenant:acme:document:doc-123',
  reconnect: true,
  reconnectDelay: 1000,
  maxReconnectDelay: 30000,
  maxReconnectAttempts: Infinity,
  reconnectJitter: true
})
```

### Options Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `url` | string | *(required)* | WebSocket server URL |
| `auth.token` | string | *(required)* | External JWT for authentication |
| `storeNamespace` | string | `'public'` | Namespace for store operations. Can also be derived from JWT on the server. |
| `presenceNamespace` | string | same as `storeNamespace` | Namespace for presence. Usually more specific (e.g., document-scoped). |
| `reconnect` | boolean | `true` | Auto-reconnect on unexpected disconnect |
| `reconnectDelay` | number | `1000` | Base delay (ms) between reconnect attempts |
| `maxReconnectDelay` | number | `30000` | Maximum delay cap (ms) for exponential backoff |
| `maxReconnectAttempts` | number | `Infinity` | Max retry attempts before giving up |
| `reconnectJitter` | boolean | `true` | Add ±10% randomness to retry timing (prevents thundering herd) |

### Namespace Examples

```typescript
// Simple app (defaults to public namespace)
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token }
})
// storeNamespace: 'public', presenceNamespace: 'public'

// Multi-tenant (JWT-derived on server)
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token }  // JWT contains tenantId; server derives namespace
})

// Explicit namespaces
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme:workspace:ws-1',
  presenceNamespace: 'tenant:acme:workspace:ws-1:document:doc-123'
})
```

---

## Connection Lifecycle

### `client.connect()`

Initiates the connection sequence:
1. **Ticket exchange** (HTTP POST `/auth/ticket`) — obtains a single-use ticket from the external JWT
2. **WebSocket upgrade** (`GET /ws?ticket=...`) — opens the WebSocket connection
3. **`Connected` push** — the server sends a `Connected` message with `userId`, `session`, and active namespaces

The SDK should wait for the `Connected` push before resolving the `connect()` promise.

```typescript
await client.connect()
// Connection is fully established, ready to use store and presence APIs
```

**Returns:** `Promise<void>`  
**Throws:** `ZyncBaseError` with code `AUTH_FAILED` or `CONNECTION_FAILED`

### `client.disconnect()`

Gracefully closes the connection. Automatically clears presence in the active namespace.

```typescript
client.disconnect()
```

> [!NOTE]
> For full wire-level details of the connection lifecycle (ticket format, `Connected` payload, heartbeat, graceful close), see the [Wire Protocol](../implementation/wire-protocol.md#connection-lifecycle).

---

## Namespace Switching

### `client.setStoreNamespace(namespace)`

Switch the active store namespace at runtime. Active store subscriptions are invalidated — the client must re-subscribe.

```typescript
await client.setStoreNamespace('tenant:acme:workspace:ws-2')
```

**Parameters:** `namespace` (string)  
**Returns:** `Promise<void>`  
**Throws:** `ZyncBaseError` with code `NAMESPACE_UNAUTHORIZED` if not permitted

### `client.setPresenceNamespace(namespace)`

Switch the active presence namespace. Automatically clears your presence in the old namespace and joins the new one.

```typescript
await client.setPresenceNamespace('tenant:acme:document:doc-456')
```

**Parameters:** `namespace` (string)  
**Returns:** `Promise<void>`

---

## Event Listeners

### `client.on(event, callback)`

Listen to connection lifecycle events.

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

client.on('error', (error: ZyncBaseError) => {
  console.error('Error:', error.code, error.message)
})

client.on('tokenExpired', async () => {
  const newToken = await refreshAuthToken()
  await client.authRefresh(newToken)
})
```

### Events

| Event | Callback Signature | Description |
|-------|-------------------|-------------|
| `connected` | `() => void` | WebSocket established and `Connected` push received |
| `disconnected` | `() => void` | Connection closed (manually or after max retries) |
| `reconnecting` | `() => void` | Attempting to reconnect after unexpected disconnect |
| `error` | `(error: ZyncBaseError) => void` | Error from a fire-and-forget write or subscription |
| `tokenExpired` | `() => void` | Server indicates token has expired; SDK should refresh |
| `statusChange` | `(status, detail) => void` | Fired on any state transition (see below) |

### `statusChange` Detail

```typescript
client.on('statusChange', (status, detail) => {
  // status: 'connecting' | 'connected' | 'reconnecting' | 'disconnected'
  // detail.previousStatus: the state before this transition
  // detail.retryCount: current attempt number (0 when first connecting)
  // detail.retryIn: ms until next attempt (null if not reconnecting)
  // detail.error: last error, if any
})
```

---

## Reconnection Strategy

When a connection is lost unexpectedly, the SDK uses exponential backoff with optional jitter:

```
delay = min(reconnectDelay × 2^attempt + jitter, maxReconnectDelay)
```

Where `jitter = delay × 0.1 × random(-1, 1)` (±10% randomness).

**Sequence example** (with defaults):
```
Attempt 1: ~1s
Attempt 2: ~2s
Attempt 3: ~4s
Attempt 4: ~8s
Attempt 5: ~16s
Attempt 6+: ~30s (capped)
```

The SDK should continue retrying up to `maxReconnectAttempts`. If exhausted, emit `disconnected` and stop.

---

## Token Refresh

### `client.authRefresh(token)`

Update the connection's session with a new external JWT without disconnecting.

```typescript
client.on('tokenExpired', async () => {
  const newToken = await myAuthService.refresh()
  await client.authRefresh(newToken)
})
```

**Parameters:** `token` (string) — new external JWT  
**Returns:** `Promise<void>`

Under the hood, this sends an `AuthRefresh` wire message. See [Wire Protocol](../implementation/wire-protocol.md#authrefresh) for details.

---

## See Also

- [Store API](./store-api.md) — Persistent state operations
- [Presence API](./presence-api.md) — Ephemeral user awareness
- [Error Handling](./error-handling.md) — Error types and retry behavior
- [Wire Protocol](../implementation/wire-protocol.md) — Full wire-level connection lifecycle
