# TypeScript SDK Implementation

This document records the current TypeScript SDK implementation choices. It is not a
migration plan. The SDK is greenfield and internal compatibility is not a goal; keep
the module boundaries clean and update call sites directly when contracts change.

## Design Goals

- Keep the public API small and stable while allowing internals to change cleanly.
- Give every stateful concern exactly one owner.
- Keep wire encoding at the network boundary.
- Keep store/query encoding outside the public store facade.
- Keep subscription materialization in the subscription tracker.
- Prefer pure functions for stateless builders and shapers.
- Prefer small stateful classes only where state is intrinsic.
- Avoid generic framework abstractions that hide the protocol.
- Avoid compatibility layers, duplicate implementations, and transition shims.

## Module Ownership

### `client.ts`

Composition root for the SDK.

Owns:

- Constructing `ConnectionManager`, `StoreImpl`, and `SubscriptionTracker`.
- Public client lifecycle methods.
- Client-level error fanout.
- Subscription replay after reconnect.

Does not own:

- Store request construction.
- Wire encoding.
- WebSocket event internals.
- Materialized view mutation.

### `connection.ts`

Stateful WebSocket lifecycle facade.

Owns:

- WebSocket creation and teardown.
- Reconnect policy and timers.
- Lifecycle event listeners.
- Active store and presence namespaces.
- Public `connect`, `disconnect`, `dispatch`, `send`, `on`, and `off`.
- Inbound message routing after wire decoding.

Delegates:

- Request id and promise tracking to `pending_requests.ts`.
- MessagePack and schema-aware conversion to `connection_wire.ts`.

Must not own:

- MessagePack imports.
- Schema table/field lookup logic.
- Store query or batch encoding.
- Raw pending request map management.

### `pending_requests.ts`

Small request table for in-flight RPCs.

Owns:

- Monotonic request id allocation.
- Promise registration.
- Resolve/reject by id.
- Reject-all on disconnect.
- Optional context attached to each request.

Rules:

- Unknown ids return `false`.
- `rejectAll` clears the map before invoking rejections.
- It does not construct SDK errors. Callers pass the final reason.
- It has no WebSocket, MessagePack, or schema knowledge.

### `connection_wire.ts`

Transport wire codec.

Owns:

- MessagePack encode/decode.
- `SchemaDictionary` instance and schema sync application.
- Schema-aware outbound store conversion.
- Schema-aware inbound row and delta conversion.
- Mapping schema lookup failures to `ZyncBaseError`.
- Returning pending-request context needed to decode future responses.

Rules:

- `ConnectionManager` sends semantic outbound SDK messages to the codec.
- The codec performs final compact schema conversion immediately before MessagePack.
- Inbound deltas and query rows are decoded before they reach store or subscription code.
- Store and subscription modules do not import `@msgpack/msgpack`.

### `store.ts`

Public store facade.

Owns:

- Store API methods: `set`, `remove`, `create`, `push`, `update`, `get`, `query`,
  `batch`, `listen`, and `subscribe`.
- Calling `ConnectionManager.dispatch`.
- User-facing error normalization and emission.
- High-level subscription open/close flow.

Delegates:

- Store message construction and result shaping to `store_wire.ts`.
- Subscription entry and initial snapshot handling to `subscriptions.ts`.

Must not own:

- Query operator opcode maps.
- Wire condition tuple construction.
- Path flatten/unflatten implementation details.
- Materialized view construction or mutation.

### `store_wire.ts`

Pure store request and response helpers.

Owns:

- Path normalization for store operations.
- Path depth validation.
- Store command builders.
- Query condition and order encoding.
- Batch operation normalization.
- `get` and `query` response shaping.

Rules:

- Builders throw SDK errors for invalid API input.
- Builders return normalized segments when later response shaping needs them.
- No network calls.
- No subscription tracker imports.
- No MessagePack imports.

### `subscriptions.ts`

Subscription registry and local materialization.

Owns:

- Active subscription entries.
- Delta queueing while disconnected.
- Replay/remap after reconnect.
- Listen projection.
- Materialized collection views.
- Initial snapshot-to-delta construction.
- Incremental delta application.

Rules:

- The tracker does not dispatch network messages.
- Store code opens/closes server subscriptions, then asks the tracker to register or
  unregister local state.
- Collection materialized views are owned entirely by the tracker.

### `types.ts`

Shared public and protocol-adjacent TypeScript types.

Rules:

