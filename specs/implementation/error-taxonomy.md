# Error Taxonomy

This file is the canonical public error catalog for implementation docs. Other implementation specs may mention local Zig errors when describing control flow, but they should link here for public codes and retry behavior instead of duplicating tables.

## Source Files

- `src/wire/errors.zig` owns server-side mapping from Zig errors to public wire codes.
- `sdk/typescript/src/errors.ts` owns the SDK `ErrorCodes`, category derivation, retryability, and `ZyncBaseError` shape.
- `src/wire/encode.zig` owns the encoded error response and write-error push payloads.
- `src/message_handler.zig` owns request error propagation for WebSocket operations.

## Public Error Object

All server errors are encoded as a normal wire error response or a write-error push:

| Field | Meaning |
|-------|---------|
| `code` | Stable uppercase public code from this catalog. |
| `message` | Human-readable diagnostic. Not a stable parsing target. |
| `retryAfter` | Optional retry delay in milliseconds, currently used by rate limiting. |
| `phase` | Present on `WriteError` pushes; currently `"write"`. |
| `batchIndex` | Optional on `WriteError` pushes when a failing batch operation can be identified. |

SDK errors are surfaced as `ZyncBaseError` with `code`, `message`, `category`, `retryable`, optional `retryAfter`, optional `requestId`, and optional SDK-local `details`.

## Categories

| Category | Retryable | Owner | Notes |
|----------|-----------|-------|-------|
| `authentication` | No | Server + SDK | Token/ticket/session identity problems. The caller must refresh or reconnect. |
| `authorization` | No | Server + SDK | Authorization rules denied access. |
| `state` | No | Server + SDK | Scope, namespace, or subscription state is not valid for the request. |
| `validation` | No | Server + SDK | Request payload, path, schema, query, or message format is invalid. |
| `client` | No | SDK + server limits | Client-side path/batch/size issues. |
| `rate_limit` | Yes | Server + SDK | SDK may retry after `retryAfter`; callers can opt out. |
| `server` | Yes | Server + SDK | Bounded retry only; persistent failures are operational issues. |
| `network` | Yes | SDK | Local WebSocket/connectivity failures before a server error exists. |
| `unknown` | No | SDK | Fallback for unrecognized codes. Treat as non-retryable until classified. |

## Public Catalog

