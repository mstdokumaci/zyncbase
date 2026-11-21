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
  retryable: boolean;                    // Whether the SDK's retry/reconnect policy treats this error class as retryable; not whether replaying the operation is safe
  retryAfter?: number;                   // ms to wait before retry (server-provided)
  requestId?: number;                    // ID of the failed request, if known
  path?: string[];                       // Affected data path, if applicable
  details?: {
    phase?: 'accept' | 'write';           // Request acceptance or writer-thread outcome
    batchIndex?: number;                  // Failed batch operation, when known
    [key: string]: unknown;
  };
}
```

`retryable` describes the SDK's automatic retry and reconnect policy, not the failed operation. A `true` value does not mean the SDK will retry this call, and a `false` value does not forbid a manual retry. Store writes are never automatically retried, regardless of `retryable`. A write `TIMEOUT` leaves the outcome ambiguous: the write may still commit, and a manual retry may apply it twice.

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

Mutation promises resolve when the write commits. When the server reports a rejection, it carries one of two phases:

- `phase: "accept"`: the server rejected the request before the writer owned it.
- `phase: "write"`: the writer rejected the write.

`TIMEOUT` and connection failures reject without a `details.phase` because no server outcome arrived. They are ambiguous: they do not establish that the write was refused or rejected, or that it failed to commit. See [Write Failure Reporting](#write-failure-reporting).

```typescript
try {
  await client.store.set('tasks.t1.status', 'done')
} catch (error: ZyncBaseError) {
  if (error.details?.phase === 'write') {
    // The writer rejected this write
  }
}
```

### 2. `client.on('error', ...)` for connection and systemic errors

The global error event surfaces connection-level errors and every store operation failure, including failures of writes nobody awaits:

```typescript
client.on('error', (error: ZyncBaseError) => {
  console.error(error.code, error.message)
})
```

### 3. WriteError messages

Writer failures arrive as `WriteError`s. They carry the write's request id, and the SDK rejects that write's promise with them.

A write the SDK showed optimistically reverts when it fails, whatever the failure: an accept-phase `error`, a `WriteError`, a timeout, or a disconnect. The SDK removes only that write's overlay, then recomputes the displayed value from committed state plus any remaining pending writes; earlier or later pending writes to the same document stay visible. The value returns to committed state only when no pending write remains. Subscriptions and listens deliver the recomputed value again before the promise rejects. `WriteError` is used for user feedback and diagnostics.

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
2. Every write rejects its promise when the server refuses it or the writer rejects it.
3. Batch write errors include `details.batchIndex` when the failing operation is known.
4. `PRECONDITION_FAILED` means the write did not apply: a conditional `if` did not hold, the row was missing, or an increment was NULL, out of range, or would overflow. No subscription delta is emitted. The application may retry after re-reading; the SDK never auto-retries a write.
5. Increments are not idempotent. A manual retry after an ambiguous connection failure or timeout may apply twice; there is no write dedupe.

A write that gets no outcome within `writeTimeoutMs` (default 30 s) rejects with `TIMEOUT`. A timeout or a disconnect does not imply the write was aborted or failed to commit: its optimistic value reverts, and if it committed, the delta brings it back. After reconnect, subscriptions remain the source of truth for final state.

---

## Auto-Retry Summary

Per-category retry behavior and the canonical error code catalog live in [Error Taxonomy](../implementation/error-taxonomy.md). Reconnection backoff and attempt limits live in [Connection Management](./connection-management.md#reconnection-strategy).

---

## Related Specifications

- [Connection Management](./connection-management.md) — Client lifecycle and events
- [Store API](./store-api.md) — Mutation methods and their outcomes
- [Error Taxonomy](../implementation/error-taxonomy.md) — Canonical public error code catalog and retry behavior
