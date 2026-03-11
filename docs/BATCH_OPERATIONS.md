# ZyncBase Batch Operations (`BATCH_OPERATIONS.md`)

**Status**: Draft  
**Target Version**: v1

## 1. Core Principle
ZyncBase supports **Atomic Batches**, providing a "simplified transaction" model for frontend developers. A batch is a collection of write operations (`set` and `remove`) that are executed atomically on the server.

**Atomicity Guarantee**: If *any* operation in the batch fails (due to schema validation, authorization denial, or syntax errors), the *entire* batch is rejected. No partial writes are applied to the database or broadcast to subscribers.

## 2. Client SDK API

The API provides a single `client.store.batch()` method that accepts an array of operations.

```typescript
type BatchOp = 
  | { op: 'set', path: string, value: any }
  | { op: 'remove', path: string };

// Example: Atomic transfer of responsibility
await client.store.batch([
  { op: 'set', path: 'tasks.123', value: { status: 'assigned', user: 'bob' } },
  { op: 'set', path: 'users.bob.taskCount', value: 5 },
  { op: 'set', path: 'users.alice.taskCount', value: 3 }
]);
```

### Optimistic Reverts
Because writes in ZyncBase are optimistic (ADR-005), calling `.batch()` immediately applies all changes to the local cache. If the server rejects the batch, the entire batch is locally reverted.

## 3. Wire Protocol Format

To minimize payload size (since batches can contain many operations), the `StoreBatch` message uses compressed operation arrays instead of verbose objects.

**Message Type**: `StoreBatch`

**Request Payload**:
```json
{
  "type": "StoreBatch",
  "id": 101,
  "ops": [
    ["s", ["tasks", "123"], { "status": "assigned" }],  // 's' = set
    ["s", ["users", "bob", "taskCount"], 5],
    ["r", ["temporary_locks", "123"]]                   // 'r' = remove
  ]
}
```

**Response**:
- Success: Standard `{ "type": "ok", "id": 101 }`
- Failure: Standard error envelope, but the `details` block includes the index of the failed operation.

```json
{
  "type": "error",
  "id": 101,
  "code": "SCHEMA_VALIDATION_FAILED",
  "category": "validation",
  "message": "Batch failed at index 1: Schema validation failed",
  "details": {
    "batchIndex": 1,
    "path": ["users", "bob", "taskCount"],
    "reason": "Expected integer, got string"
  }
}
```

## 4. Server Execution Pipeline

To maintain the high performance of the Zig core and SQLite storage:

1. **Pre-Flight Validation**: Before taking SQLite locks, Zig iterates through the `ops` array to validate schemas and evaluate `auth.json` rules for *every* operation.
2. **Sidecar Delegation Constraints**: If any operation in the batch requires Bun Hook Server authorization (`"hook": "..."`), Zig batches these authorization checks into a single IPC message to the Hook Server. The Hook Server must approve all operations. If one is denied, the batch is rejected.
3. **SQLite Transaction**: Zig begins a `BEGIN IMMEDIATE` transaction, executes all `INSERT`/`UPDATE`/`DELETE` statements, and calls `COMMIT`. SQLite guarantees the atomicity at the disk level.
4. **Broadcast**: All changes are aggregated into a single `StoreDelta` broadcast message for connected clients watching the affected paths.

## 5. Limits & Constraints

To prevent abuse and degraded performance on the single-threaded SQLite writer loop:

- **Max Operations**: Hard limit of **500 operations** per `StoreBatch`.
- **Max Payload Size**: Governed by the global `security.rateLimit.maxMessageSize` config.
- **Allowed Operations**: Only `set` and `remove` are allowed. Reads (`get`) cannot be batched, as this is an atomic *write* batch, not an interactive transaction.