| Code | Category | Origin | Meaning |
|------|----------|--------|---------|
| `AUTH_FAILED` | `authentication` | Server | Identity verification failed or the connection lacks required external identity. |
| `TOKEN_EXPIRED` | `authentication` | Server | Session token expired. The client is notified and may replace the token in place before the connection is terminated. |
| `NAMESPACE_UNAUTHORIZED` | `authorization` | Server | Namespace-level authorization denied access. |
| `PERMISSION_DENIED` | `authorization` | Server | Store, presence, or action rule denied the operation. |
| `SESSION_NOT_READY` | `state` | Server | Store/presence operation arrived before the required scoped session was ready. |
| `REQUEST_SUPERSEDED` | `state` | Server | A newer scope request superseded in-flight work (scope resolution or a pending action call). |
| `NAMESPACE_SWITCH_REJECTED` | `state` | Server | Namespace switching is forbidden for the active `users.namespaced` model. |
| `SUBSCRIPTION_NOT_FOUND` | `state` | Server | Requested subscription id is not known for the connection. |
| `NO_ACTION_WORKER` | `state` | Server | No connected worker is registered for the action in the bound scope and namespace. |
| `COLLECTION_NOT_FOUND` | `validation` | Server | Store table/collection is not present in the loaded schema. |
| `FIELD_NOT_FOUND` | `validation` | Server | Referenced field is not present in the table schema. |
| `IMMUTABLE_FIELD` | `validation` | Server | Request attempted to write a protected system field. |
| `SCHEMA_VALIDATION_FAILED` | `validation` | Server | Value failed type, constraint, or required-field validation. |
| `UNIQUE_CONSTRAINT_VIOLATED` | `validation` | Server | Write collided with a schema-declared unique constraint in the row's effective namespace. Non-retryable; the client must change the value. Observable only on `confirm: "committed"` writes — default accepted writes give no writer-failure guarantee (see ADR-018). Constraint names are not included in the payload. |
| `INVALID_FIELD_NAME` | `validation` | Server | Field name contains a forbidden sequence or identifier shape. |
| `INVALID_ARRAY_ELEMENT` | `validation` | Server | Array field contains a nested array/object or other unsupported element. |
| `INVALID_MESSAGE` | `validation` | Server | Request payload is malformed for the selected message type. |
| `INVALID_MESSAGE_FORMAT` | `validation` | Server | MessagePack envelope or required scalar field is malformed/missing. |
| `INVALID_MESSAGE_TYPE` | `validation` | Server | Transport frame or message type is unsupported. |
| `INVALID_PATH` | `client` | SDK | Client path parsing failed before the request was sent. |
| `BATCH_TOO_LARGE` | `client` | Server + SDK | Batch exceeds the configured maximum operation count. |
| `MESSAGE_TOO_LARGE` | `client` | Server + SDK | Payload exceeded configured parser or message-size limits. |
| `RATE_LIMITED` | `rate_limit` | Server | Per-connection request token bucket rejected the message. |
| `MAX_CONNECTIONS` | `rate_limit` | Server | Server connection cap reached; the connection was not accepted. |
| `ACTION_TIMEOUT` | `server` | Server | Sync action worker failed to reply before the server deadline. The action may still execute; action calls are never auto-retried. |
| `WORKER_DISCONNECTED` | `server` | Server | Worker disconnected while processing a sync action. The action may have partially executed; action calls are never auto-retried. |
| `INTERNAL_ERROR` | `server` | Server | Unclassified internal failure. This is a bug or operational problem. |
| `ENGINE_UNHEALTHY` | `server` | Server | Storage/write engine is degraded and cannot complete the request now. |
| `SERVER_SHUTDOWN` | `server` | Server | Server is draining or restarting and closed the connection. |
| `CONNECTION_FAILED` | `network` | SDK | WebSocket connection failed or closed unexpectedly. |
| `IDLE_TIMEOUT` | `network` | Server | Connection exceeded the server's idle deadline and was closed. |
| `BACKPRESSURE_LIMIT` | `network` | Server | Outbound buffer exceeded the per-connection limit; the peer is not consuming fast enough. |
| `TIMEOUT` | `network` | SDK | Pending request exceeded the SDK timeout. |

## Disconnect Codes

