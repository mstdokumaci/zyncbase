# Design TODO

Items requiring dedicated design work before implementation. Each item should result in a specification document or a decision record in `DESIGN_DECISIONS.md`.

---

## High Priority (Impacts API surface)

### 1. Connection Status API
**Why**: Developers need observable connection state for UI feedback.
**Status**: ✅ Done. See `API_REFERENCE.md`.
**Decision**: Expose a 4-state observable property (`client.status`) and a React hook (`useConnectionStatus`). Reconnection should use exponential backoff with jitter.

### 2. Cursor-based Pagination for Real-time Queries
**Why**: Offset-based pagination breaks when items are inserted in real-time.
**Decision needed**: Cursor format, interaction with subscriptions, `loadMore` API design.

---

## Tracking

| # | Item | Status | Decision Document |
|---|------|--------|-------------------|
| 1 | Connection Status API | ✅ Done | `API_REFERENCE.md` |
| 2 | Cursor-based Pagination | ❌ Not started | — |
