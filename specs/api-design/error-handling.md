# Error Handling

How the SDK surfaces errors to developers: the `ZyncBaseError` interface, propagation model, write failure reporting, and auto-retry behavior.

> [!NOTE]
> This document defines the SDK consumer contract.

---

## Table of Contents

1. [The ZyncBaseError Object](#the-zyncbaseerror-object)
2. [Error Propagation](#error-propagation)
3. [Write Failure Reporting](#write-failure-reporting)
4. [Auto-Retry Summary](#auto-retry-summary)

---

## The ZyncBaseError Object

All errors surfaced to SDK consumers use a consistent typed object:

```typescript
interface ZyncBaseError extends Error {
  code: string;                          // Machine-readable code (e.g., 'RATE_LIMITED')
  retryable: boolean;                    // Whether the SDK can/will auto-retry
  retryAfter?: number;                   // ms to wait before retry (server-provided)
  requestId?: number;                    // ID of the failed immediate request
  writeId?: string;                      // ID of a tracked or confirmed write, if applicable
  path?: string[];                       // Affected data path, if applicable
  details?: {
    phase?: 'accept' | 'write';           // Request acceptance or writer-thread outcome
    batchIndex?: number;                  // Failed batch operation, when known
    [key: string]: unknown;
  };
}
```

---

## Error Propagation

Errors reach the developer through two channels:

### 1. `try/catch` on async methods

Methods that return a `Promise` throw `ZyncBaseError` directly:

```typescript
try {
  await client.connect()
} catch (error: ZyncBaseError) {
  if (error.code === 'AUTH_FAILED') {
    // Handle authentication error
  }
}
```

Mutation promises use two phases:

- `phase: "accept"`: the server rejected the request before the writer owned it.
- `phase: "write"`: the writer reported a failure for a confirmed write.

Default mutations use `confirm: "accepted"` and resolve after request acceptance. They do not optimistically update local subscription state and do not receive guaranteed per-operation async error delivery after acceptance.

```typescript
try {
  await client.store.set('tasks.t1.status', 'done', { confirm: 'committed' })
} catch (error: ZyncBaseError) {
  if (error.details?.phase === 'write') {
    // Writer-thread failure for this confirmed write
  }
}
```

### 2. `client.on('error', ...)` for connection and systemic errors

The global error event surfaces connection-level errors, systemic writer/storage failures, and tracked write errors that are not attached to a currently awaited confirmed mutation:

```typescript
client.on('error', (error: ZyncBaseError) => {
  console.error(error.code, error.message)
})
```

### 3. WriteError events

Asynchronous writer failures are `WriteError`s, not rollback NACKs. They use `writeId` to correlate with tracked or confirmed writes.

`WriteError` is used for user feedback and diagnostics. It does not imply local rollback because the SDK does not apply speculative local subscription updates.

### 4. Framework hooks

Framework integrations (React/Vue) populate an `error` field in the hook return value:

```typescript
const { data, error } = useStore('tasks.123')
if (error) { /* render error state */ }
```

---

## Write Failure Reporting

ZyncBase separates state delivery from write outcome reporting:

1. Subscription callbacks are the authoritative channel for committed observable state.
2. Default accepted writes do not receive guaranteed per-operation async error delivery after acceptance.
3. Confirmed writes reject their promise when the writer reports failure.
4. Tracked write errors use `writeId` and may include best-effort `path` metadata.
5. Batch write errors include `details.batchIndex` when the failing operation is known.

Confirmed write timeouts mean confirmation was not received. They do not imply the write was aborted or failed to commit. After reconnect, subscriptions remain the source of truth for final state.

---

## Auto-Retry Summary

Per-category retry behavior and the canonical error code catalog live in [Error Taxonomy](../implementation/error-taxonomy.md). Reconnection backoff and attempt limits live in [Connection Management](./connection-management.md#reconnection-strategy).

---

## Related Specifications

- [Connection Management](./connection-management.md) — Client lifecycle and events
- [Store API](./store-api.md) — Accepted/committed mutation methods
- [Error Taxonomy](../implementation/error-taxonomy.md) — Canonical public error code catalog and retry behavior