`ServerDisconnect` carries a code the client is expected to *act* on rather than display. Its `code` is a closed subset of the [Public Catalog](#public-catalog) — a disconnect never introduces a code absent from that table, so a connection has one error vocabulary rather than one for requests and another for teardown.

The server sends `ServerDisconnect` and then closes. That send is **best-effort**: a connection already over its backpressure limit may drop the frame. The WebSocket close code is therefore the authoritative signal, and both channels are specified to carry the same information so a client can always determine why it was disconnected. Close codes are defined in [Wire Protocol → Close Codes](./wire-protocol.md#close-codes).

| `ServerDisconnect` code | Close code | Retryable | Client behavior |
|-------------------------|-----------|-----------|-----------------|
| `AUTH_FAILED` | `4001` | No | Credentials are broken; reconnecting fails identically until they change. Stop retrying and surface an auth error. |
| `TOKEN_EXPIRED` | `4006` | No | Reached only after the refresh window closed without a replacement — no provider, a rejected refresh, or a timeout. Terminal: the socket is already gone, so the client reconnects with a fresh ticket. |
| `SERVER_SHUTDOWN` | `4002` | Yes | The server is draining. Reconnect on the standard backoff. |
| `IDLE_TIMEOUT` | `4003` | Yes | The connection was silent too long. Reconnect. |
| `BACKPRESSURE_LIMIT` | `4004` | Yes | The client is not consuming fast enough. Reconnect, but reduce subscription fan-out or the condition recurs on replay. |
| `MAX_CONNECTIONS` | `4005` | Yes | The server is at capacity. Reconnect on the standard backoff. |

Any other `ServerDisconnect` code is treated as `INTERNAL_ERROR`: not retryable, and a bug or operational problem on the server.

`retryable` states whether the SDK reconnects on the normal backoff, not whether the cause is resolved. A retryable close can recur if its cause is unchanged — most obviously `BACKPRESSURE_LIMIT`, where replaying the same subscriptions reproduces the condition — so an application may still need to change something after reconnecting.

Not every server-initiated close is classified. ZyncBase checks idleness itself and emits `ServerDisconnect` with `IDLE_TIMEOUT` before the transport can act, but the transport's own reaper is a backstop for peers that check does not catch. It ends in a raw socket close with no WebSocket close frame, so such a close delivers no code and no reason, and surfaces as `CONNECTION_FAILED`.

`ServerDisconnect` carries no `retryAfter`; its payload is exactly `code` and `message`. Capacity and rate signals pace a reconnecting client through the SDK's backoff schedule rather than a server-supplied delay.

## Internal Error Mapping Rules

- Internal Zig errors are not public API. They map to the closest public code in `src/wire/errors.zig`.
- Parser limit failures currently map to `MESSAGE_TOO_LARGE` or `INVALID_MESSAGE_FORMAT`; do not document separate public MessagePack limit codes unless they are added to `src/wire/errors.zig` and the SDK.
- SQLite, cache, checkpoint, and allocator failures are operational/internal details. They should map to `ENGINE_UNHEALTHY` or `INTERNAL_ERROR` unless a user-facing public error code is intentionally added.
- Authorization failures map to `NAMESPACE_UNAUTHORIZED` only for namespace admission. Store, presence, and action operation denials map to `PERMISSION_DENIED`.
- Write acknowledgement failures use the same code catalog inside `WriteError` pushes; top-level `phase` and optional `batchIndex` fields explain where the failure happened.

## Propagation

- Synchronous request failures: `MessageHandler.handleMessage` catches the Zig error, converts it with `wire.getWireError`, and sends an error response with the request id.
- Asynchronous scope resolution failures: background resolution checks `scope_seq`; superseded work reports `REQUEST_SUPERSEDED` or is dropped if no longer relevant.
- Deferred write failures: the write path emits `WriteError` when the request asked for committed acknowledgement and storage fails after the immediate request phase.
- Local SDK failures: the SDK creates `ZyncBaseError` directly for path validation, timeout, and connection failures.
- Token expiry is signalled twice: an uncorrelated `error` carrying `TOKEN_EXPIRED` when the token expires, which resolves no pending request, and a `ServerDisconnect(TOKEN_EXPIRED)` only if the refresh window closes without a replacement. The SDK treats the first as `tokenExpired` and the second as a terminal disconnect.
- Disconnects: the server encodes `ServerDisconnect` with a code from [Disconnect Codes](#disconnect-codes) and closes the connection, on the event loop or from a timer sweep. A failed send is logged and the close proceeds, leaving the close code authoritative. The SDK surfaces the code as a `ZyncBaseError` and rejects the connection's pending requests with it.

## Retry Policy

| Category | SDK auto-retry | User action |
|----------|----------------|-------------|
| `network` | Yes | None unless reconnect keeps failing. |
| `rate_limit` | Yes, honoring `retryAfter` when available | Reduce request rate if sustained. |
| `server` | Bounded retry | Inspect server health if persistent. |
| `authentication` | No | Refresh credentials or reconnect. |
| `authorization` | No | Fix rules, namespace, or caller identity. |
| `state` | No | Wait for scope readiness, resubscribe, or reconnect depending on the code. |
| `validation` | No | Fix request shape/schema/query. |
| `client` | No | Fix SDK call site or reduce payload/batch size. |

Action call results are never auto-retried by the SDK, regardless of category: a retried call may already have executed. Retry policy for actions is an application decision.

## Related Specifications

- [Wire Protocol](./wire-protocol.md) - Error response and `WriteError` push shape.
- [Message Handler](./message-handler.md) - Request propagation path.
- [TypeScript SDK](./typescript-sdk.md) - SDK error object and pending request handling.
- [ADR-019](../architecture/adrs.md#adr-019-error-taxonomy-and-sdk-error-handling) - Error taxonomy decision.
