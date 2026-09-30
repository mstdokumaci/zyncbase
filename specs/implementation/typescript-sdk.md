# TypeScript SDK

**Drivers**: [Wire Protocol](./wire-protocol.md), [Error Taxonomy](./error-taxonomy.md), [ADR-017](../architecture/adrs.md#adr-017-strict-sdk-api-surface--store-vs-presence), [ADR-018](../architecture/adrs.md#adr-018-mutation-acknowledgement-and-consistency-semantics)

The TypeScript SDK owns the browser/application API surface, connection lifecycle, wire translation, local subscription materialization, presence API, retry behavior, and client-side validation before requests reach the server.

## Source Files

| File | Responsibility |
|------|----------------|
| `sdk/typescript/src/client.ts` | Public `ZyncBaseClient` composition, recovery orchestration (`connect()` resolves at `synced`, after replay), and `createClient`. |
| `sdk/typescript/src/connection.ts` | WebSocket lifecycle, auth ticket acquisition, reconnect, namespace coordination, and outbound dispatch. |
| `sdk/typescript/src/connection_wire.ts` | MessagePack wire encoding/decoding, request ids, response demux, and server push handling. |
| `sdk/typescript/src/pending_requests.ts` | Pending request registry, timeout handling, and write-outcome correlation. |
| `sdk/typescript/src/store.ts` | Public store API, subscription registry (keyed sharing, readiness queue, grace teardown), and namespace-aware store connection wrapper. |
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
| `sdk/typescript/src/index.ts` | Public export barrel. |
| `sdk/typescript/cli/generate.ts` | CLI schema/type generation entry point. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `ZyncBaseClient` | `ConnectionManager`, `StoreImpl`, `PresenceImpl` | Public client facade. |
| `ConnectionManager` | WebSocket, fetch, `PendingRequests`, `ConnectionWireCodec`, `RetryPolicy` | Owns transport state, reconnect, auth ticket exchange, and request dispatch. |
| `ConnectionWireCodec` | MessagePack, schema dictionary, errors | Converts SDK commands to wire messages and server messages back to SDK events/errors. |
| `PendingRequests` | timers, request ids, write ids | Resolves/rejects request promises and committed write waits. |
| `StoreImpl` | `StoreCommand`, subscriptions, connection | Implements store reads, writes, batches, listens, and load-more behavior. |
| `SubscriptionRegistry` | key index, refcounts, grace timers, readiness queue | Shares one server subscription per key across consumers; sits above `SubscriptionTracker` (which remains the subId→entry layer). |
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
3. `ConnectionWireCodec` encodes the command using current schema dictionaries and replaces the logical `type` name with its numeric wire ID from the shared registry (`WireMessageType`); `decodeMessage` maps numeric IDs back to the logical `InboundMessage` type names, so the rest of the SDK never sees numeric wire IDs.
4. `PendingRequests` records the request id, timeout, and optional committed write id.
5. Server response resolves/rejects the immediate request.
6. For committed writes, `WriteCommitted` or `WriteError` resolves/rejects the tracked write.
7. Server pushes update subscription and presence listeners independently of mutation responses.

Public methods that receive an `ok` response expose it through a promise. For subscriptions, the promise resolves once *this consumer* is registered — settlement rules live in [Store API → Subscription Lifecycle](../api-design/store-api.md#subscription-lifecycle). Callbacks deliver initial results and later updates independently. `Actions.handle()` resolves after the server accepts the registration.

Recovery orchestration lives in `client.ts` (resolve-at-`synced`, emit `synced`/`reconnected`) and `connection.ts` (attach `DisconnectDetail` to every `disconnected`). Event contract: [Connection Management → Recovery Complete](../api-design/connection-management.md#recovery-complete).

## Liveness Implementation

`ConnectionManager` implements the public contract in [Connection Management](../api-design/connection-management.md). It owns the probe timer, randomizes the first deadline within `liveness.intervalMs`, tracks a single in-flight Ping id, sends Ping through `ConnectionWireCodec` before scope readiness, resets the timer from the response-correlation path, and closes the socket on probe timeout to use the existing reconnect path.

## Complete Store Record Decoding

- `SchemaDictionary.decodeRecord` is the single authority for complete positional records from `StoreQuery`, `StoreSubscribe`, `StoreLoadMore`, and `StoreDelta` set operations. It validates the schema field count, decodes typed fields, and constructs the final nested SDK record in one pass.
- `ConnectionWireCodec` decodes correlated read rows before resolving their pending request. Query and subscribe requests provide the response table index directly; load-more keeps that index only in local pending-request context while the wire request contains just `subId` and `nextCursor`.
- `StoreImpl` and `SubscriptionTracker` receive final nested records. They must not reinterpret positional rows or unflatten complete records.
- A malformed correlated record rejects its pending request. A malformed delta push is dropped without preventing later complete messages in the same frame from being processed.

## Subscription Delivery Contract

- `store.subscribe` callbacks receive the current full snapshot of matching records and fire **at most once per event-loop tick** while deltas arrive. Deltas within a tick are applied to the local materialized view in arrival order, then one snapshot is delivered. The view state read inside a callback is always current; only the callback timing is batched (≈1 tick, sub-ms to a few ms under load).
- `store.listen` callbacks are synchronous per emitted committed delta within the message handling task (single-record projection, O(1) per delta). A delta represents one record's transaction endpoints, not one accepted write: repeated writes to a record in one writer transaction may yield one callback, and create-then-delete may yield none.
- Both preserve per-subscription arrival order; there is no cross-subscription ordering contract.
- Delivery is per server subscription, not per consumer: all consumers of a shared key observe the same snapshots at the same times — no per-consumer buffering or divergence.

## Subscription Registration Lifecycle

- **Readiness queue.** `listen`/`subscribe` issued before session readiness are held in a pending queue and dispatched when readiness is reached. Readiness must be awaited by re-checking after each connection cycle: `awaitSchemaSync()` rejects on mid-session drops, so a bare single await is wrong — the flush loop catches rejection and waits for the next cycle. Contract (flush points, disconnect rejection, writes excluded): [Store API → Readiness queue](../api-design/store-api.md#readiness-queue).
- **Keyed sharing.** One server subscription per key (key definition: [Store API → Keyed sharing](../api-design/store-api.md#keyed-sharing)). `SubscriptionRegistry` owns key→subId, refcounts, per-key pagination state (`nextCursor`, `hasMore`), and grace timers. Establishment races use the presence generation-guard pattern (`presence.ts` establish loop): detach-during-establishment re-checks the refcount when the wire response lands and unsubscribes immediately if it is zero.
- **Grace teardown.** Last-consumer detach schedules the wire unsubscribe after the contract's grace window via a single `setTimeout` per key, cancelled on re-attach.
- **Snapshots.** Collection entries read the sorted `materializedView.records`; listen entries retain a `lastValue` field (projection dispatch stores what it delivers — new field on `SubscriptionEntry`), which `getSnapshot()` returns.
- **Namespace switch.** `setStoreNamespace` flushes every live store key against the new namespace through the registry before resolving; registry refcounts are preserved across re-dispatch. Presence and action replay is scoped to `setPresenceNamespace`.

## Error And Retry Rules

- Public server codes mirror [Error Taxonomy](./error-taxonomy.md).
- SDK-local `CONNECTION_FAILED`, `TIMEOUT`, and `INVALID_PATH` are created client-side.
- Retry behavior is driven by error category plus `retryAfter` when supplied by the server.
- Auth refresh/token failure must not silently retry an unauthorized operation under stale identity.

## Maintenance Rules

- A wire message change must update `connection_wire.ts` (registry + encode/decode), server `src/wire/*`, [Wire Protocol](./wire-protocol.md), and relevant tests together.
- A public API type change must update `types.ts` and `index.ts` exports together.
- SDK distribution changes must keep `sdk/typescript/src/index.ts`, emitted declarations, and the CLI build entry aligned.
- Store and presence APIs stay separate; do not reintroduce presence through store paths.
- SDK docs should name modules/types and responsibilities, not mirror implementation code.
