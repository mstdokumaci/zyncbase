# Connection Management

SDK client lifecycle: creating clients, connecting, namespace switching, reconnection, and event handling.

---

## Table of Contents

1. [Creating a Client](#creating-a-client)
2. [Connection Lifecycle](#connection-lifecycle)
3. [Liveness Detection](#liveness-detection)
4. [Recovery Complete](#recovery-complete)
5. [Namespace Switching](#namespace-switching)
6. [Event Listeners](#event-listeners)
7. [Reconnection Strategy](#reconnection-strategy)
8. [Token Refresh](#token-refresh)

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
  reconnectJitter: true,
  liveness: { enabled: true, intervalMs: 15000, timeoutMs: 10000 }
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
| `liveness.enabled` | boolean | `true` | Probe a silent connection to detect a broken path that never delivered a close |
| `liveness.intervalMs` | number | `15000` | Silence after which a probe is sent, measured from the last frame received from the server. A local send does not reset it |
| `liveness.timeoutMs` | number | `10000` | Wait for the probe's `ok` before declaring the connection dead |

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
3. **`SchemaSync` push** — the server sends a `SchemaSync` message with table and field arrays; the SDK builds its integer routing dictionary from this payload (per ADR-009)
4. **Scope resolution** — the SDK sends initial store/presence namespace selections; the server resolves each namespace and internal `users.id`

The SDK waits for WebSocket open, `SchemaSync`, and the initial required namespace acknowledgements before resolving the `connect()` promise. Presence scope acknowledgement installs the canonical internal user UUID before the `connected` lifecycle event replays subscriptions.

```typescript
await client.connect()
// Required store and presence scopes are ready.
```

This promise resolves at `connected`, when the transport is up and the required scopes are resolved. It does **not** mean subscriptions and action registrations have been replayed — that completes later, at `synced`. Register a `synced` handler before calling `connect()` if you need to react to a fully restored client; see [Recovery Complete](#recovery-complete).

**Returns:** `Promise<void>`  
**Throws:** `ZyncBaseError` with code `AUTH_FAILED` or `CONNECTION_FAILED`

### `client.disconnect()`

Gracefully closes the connection. Automatically clears presence in the active namespace. Emits `disconnected` with code `CLIENT_DISCONNECT` and stops the reconnect loop; pending requests are rejected as non-retryable.

```typescript
client.disconnect()
```

> [!NOTE]
> For full wire-level details of the connection lifecycle (ticket format, scope acknowledgements, liveness probing, close codes, graceful close), see the [Wire Protocol](../implementation/wire-protocol.md#liveness-probing).

---

## Liveness Detection

A connection can be **closed** or merely **broken**. A closed one receives a FIN or RST and reaches a terminal state. A broken one — a NAT timeout, a dropped mobile network, a server that died — stays `OPEN` at the socket layer while carrying nothing, because a send on a dead path buffers locally and resolves. No client-side signal distinguishes them: `readyState` says `OPEN`, sends succeed, and outstanding promises never settle.

The SDK closes that gap on a timer. It tracks the last frame received from the server. After `liveness.intervalMs` of silence it sends a `Ping` and starts a `liveness.timeoutMs` deadline; any frame arriving in that window proves liveness and cancels the probe. On expiry the SDK closes the socket and enters the ordinary reconnect path, so recovery is identical whether the connection was closed or broken and no application needs a second branch for the silent case.

Two properties keep it free:

- **An active connection is never probed.** A client receiving deltas is already demonstrably alive, so the probe is suppressed. Liveness traffic exists only for idle connections.
- **Client and server liveness are independent.** These options are client-side and have no relationship to the server's idle timeout, which is a much longer dead-peer reaper. Tuning one does not tune the other.

The probe is a correlated request answered with `ok`, and is never retried — a retry would mask a dead connection behind its own backoff. It is subject to the same per-connection rate limit as any other client message.

Applications do not implement a keepalive on top of this. A *domain* liveness need — expiring a user who stops sending, re-admitting a participant whose tab slept — is application policy built on these signals, not a substitute for them.

---

## Recovery Complete

Restoring a client is not one event. The transport comes up, then the required scopes resolve, and only then can the SDK replay the subscriptions and action registrations the application asked for. A single event at the first step leaves every application racing its own SDK.

The SDK therefore emits three ordered events:

| Event | Fires when |
|-------|-----------|
| `connected` | The WebSocket is open and the initial required store and presence scopes are resolved. |
| `reconnected` | The same, but a connection existed earlier in this process. Does not fire on a first connect. |
| `synced` | Store subscriptions, presence subscriptions, and action registrations have all been replayed. The client is fully restored. |

**`synced` is the only point at which it is safe to issue requests.** It fires on every successful recovery, including a first connect, so an application writes one handler rather than branching on cold versus warm:

```typescript
client.on('synced', () => {
  // Subscriptions are live and registrations are advertised.
})
```

Anything issued before `synced` — from a `connected` handler, or after a drop while the SDK is still replaying — reaches a connection whose subscriptions are not yet restored, and is dropped rather than queued. Applications that must survive a gap do their setup in `synced` and treat a connection failure as retryable from the last confirmed point.

`reconnected` exists for where the two must differ: an application resuming an interrupted workflow resets state there, while one wanting a clean slate resets on `connected`. Without it, every application guesses with its own flag.

---

## Namespace Switching

### `client.setStoreNamespace(namespace)`

Switch the active store namespace at runtime. The returned promise resolves after the server resolves both the namespace ID and store-scoped internal user ID. Active store subscriptions are invalidated — the client must re-subscribe.

```typescript
await client.setStoreNamespace('tenant:acme:workspace:ws-2')
```

**Parameters:** `namespace` (string)  
**Returns:** `Promise<void>`  
**Throws:** `ZyncBaseError` with code `NAMESPACE_UNAUTHORIZED` if not permitted, or `NAMESPACE_SWITCH_REJECTED` if `users.namespaced` is enabled

### `client.setPresenceNamespace(namespace)`

Switch the active presence namespace. The returned promise resolves after the server resolves both the namespace ID and presence-scoped internal user ID. Automatically clears your presence in the old namespace and joins the new one.

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

client.on('synced', () => {
  // Subscriptions and registrations are restored. Safe to use the client.
})

client.on('disconnected', (detail) => {
  console.log('Disconnected:', detail.code, '—', detail.reason)
})

client.on('reconnecting', (attempt, delayMs) => {
  console.log(`Reconnecting (attempt ${attempt} in ${delayMs}ms)`)
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
| `connected` | `() => void` | WebSocket established and initial required scopes are ready |
| `reconnected` | `() => void` | The same, after a previous connection in this process. Does not fire on a first connect |
| `synced` | `() => void` | Subscriptions and action registrations fully replayed; the client is safe to use |
| `disconnected` | `(detail: DisconnectDetail) => void` | Connection closed. `detail` says why and whether reconnecting is worthwhile |
| `reconnecting` | `(attempt: number, delayMs: number) => void` | Attempting to reconnect after unexpected disconnect |
| `error` | `(error: ZyncBaseError) => void` | Connection, subscription, systemic writer/storage, or tracked write error |
| `tokenExpired` | `() => void` | Session token expired. Emitted while the connection is still open, so the token can be refreshed in place. Rejects no pending request |
| `statusChange` | `(status, detail) => void` | Fired on any state transition (see below) |

### `disconnected` Detail

A connection can end for reasons that demand opposite responses — refresh a token, back off, or give up — so the reason is data rather than a bare notification.

```typescript
client.on('disconnected', (detail) => {
  // detail.code:      'AUTH_FAILED' | 'TOKEN_EXPIRED' | 'SERVER_SHUTDOWN'
  //                  | 'IDLE_TIMEOUT' | 'BACKPRESSURE_LIMIT' | 'MAX_CONNECTIONS'
  //                  | 'CLIENT_DISCONNECT' | 'RETRIES_EXHAUSTED' | 'CONNECTION_FAILED'
  // detail.reason:    human-readable text from the server, when it sent one
  // detail.category:  ZyncBaseError category, for existing retry logic
  // detail.retryable: whether reconnecting can succeed without changes
  // detail.attempt:   reconnect attempts made before giving up
})
```

`code` is always set. `CLIENT_DISCONNECT` and `RETRIES_EXHAUSTED` are both non-retryable, since neither is a condition reconnecting can fix. Server-originated codes and their close-code equivalents are defined in [Error Taxonomy → Disconnect Codes](../implementation/error-taxonomy.md#disconnect-codes).

Two behaviors follow from `retryable`, and replace matching on error text:

- **`retryable: false`** — reconnecting fails until something changes. `AUTH_FAILED` is terminal: nothing the SDK can do succeeds, so it stops the retry loop and surfaces the failure. `TOKEN_EXPIRED` is recoverable: the SDK stops the retry loop but, with `auth.tokenProvider` configured, obtains a new token and continues on the same connection; otherwise it emits `tokenExpired` and waits for the application.
- **`retryable: true`** — the SDK reconnects on the normal backoff and the application does nothing.

`disconnected` fires for a client-initiated `disconnect()` and after retries are exhausted as well, so teardown handlers are registered once instead of per exit path.

### `statusChange` Detail

```typescript
client.on('statusChange', (status, detail) => {
  // status: 'connecting' | 'scoping' | 'connected' | 'reconnecting' | 'disconnected'
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

The SDK should continue retrying up to `maxReconnectAttempts`. If exhausted, emit `disconnected` with code `RETRIES_EXHAUSTED` and stop.

Each attempt that reaches a fully restored client emits `connected`/`reconnected` and then `synced`; an attempt that fails during the handshake emits no `synced`, and the next begins from nothing. Reconnect attempts are also subject to [Liveness Detection](#liveness-detection) — a connection that stops responding fails its probe and restarts the backoff schedule rather than counting as healthy.

---

## Token Refresh

### `client.authRefresh(token)`

Update the connection's session with a new external JWT without disconnecting. The server re-validates the new JWT and updates the session claims and token expiry in-place. Active store and presence scopes continue without interruption.

`tokenExpired` is emitted **before** the connection closes, so `authRefresh()` is sent on a live socket and the refresh completes without a reconnect. The window is bounded by the server's configured [`session.tokenGracePeriodSeconds`](./configuration.md), and the close follows only when no replacement arrives within it — no `auth.tokenProvider` is configured, the provider rejects, the server rejects the refreshed token, or the window times out. An application supplying tokens itself therefore has until the window closes to call `authRefresh()`; once `disconnected` has fired the socket is gone and reconnecting with a fresh ticket via `connect()` is the only remaining option.

If the new JWT is invalid, the server sends `ServerDisconnect` with code `AUTH_FAILED`, closes with code `4001`, and the SDK emits `disconnected` with `retryable: false`. A failed `AuthRefresh` is terminal for the connection — the SDK does not reconnect, because the credentials it would present are the ones the server just rejected.

```typescript
client.on('tokenExpired', async () => {
  const newToken = await myAuthService.refresh()
  await client.authRefresh(newToken)
})
```

**Parameters:** `token` (string) — new external JWT  
**Returns:** `Promise<void>`

Under the hood, this sends an `AuthRefresh` wire message. See [Wire Protocol → Client Messages](../implementation/wire-protocol.md#client-messages) for details.

---

## Related Specifications

- [Store API](./store-api.md) — Persistent state operations
- [Presence API](./presence-api.md) — Ephemeral user awareness
- [Error Handling](./error-handling.md) — Error types and retry behavior
- [Wire Protocol](../implementation/wire-protocol.md) — Full wire-level connection lifecycle
