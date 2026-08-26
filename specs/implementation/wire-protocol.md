# Wire Protocol

**Drivers**: [ADR-008](../architecture/adrs.md#adr-008-wire-encoding), [ADR-009](../architecture/adrs.md#adr-009-integer-routing-architecture), [ADR-014](../architecture/adrs.md#adr-014-unified-subscription-engine), [ADR-018](../architecture/adrs.md#adr-018-mutation-acknowledgement-and-consistency-semantics), [ADR-020](../architecture/adrs.md#adr-020-typed-two-tier-presence-system)

This document is the canonical implementation contract for ZyncBase's WebSocket messages. It names the message types, stable fields, source files, and routing rules. Detailed query operators, schema dictionaries, and public error codes live in their owner specs.

## Design Principles

- **1:1 SDK mapping** — Every client SDK method maps to exactly one message type. No overloaded messages.
- **Correlate by ID** — Every client request has a unique `id`. The server response echoes it.
- **Pushes are unsolicited** — Server-initiated messages (subscription deltas, presence broadcasts) have their own types and do not carry a request `id`.
- **Spec and SDK move together** — Wire changes are allowed in the green-field stage, but server, SDK, tests, and this spec must be updated together.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/wire/*.zig` | Public wire module facade and wire submodules. |
| `src/wire/decode.zig` | MessagePack envelope and request extractors. |
| `src/wire/encode.zig` | Response, schema sync, subscription delta, write outcome, and presence encoders. |
| `src/wire/errors.zig` | Internal Zig error to public wire-code mapping. |
| `src/wire/comptime.zig` | Compile-time MessagePack key/value encoding helpers. |
| `src/wire/msgpack_skip.zig`, `src/msgpack_utils.zig` | MessagePack skip helpers, parser limits, and low-level decoding utilities. |
| `src/typed/doc_id.zig` | 16-byte document id packing and parsing used by binary wire fields. |
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
| Request envelope | MessagePack map with `type: u8` (numeric message type ID, one-byte positive fixint) and `id: u64`. |
| Response envelope | MessagePack map with `type: 0x00` (`ok`) or `type: 0x01` (`error`) and matching `id`. |
| Push envelope | MessagePack map with a numeric push `type` ID; no request `id`. |
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

## Message Type Registry

Every top-level message carries a fixed numeric `type` ID. The registry is the
single source of truth shared by the Zig enum (`src/wire/message_type.zig`),
the SDK registry (`sdk/typescript/src/connection_wire.ts`), and this spec.
All IDs are ≤ `0x7f` so MessagePack encodes them as a one-byte positive
fixint. **Never reuse or renumber an assigned ID.**

| ID | Name | Direction | Purpose |
|----|------|-----------|---------|
| `0x00` | `ok` | S→C | Successful correlated response. |
| `0x01` | `error` | S→C | Failed correlated or uncorrelated response. |
| `0x02` | `Connected` | S→C | Connection/session bootstrap. |
| `0x03` | `SchemaSync` | S→C | Schema dictionary bootstrap. |
| `0x04` | `AuthRefresh` | C→S | Refresh connection authentication. |
| `0x05` | `ServerDisconnect` | S→C | Structured disconnect reason. |
| `0x10` | `StoreSetNamespace` | C→S | Establish store scope. |
| `0x11` | `StoreSet` | C→S | Set a document or field. |
| `0x12` | `StoreRemove` | C→S | Remove a document or field. |
| `0x13` | `StoreBatch` | C→S | Apply a write batch. |
| `0x14` | `StoreQuery` | C→S | Execute a one-shot query. |
| `0x15` | `StoreSubscribe` | C→S | Start a live query. |
| `0x16` | `StoreUnsubscribe` | C→S | Stop a live query. |
| `0x17` | `StoreLoadMore` | C→S | Page an active query. |
| `0x18` | `StoreDelta` | S→C | Push committed subscription changes. |
| `0x19` | `WriteCommitted` | S→C | Confirm a tracked write. |
| `0x1a` | `WriteError` | S→C | Fail a tracked write. |
| `0x20` | `PresenceSetNamespace` | C→S | Establish presence scope. |
| `0x21` | `PresenceSet` | C→S | Update user presence. |
| `0x22` | `PresenceSetShared` | C→S | Update shared presence state. |
| `0x23` | `PresenceSubscribe` | C→S | Subscribe to user presence. |
| `0x24` | `PresenceUnsubscribe` | C→S | Unsubscribe from user presence. |
| `0x25` | `PresenceSubscribeShared` | C→S | Subscribe to shared state. |
| `0x26` | `PresenceUnsubscribeShared` | C→S | Unsubscribe from shared state. |
| `0x27` | `PresenceRemove` | C→S | Remove user presence. |
| `0x28` | `PresenceBroadcast` | S→C | Push user presence changes. |
| `0x29` | `SharedStateBroadcast` | S→C | Push shared state changes. |

**Direction rules:** server-only IDs (`0x00`–`0x03`, `0x05`, `0x18`–`0x1a`,
`0x28`–`0x29`) received as client requests are rejected with
`INVALID_MESSAGE_TYPE`. `0x04` (`AuthRefresh`) is a client request; unknown or
unassigned IDs are rejected the same way.
Legacy string `type` values fail envelope decoding with
`INVALID_MESSAGE_FORMAT`. The map key remains the string `"type"`; only the
value is numeric.

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
| `StoreLoadMore` | `subId`, `nextCursor`, optional `table_index` | Ready store scope and known subscription. | Page historical results for an active subscription. The server resolves the retained query by `subId`; SDKs may include `table_index` as response-context metadata. |
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

Query fields for `StoreQuery` and `StoreSubscribe` are owned by [Query Grammar](./query-grammar.md). `orderBy` is an ordered array of positional sort tuples, `[[field_index, desc_flag], ...]`; array order defines precedence. Cursor behavior is owned by [Cursor Pagination](./cursor-pagination.md).

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
- New message types must be added to `MessageType` (`src/wire/message_type.zig`), the message routing switch in `src/message_handler.zig`, the SDK registry in `sdk/typescript/src/connection_wire.ts`, this file, and the [Message Type Registry](#message-type-registry) in the same change.
- New public errors must be added to `src/wire/errors.zig`, `sdk/typescript/src/errors.ts`, and [Error Taxonomy](./error-taxonomy.md).
- Breaking wire changes are acceptable during the current green-field stage, but the docs and SDK must move in the same commit.

## Related Specifications

- [Message Handler](./message-handler.md)
- [Query Grammar](./query-grammar.md)
- [Schema Grammar](./schema-grammar.md)
- [Presence Internals](./presence-internals.md)
- [TypeScript SDK](./typescript-sdk.md)
