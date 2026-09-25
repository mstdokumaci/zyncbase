# Actions API Reference

The Actions API enables backend-enforced business logic and high-frequency ephemeral streaming. Actions route schema-validated messages from clients to backend workers without polluting SQLite storage or leaking commands to peer clients via presence.

Actions are defined declaratively in `schema.json`. Whether an action is executed synchronously (as an RPC call) or asynchronously (as a fire-and-forget stream) is determined by its schema declaration: actions with a `returns` definition are synchronous; actions where `returns` is `null` or omitted are asynchronous. Each action is bound to the `store` or `presence` namespace scope (default `store`).

---

## Table of Contents

1. [Schema Definition](#schema-definition)
2. [Execution Tiers: Inherent Sync vs. Async](#execution-tiers-inherent-sync-vs-async)
3. [Namespace Scope](#namespace-scope)
4. [Client API (`client.actions.call`)](#client-api-clientactionscall)
5. [Backend Worker API (`server.actions.handle`)](#backend-worker-api-serveractionshandle)
6. [Action Context (`ActionContext`)](#action-context-actioncontext)
7. [Authorization](#authorization)
8. [Error Handling & Timeouts](#error-handling--timeouts)
9. [Framework Integration (React)](#framework-integration-react)
10. [Limits](#limits)
11. [Wire Protocol Mapping](#wire-protocol-mapping)

---

## Schema Definition

Actions are defined under the top-level `"actions"` key in `schema.json`, parallel to `store` and `presence`:

```json
{
  "version": "1.0.0",
  "store": { ... },
  "presence": { ... },
  "actions": {
    "player_move": {
      "params": {
        "direction": { "type": "string", "enum": ["up", "down", "left", "right"] },
        "seq": { "type": "integer", "minimum": 0 }
      },
      "required": ["direction"],
      "returns": null,
      "scope": "presence"
    },
    "checkout": {
      "params": {
        "cart_id": { "type": "string", "minLength": 1 }
      },
      "required": ["cart_id"],
      "returns": {
        "order_id": { "type": "string" },
        "remaining_coins": { "type": "integer", "minimum": 0 }
      }
    }
  }
}
```

### Field Constraints

- `params` and `returns` use the standard field grammar: primitives with `type` plus validation constraints (`minimum`, `maximum`, `enum`, `pattern`, `minLength`, `maxLength`), arrays with `items`, and nested objects with `fields` (flattened with `__`). Store-only properties (`indexed`, `references`, `onDelete`, `unique`, `metadata`) are rejected.
- `required` is an action-level array of param paths using dot notation. Every declared `returns` field must be present in a successful reply.
- `scope` selects the namespace scope: `"store"` (default) or `"presence"`. See [Namespace Scope](#namespace-scope).
- Input validation runs inside the Zig engine before forwarding to workers. Payloads violating constraints are rejected immediately with `SCHEMA_VALIDATION_FAILED`.
- Output validation runs when the worker replies. Invalid worker return payloads are rejected before delivery to the client with `SCHEMA_VALIDATION_FAILED`.
- Schema errors (unknown keys, invalid constraints, too many flat fields) fail server startup.

---

## Execution Tiers: Inherent Sync vs. Async

An action's operational mode is determined directly by the presence or absence of the `returns` object in `schema.json`:

| Feature | Async Action (`returns: null`) | Sync Action (`returns: { ... }`) |
| :--- | :--- | :--- |
| **Primary Use Case** | Ephemeral inputs (joystick, movement, telemetry) | Backend-enforced operations (purchases, RPC) |
| **Storage Impact** | Zero (In-memory only, no SQLite I/O) | Zero (Worker may choose to mutate store) |
| **Acknowledgment** | Accepted on forward-path admission (`0x00 OK`) | Awaits worker response and returns data |
| **Client Return Type** | `Promise<void>` | `Promise<TOutput>` |
| **Delivery** | At-most-once: no persistence, no redelivery, no failure report | Exactly one reply per call, or a typed failure |
| **Routing** | Round-robin to registered workers in the bound scope | Round-robin to registered workers in the bound scope |
| **Peer Visibility** | Private (Delivered to worker only) | Private (Delivered to caller only) |

> [!IMPORTANT]
> Sync actions are **orchestration, not transaction management**. The engine provides no atomic increment or compare-and-set, reads and writes inside a handler are ordinary store operations subject to last-write-wins, and a returned value is a claim — not committed state. Use `confirm: "committed"` for store writes whose outcome matters, guard invariants with schema constraints, and never auto-retry a call whose first attempt may have executed.

---

## Namespace Scope

Actions reuse the existing store and presence scopes; there is no separate action namespace.

- An action's `scope` (default `"store"`) selects which scope resolves its namespace and user identity.
- Calls and registrations require the bound scope to be ready. Before readiness they fail with `SESSION_NOT_READY`.
- Namespace admission uses the bound scope's existing rules: `storeFilter` for store-scoped actions, `presenceRead` for presence-scoped actions.
- Switching the bound scope's namespace clears that connection's registrations for the scope, mirroring subscription invalidation. Workers must re-register after a switch.
- The SDK selects the bound scope per action from the `SchemaSync` dictionaries.

```typescript
const client = createClient({
  url: 'ws://localhost:4000',
  auth: { token },
  storeNamespace: 'room:1',
  presenceNamespace: 'room:1:document:lobby',
})
```

---

## Client API (`client.actions.call`)

Clients invoke actions through `client.actions.call(name, params, options?)`.

```typescript
// 1. Invoking an Asynchronous Action (e.g., game loop movement)
// Resolves immediately upon server forward-path admission (Promise<void>)
await client.actions.call('player_move', {
  direction: 'up',
  seq: 42,
});

// 2. Invoking a Synchronous Action (e.g., checkout)
// Awaits worker response and returns typed output (Promise<TOutput>)
const result = await client.actions.call('checkout', {
  cart_id: 'cart_123',
});

console.log(result.order_id, result.remaining_coins);
```

### Options (`ActionCallOptions`)

```typescript
interface ActionCallOptions {
  /**
   * Upper bound (in ms) on how long the server may wait for a sync action reply.
   * Defaults to 10000ms on the server. A smaller value only shortens the deadline.
   */
  timeoutMs?: number;
}
```

Example with a shortened timeout:

```typescript
try {
  const result = await client.actions.call('checkout', { cart_id: 'c1' }, {
    timeoutMs: 5000,
  });
} catch (err) {
  if (err.code === 'ACTION_TIMEOUT') {
    console.error('Checkout took too long');
  }
}
```

Client-side cancellation is not supported in this version. A pending sync call settles when the worker replies, the server deadline expires (`ACTION_TIMEOUT`), the worker disconnects (`WORKER_DISCONNECTED`), the bound scope changes (`REQUEST_SUPERSEDED`), or the connection drops (`CONNECTION_FAILED`).

---

## Backend Worker API (`server.actions.handle`)

A worker is a client that handles actions. A backend service becomes a worker by connecting like any other client and satisfying the action's `register` authorization rule; the server then forwards that action's calls to it. Any client whose session passes the rule can be a worker. Workers handle actions using `server.actions.handle(name, handler)`.

> [!IMPORTANT]
> **Granting `register` is a trust decision.** A worker receives raw action params and replies on the action's behalf. Run workers as trusted backend service processes with service identities, deployed alongside your infrastructure, and keep `register` rules narrow (for example, a dedicated service claim).

Calling `server.actions.handle()` registers the handler locally and sends `ActionRegister` to the server. Registration requires the connection to be established with the action's bound scope ready; calling `handle()` before that throws `SESSION_NOT_READY`.

```typescript
import { createClient } from '@zyncbase/client';

const server = createClient({
  url: 'ws://localhost:4000',
  auth: { token: process.env.ZYNCBASE_SERVICE_KEY },
  storeNamespace: 'room:1',
  presenceNamespace: 'room:1:document:lobby',
});

await server.connect();

// Async Action Handler (no return value required)
server.actions.handle('player_move', async (ctx, params) => {
  world.queueInput(ctx.userId, params.direction, params.seq);
});

// Sync Action Handler (must return an object matching the schema's returns definition)
server.actions.handle('checkout', async (ctx, params) => {
  const user = await server.store.get(['users', ctx.userId]);
  if (user.coins < 100) {
    throw new ActionError('INSUFFICIENT_FUNDS', 'Balance is too low');
  }

  // Confirmed so the reply only claims state that committed.
  await server.store.batch([
    { op: 'set', path: ['users', ctx.userId], value: { coins: user.coins - 100 } },
  ], { confirm: 'committed' });

  return {
    order_id: server.utils.id(),
    remaining_coins: user.coins - 100,
  };
});
```

### Registration Lifecycle

- Registrations are per-connection and removed on disconnect.
- When a worker's token is refreshed, `register` is re-evaluated against the new `$session`; registrations that no longer pass are removed and the worker's in-flight sync calls fail with `PERMISSION_DENIED` (the handler may already have executed).
- The SDK re-registers handlers automatically after reconnect.
- A namespace switch on the action's bound scope invalidates that scope's registrations; the SDK re-registers when the new scope is ready.
- Round-robin provides no sticky routing: handlers must be stateless across invocations or share state explicitly.

> [!WARNING]
> The `checkout` pattern above is read-modify-write and remains subject to last-write-wins: two concurrent handlers can read the same balance and lose a decrement. Do not model atomic counters this way. Prefer schema constraints (unique indexes, required fields) for invariants, or serialize through a single worker/namespace design.

---

## Action Context (`ActionContext`)

Every worker handler receives an `ActionContext` containing verified request metadata injected by the Zig server:

```typescript
interface ActionContext {
  /** Canonical UUIDv7 string of the authenticated user resolved by the action's bound scope. */
  readonly userId: string;
  /** Active namespace of the action's bound scope. */
  readonly namespace: string;
  /**
   * Server-assigned execution id for this invocation. Matches the `execId`
   * carried by `ActionForward` and echoed by `ActionReply`.
   */
  readonly execId: number;
}
```

Worker-side cancellation is not part of this version: a caller timeout or disconnect does not stop a running handler. Handlers must assume they may run to completion even when the caller stopped waiting.

---

## Authorization

Action rules live in `authorization.json` in a top-level `"actions"` array parallel to `"store"`:

```json
{
  "namespaces": [ ... ],
  "store": [ ... ],
  "actions": [
    {
      "action": "checkout",
      "invoke": { "$session.role": { "eq": "member" } },
      "register": { "$session.role": { "eq": "worker" } }
    },
    {
      "action": "player_move",
      "invoke": true,
      "register": { "$session.role": { "eq": "game_server" } }
    },
    { "action": "*", "invoke": false, "register": false }
  ]
}
```

| Key | Controls |
|---|---|
| `action` | Action name, or `*` for a catch-all fallback rule. |
| `invoke` | Who may call the action. Evaluated against `$session`, `$namespace`, and `$value` (the params payload) before the call is accepted. |
| `register` | Who may register a handler for the action via `ActionRegister`. |

- Rules are fail-closed. When `authorization.json` is omitted, the playground defaults allow `invoke` on `"*"` and deny `register`; running a worker requires explicit authorization rules.
- Denials return `PERMISSION_DENIED`.
- A "worker role" is a mapped `$session` claim (see `authentication.session.claims`); there is no separate role system.

---

## Error Handling & Timeouts

### Error Classes

| Class | Public Error Code | Category | Cause |
| :--- | :--- | :--- | :--- |
| `NoActionWorkerError` | `NO_ACTION_WORKER` | `state` | No connected worker is registered for this action in the bound namespace. |
| `ActionTimeoutError` | `ACTION_TIMEOUT` | `server` | Worker failed to reply before the server deadline. The action may still execute. |
| `WorkerDisconnectedError` | `WORKER_DISCONNECTED` | `server` | Worker disconnected while processing a sync action. The action may have partially executed. |
| `ActionValidationError` | `SCHEMA_VALIDATION_FAILED` | `validation` | Input params or worker return payload violated schema constraints. |
| `ActionExecutionError` | Custom (e.g. `INSUFFICIENT_FUNDS`) | `server` | Worker threw an application-level `ActionError`. |
| — | `PERMISSION_DENIED` | `authorization` | The `invoke` rule denied the call. |

### Timeout Semantics

- The server owns the deadline: 10000ms default; `timeoutMs` may only shorten it.
- On expiry the caller rejects with `ACTION_TIMEOUT` and the pending entry is removed. The worker may still be executing — timeout means "no response received", not "not executed".
- The SDK-local `TIMEOUT` applies only when the transport stalls before any server response arrives.
- **The SDK never auto-retries action calls**, regardless of error category: a retried call may execute twice. Retry policy is an application decision.

### Raising Worker Errors

Workers throw `ActionError` to send structured, typed errors back to the caller:

```typescript
throw new ActionError('INSUFFICIENT_FUNDS', 'User does not have enough coins');
```

The client catches this as an `ActionExecutionError`:

```typescript
try {
  await client.actions.call('checkout', { cart_id: 'c1' });
} catch (err) {
  if (err instanceof ActionExecutionError) {
    console.error(err.code);    // "INSUFFICIENT_FUNDS"
    console.error(err.message); // "User does not have enough coins"
  }
}
```

An unhandled handler exception surfaces to the caller as `INTERNAL_ERROR`. A worker return payload that fails schema validation rejects the call with `SCHEMA_VALIDATION_FAILED`.

---

## Framework Integration (React)

The `@zyncbase/react` package provides a unified `useAction` hook for both synchronous and asynchronous actions, following the same `{ data, loading, error }` convention as the other hooks:

```tsx
import { useAction } from '@zyncbase/react';

// 1. Asynchronous Action (e.g. high-frequency game input)
function DirectionPad() {
  const { execute: move } = useAction('player_move');

  return (
    <button onClick={() => move({ direction: 'up', seq: 1 })}>
      Up
    </button>
  );
}

// 2. Synchronous Action (e.g. backend-enforced checkout)
function CheckoutButton({ cartId }: { cartId: string }) {
  const { execute: checkout, loading, error, data } = useAction('checkout');

  return (
    <div>
      <button disabled={loading} onClick={() => checkout({ cart_id: cartId })}>
        {loading ? 'Processing...' : 'Pay Now'}
      </button>
      {error && <p className="error">{error.message}</p>}
      {data && <p className="success">Order #{data.order_id} confirmed!</p>}
    </div>
  );
}
```

- `execute` always returns the call's own promise. Async actions resolve to `void`; sync actions resolve to the typed output and also populate `data`.
- `loading` and `error` reflect the most recent `execute` call; concurrent calls do not cancel each other.
- Errors are `ZyncBaseError` instances and are never auto-retried.

---

## Limits

- Every action message is subject to the per-connection rate limit (`security.maxMessagesPerSecond`), like all other messages. Sustained high-frequency streams must stay within it.
- `maxMessageSize` applies to encoded params and returns.
- Async actions are at-most-once: no persistence, no redelivery, no failure feedback.
- Each `params` and `returns` schema supports up to 500 flat fields.
