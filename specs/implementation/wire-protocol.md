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
| Push envelope | Message-specific MessagePack shape with a numeric push `type` ID; no request `id`. `StoreDelta`, `PresenceBroadcast`, and `SharedStateBroadcast` use compact tuples. |
| Unknown fields | Ignored by decoders unless the owning message requires a stricter shape. |
| Document ids | SDK strings at the API boundary; 16-byte binary ids where the wire format carries typed document ids. |
| Field/table routing | Integer ids from `SchemaSync`; see [Schema Grammar](./schema-grammar.md). |
| Value encoding | Sparse field maps use pair-arrays; complete store records use positional arrays. See [Value Encoding](#value-encoding). |

## Value Encoding

Sparse field maps are encoded as **pair-arrays** so omitted fields retain their meaning.

**Sparse format:** `[[field_index, value], ...]`

- `field_index` — uint, the dense positional index within the table (from `SchemaSync`).
- `value` — the typed MessagePack value, unchanged encoding.
- Pairs are unordered, duplicate indices are processed in order with last-wins semantics, and empty `[]` means no fields.

Complete server-to-client store records are encoded as **positional arrays**.

**Complete-record format:** `[value_0, value_1, ...]`

- Position `i` maps to `SchemaSync.fields[table_index][i]`.
- Every schema field appears exactly once, including system fields.
- The array length must exactly equal the schema field count.
- Nullable fields are present as MessagePack `nil`; they are never omitted.
- Typed value encoding is unchanged, including document-id packing and type coercion.

**Affected locations:**

| Location | Direction | Format |
|----------|-----------|--------|
| `StoreSet.value` | C→S | pair-array |
| `StoreBatch` set-op `op[2]` | C→S | pair-array |
| `StoreDelta` set payload | S→C | complete positional record |
| Query/subscription/load-more result row (`ok.value[]`) | S→C | complete positional record |
| `PresenceSet.data` | C→S | pair-array |
| `PresenceSetShared.data` | C→S | pair-array |
| `PresenceBroadcast` user `data` | S→C | pair-array |
| `PresenceSubscribe` ok `users[].data` | S→C | pair-array |
| `PresenceSubscribeShared` ok `shared` | S→C | pair-array |
| `SharedStateBroadcast patches` | S→C | always array of pair-array patches |

## Message Type Registry

Every top-level message carries a fixed numeric `type` ID. The registry is the
single source of truth shared by the Zig enum (`src/wire/message_type.zig`),
the SDK registry (`sdk/typescript/src/connection_wire.ts`), and this spec.
All IDs are ≤ `0x7f` so MessagePack encodes them as a one-byte positive
fixint.

| ID | Name | Direction | Purpose |
|----|------|-----------|---------|
| `0x00` | `ok` | S→C | Successful correlated response. |
| `0x01` | `error` | S→C | Failed correlated or uncorrelated response. |
| `0x02` | `Ping` | C→S | Application-level liveness probe. |
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
| `0x30` | `ActionCall` | C→S | Invoke an action. |
| `0x31` | `ActionForward` | S→W | Forward an action call to a registered worker. |
| `0x32` | `ActionReply` | W→S | Worker reply to a synchronous action call. |
| `0x33` | `ActionRegister` | W→S | Advertise handled actions. |

**Direction rules:** server-only IDs (`0x00`–`0x01`, `0x03`, `0x05`,
`0x18`–`0x1a`, `0x28`–`0x29`, `0x31`) received as client requests are rejected
with `INVALID_MESSAGE_TYPE`. `0x02` (`Ping`), `0x04` (`AuthRefresh`), and
`0x30` (`ActionCall`) are client requests. `0x32` (`ActionReply`) is accepted
only from the worker the call was forwarded to; `0x33` (`ActionRegister`) is
accepted from any client whose `$session` passes the action `register` rule.
Unknown or unassigned IDs are rejected the same way.
Legacy string `type` values fail envelope decoding with
`INVALID_MESSAGE_FORMAT`. Map-form messages retain the string `"type"` key;
only its value is numeric. `StoreDelta`, `PresenceBroadcast`,
`SharedStateBroadcast`, and `ActionForward` use the fixed tuples described below.

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
| `ActionCall` | `action_id`, optional `timeoutMs`, `params` | Ready bound scope (store or presence per the action's schema `scope`) and `invoke` authorization. | Invoke an action. |
| `AuthRefresh` | `token` | Existing connection. | Refresh base session claims and token expiry. |
| `Ping` | *(none)* | Established connection; requires no scope. | Liveness probe. Answered with `ok`. |
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
| `ok` presence scope | `id`, `userId` | Successful `PresenceSetNamespace`; `userId` is the mandatory bin16 internal `users.id` used by presence snapshots and broadcasts. |
| `ok` with `session` | `id`, `session` | Namespace or auth refresh resolved session claims. |
| `ok` query response | `id`, `value`, `nextCursor`; optional `subId`, `hasMore` | One-shot query or store subscription snapshot/page. |
| `ok` presence user snapshot | `id`, `subId`, `users` | Initial user presence snapshot. |
| `ok` presence shared snapshot | `id`, `subId`, `shared` | Initial shared presence snapshot. |
| `ok` sync action response | `id`, `value` | Synchronous `ActionCall` result; `value` is the validated returns pair-array. |
| `error` | `id` (omitted when uncorrelated), `code`, `message`; optional `retryAfter` | Request failed before a committed async write outcome, or a proactive uncorrelated server notification (see [Token Expiry Notification](#token-expiry-notification)). |

Public error codes and retry categories are owned by [Error Taxonomy](./error-taxonomy.md).

## Server Pushes

| Push | Fields | Meaning |
|------|--------|---------|
| `SchemaSync` | `tables`, `fields`, `fieldFlags`, `presenceUserFields`, `presenceSharedFields`, `actions`, `actionParams`, `actionReturns`, `actionFlags` | Integer dictionaries used by store, query, presence, and action messages. Action arrays are parallel: `actions[i]` is the action name, `actionParams[i]`/`actionReturns[i]` are its flattened param/return field names (empty for no params / async), and `actionFlags[i]` bit 0 marks sync (has `returns`), bit 1 marks presence scope. |
| `StoreDelta` | Fixed tuple (below) | Committed record-level subscription change. |
| `WriteCommitted` | `writeId` | Tracked write committed. |
| `WriteError` | `writeId`, `code`, `message`, `phase`, optional `batchIndex` | Tracked write failed in writer phase. |
| `ServerDisconnect` | `code`, `message` | Server will close the connection for an unrecoverable session/transport condition. Sent before every server-initiated close; `code` is owned by [Error Taxonomy → Disconnect Codes](./error-taxonomy.md#disconnect-codes). |
| `PresenceBroadcast` | Fixed tuple (below) | User presence join/update/leave events. |
| `SharedStateBroadcast` | Fixed tuple (below) | Shared presence patch or batch of patches. |

## Push Payload Notes

- `StoreDelta` uses the fixed five-element tuple `[0x18, subId, opTag, tableIndex, payload]`. `opTag` is `0` for `set` and `1` for `remove`. A `set` payload is a complete positional record whose document ID is at position zero; a `remove` payload is the typed document ID. Each push carries exactly one record operation. The SDK expands the tuple to the public `{ type: "StoreDelta", subId, ops: [...] }` shape. Map-form messages, old six-element tuples, partial records, and records with the wrong field count are invalid.
- `PresenceBroadcast` uses the exact three-element tuple `[0x28, subId, entries]`. Each entry is one exact variable-arity tuple: join `[userId, 0, data, joinedAt]`, update `[userId, 1, data]`, or leave `[userId, 2]`. Event tags `0`, `1`, and `2` are permanent protocol values. `userId` is MessagePack `bin16`; `data` is a pair-array; join `joinedAt` is a non-negative JavaScript-safe integer. Map-form presence broadcasts, string event names, extra fields, and tag/arity mismatches are invalid.
- `SharedStateBroadcast` uses the exact three-element tuple `[0x29, subId, patches]`. Every element of `patches` is a pair-array patch, including when only one update is flushed. Map-form shared-state broadcasts are invalid.
- Presence push `subId` values are non-negative JavaScript-safe integers. Empty `entries` and `patches` arrays are structurally valid.
- `SchemaSync` dictionaries are the only source for table/field integer ids. Specs should not repeat generated dictionary contents.

## Action Messages

- `ActionCall` is a map request `{type: 0x30, id, action_id, timeoutMs?, params}`. `id` is the client envelope id used for the correlated response; `timeoutMs` is a non-negative integer or omitted and may only shorten the server deadline; `params` is a pair-array of `[field_index, value]` pairs.
- `ActionForward` uses the fixed five-element tuple `[0x31, execId, userId, actionId, paramsPairArray]`. `execId` is minted by the server for this execution and is the only cross-connection correlation key; `userId` is `bin16` from the action's bound scope.
- `ActionReply` is a map message `{type: 0x32, id, execId, ok, payload}`. When `ok` is `true`, `payload` is a pair-array of return fields. When `ok` is `false`, `payload` is an error tuple `[code, message]`. The `id` satisfies the standard client envelope but the server does not answer `ActionReply`. The server accepts a reply only from the worker the call was forwarded to; unknown or foreign replies are discarded. Workers send `ActionReply` only for synchronous actions; a reply received for an asynchronous execution id is discarded.
- `ActionRegister` is a map request `{type: 0x33, id, action_ids}`. `action_ids` is an array of registered action ids. Registration is correlated with `id` and answers `ok` or `error` (for example `SESSION_NOT_READY` or `PERMISSION_DENIED`). The bound scope and namespace are derived from the schema and the worker's resolved scopes; they are not carried on the wire.
- `0x31` is a server-only message type. Application clients sending it are rejected with `INVALID_MESSAGE_TYPE`.
- `0x32` (`ActionReply`) is accepted only from the worker the call was forwarded to.
- `0x33` (`ActionRegister`) is accepted from any client whose `$session` passes the action `register` rule.
- A synchronous `ActionCall` success responds `ok` with `value` set to the validated returns pair-array. Return-payload validation failures reject the caller's pending call with `SCHEMA_VALIDATION_FAILED`; a worker error tuple rejects it with the carried code.

## Scoped Session Rules

- `StoreSetNamespace` and `PresenceSetNamespace` establish independent scoped sessions.
- Store operations before store scope readiness return `SESSION_NOT_READY`.
- Presence operations before presence scope readiness return `SESSION_NOT_READY`.
- Action calls and registrations require the action's bound scope (store or presence per the schema `scope`) to be ready; otherwise they return `SESSION_NOT_READY`.
- Every successful `PresenceSetNamespace` returns the active internal `users.id` as bin16; the SDK uses that canonical UUID for self-filtering.
- External JWT and anonymous subjects remain server-internal after ticket exchange and are not sent over WebSocket.
- A superseded namespace resolution must not activate an older scope.
- When `users.namespaced` forbids cross-namespace switching on a connection, the server returns `NAMESPACE_SWITCH_REJECTED`.

## Liveness Probing

A transport can be open yet unable to carry traffic, and no data message reveals it (ADR-015). Detection is split by direction because neither side's signal reaches the other.

**Server side.** uWebSockets emits a WebSocket PING once a connection has been idle past a margin derived from the idle timeout, and force-closes when no PONG arrives. Clients answer PING at the protocol layer, so this needs no cooperation from them.

**Client side.** A browser cannot emit a PING frame: `WebSocket` exposes no `ping()`, and a send on a broken path buffers locally and resolves. The client probes with `Ping` instead.

- `Ping` is correlated like every other client message. The server answers `ok` with no additional fields, and the reply is itself the proof of life. It is never answered with `error` under normal operation.
- The SDK never retries a probe. A retry would mask a dead connection behind its own backoff instead of detecting it.
- Any inbound frame satisfies the probe, not only the `ok`. A connection receiving deltas is demonstrably alive and is not probed on top of that traffic.
- `Ping` requires an established connection but no resolved scope, so it is answerable while store or presence scope is still resolving, and before it.
- `Ping` is ordinary client traffic for rate-limiting purposes. It does not bypass the per-connection token bucket.

## Token Expiry Notification

Token expiry is signalled in two steps, so a client can replace its token without losing the connection.

1. **Notification.** When a token expires, the server sends an `error` carrying `TOKEN_EXPIRED`. It is **uncorrelated** — `id` is omitted, because no request is being answered and the message must not resolve or reject an unrelated pending request. The connection stays open.
2. **Refresh window.** The client answers with `AuthRefresh`, which updates the session in place; active scopes continue without interruption. The window is bounded by the server's configured `tokenGracePeriodSeconds`.
3. **Termination.** Only if no valid replacement arrives within the window — no provider, a rejected refresh, or a timeout — does the server send `ServerDisconnect` with code `TOKEN_EXPIRED` and close with `4001`.

The notification is therefore the normal path and the disconnect is the fallback. A client that has no way to obtain a token receives the notification, cannot act on it, and is terminated when the window closes.

## Close Codes

Server-initiated closes carry a WebSocket close code in addition to the `ServerDisconnect` message. Both are specified because the in-band message is best-effort: a connection already over its backpressure limit may drop the frame, leaving the close code as the only signal.

| Close code | Meaning | `ServerDisconnect` code |
|------------|---------|--------------------------|
| `4001` | Authentication or session token is no longer valid. `TOKEN_EXPIRED` reaches this only after the refresh window closes. | `AUTH_FAILED` / `TOKEN_EXPIRED` |
| `4002` | Server is draining or restarting. | `SERVER_SHUTDOWN` |
| `4003` | Connection exceeded the server's idle deadline. | `IDLE_TIMEOUT` |
| `4004` | Outbound buffer exceeded the per-connection limit. | `BACKPRESSURE_LIMIT` |
| `4005` | Server connection cap reached. | `MAX_CONNECTIONS` |

`4000`–`4999` is the private-use range, so these cannot collide with codes assigned by the WebSocket specification. A close code outside this set was not produced by ZyncBase — a proxy, load balancer, or the peer sent it — and must not be interpreted as a ZyncBase reason.

Client-initiated closes carry no ZyncBase code. A client closing its own socket already knows why, and one would imply a server-originated reason it did not produce.

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
