# TypeScript SDK

**Drivers**: [Wire Protocol](./wire-protocol.md), [Error Taxonomy](./error-taxonomy.md), [ADR-017](../architecture/adrs.md#adr-017-strict-sdk-api-surface--store-vs-presence), [ADR-018](../architecture/adrs.md#adr-018-mutation-acknowledgement-and-consistency-semantics)

The TypeScript SDK owns the browser/application API surface, connection lifecycle, wire translation, local subscription materialization, presence API, retry behavior, and client-side validation before requests reach the server.

## Source Files

| File | Responsibility |
|------|----------------|
| `sdk/typescript/src/client.ts` | Public `ZyncBaseClient` composition and `createClient`. |
| `sdk/typescript/src/connection.ts` | WebSocket lifecycle, auth ticket acquisition, reconnect, namespace coordination, and outbound dispatch. |
| `sdk/typescript/src/connection_wire.ts` | MessagePack wire encoding/decoding, request ids, response demux, and server push handling. |
| `sdk/typescript/src/pending_requests.ts` | Pending request registry, timeout handling, and write-outcome correlation. |
| `sdk/typescript/src/store.ts` | Public store API and namespace-aware store connection wrapper. |
| `sdk/typescript/src/store_wire.ts` | Store command construction for set/remove/create/get/query/batch/listen/subscribe/loadMore. |
| `sdk/typescript/src/subscriptions.ts` | Local materialized views, listen projections, sorting, pagination, and delta application. |
| `sdk/typescript/src/presence.ts` | Public presence API, user/shared subscriptions, and presence event delivery. |
| `sdk/typescript/src/schema_dictionary.ts` | `SchemaSync` dictionary decoding and integer table/field lookup. |
| `sdk/typescript/src/errors.ts` | SDK `ErrorCodes`, `ZyncBaseError`, category derivation, and retryability. |
| `sdk/typescript/src/retry_policy.ts` | Reconnect/request retry policy. |
| `sdk/typescript/src/path.ts` | Path normalization plus flatten/unflatten helpers. |
| `sdk/typescript/src/doc_id.ts`, `sdk/typescript/src/uuid.ts` | Document id validation, packing/unpacking, and UUIDv7 generation. |
| `sdk/typescript/src/auth.ts`, `sdk/typescript/src/anonymous.ts` | Auth endpoint derivation and anonymous subject helpers. |
| `sdk/typescript/src/types.ts` | Public SDK types and interfaces. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `ZyncBaseClient` | `ConnectionManager`, `StoreImpl`, `PresenceImpl` | Public client facade. |
| `ConnectionManager` | WebSocket, fetch, `PendingRequests`, `ConnectionWireCodec`, `RetryPolicy` | Owns transport state, reconnect, auth ticket exchange, and request dispatch. |
| `ConnectionWireCodec` | MessagePack, schema dictionary, errors | Converts SDK commands to wire messages and server messages back to SDK events/errors. |
| `PendingRequests` | timers, request ids, write ids | Resolves/rejects request promises and committed write waits. |
| `StoreImpl` | `StoreCommand`, subscriptions, connection | Implements store reads, writes, batches, listens, and load-more behavior. |
| `PresenceImpl` | connection, schema dictionary | Implements user and shared presence APIs. |
| `SubscriptionTracker` | materialized view, comparator, cursor state | Tracks local subscription state and applies `StoreDelta` pushes. |
| `SchemaDictionary` | `SchemaSync` payload | Maps names to integer table/field ids and decodes server records. |
| `ZyncBaseError` | `ErrorCodes` | Stable SDK error object and retry metadata. |

## Ownership Boundaries

- `client.ts` should compose modules; it should not know MessagePack field-level encoding.
- `connection.ts` owns transport and lifecycle state; store/presence modules should not open sockets directly.
- `connection_wire.ts` owns protocol translation; store/presence modules build semantic commands.
- `schema_dictionary.ts` is the only SDK module that should decode `SchemaSync` dictionaries.
- `subscriptions.ts` owns local materialization; server deltas remain record-level.
- `errors.ts` owns SDK categories and retryability; implementation specs should not duplicate category tables outside [Error Taxonomy](./error-taxonomy.md).

## Request Flow

1. Public store/presence method validates SDK inputs and builds a semantic command.
2. `ConnectionManager` ensures the connection and required namespace scope are ready.
3. `ConnectionWireCodec` encodes the command using current schema dictionaries.
4. `PendingRequests` records the request id, timeout, and optional committed write id.
5. Server response resolves/rejects the immediate request.
6. For committed writes, `WriteCommitted` or `WriteError` resolves/rejects the tracked write.
7. Server pushes update subscription and presence listeners independently of mutation responses.

## Error And Retry Rules

- Public server codes mirror [Error Taxonomy](./error-taxonomy.md).
- SDK-local `CONNECTION_FAILED`, `TIMEOUT`, and `INVALID_PATH` are created client-side.
- Retry behavior is driven by error category plus `retryAfter` when supplied by the server.
- Auth refresh/token failure must not silently retry an unauthorized operation under stale identity.

## Maintenance Rules

- A wire message change must update `connection_wire.ts`, server `src/wire/*`, [Wire Protocol](./wire-protocol.md), and relevant tests together.
- A public API type change must update `types.ts` and `index.ts` exports together.
- Store and presence APIs stay separate; do not reintroduce presence through store paths.
- SDK docs should name modules/types and responsibilities, not mirror implementation code.
