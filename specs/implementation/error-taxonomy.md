# ZyncBase Error Taxonomy & Handling Strategy

**Status**: Finalized  

This document defines the formal error taxonomy for ZyncBase, covering error categories, retry semantics, and SDK-level handling.

---

## Drivers

This implementation follows the decisions established in:
- [ADR-019: Formal Error Taxonomy](../architecture/adrs.md#adr-019-formal-error-taxonomy-and-handling-strategy)

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

| Code | Category | Description | Trigger | HTTP Status | Retry Strategy |
|------|----------|-------------|---------|-------------|----------------|
| `AUTH_FAILED` | Authentication | Identity verification failed | Invalid ticket or expired initial JWT | 401 | No - Get new token |
| `TOKEN_EXPIRED` | Authentication | Session has expired | Connection closed by server; requires re-auth | 401 | Yes - Refresh token |
| `NAMESPACE_UNAUTHORIZED` | Authorization | No access to namespace | `setStoreNamespace` to a restricted path | 403 | No - Check permissions |
| `PERMISSION_DENIED` | Authorization | Rule blocked operation | `authorization.json` or Hook Server returned `false` | 403 | No - Check permissions |
| `SCHEMA_VALIDATION_FAILED` | Validation | Data shape mismatch | `store.set` with invalid fields/types | 400 | No - Fix data |
| `COLLECTION_NOT_FOUND` | Authorization | Collection missing in schema | Path refers to a table/collection not defined in the schema | 403 | No - Fix schema or path |
| `FIELD_NOT_FOUND` | Validation | Field missing in schema | Path/value refers to a field not defined in the schema | 400 | No - Fix schema or data |
| `INVALID_FIELD_NAME` | Validation | Field name contains forbidden characters | Path/value contains `__` sequence | 400 | No - Fix path or data |
| `INVALID_ARRAY_ELEMENT` | Validation | Array field contains non-literal value | `store.set` with an array containing nested objects or arrays | 400 | No - Fix data |
| `INVALID_MESSAGE` | Validation | Malformed frame | Failed to decode MessagePack or missing `type` | 400 | No - Fix message format |
| `RATE_LIMITED` | Rate-Limit | Threshold exceeded | Too many messages per second (per IP/token) | 429 | Yes - Exponential backoff |
| `MESSAGE_TOO_LARGE` | Rate-Limit | Payload too big | Exceeding `maxMessageSize` | 413 | No - Reduce message size |
| `CONNECTION_FAILED` | Connection | Transport failure | WebSocket closed unexpectedly or DNS failure | - | Yes - Reconnect |
| `TIMEOUT` | Connection | No server response | Request exceeded `client.timeout` (default: 10s) | 408 | Yes - Retry with backoff |
| `INTERNAL_ERROR` | Server | Zig core failure | Crash, Disk I/O error, or unhandled exception | 500 | Yes - Retry up to 3 times |
| `HOOK_SERVER_UNAVAILABLE` | Hook Server | Logic runtime down | Zig cannot reach the Bun Hook Server process | 503 | No - Check Hook Server |
| `HOOK_DENIED` | Hook Server | Logic rejected write | Developer's TS hook explicitly returned an error | 403 | No - Check hook logic |
| `MSGPACK_MAX_DEPTH_EXCEEDED` | Validation | MessagePack nesting too deep | Message exceeds max depth of 32 levels | 400 | No - Reduce nesting |
| `MSGPACK_MAX_SIZE_EXCEEDED` | Validation | MessagePack message too large | Message exceeds 10MB limit | 413 | No - Reduce message size |
| `MSGPACK_MAX_STRING_LENGTH_EXCEEDED` | Validation | String too long | String exceeds 1MB limit | 400 | No - Reduce string length |
| `MSGPACK_MAX_ARRAY_LENGTH_EXCEEDED` | Validation | Array too large | Array exceeds 100k elements | 400 | No - Reduce array size |
| `MSGPACK_MAX_MAP_SIZE_EXCEEDED` | Validation | Map too large | Map exceeds 100k entries | 400 | No - Reduce map size |
| `CHECKPOINT_FAILED` | Server | Database checkpoint failed | SQLite checkpoint operation failed | 500 | Yes - Automatic retry |
| `DATABASE_BUSY` | Server | Database locked | SQLite database is busy | 503 | Yes - Retry with backoff |
| `DATABASE_LOCKED` | Server | Database locked by another process | SQLite database is locked | 503 | Yes - Retry with backoff |
| `DATABASE_CORRUPT` | Server | Database corruption detected | SQLite integrity check failed | 500 | No - Restore from backup |
| `CACHE_REF_COUNT_OVERFLOW` | Server | Too many concurrent readers | Cache ref_count exceeded u32 max | 500 | No - Indicates bug |
| `CIRCUIT_BREAKER_OPEN` | Hook Server | Circuit breaker is open | Too many Hook Server failures | 503 | Yes - Wait for timeout |
| `SUBSCRIPTION_LIMIT_EXCEEDED` | Rate-Limit | Too many subscriptions | Client exceeded max subscriptions | 429 | No - Reduce subscriptions |
| `WAL_SIZE_EXCEEDED` | Server | WAL file too large | WAL file exceeded threshold | 500 | Yes - Automatic checkpoint |

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

```

### 4.1 Asynchronous Error Reporting (NACKs)

For high-throughput "fire-and-forget" operations (where the server returns `ok` immediately after queueing), the server may send a later, unsolicited error message if the background persistence fails.

1. **Protocol**: The server sends an error message where `requestId` matches the original write request, but potentially seconds later.
2. **Context**: These errors are primarily related to `DATABASE_BUSY`, `DATABASE_LOCKED`, `DISK_FULL`, or `SCHEMA_VIOLATION` that occur during background batch processing.
3. **SDK Action**: Upon receiving an unsolicited error with a known `requestId`, the SDK **must** asynchronously revert the optimistic state associated with that ID, even if the user has already moved on to other operations.

---

## 5. Detailed Retry Strategies

### Connection Errors

**Errors**: `CONNECTION_FAILED`, `TIMEOUT`

**Strategy**: Exponential backoff with jitter
```typescript
const retryConfig = {
  initialDelay: 1000,      // 1 second
  maxDelay: 30000,         // 30 seconds
  multiplier: 2,           // Double each time
  jitter: 0.1,             // ±10% randomness
  maxAttempts: Infinity    // Keep trying
}

// Retry delays: 1s, 2s, 4s, 8s, 16s, 30s, 30s, ...
```

**Implementation**:
```typescript
async function connectWithRetry() {
  let attempt = 0
  
  while (true) {
    try {
      await client.connect()
      return
    } catch (error) {
      if (error.code === 'CONNECTION_FAILED' || error.code === 'TIMEOUT') {
        attempt++
        const delay = Math.min(
          retryConfig.initialDelay * Math.pow(retryConfig.multiplier, attempt),
          retryConfig.maxDelay
        )
        const jitter = delay * retryConfig.jitter * (Math.random() * 2 - 1)
        await sleep(delay + jitter)
      } else {
        throw error
      }
    }
  }
}
```

### Rate Limit Errors

**Errors**: `RATE_LIMITED`

**Strategy**: Respect `retryAfter` header, exponential backoff if not provided
```typescript
async function handleRateLimit(error: ZyncBaseError) {
  if (error.retryAfter) {
    // Server told us exactly when to retry
    await sleep(error.retryAfter)
  } else {
    // Use exponential backoff
    const delay = 1000 * Math.pow(2, attempt)
    await sleep(delay)
  }
  
  // Retry the request
  return retry()
}
```

**Auto-retry**: Enabled by default, can be disabled
```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  retryRateLimits: true  // Default: true
})
```

### Server Errors

**Errors**: `INTERNAL_ERROR`, `DATABASE_BUSY`, `DATABASE_LOCKED`, `CHECKPOINT_FAILED`

**Strategy**: Bounded retry with exponential backoff
```typescript
const serverErrorRetry = {
  maxAttempts: 3,
  initialDelay: 1000,
  multiplier: 2
}

