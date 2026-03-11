# ZyncBase Error Taxonomy & Handling Strategy

**Status**: Finalized  
**ADR**: Error Taxonomy (design_todo #1)

This document defines the formal error taxonomy for ZyncBase, covering error categories, retry semantics, and SDK-level handling.

---

## 1. Error Categories

Errors are grouped into 7 functional categories to determine automatic SDK behavior (retries, reverts, etc.).

| Category | Typical Codes | Retryable? | SDK Behavior |
|----------|---------------|------------|--------------|
| **Connection** | `CONNECTION_FAILED`, `TIMEOUT` | **Yes (Auto)** | Exponential backoff + jitter until reconnected. |
| **Authentication** | `AUTH_FAILED`, `TOKEN_EXPIRED` | **Partial** | Fire `tokenExpired` event; wait for `authRefresh`. |
| **Authorization** | `NAMESPACE_UNAUTHORIZED`, `PERMISSION_DENIED` | No | Surface error immediately; revert optimistic update. |
| **Validation** | `SCHEMA_VALIDATION_FAILED`, `INVALID_MESSAGE` | No | Surface error; revert optimistic update. |
| **Rate-Limit** | `RATE_LIMITED`, `MESSAGE_TOO_LARGE` | **Yes (Opt-out)** | Auto-retry with backoff if `RATE_LIMITED`. |
| **Server** | `INTERNAL_ERROR` | **Yes (Bounded)** | Retry up to 3 times with backoff. |
| **Hook Server** | `HOOK_SERVER_UNAVAILABLE`, `HOOK_DENIED` | No | Surface error; indicates issue in developer's hook logic. |

---

## 2. Complete Error Catalog

| Code | Category | Description | Trigger |
|------|----------|-------------|---------|
| `AUTH_FAILED` | Authentication | Identity verification failed | Invalid ticket or expired initial JWT |
| `TOKEN_EXPIRED` | Authentication | Session has expired | Connection closed by server; requires re-auth |
| `NAMESPACE_UNAUTHORIZED` | Authorization | No access to namespace | `setStoreNamespace` to a restricted path |
| `PERMISSION_DENIED` | Authorization | Rule blocked operation | `auth.json` or Hook Server returned `false` |
| `SCHEMA_VALIDATION_FAILED` | Validation | Data shape mismatch | `store.set` with invalid fields/types |
| `INVALID_MESSAGE` | Validation | Malformed frame | Failed to decode MessagePack or missing `type` |
| `RATE_LIMITED` | Rate-Limit | Threshold exceeded | Too many messages per second (per IP/token) |
| `MESSAGE_TOO_LARGE` | Rate-Limit | Payload too big | Exceeding `maxMessageSize` |
| `CONNECTION_FAILED` | Connection | Transport failure | WebSocket closed unexpectedly or DNS failure |
| `TIMEOUT` | Connection | No server response | Request exceeded `client.timeout` (default: 10s) |
| `INTERNAL_ERROR` | Server | Zig core failure | Crash, Disk I/O error, or unhandled exception |
| `HOOK_SERVER_UNAVAILABLE` | Hook Server | Logic runtime down | Zig cannot reach the Bun Hook Server process |
| `HOOK_DENIED` | Hook Server | Logic rejected write | Developer's TS hook explicitly returned an error |

> [!NOTE]
> `PATH_NOT_FOUND` has been removed. Reads from empty paths return `null`, and writes to new paths automatically create them (upsert).

---

## 3. SDK Implementation Details

### The `ZyncBaseError` Object

All errors surfaced to developers use a consistent typed object:

```typescript
interface ZyncBaseError extends Error {
  code: string;           // Machine-readable code (e.g., 'RATE_LIMITED')
  category: string;       // Category for grouping logic
  retryable: boolean;     // Whether the SDK can/will retry this
  retryAfter?: number;    // ms suggested by server to wait
  requestId?: number;     // ID of the failed request
  path?: string[];        // Affected data path (if applicable)
  details?: Record<string, string[]>; // Field-level validation errors
}
```

### Retry Semantics

1. **Exponential Backoff**: For all retryable errors, the SDK uses `initialDelay * base ^ attempt + jitter`.
2. **Rate-Limit Retries**: Enabled by default. If the server provides `retryAfter`, the SDK respects it exactly.
3. **Optimistic Reverts**: If a `store.set` or `store.remove` receives an error response, the SDK **must** immediately revert the local state change to maintain synchronization.

---

## 4. Error Propagation Flow

1. **Wire Layer**: Server sends `{ type: "error", code: "...", ... }`.
2. **SDK Internal**: Reverts optimistic state if request `id` matches a pending write.
3. **Core API**:
   - `await` calls (e.g., `connect()`, `query()`) throw the `ZyncBaseError`.
   - Continuous streams (subscriptions) fire the global `client.on('error', ...)` event.
4. **Framework Hooks**: (React/Vue/Svelte) Populate the `error` state in the hook result.

```typescript
// Example: React handling
const { data, error } = useStore('tasks.123');

if (error) {
  if (error.code === 'PERMISSION_DENIED') return <NoAccess />;
  return <ErrorMessage message={error.message} />;
}
```
