# ZyncBase Project Specifications

This directory contains the formal specifications and architectural decisions for ZyncBase.

## Documentation Index

### 🏗️ [Architecture](./architecture/README.md)
*Core principles and long-term architectural decisions.*
- [Core Principles](./architecture/core-principles.md) — The fundamental pillars of ZyncBase.
- [Architecture Decisions (ADRs)](./architecture/adrs.md) — Record of major technical choices.
- [Deep Dives](./architecture/README.md#architectural-deep-dives) — Storage layer and threading models.

### 📐 [API Design](./api-design/README.md)
*External contracts for clients and SDKs.*
- [Store API](./api-design/store-api.md) — Path-based synchronization and batching.
- [Query Language](./api-design/query-language.md) — Reference for filtering and sorting.
- [Presence API](./api-design/presence-api.md) — Ephemeral state and user awareness.

### ⚙️ [Implementation](./implementation/README.md)
*Technical specs for the server core and internal systems.*
- [Wire Protocol](./implementation/wire-protocol.md) — MessagePack & WebSocket binary contract.
- [Security Implementation](./implementation/security.md) — Detailed auth and networking specs.
- [Core Engine](./implementation/threading.md) — Threading, memory, and cache internals.

---

## Implementation Roadmap

### Phase 1: Core Engine (Complete)
**Goal**: High-performance multi-threaded core
- [x] uWebSockets integration (with C++ wrapper)
- [x] Multi-threaded core engine (SWMR model)
- [x] Lock-free cache implementation (Atomic ref-counting)
- [x] SQLite integration with WAL
- [x] MessagePack serialization (Iterative parser)
- [x] Memory management strategy (Duality Pool)
- [x] Reliability sanitizers (TSan/GPA)

### Phase 2: Store API (Complete)
**Goal**: Path-based state access
- [x] Store.get() / Store.set() / Store.remove()
- [x] Store.subscribe() implementation
- [x] Store.batch() atomic operations
- [x] Schema validation (Strict/Server-side)
- [x] Namespace isolation

### Phase 3: Query & Presence (Complete)
**Goal**: Filtering and User Awareness
- [ ] Query parser & SQLite executor
- [ ] Standard operators (`eq`, `in`, `gt`/`lt`, `startsWith`)
- [ ] Real-time query subscriptions
- [ ] Presence.set() / Presence.subscribe()
- [ ] Ephemeral in-memory storage

### Phase 4: Production Hardening (In-Progress)
**Goal**: V1 Stability
- [/] Error taxonomy & retry strategies (Implemented in core)
- [/] Documentation alignment (This task)
- [ ] Connection management optimizations
- [ ] TypeScript types generation refinement
- [ ] Security audit

---

## Out of V1 Scope

To focus on a rock-solid core, the following features are explicitly deferred or rejected:

- **Horizontal Scaling**: **Rejected for V1**. ZyncBase is designed for vertical scaling to 100k+ connections on a single node. Distributed state complexity is avoided to maintain predictability (See [ADR-006](./architecture/adrs.md)).
- **Offline Support**: Deferred. (Sync queue, client-side conflict resolution).
- **Advanced Queries**: Multi-field sorting, Aggregations, Regex (Roadmap: post-v1).
- **Frameworks**: Vue/Svelte integrations (V1 focuses on React/Vanilla).
