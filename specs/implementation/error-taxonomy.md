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

## 6. Error Handling Examples

### Example 1: Connection Error with Retry

```typescript
import { createClient } from '@zyncbase/client'

const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token: userJWT },
  namespace: 'room:abc-123',
  // Connection retry is automatic
  retryConnection: true,
  retryConfig: {
    initialDelay: 1000,
    maxDelay: 30000,
    multiplier: 2
  }
})

// Listen for connection events
client.on('connecting', () => {
  console.log('Reconnecting...')
})

client.on('connected', () => {
  console.log('Connected!')
})

client.on('error', (error) => {
  if (error.code === 'CONNECTION_FAILED') {
    // SDK will automatically retry
    console.log('Connection failed, retrying...')
  }
})

await client.connect()
```

### Example 2: Rate Limit Error

```typescript
try {
  // Send many messages quickly
  for (let i = 0; i < 1000; i++) {
    await client.store.set(`tasks.${i}`, { title: `Task ${i}` })
  }
} catch (error) {
  if (error.code === 'RATE_LIMITED') {
    // SDK automatically retries with backoff
    // Or disable auto-retry:
    // client.retryRateLimits = false
    console.log(`Rate limited, retry after ${error.retryAfter}ms`)
  }
}
```

### Example 3: Validation Error

```typescript
try {
  await client.store.set('tasks.123', {
    title: 'My Task',
    priority: 999  // Invalid: priority should be 1-5
  })
} catch (error) {
  if (error.code === 'SCHEMA_VALIDATION_FAILED') {
    // Don't retry - fix the data
    console.error('Validation failed:', error.details)
    // error.details = { priority: ['Must be between 1 and 5'] }
    
    // Revert optimistic update
    // SDK does this automatically
  }
}
```

### Example 4: Hook Server Error

```typescript
try {
  await client.store.set('tasks.123', { title: 'My Task' })
} catch (error) {
  if (error.code === 'HOOK_DENIED') {
    // Hook Server rejected the write
    console.error('Hook denied:', error.message)
    // Check your hook logic in hooks/auth.ts
  }
  
  if (error.code === 'HOOK_SERVER_UNAVAILABLE') {
    // Hook Server is down
    console.error('Hook Server unavailable')
    // Check Hook Server status
  }
  
  if (error.code === 'CIRCUIT_BREAKER_OPEN') {
    // Too many Hook Server failures
    console.error('Circuit breaker open')
    // Wait for automatic recovery (60s default)
  }
}
```

### Example 5: Token Expiration

```typescript
client.on('tokenExpired', async () => {
  console.log('Token expired, refreshing...')
  
  // Get new token from your auth service
  const response = await fetch('/api/auth/refresh', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${refreshToken}` }
  })
  const { token } = await response.json()
  
  // Reconnect with new token
  await client.reconnect({ token })
  
  console.log('Token refreshed, reconnected')
})
```

### Example 6: Database Error

```typescript
try {
  await client.store.set('tasks.123', { title: 'My Task' })
} catch (error) {
  if (error.code === 'DATABASE_BUSY') {
    // SDK will automatically retry up to 3 times
    console.log('Database busy, retrying...')
  }
  
  if (error.code === 'DATABASE_CORRUPT') {
    // Critical error - database needs recovery
    console.error('Database corruption detected!')
    // Alert operations team
    // Restore from backup
  }
}
```

### Example 7: MessagePack Limit Exceeded

```typescript
try {
  // Try to send deeply nested object
  const deepObject = createDeeplyNestedObject(50)  // 50 levels deep
  await client.store.set('tasks.123', deepObject)
} catch (error) {
  if (error.code === 'MSGPACK_MAX_DEPTH_EXCEEDED') {
    // Don't retry - reduce nesting
    console.error('Object too deeply nested (max 32 levels)')
    // Flatten the object structure
  }
}
```

---

## 7. Monitoring and Alerting

### Error Metrics

Track these metrics in production:

```typescript
// Error rate by category
zyncbase_errors_total{category="connection"} 45
zyncbase_errors_total{category="authentication"} 12
zyncbase_errors_total{category="authorization"} 8
zyncbase_errors_total{category="validation"} 23
zyncbase_errors_total{category="rate_limit"} 156
zyncbase_errors_total{category="server"} 3
zyncbase_errors_total{category="hook_server"} 7

// Error rate by code
zyncbase_errors_total{code="CONNECTION_FAILED"} 45
zyncbase_errors_total{code="RATE_LIMITED"} 156
zyncbase_errors_total{code="SCHEMA_VALIDATION_FAILED"} 23

// Retry attempts
zyncbase_retry_attempts_total{error_code="CONNECTION_FAILED"} 234
zyncbase_retry_success_total{error_code="CONNECTION_FAILED"} 189
```

### Alert Rules

```yaml
# Prometheus alert rules
groups:
  - name: zyncbase_errors
    rules:
      # High error rate
      - alert: HighErrorRate
        expr: rate(zyncbase_errors_total[5m]) > 10
        for: 5m
        annotations:
          summary: "High error rate detected"
          
      # Database errors
      - alert: DatabaseErrors
        expr: zyncbase_errors_total{code="DATABASE_CORRUPT"} > 0
        annotations:
          summary: "Database corruption detected"
          severity: "critical"
          
      # Hook Server down
      - alert: HookServerDown
        expr: zyncbase_errors_total{code="HOOK_SERVER_UNAVAILABLE"} > 10
        for: 2m
        annotations:
          summary: "Hook Server unavailable"
          
      # Circuit breaker open
      - alert: CircuitBreakerOpen
        expr: zyncbase_hook_server_circuit_breaker_state == 1
        for: 5m
        annotations:
          summary: "Hook Server circuit breaker open"
```

---

## 8. Error Logging

### Structured Error Logs

```json
{
  "timestamp": "2026-03-09T10:30:00Z",
  "level": "error",
  "error_code": "SCHEMA_VALIDATION_FAILED",
  "error_category": "validation",
  "message": "Validation failed for field 'priority'",
  "user_id": "user-123",
  "namespace": "room:abc-123",
  "path": "tasks.123",
  "request_id": 456,
  "client_ip": "192.168.1.100",
  "details": {
    "priority": ["Must be between 1 and 5"]
  }
}
```

### Log Levels by Error Category

| Category | Log Level | Rationale |
|----------|-----------|-----------|
| Connection | INFO | Expected during network issues |
| Authentication | WARN | May indicate attack or misconfiguration |
| Authorization | WARN | May indicate permission issues |
| Validation | INFO | Client-side bugs, not server issues |
| Rate-Limit | WARN | May indicate abuse |
| Server | ERROR | Server-side issues need investigation |
| Hook Server | ERROR | Hook Server issues need investigation |


