# Design TODO

Items requiring dedicated design work before implementation. Each item should result in a specification document or a decision record in `DESIGN_DECISIONS.md`.

---

## Critical (Blocks Core Implementation)

### 1. Wire Protocol Specification
**Why**: The entire client-server contract. Every MessagePack message type, field, response shape, error format.
**Decision needed**: Formal spec for all message types, fields, response shapes, and error formats.
**Blocks**: Server implementation, client SDK development (cannot build in parallel without this).

### 2. Authorization Format (`auth.json`)
**Why**: Referenced throughout docs but no formal spec exists.
**Decision needed**: Rule format, evaluation order, namespace wildcard behavior, composition model.
**Blocks**: Security layer implementation.

### 3. Authentication Architecture & Token Exchange
**Why**: The docs assume ZyncBase is just a JWT validator (`auth.jwt.secret` config). If the developer's external system generates the JWT, how does ZyncBase guarantee the `namespace` or `tenant_id` claims are correctly injected? If ZyncBase needs to issue tokens itself, we need exchange endpoints.
**Decision needed**: Are we the Identity Provider (issuer) or just a Resource Server (validator)? If validator, how do we enforce claim formats? How does token refresh work?
**Blocks**: Security layer and SDK connection flow.

### 4. Conflict Resolution Strategy
**Why**: Determines the fundamental semantics of `store.set()` for concurrent users.
**Decision needed**: Last-Write-Wins vs field-level merge vs collision rejection.
**Blocks**: Core store engine.

---

## High Priority (Impacts API surface)

### 4. Error Taxonomy
**Why**: Only six error codes exist in API_REFERENCE. No formal error handling strategy.
**Decision needed**: Complete error taxonomy (connection, auth, validation, rate-limit, server errors), retry semantics, error propagation to client.

### 5. Batch Operations API
**Why**: Referenced in QUERY_ENGINE.md best practices but not documented in API_REFERENCE.
**Decision needed**: API surface (`store.batch()`), transaction semantics, error handling for partial failures.

### 6. Real-time Subscription Invalidation Strategy
**Why**: QUERY_ENGINE.md describes two approaches (table-grained vs fine-grained) but doesn't commit.
**Decision needed**: Which strategy to implement, performance implications, fallback behavior.

### 7. Connection Status API
**Why**: Developers need observable connection state for UI feedback.
**Decision needed**: Status values (`connecting` | `connected` | `disconnected` | `reconnecting`), React hook API (`useClient()`), event model.

### 8. Cursor-based Pagination for Real-time Queries
**Why**: Offset-based pagination breaks when items are inserted in real-time.
**Decision needed**: Cursor format, interaction with subscriptions, `loadMore` API design.

### 9. Query API MVP Scope
**Why**: We need to limit the scope of the v1 query engine to the most critical operators to ship faster.
**Decision needed**: Formally drop complex operators (e.g., regex, full-text, complex joins) and define the exact boolean logic (AND/OR) boundaries for v1.
**Status**: Limit to `eq`, `in`, `gt`/`lt`, and `startsWith`.

---

## Medium Priority (Impacts DX / extensibility)

### 10. Configuration Extensibility (Webhook Hooks)
**Why**: JSON-only config will hit limits for rate limiting rules, custom validation, computed fields.
**Decision needed**: Make webhook hooks first-class, define hook points, request/response contract.

### 10. Offline Support
**Why**: Listed as a selling point but has zero design. Massively complex.
**Decision needed**: Whether to pursue at all in near-term. If yes: local storage strategy, sync queue, client-side conflict resolution.
**Status**: Scoped out of v1. Design only when revisited.

---

## Tracking

| # | Item | Status | Decision Document |
|---|------|--------|-------------------|
| 1 | Wire Protocol Spec | ❌ Not started | — |
| 2 | Authorization Format | ❌ Not started | — |
| 3 | Auth Token Exchange | ❌ Not started | — |
| 4 | Conflict Resolution | ❌ Not started | — |
| 5 | Error Taxonomy | ❌ Not started | — |
| 6 | Batch Operations API | ❌ Not started | — |
| 7 | Subscription Invalidation | ❌ Not started | — |
| 8 | Connection Status API | ❌ Not started | — |
| 9 | Cursor-based Pagination | ❌ Not started | — |
| 10 | Query API MVP Scope | ❌ Not started | — |
| 11 | Config Extensibility | ❌ Not started | — |
| 12 | Offline Support | 🔒 Scoped out of v1 | — |
