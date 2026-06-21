# Authentication Exchange

**Drivers**: [ADR-015](../architecture/adrs.md#adr-015-scoped-session-management), [ADR-016](../architecture/adrs.md#adr-016-authentication-authorization-and-the-trust-boundary), [Memory Strategy](./memory-strategy.md), [Security](./security.md)

ZyncBase acts as a **resource server**, not an identity provider. It validates incoming credentials (JWTs or anonymous subjects), projects trusted claims into `$session`, issues short-lived connection tickets, and executes authorization natively in Zig.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/connection/ticket_exchange.zig` | Generates, parses, and validates single-use auth tickets. |
| `src/jwt_validator.zig` | JWT validation, signature verification, and JWKS metadata retrieval. |
| `src/server.zig` | Gathers credentials via HTTP `/auth/ticket` and upgrade query string. |
| `src/authorization.zig` | Evaluates `$session` variables against current permission states. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `TicketExchange` | cryptographic keys, allocator | Manages single-use tickets, tracking issued and spent states. |
| `Session` | allocator | Holds projected JWT claims, authentication scopes, and user identities. |
| `JWTClaims` | JSON parser | Decoded structure containing external subject, tenant, role, and custom scopes. |

---

## The `$session` Context

`$session` is the unified source of truth for ZyncBase-side authorization. Rules never inspect raw JWTs directly.
- **JWT source**: Configured claim projection from a validated external JWT.
- **Anonymous source**: SDK-generated high-entropy subject with `isAnonymous = true`.
- **Identity**: `$session.userId` is always the internal `users.id` resolved through SQLite, never a raw JWT subject or anonymous subject.
- **Persistence**: Fixed for a resolved scope until auth refresh or namespace switching requires re-resolution.

---

## Connection Lifecycle Steps

| Step | Protocol & Endpoint | Request Payload / Header | Response Payload / Output | Action / Validation |
|:---|:---|:---|:---|:---|
| **1. Ticket Request (JWT)** | `POST /auth/ticket` | `Authorization: Bearer <external_jwt>` | `{"ticket": "zyc_tk_...", "expiresAt": 1741551234}` | Validates JWT (signature, issuer, aud, exp, algorithms). Projects claims. |
| **1. Ticket Request (Anon)** | `POST /auth/ticket` | `{"anonymousSubject": "anon:6c6f8b0d..."}` | `{"ticket": "zyc_tk_...", "expiresAt": 1741551234}` | Checks if anonymous auth is enabled. Validates subject entropy. |
| **2. WebSocket Upgrade** | `ws://server/ws?ticket=zyc_tk_...` | Ticket in query parameter | WebSocket Upgrade established | Verifies ticket signature, expiry, and single-use state. Hydrates base session. |
| **3. Scoped Readiness** | WS Msg: `StoreSetNamespace`, `PresenceSetNamespace` | Namespace identifier string | Scoped `ok` with store/presence session mappings | Resolves namespace to internal ID and subject to internal `users.id` (global/namespaced). |

---

## Token Refresh

To rotate sessions without WebSocket disconnection, the client updates security credentials over the active transport:

| Direction | Message Type | Fields | Action / Validation |
|:---|:---|:---|:---|
| **Client → Server** | `AuthRefresh` | `token` (New external JWT) | Evaluated over existing WS. Re-validates signature, audience, and nbf/exp. |
| **Server → Client** | `ok` (Response) | `id`, `session` (Updated claims) | Projects new claims, extends token expiry, updates active session context. |
| **Server → Client (Fail)** | `ServerDisconnect` | `code: AUTH_FAILED`, `message` | Instantly closes connection, clearing active connection and presence states. |

---

## Handshake Error Mapping

During the connection lifecycle and handshake upgrade, authentication and validation errors are mapped to specific HTTP and WebSocket protocol responses:

| Step | Condition | HTTP/WS Response Status |
|------|-----------|-------------------------|
| Ticket Request | JWT signature invalid or expired | HTTP 401 `AUTH_FAILED` |
| Ticket Request | JWT issuer, audience, or algorithm invalid | HTTP 401 `AUTH_FAILED` |
| Ticket Request | Anonymous auth disabled | HTTP 401 `AUTH_FAILED` |
| Ticket Request | Anonymous subject invalid | HTTP 400 `INVALID_MESSAGE` |
| WebSocket Upgrade | Ticket expired | HTTP 401 `AUTH_FAILED` |
| WebSocket Upgrade | Ticket already used | HTTP 401 `AUTH_FAILED` |
| WebSocket Upgrade | Origin not in `allowedOrigins` | HTTP 403 `FORBIDDEN` |
| `AuthRefresh` | New JWT invalid or expired | `ServerDisconnect` `AUTH_FAILED`, connection closed |
| `AuthRefresh` | Subject mismatch (different user) | `ServerDisconnect` `AUTH_FAILED`, connection closed |

---

## Rules

- JWTs must never be placed directly in WebSocket query parameters; a single-use ticket is mandatory.
- Ticket expiry must be short-lived (e.g., ≤ 60 seconds).
- Re-use of a ticket must result in an immediate auth failure.
- A failed token refresh must immediately terminate the WebSocket connection.
- No user profile fields are resolved during authorization evaluation; ZyncBase only resolves the internal `users.id` mapping.

---

## See Also

- [Error Taxonomy](./error-taxonomy.md)
- [Security](./security.md)
- [Message Handler](./message-handler.md)
