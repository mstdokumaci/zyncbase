# Design TODO

Items requiring dedicated design work before implementation. Each item should result in a specification document or a decision record in `DESIGN_DECISIONS.md`.

---

## High Priority (Impacts API surface)

### 1. Error Taxonomy
**Status**: Done. See `ERROR_TAXONOMY.md`.
**Decision**: Established a comprehensive error handling strategy including 7 categories, retry semantics (auto-retry for connections/server, configurable for rates), and standardized SDK error objects. Renamed "sidecar" to "Hook Server".

### 2. Batch Operations API
**Status**: Done. See `BATCH_OPERATIONS.md`.
**Decision**: Minimum 500 operations per batch, strict atomicity (all-or-nothing), optimized wire format `[op, path, value]`.

### 3. Real-time Subscription Invalidation Strategy
**Status**: Done. See `ADR-018` in `DESIGN_DECISIONS.md`.
**Decision**: Fine-Grained Observation. In-memory evaluation of AST filters against write deltas to skip SQLite re-execution.

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
**Status**: Done. See `ADR-017` in `DESIGN_DECISIONS.md`.
**Decision**: Canonical paths are arrays `['table', 'id', ...fields]`, SDK handles dot-notation sugar, return types mapped by depth (Array/Object/Scalar).

---

## Tracking

| # | Item | Status | Decision Document |
|---|------|--------|-------------------|
| 1 | Error Taxonomy | ✅ Done | `ERROR_TAXONOMY.md` |
| 2 | Batch Operations API | ✅ Done | `BATCH_OPERATIONS.md` |
| 3 | Subscription Invalidation | ✅ Done | [ADR-018](DESIGN_DECISIONS.md#adr-018-fine-grained-subscription-invalidation) |
| 4 | Connection Status API | ❌ Not started | — |
| 5 | Cursor-based Pagination | ❌ Not started | — |
| 6 | Binary Delta Sync | ❌ Not started | — |
| 7 | Offline Support | ❌ Scoped out | — |
| 8 | Data Structure & PK | ✅ Done | [ADR-017](DESIGN_DECISIONS.md#adr-017-relational-document-hybrid-path-conventions) |