- Public API types must not expose schema-encoded numeric wire internals.
- Wire message types may describe logical SDK-side messages before codec conversion.
- If protocol details become too broad, split internal wire-only types out of `types.ts`
  rather than bloating public type exports.

## Dependency Graph

Allowed dependencies:

```text
client.ts
  -> connection.ts
  -> store.ts
  -> subscriptions.ts

connection.ts
  -> connection_wire.ts
  -> pending_requests.ts
  -> errors.ts
  -> types.ts

connection_wire.ts
  -> schema_dictionary.ts
  -> errors.ts
  -> types.ts
  -> @msgpack/msgpack

store.ts
  -> connection.ts
  -> store_wire.ts
  -> subscriptions.ts
  -> errors.ts
  -> types.ts

store_wire.ts
  -> path.ts
  -> errors.ts
  -> types.ts

subscriptions.ts
  -> path.ts
  -> types.ts
```

Forbidden dependencies:

- `store_wire.ts -> connection.ts`
- `store_wire.ts -> subscriptions.ts`
- `subscriptions.ts -> connection.ts`
- `connection_wire.ts -> store.ts`
- `connection.ts -> path.ts` for store-specific path handling
- Any module except `connection_wire.ts` importing `@msgpack/msgpack`

## Request Flow

Store write/read flow:

1. Public API method in `store.ts` receives user input.
2. `store_wire.ts` validates and builds a logical outbound store message.
3. `store.ts` dispatches that message through `ConnectionManager`.
4. `connection.ts` allocates a request id through `PendingRequests`.
5. `connection_wire.ts` schema-encodes the message and MessagePack-encodes bytes.
6. `connection.ts` sends bytes over the WebSocket.
7. Inbound `ok`/`error` resolves or rejects the pending request.
8. `store_wire.ts` shapes store results for public return values.

Subscription flow:

1. `store.ts` builds subscribe params through `store_wire.ts`.
2. `store.ts` dispatches the subscribe request.
3. On success, `store.ts` asks `SubscriptionTracker` to register listen or collection
   state.
4. Initial snapshots are converted into local deltas by `subscriptions.ts`.
5. Server `StoreDelta` pushes are decoded by `connection_wire.ts`.
6. `connection.ts` routes decoded deltas to `SubscriptionTracker`.
7. `SubscriptionTracker` projects or materializes the update and calls user callbacks.

Reconnect flow:

1. `ConnectionManager` owns reconnect timers and reconnect attempts.
2. `SubscriptionTracker` queues deltas while disconnected.
3. `client.ts` replays active subscriptions after reconnect.
4. `SubscriptionTracker` remaps old server subscription ids to new ids.
5. Fresh snapshots repopulate materialized views before queued deltas drain.

## Error Handling

- Server `error` responses are converted with `ZyncBaseError.fromServerResponse`.
- Store API input validation throws client-category `ZyncBaseError`.
- Unknown non-SDK errors from store operations are normalized in `store.ts`.
- Pending requests are rejected on disconnect before the pending map is cleared.
- Schema lookup failures during wire encoding are mapped in `connection_wire.ts`.

## Performance Rules

- Normalize each path once per public operation.
- Build batch messages in one pass.
- Keep MessagePack conversion at the connection boundary only.
- Decode schema-encoded rows before store/subscription code receives them.
- Use maps for pending requests and subscription entries.
- Keep collection materialized views incremental.
- Avoid cloning rows unless mutation safety requires it.

## Testing Ownership

Direct boundary tests should exist for:

- `pending_requests.ts`: id allocation, resolve/reject, unknown ids, reject-all.
- `connection_wire.ts`: schema-aware encode/decode and response row decoding.
- `store_wire.ts`: path validation, query encoding, batch normalization, result shaping.
- `connection.ts`: lifecycle, reconnect, dispatch routing, pending resolution.
- `store.ts`: one-dispatch public operation behavior and error emission.
- `subscriptions.ts`: projection, materialized views, queue/replay/remap behavior.

Run for SDK changes:

```bash
bun run --filter @zyncbase/client build
bun test sdk
bunx biome check --write
```

Run for protocol-facing changes:

```bash
bun run test:e2e
```

Run repo lint before completion:

```bash
bun run lint
```

## Maintenance Notes

- Internal API breaks are acceptable. Update call sites directly.
- Do not reintroduce wrappers that mirror old private methods.
- Do not move codec behavior back into `connection.ts`.
- Do not move query/path helpers back into `store.ts`.
- Add new modules only when ownership is genuinely distinct.
- Prefer small pure helpers over new classes when no state is involved.
