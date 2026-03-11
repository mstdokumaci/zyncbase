# Design TODO

Items requiring dedicated design work before implementation. Each item should result in a specification document or a decision record in `DESIGN_DECISIONS.md`.

---

## High Priority (Impacts API surface)

### 1. Connection Status API
**Why**: Developers need observable connection state for UI feedback.
**Decision needed**: Status values (`connecting` | `connected` | `disconnected` | `reconnecting`), React hook API (`useClient()`), event model.

### 2. Cursor-based Pagination for Real-time Queries
**Why**: Offset-based pagination breaks when items are inserted in real-time.
**Decision needed**: Cursor format, interaction with subscriptions, `loadMore` API design.

---

## Medium Priority (Impacts DX / extensibility)

### 3. Configuration Extensibility (Webhook Hooks)
**Why**: JSON-only config will hit limits for rate limiting rules, custom validation, computed fields.
**Decision needed**: Make webhook hooks first-class, define hook points, request/response contract.

---

## Tracking

| # | Item | Status | Decision Document |
|---|------|--------|-------------------|
| 1 | Connection Status API | ❌ Not started | — |
| 2 | Cursor-based Pagination | ❌ Not started | — |
| 3 | Configuration Extensibility | ❌ Not started | — |
