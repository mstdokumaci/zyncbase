# Message Handler

**Drivers**: [Wire Protocol](./wire-protocol.md), [Threading](./threading.md), [Memory Strategy](./memory-strategy.md), [Error Taxonomy](./error-taxonomy.md), [ADR-015](../architecture/adrs.md#adr-015-scoped-session-management), [ADR-018](../architecture/adrs.md#adr-018-mutation-acknowledgement-and-consistency-semantics)

`MessageHandler` is the WebSocket request router. It decodes the envelope, enforces connection-local limits, gates operations on scoped session readiness, dispatches to store/presence/subscription/auth services, and encodes either an immediate response or an error.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/message_handler.zig` | Main request lifecycle, routing, scoped session gates, rate-limit enforcement, and response/error send path. |
| `src/wire/decode.zig` | Zero/low-allocation envelope and payload extractors for supported message types. |
| `src/wire/encode.zig` | Success, query, schema sync, write acknowledgement, presence, and error encoders. |
| `src/connection/state.zig` | Per-connection state, send outbox, scoped session fields, and subscription ownership. |
| `src/connection/session_resolver.zig` | Background namespace/user resolution and stale-result protection. |
| `src/store_service.zig` | Store mutations, queries, pagination, and scope lookup. |
| `src/presence/manager.zig` | Presence writes, snapshots, and subscriber fanout source state. |
| `src/authorization/*` | Namespace, read, write, and presence authorization decisions. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `MessageHandler` | `MemoryStrategy`, `Connection`, `StoreService`, `PresenceManager`, `SubscriptionEngine`, `AuthConfig`, `Schema`, `JwtValidator` | Owns request handling and all domain dispatch from a decoded wire envelope. |
| `Connection` | `Outbox`, `Session`, `WebSocket`, allocator | Holds mutable per-client state, scoped namespace/user ids, pending namespace resolution, and connection subscriptions. |
| `ConnectionViolationTracker` | Security config | Counts malformed/security-sensitive messages and closes abusive connections. |
| `wire.Envelope` | MessagePack extractor | Carries `type` and `id`, the only fields needed before routing. |
| `StoreService` | `StorageEngine`, `Schema`, `Authorization` | Executes store reads/writes and resolves namespace/user scope. |
| `SubscriptionEngine` | `QueryFilter`, `RecordChange` | Tracks store subscriptions and evaluates record changes for fanout. |
| `PresenceManager` | Presence schema, subscribers | Maintains user/shared presence state and produces snapshots/broadcasts. |

## Request Lifecycle

1. Apply per-connection message rate limiting from `Config.SecurityConfig`.
2. Decode `wire.Envelope` from the raw MessagePack frame.
3. Acquire a request arena from `MemoryStrategy`.
4. Classify the message type with `classifyMsgType`.
5. Route to the store, auth, or presence handler.
6. Send an immediate response when the route completes synchronously.
7. Return `null` for asynchronous scope resolution; the resolver later sends the response if the `scope_seq` is still current.
8. Convert route failures through `wire.getWireError` and send a canonical error response.

## Supported Routes

| Group | Message names | Gate |
|-------|---------------|------|
| Scope setup | `StoreSetNamespace`, `PresenceSetNamespace` | Requires authenticated connection; may run before scoped readiness. |
| Store write | `StoreSet`, `StoreRemove`, `StoreBatch` | Requires ready store scope and write authorization. |
| Store read | `StoreQuery`, `StoreSubscribe`, `StoreLoadMore` | Requires ready store scope and read authorization. |
| Store subscription control | `StoreUnsubscribe` | Connection-local subscription id. |
| Auth | `AuthRefresh` | Requires valid refresh token/JWT validation path. |
| Presence write | `PresenceSet`, `PresenceSetShared`, `PresenceRemove` | Requires ready presence scope and presence authorization. |
| Presence subscription control | `PresenceSubscribe`, `PresenceUnsubscribe`, `PresenceSubscribeShared`, `PresenceUnsubscribeShared` | Requires ready presence scope except local cleanup paths. |

## Scoped Session Rules

- Transport open is not the same as store/presence readiness.
- Store operations require `Connection.getStoreSession()` to be ready and to hold a resolved namespace id.
- Presence operations require the presence namespace/user scope to be ready.
- Namespace setup messages start a new resolution sequence and detach stale store subscriptions.
- `users.namespaced = true` forbids switching to a different namespace on the same connection; clients must reconnect for a different namespace.
- Background resolution must check `scope_seq` before committing results so stale async work cannot activate an older scope.

## Error Handling

- Public codes and retry categories are owned by [Error Taxonomy](./error-taxonomy.md).
- Message format and parser-limit failures are recorded in `ConnectionViolationTracker`.
- Repeated security-sensitive violations close the WebSocket instead of allowing unbounded error responses.
- Write operations that request committed acknowledgement may complete through `WriteCommitted` or `WriteError` pushes after the immediate request phase.

## Error Propagation

Errors flow through four distinct paths depending on when they occur:

### Synchronous Request Errors

1. Error originates in `routeMessageFast` (validation, authorization, storage, etc.).
2. `handleMessage` catches the error and calls `wire.getWireError(err)` to translate it.
3. `wire.encodeError()` builds the MessagePack error response with the request `id`.
4. `conn.send()` delivers the response; backpressure or drop closes the connection.

### Asynchronous Write Errors

1. Write op is enqueued with `conn_id` and `write_id`.
2. Writer thread commits the transaction; on failure, pushes `WriteOutcomeResult` with error into `WriteOutcomeBuffer`.
3. `WriteOutcomeDispatcher` drains the buffer and calls `wire.encodeWriteError()` with `write_id` and optional `batch_index`.
4. `ConnectionManager.sendToConnection()` delivers the `WriteError` push to the origin connection.

### Asynchronous Session Resolution Errors

1. Namespace resolution is enqueued on cache miss.
2. Writer thread resolves namespace/user IDs; on failure, pushes `SessionResolutionResult` with error.
3. `SessionResolver` drains the buffer, re-checks `scope_seq`, and calls `wire.encodeError()` with the original request `id`.
4. If the scope was superseded, sends `REQUEST_SUPERSEDED` instead.

### Security Violations

1. Decode-level errors (max depth, array too large, etc.) are identified by `isSecurityError()`.
2. `ConnectionViolationTracker` records the violation.
3. If the threshold is exceeded, the connection is closed immediately without sending an error response.
4. Repeated malformed messages follow the same path; the tracker is connection-scoped.

**Canonical translation**: All Zig errors map through `wire.getWireError()` in `src/wire/errors.zig`. The translation table is the single source of truth for public error codes.

## Memory And Concurrency Invariants

- Request-temporary allocations use the `MemoryStrategy` arena and are released before `handleMessage` returns.
- Persistent connection-owned data is allocated from the connection allocator and cleared during teardown.
- Per-connection mutable state is guarded by `Connection` methods; cross-connection fanout is handled by dedicated managers.
- Store writes are serialized by the storage write queue; read/subscription paths must not mutate connection scope.
- Disconnect teardown clears violation state, detaches subscriptions, resets scope, and removes presence owned by the connection.

## See Also

- [Wire Protocol](./wire-protocol.md)
- [Auth Exchange](./auth-exchange.md)
- [Presence Internals](./presence-internals.md)
- [Storage](./storage.md)
