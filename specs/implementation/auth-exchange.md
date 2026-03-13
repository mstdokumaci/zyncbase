# ZyncBase Authentication Exchange (`AUTH_EXCHANGE.md`)

**Status**: Draft  
**Target Version**: v1

## 1. Core Principle
ZyncBase is a **Resource Server (Validator)**, not an Identity Provider (IDP). It does not manage user accounts, passwords, or OAuth flows. It trusts external tokens (JWTs) or relies on a developer-provided **Bun Hook Server** to resolve identity into a local session context.

## 2. The `$session` Context
The `$session` object is the unified source of truth for authorization. It replaces the raw `$jwt` in all `authorization.json` rules. 

- **Source**: Populated via the `onConnect` hook in the Hook Server.
- **Default**: If no Hook Server is present, `$session` defaults to the standard claims found in the validated external JWT.
- **Persistence**: Fixed for the duration of the WebSocket connection (unless refreshed).

## 3. The Connection Lifecycle (Ticket Exchange)

To ensure security (avoiding JWTs in URLs) and flexibility (Hook Server enrichment), ZyncBase uses a mandatory ticket-based handshake.

### Step 1: Ticket Request (HTTP)
The client SDK sends the external JWT to the ZyncBase HTTP endpoint.

```http
POST /auth/ticket
Authorization: Bearer <external_jwt>
```

### Step 2: Enrichment (Zig ↔ Hook Server)
Zig validates the signature of the external JWT. If a Bun Hook Server is configured, Zig sends a `HookServerOnConnect` message to it.

```json
// Zig -> Hook Server
{ "type": "HookServerOnConnect", "jwt": { ...claims... }, "namespace": "..." }
```

The Hook Server returns an enriched session object:
```json
// Hook Server -> Zig
{ "type": "ok", "session": { "tenant_id": "acme", "role": "admin" } }
```

### Step 3: Ticket Issuance (Zig)
Zig generates a short-lived, single-use **ticket**. This ticket is a signed blob internally containing the resolved `$session`.

```json
// Response to Client
{ "ticket": "zyc_tk_8s2k...", "expiresAt": 1741551234 }
```

### Step 4: WebSocket Connection
The SDK connects to the WebSocket providing the ticket in the query string.

```
ws://server/ws?ticket=zyc_tk_8s2k...
```

Zig verifies the ticket signature, extracts the `$session`, hydrates the connection context, and accepts the upgrade. **No Hook Server call is required during this step.**

---

## 4. Token Refresh
Since external JWTs and ZyncBase tickets are short-lived, but WebSockets are long-lived, the SDK can rotate the session without disconnecting.

1. **Client**: Sends `AuthRefresh` message over the existing WebSocket with a new external JWT.
2. **Zig**: Re-validates the new JWT.
3. **Zig**: (Optional) Calls Hook Server `onConnect` again for updated enrichment.
4. **Zig**: Updates the internal `$session` context in-place for that connection.
5. **Zig**: Sends an `ok` response to the client.

Subsequent operations on the same connection now evaluate against the updated `$session`.

## 5. Security & Performance
- **Zero-Trust Handshake**: Zig never accepts a WebSocket connection without a valid ticket.
- **Microsecond Authorization**: Because the `$session` is baked into the connection (or ticket), `authorization.json` evaluation happens natively in Zig with no foreign calls.
- **No Hook Server Latency on Sync**: Relational lookups are done once (at ticket time) and cached in the `$session`, keeping the sync loop incredibly fast.
