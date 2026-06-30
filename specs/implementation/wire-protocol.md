# Wire Protocol

**Drivers**: [ADR-008](../architecture/adrs.md#adr-008-wire-encoding), [ADR-009](../architecture/adrs.md#adr-009-integer-routing-architecture), [ADR-014](../architecture/adrs.md#adr-014-unified-subscription-engine), [ADR-018](../architecture/adrs.md#adr-018-mutation-acknowledgement-and-consistency-semantics), [ADR-020](../architecture/adrs.md#adr-020-typed-two-tier-presence-system)

This document is the canonical implementation contract for ZyncBase's WebSocket messages. It names the message types, stable fields, source files, and routing rules. Detailed query operators, schema dictionaries, and public error codes live in their owner specs.

## Design Principles

- **1:1 SDK mapping** — Every client SDK method maps to exactly one message type. No overloaded messages.
- **Correlate by ID** — Every client request has a unique `id`. The server response echoes it.
- **Pushes are unsolicited** — Server-initiated messages (subscription deltas, presence broadcasts) have their own types and do not carry a request `id`.
- **Extend, never break** — New fields can be added to any message type. Unknown fields are ignored. See [Extensibility](#extensibility).

## Source Files

| File | Responsibility |
|------|----------------|
| `src/wire.zig` | Public wire module facade and re-exports. |
| `src/wire/decode.zig` | MessagePack envelope and request extractors. |
| `src/wire/encode.zig` | Response, schema sync, subscription delta, write outcome, and presence encoders. |
| `src/wire/errors.zig` | Internal Zig error to public wire-code mapping. |
| `src/wire/comptime.zig` | Compile-time MessagePack key/value encoding helpers. |
| `src/message_handler.zig` | Message classification, scoped-session gates, and route dispatch. |
| `sdk/typescript/src/connection_wire.ts` | SDK-side wire encoding/decoding boundary. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `wire.Envelope` | MessagePack extractor | Required client request header: `type`, `id`. |
| `StorePathPayloads` | MessagePack `Payload` | Shared extractor result for `StoreSet` and `StoreRemove`. |
| `StoreBatchPayloads` | MessagePack `Payload` | Extractor result for `StoreBatch`. |
| `PresenceSetRequest` | MessagePack `Payload` | User presence patch payload. |
| `PresenceSetSharedRequest` | MessagePack `Payload` | Shared presence patch payload. |
| `WireError` | public error taxonomy | Encoded error code/message/retry metadata. |
| `QueryResponse` | storage result metadata | Encoded store query/subscription snapshot response. |

## Transport And Encoding

| Property | Contract |
|----------|----------|
| Transport | WebSocket. |
| Frame type | Binary MessagePack frames. |
| Compression | Disabled. |
| Request envelope | MessagePack map with `type: string` and `id: u64`. |
| Response envelope | MessagePack map with `type: "ok"` or `type: "error"` and matching `id`. |
| Push envelope | MessagePack map with a push `type`; no request `id`. |
| Unknown fields | Ignored by decoders unless the owning message requires a stricter shape. |
| Document ids | SDK strings at the API boundary; 16-byte binary ids where the wire format carries typed document ids. |
| Field/table routing | Integer ids from `SchemaSync`; see [Schema Grammar](./schema-grammar.md). |
| Value encoding | Integer-keyed field maps are encoded as pair-arrays: `[[field_index, value], ...]`. See [Value Encoding](#value-encoding). |

## Value Encoding

All values that represent integer-keyed field maps (store documents, presence data, query result rows) are encoded as **pair-arrays** on the wire: a MessagePack array of 2-element arrays.

**Format:** `[[field_index, value], ...]`

- `field_index` — uint, the dense positional index within the table (from `SchemaSync`).
- `value` — the typed MessagePack value, unchanged encoding (same doc-id bin packing, same type coercion). Only the container changes, not the values.

**Affected locations:**

| Location | Direction | Format |
|----------|-----------|--------|
| `StoreSet.value` | C→S | pair-array |
| `StoreBatch` set-op `op[2]` | C→S | pair-array |
| `StoreDelta` set-op `value` | S→C | pair-array |
| Query result row (`ok.value[]`) | S→C | pair-array |
| `PresenceSet.data` | C→S | pair-array |
| `PresenceSetShared.data` | C→S | pair-array |
| `PresenceBroadcast` user `data` | S→C | pair-array |
| `PresenceSubscribe` ok `users[].data` | S→C | pair-array |
| `PresenceSubscribeShared` ok `shared` | S→C | pair-array |
| `SharedStateBroadcast.data` | S→C | always array of pair-array patches |

**Semantics:**

- Duplicate field index in one pair-array: processed in order, last-wins.
- Ordering: pairs are unordered; server/SDK must not assume sorted-by-index.
- Empty `[]`: valid; means no fields.

## Client Messages

All client messages include `type` and `id`. The fields below are additional message-specific fields.

| Message | Fields | Scope/session rule | Responsibility |
|---------|--------|--------------------|----------------|
| `StoreSetNamespace` | `namespace` | Authenticated connection; may run before store scope is ready. | Resolve and activate store namespace/user scope. |
| `StoreSet` | `path`, `value`, optional `confirm`, optional `writeId` | Ready store scope. | Set or merge store data at a path. |
| `StoreRemove` | `path`, optional `confirm`, optional `writeId` | Ready store scope. | Remove a store document/path. |
| `StoreBatch` | `ops`, optional `confirm`, optional `writeId` | Ready store scope. | Apply a bounded atomic batch of set/remove operations. |
| `StoreQuery` | `table_index`, optional query fields | Ready store scope. | Execute a one-shot store query. |
| `StoreSubscribe` | `table_index`, optional query fields | Ready store scope. | Create a live store subscription and return initial snapshot. |
| `StoreLoadMore` | `subId`, `nextCursor` | Ready store scope and known subscription. | Page historical results for an active subscription. |
| `StoreUnsubscribe` | `subId` | Connection-local subscription id. | Stop a store subscription. |
| `AuthRefresh` | `token` | Existing connection. | Refresh base session claims and token expiry. |
| `PresenceSetNamespace` | `namespace` | Authenticated connection; may run before presence scope is ready. | Resolve and activate presence namespace/user scope. |
| `PresenceSet` | `data` | Ready presence scope. | Merge user presence fields. |
| `PresenceSetShared` | `data` | Ready presence scope and shared-write authorization. | Merge namespace shared presence fields. |
| `PresenceSubscribe` | none | Ready presence scope. | Subscribe to user presence and receive snapshot. |
| `PresenceUnsubscribe` | `subId` | Connection-local subscription id. | Stop user-presence updates. |
| `PresenceSubscribeShared` | none | Ready presence scope. | Subscribe to shared presence and receive snapshot. |
| `PresenceUnsubscribeShared` | `subId` | Connection-local subscription id. | Stop shared-presence updates. |
| `PresenceRemove` | none | Ready presence scope. | Remove the connection's user presence. |

Query fields for `StoreQuery` and `StoreSubscribe` are owned by [Query Grammar](./query-grammar.md). Cursor behavior is owned by [Cursor Pagination](./cursor-pagination.md).

## Write Confirmation

| Field/value | Meaning |
|-------------|---------|
| Omitted `confirm` or `confirm: "accepted"` | Server response confirms the mutation was accepted into the write path. |
| `confirm: "committed"` | SDK waits for committed outcome before resolving the mutation. |
| `writeId` | Client-provided write correlation id when the SDK is tracking committed outcome. |
| `WriteCommitted` push | Writer committed the tracked mutation. |
| `WriteError` push | Writer failed the tracked mutation after the immediate accept phase. |

Store subscription state is updated by committed `StoreDelta` pushes, not by optimistic mutation responses.

## Server Responses

| Response | Fields | Meaning |
|----------|--------|---------|
| `ok` | `id` | Generic success. |
| `ok` with `session` | `id`, `session` | Namespace or auth refresh resolved session claims. |
| `ok` query response | `id`, `value`, `nextCursor`; optional `subId`, `hasMore` | One-shot query or store subscription snapshot/page. |
| `ok` presence user snapshot | `id`, `subId`, `users` | Initial user presence snapshot. |
| `ok` presence shared snapshot | `id`, `subId`, `shared` | Initial shared presence snapshot. |
| `error` | `id`, `code`, `message`; optional `retryAfter` | Request failed before a committed async write outcome. |

Public error codes and retry categories are owned by [Error Taxonomy](./error-taxonomy.md).

## Server Pushes

| Push | Fields | Meaning |
|------|--------|---------|
| `Connected` | `userId` | Transport/session bootstrap push after connection setup. |
| `SchemaSync` | `tables`, `fields`, `fieldFlags`, `presenceUserFields`, `presenceSharedFields` | Integer dictionaries used by store, query, and presence messages. |
| `StoreDelta` | `subId`, `ops` | Committed record-level subscription changes. |
| `WriteCommitted` | `writeId` | Tracked write committed. |
| `WriteError` | `writeId`, `code`, `message`, `phase`, optional `batchIndex` | Tracked write failed in writer phase. |
| `ServerDisconnect` | `code`, `message` | Server will close the connection for an unrecoverable session/transport condition. |
| `PresenceBroadcast` | `subId`, `users` | User presence join/update/leave events. |
| `SharedStateBroadcast` | `subId`, `data` | Shared presence patch or batch of patches. |

## Push Payload Notes

- `StoreDelta.ops` contains record-level `set` and `remove` operations. `set` carries the full encoded record; `remove` carries the record path/id.
- `PresenceBroadcast.users` entries include `userId` and `event`. `join` includes `data` and `joinedAt`; `update` includes `data`; `leave` includes neither.
- `SharedStateBroadcast.data` is one patch when a single update is flushed, or an array of patches when several updates are flushed together.
- `SchemaSync` dictionaries are the only source for table/field integer ids. Specs should not repeat generated dictionary contents.

## Scoped Session Rules

- `StoreSetNamespace` and `PresenceSetNamespace` establish independent scoped sessions.
- Store operations before store scope readiness return `SESSION_NOT_READY`.
- Presence operations before presence scope readiness return `SESSION_NOT_READY`.
- A superseded namespace resolution must not activate an older scope.
- When `users.namespaced` forbids cross-namespace switching on a connection, the server returns `NAMESPACE_SWITCH_REJECTED`.

## Extensibility

- Additive fields are allowed when older decoders can safely ignore them.
- New message types must be added to `MessageHandler.classifyMsgType`, `src/wire/decode.zig`, SDK wire code, and this file in the same change.
- New public errors must be added to `src/wire/errors.zig`, `sdk/typescript/src/errors.ts`, and [Error Taxonomy](./error-taxonomy.md).
- Breaking wire changes are acceptable during the current green-field stage, but the docs and SDK must move in the same commit.

## See Also

- [Message Handler](./message-handler.md)
- [Query Grammar](./query-grammar.md)
- [Schema Grammar](./schema-grammar.md)
- [Presence Internals](./presence-internals.md)
- [TypeScript SDK](./typescript-sdk.md)
