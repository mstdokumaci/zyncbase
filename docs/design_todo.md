# Design TODO

Items requiring dedicated design work before implementation. Each item should result in a specification document or a decision record in `DESIGN_DECISIONS.md`.

---

## High Priority (Impacts API surface)

### 1. Error Taxonomy
**Why**: Only six error codes exist in API_REFERENCE. No formal error handling strategy.
**Decision needed**: Complete error taxonomy (connection, auth, validation, rate-limit, server errors), retry semantics, error propagation to client.

### 2. Batch Operations API
**Why**: Referenced in QUERY_ENGINE.md best practices but not documented in API_REFERENCE.
**Decision needed**: API surface (`store.batch()`), transaction semantics, error handling for partial failures.

### 3. Real-time Subscription Invalidation Strategy
**Why**: QUERY_ENGINE.md describes two approaches (table-grained vs fine-grained) but doesn't commit.
**Decision needed**: Which strategy to implement, performance implications, fallback behavior.

### 4. Connection Status API
**Why**: Developers need observable connection state for UI feedback.
**Decision needed**: Status values (`connecting` | `connected` | `disconnected` | `reconnecting`), React hook API (`useClient()`), event model.

### 5. Cursor-based Pagination for Real-time Queries
**Why**: Offset-based pagination breaks when items are inserted in real-time.
**Decision needed**: Cursor format, interaction with subscriptions, `loadMore` API design.

---

## Medium Priority (Impacts DX / extensibility)

### 6. Configuration Extensibility (Webhook Hooks)
**Why**: JSON-only config will hit limits for rate limiting rules, custom validation, computed fields.
**Decision needed**: Make webhook hooks first-class, define hook points, request/response contract.

### 7. Offline Support
**Why**: Listed as a selling point but has zero design. Massively complex.
**Decision needed**: Whether to pursue at all in near-term. If yes: local storage strategy, sync queue, client-side conflict resolution.
**Status**: Scoped out of v1. Design only when revisited.

### 8. Data Structure & Primary Key Conventions
**Why**: The wire protocol needs a canonical format for data access, and the client SDK return types must be completely consistent.
**Decision needed**: Formalize the Relational-Document Hybrid Model:
- Canonical path format for wire protocol is `['Table', 'PrimaryKey', 'Column(s)']`.
- SDK must parse dot-notation strings into this array format before transmission.
- Return types: Collections as Arrays, Documents as Objects, Properties as Scalars.
- Presence: Always return Arrays for `getAll` and `subscribe`, injecting `userId` into items.

---

## Tracking

| # | Item | Status | Decision Document |
|---|------|--------|-------------------|
md#adr-015-conflict-resolution-strategy) |
| 1 | Error Taxonomy | ❌ Not started | — |
| 2 | Batch Operations API | ❌ Not started | — |
| 3 | Subscription Invalidation | ❌ Not started | — |
| 4 | Connection Status API | ❌ Not started | — |
| 5 | Cursor-based Pagination | ❌ Not started | — |
md#adr-016-query-api-mvp-scope) |
| 6 | Config Extensibility | ❌ Not started | — |
| 7 | Offline Support | 🔒 Scoped out of v1 | — |
| 8 | Data Structure & Primary Key Conventions | ❌ Not started | — |
