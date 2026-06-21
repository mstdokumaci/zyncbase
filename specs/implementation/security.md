# Security

**Drivers**: [ADR-016](../architecture/adrs.md#adr-016-authentication-authorization-and-the-trust-boundary), [ADR-015](../architecture/adrs.md#adr-015-scoped-session-management), [Auth Exchange](./auth-exchange.md), [Auth System](./auth-system.md), [Error Taxonomy](./error-taxonomy.md)

Security is layered: transport admission, parser/resource limits, authentication, scoped session resolution, authorization, and teardown all fail closed. Client and SDK checks are convenience only; server-side validation is authoritative.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/config_loader.zig` | Security config values such as origins, message limits, and rate limits. |
| `src/uwebsockets_wrapper.zig`, `src/uws_bridge.cpp` | Transport callbacks and origin/frame admission surface. |
| `src/message_handler.zig` | Rate limiting, parser error handling, scoped session gate, and error propagation. |
| `src/connection/violations.zig` | Repeated malformed/security-violation tracking. |
| `src/connection/ticket_exchange.zig` | HTTP ticket exchange and session projection. |
| `src/jwt_validator.zig` | JWT/JWKS validation and key caching. |
| `src/authorization/*` | Namespace, store, write, read, and presence authorization. |
| `src/wire/decode.zig` | Envelope/request extraction and message shape validation. |
| `src/msgpack_utils.zig` | MessagePack decoding limits and helpers. |

## Security Layers

| Layer | Owner | Rule |
|-------|-------|------|
| Transport admission | networking wrapper/server config | Accept only configured WebSocket endpoint/origins and binary frames. |
| Parser limits | `msgpack_utils`, `wire/decode` | Reject malformed, oversized, or deeply nested payloads before domain routing. |
| Rate limiting | `MessageHandler`, `Connection` | Apply per-connection token bucket before envelope routing. |
| Authentication | `ticket_exchange`, `jwt_validator` | Trust only validated tickets/tokens and projected session claims. |
| Scoped session | `Connection`, `SessionResolver` | Store/presence operations require resolved namespace/user scope. |
| Authorization | `authorization/*` | Namespace/read/write/presence checks are server-side and fail closed. |
| Teardown | `MessageHandler`, `ConnectionManager`, presence/subscriptions | Disconnect removes connection-owned state and subscriptions. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `ConnectionViolationTracker` | connection id | Counts repeated malformed/security-sensitive messages and triggers close threshold. |
| `JwtValidator` | JWKS cache, validation config | Validates token issuer/audience/signature/expiration. |
| `TicketExchange` | JWT validator, session mapping | Converts a validated HTTP auth request into a short-lived WebSocket ticket/session. |
| `AuthConfig` | schema, authorization parser | Runtime authorization rule set from `authorization.json`. |
| `EvalContext` | session, namespace, record/document values | Resolves authorization operands and conditions. |
| `ReadAuthInput` / `WriteAuthInput` | query/schema/session data | Builds read predicates and write authorization decisions. |

## Fail-Closed Rules

- Missing auth configuration or missing namespace/store rule denies access unless an explicit default rule says otherwise.
- Store operations require store scope readiness; presence operations require presence scope readiness.
- Namespace switching is rejected for incompatible `users.namespaced` scope.
- Authorization predicate lowering failure denies the operation.
- Unknown fields, invalid operators, and schema mismatches fail before storage mutation.
- Public error codes and retry behavior are centralized in [Error Taxonomy](./error-taxonomy.md).

## Resource Limits

- Message size/depth/string/array/map limits are parser concerns, not domain concerns.
- Rate limiting returns a public `RATE_LIMITED` error with optional `retryAfter`.
- Repeated malformed/security-sensitive payloads close the connection.
- Allocator exhaustion is treated as request/server failure, never as partial authorization success.

## See Also

- [Auth Exchange](./auth-exchange.md)
- [Auth System](./auth-system.md)
- [Auth Grammar](./auth-grammar.md)
- [Message Handler](./message-handler.md)