// Retry delays: 1s, 2s, 4s (then give up)
```

**Implementation**:
```typescript
async function retryServerError(operation: () => Promise<any>) {
  let attempt = 0
  
  while (attempt < serverErrorRetry.maxAttempts) {
    try {
      return await operation()
    } catch (error) {
      if (isServerError(error)) {
        attempt++
        if (attempt >= serverErrorRetry.maxAttempts) {
          throw error
        }
        const delay = serverErrorRetry.initialDelay * Math.pow(serverErrorRetry.multiplier, attempt)
        await sleep(delay)
      } else {
        throw error
      }
    }
  }
}
```

### Hook Server Errors

**Errors**: `HOOK_SERVER_UNAVAILABLE`, `CIRCUIT_BREAKER_OPEN`

**Strategy**: No automatic retry (fail fast)
```typescript
// Circuit breaker prevents cascading failures
if (error.code === 'CIRCUIT_BREAKER_OPEN') {
  // Don't retry - circuit breaker will auto-recover after timeout
  throw error
}

if (error.code === 'HOOK_SERVER_UNAVAILABLE') {
  // Hook Server is down - don't retry
  // Operations are denied by default for security
  throw error
}
```

### Authentication Errors

**Errors**: `TOKEN_EXPIRED`

**Strategy**: Fire event, wait for token refresh
```typescript
client.on('tokenExpired', async () => {
  // Get new token from your auth service
  const newToken = await refreshAuthToken()
  
  // Reconnect with new token
  await client.reconnect({ token: newToken })
})
```

**No retry for**: `AUTH_FAILED`, `NAMESPACE_UNAUTHORIZED`, `PERMISSION_DENIED`
- These indicate configuration or permission issues
- Retrying won't help
- Surface error to user immediately

### Validation Errors

**Errors**: `SCHEMA_VALIDATION_FAILED`, `INVALID_MESSAGE`, `MSGPACK_*_EXCEEDED`

**Strategy**: No retry (client-side bug)
```typescript
// These errors indicate bugs in client code
// Retrying won't help - fix the code
if (isValidationError(error)) {
  console.error('Client validation error:', error)
  // Revert optimistic update
  revertOptimisticUpdate(error.requestId)
  // Surface error to developer
  throw error
}
```

### Retry Decision Matrix

| Error Category | Auto-Retry | Max Attempts | Backoff | User Action Required |
|----------------|------------|--------------|---------|---------------------|
| Connection | ✅ Yes | Infinite | Exponential | None - automatic |
| Rate-Limit | ✅ Yes (opt-out) | Infinite | Respect `retryAfter` | None - automatic |
| Server | ✅ Yes | 3 | Exponential | Alert if persistent |
| Hook Server | ❌ No | 0 | N/A | Check Hook Server |
| Authentication | ⚠️ Partial | 1 | None | Refresh token |
| Authorization | ❌ No | 0 | N/A | Fix permissions |
| Validation | ❌ No | 0 | N/A | Fix client code |

---

## 6. SDK Error Object

All errors surfaced to SDK consumers use a consistent typed object. The `ZyncBaseError` interface is defined in the SDK package; the fields below are the server-side contract that populates it.

```typescript
interface ZyncBaseError extends Error {
  code: string;           // Machine-readable code from the catalog above
  category: string;       // Functional category (connection | auth | authorization | validation | rate-limit | server | hook-server)
  retryable: boolean;     // Whether the SDK will automatically retry
  retryAfter?: number;    // ms to wait before retry (server-provided)
  requestId?: number;     // Echoed request id from the failed message
  path?: string[];        // Affected data path, if applicable
  details?: Record<string, string[]>; // Field-level validation errors
}
```

---

## See Also

- [Security Model](./security.md) — Rate limiter and circuit breaker implementation
- [Wire Protocol](./wire-protocol.md) — Error envelope wire format
- [ADR-019](../architecture/adrs.md#adr-019-formal-error-taxonomy-and-handling-strategy) — Decision record for this taxonomy


