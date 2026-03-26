# Error Handling

How the SDK surfaces errors to developers: the `ZyncBaseError` interface, propagation model, auto-retry behavior, and optimistic revert semantics.

> [!NOTE]
> This document defines the SDK consumer contract. For the full internal error catalog and server-side retry implementation, see [Error Taxonomy](../implementation/error-taxonomy.md).

---

## Table of Contents

1. [The ZyncBaseError Object](#the-zyncbaseerror-object)
2. [Error Propagation](#error-propagation)
3. [Common Error Codes](#common-error-codes)
4. [Optimistic Revert Behavior](#optimistic-revert-behavior)
5. [Auto-Retry Summary](#auto-retry-summary)

---

## The ZyncBaseError Object

All errors surfaced to SDK consumers use a consistent typed object:

```typescript
interface ZyncBaseError extends Error {
  code: string;                          // Machine-readable code (e.g., 'RATE_LIMITED')
  category: string;                      // Functional category for grouping
  retryable: boolean;                    // Whether the SDK can/will auto-retry
  retryAfter?: number;                   // ms to wait before retry (server-provided)
  requestId?: number;                    // ID of the failed request
  path?: string[];                       // Affected data path, if applicable
  details?: Record<string, string[]>;    // Field-level validation errors
}
```

---

## Error Propagation

Errors reach the developer through two channels:

### 1. `try/catch` on async methods

Methods that return a `Promise` (e.g., `connect()`, `query()`, `batch()`) throw `ZyncBaseError` directly:

```typescript
try {
  await client.connect()
} catch (error: ZyncBaseError) {
  if (error.code === 'AUTH_FAILED') {
    // Handle authentication error
  }
}
```

### 2. `client.on('error', ...)` for fire-and-forget writes

`store.set()` and `store.remove()` are optimistic and return `void` (not a Promise). If the server rejects the write, the error is emitted via the global error event:

```typescript
client.on('error', (error: ZyncBaseError) => {
  // error.path contains the affected data path
  // Optimistic state has already been reverted by the SDK
  console.error(`Write failed at ${error.path?.join('.')}:`, error.message)
})
```

### 3. Async NACKs (Late-arriving errors)

For high-throughput writes where the server returns `ok` immediately after queueing, the server may send a later error if background persistence fails (e.g., `DATABASE_BUSY`). The SDK must:
1. Match the error's `requestId` to the original write
2. Revert the optimistic state for that write
3. Surface the error via `client.on('error', ...)`

### 4. Framework hooks

Framework integrations (React/Vue) populate an `error` field in the hook return value:

```typescript
const { data, error } = useStore('tasks.123')
if (error) { /* render error state */ }
```

---

## Common Error Codes

Error codes relevant to SDK consumers, grouped by category:

### Authentication & Authorization

| Code | Description | Auto-retry? |
|------|-------------|-------------|
| `AUTH_FAILED` | Invalid ticket or expired initial JWT | No — get new token |
| `TOKEN_EXPIRED` | Session expired; fires `tokenExpired` event | Partial — refresh token |
| `NAMESPACE_UNAUTHORIZED` | Not authorized to access this namespace | No |
| `PERMISSION_DENIED` | Rule blocked the operation (via `authorization.json` or Hook Server) | No |
| `COLLECTION_NOT_FOUND` | Path refers to a collection not defined in the schema | No — fix path |

### Validation

| Code | Description | Auto-retry? |
|------|-------------|-------------|
| `SCHEMA_VALIDATION_FAILED` | Data does not match schema definition | No — fix data |
| `FIELD_NOT_FOUND` | Field name not defined in schema | No — fix path or data |
| `INVALID_FIELD_NAME` | Field name contains forbidden `__` sequence | No |
| `INVALID_ARRAY_ELEMENT` | Array contains non-literal value (e.g., nested object) | No — fix data |
| `INVALID_MESSAGE` | Malformed message or missing `type` field | No |

### Rate Limiting

| Code | Description | Auto-retry? |
|------|-------------|-------------|
| `RATE_LIMITED` | Message frequency exceeded | Yes — exponential backoff, respects `retryAfter` |
| `MESSAGE_TOO_LARGE` | Payload exceeds `maxMessageSize` | No — reduce payload |

### Connection & Server

| Code | Description | Auto-retry? |
|------|-------------|-------------|
| `CONNECTION_FAILED` | Transport failure (WebSocket closed) | Yes — reconnect |
| `TIMEOUT` | Operation timed out | Yes — retry with backoff |
| `INTERNAL_ERROR` | Unexpected server failure | Yes — retry up to 3 times |

### Hook Server

| Code | Description | Auto-retry? |
|------|-------------|-------------|
| `HOOK_SERVER_UNAVAILABLE` | Zig cannot reach the Bun Hook Server | No |
| `HOOK_DENIED` | Developer's hook explicitly rejected the operation | No |

---

## Optimistic Revert Behavior

`store.set()` and `store.remove()` apply changes to local state immediately (optimistic update). If the server rejects the write:

1. The SDK **automatically reverts** the local state to its pre-write value
2. The error is emitted via `client.on('error', ...)`
3. Any active subscriptions fire with the reverted state

This applies to both immediate error responses and [async NACKs](#3-async-nacks-late-arriving-errors).

---

## Auto-Retry Summary

| Error Category | Auto-Retry | Max Attempts | Strategy |
|----------------|------------|--------------|----------|
| Connection | ✅ Yes | Infinite | Exponential backoff (see [Reconnection](./connection-management.md#reconnection-strategy)) |
| Rate-Limit | ✅ Yes (opt-out) | Infinite | Respect `retryAfter`, else backoff |
| Server | ✅ Yes | 3 | Exponential backoff |
| Authentication | ⚠️ Partial | 1 | Fire `tokenExpired`; wait for refresh |
| Authorization | ❌ No | 0 | Surface immediately |
| Validation | ❌ No | 0 | Surface immediately |
| Hook Server | ❌ No | 0 | Surface immediately |

---

## See Also

- [Connection Management](./connection-management.md) — Client lifecycle and events
- [Store API](./store-api.md) — Optimistic write methods
- [Error Taxonomy](../implementation/error-taxonomy.md) — Full internal error catalog and retry implementations
- [Wire Protocol](../implementation/wire-protocol.md#error-format) — Error envelope wire format
