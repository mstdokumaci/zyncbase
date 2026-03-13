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

### Phase 1: Core
**Goal**: Basic real-time state sync
- [ ] uWebSockets integration (with C++ wrapper)
- [ ] Multi-threaded core engine
- [ ] Lock-free cache implementation
- [ ] SQLite integration with WAL
- [ ] MessagePack serialization
- [ ] Memory management strategy (Arena/GPA/Pool)
- [ ] Reliability sanitizers (TSan/ASan/LSan)

**Deliverable**: Echo server with real-time sync

---

### Phase 2: Store API
**Goal**: Path-based state access
- [ ] Store.get() implementation
- [ ] Store.set() and Store.remove() implementation
- [ ] Store.subscribe() implementation
- [ ] Store.batch() implementation (Atomic multi-path)
- [ ] Schema validation (Server-side)
- [ ] Namespace isolation
- [ ] Authorization engine (Basic)

**Deliverable**: Collaborative whiteboard demo

---

### Phase 3: Query API
**Goal**: Collection filtering and sorting (MVP Scope)
- [ ] Query parser
- [ ] Query executor (SQLite)
- [ ] MVP Operators (`eq`, `in`, `gt`/`lt`, `startsWith`)
- [ ] Sorting (Single-field)
- [ ] Pagination (Cursor-based)
- [ ] Real-time query subscriptions

**Deliverable**: Multi-tenant dashboard demo

---

### Phase 4: Presence API
**Goal**: User awareness
- [ ] Presence.set() implementation
- [ ] Presence.getAll() implementation (self-excluded by default)
- [ ] Presence.subscribe() implementation
- [ ] Ephemeral storage (RAM only)
- [ ] Automatic cleanup on disconnect

**Deliverable**: Collaborative editor with cursors

---

### Phase 5: Client SDK
**Goal**: TypeScript client library
- [ ] Core client implementation
- [ ] Connection management
- [ ] Reconnection logic
- [ ] TypeScript types generation
- [ ] React integration

**Deliverable**: npm package @zyncbase/client

---

### Phase 6: Production Ready
**Goal**: Production hardening
- [ ] Security audit
- [ ] Performance optimization
- [ ] Monitoring (Prometheus metrics)
- [ ] Health check endpoint
- [ ] Graceful shutdown logic
- [ ] Error taxonomy & retry strategies
- [ ] Version compatibility & maintenance
- [ ] Documentation
- [ ] Examples

**Deliverable**: v1.0.0 release

---

## Out of V1 Scope

To focus on a rock-solid core, the following features are explicitly deferred:

- **Frameworks**: Vue and Svelte integrations (Roadmap: post-v1)
- **Tooling**: Admin UI & detailed Firebase/Supabase migration guides (Roadmap: post-v1)
- **Features**: Full-text search (FTS5), and Aggregation queries (Roadmap: post-v1)
- **Advanced Queries**: Multi-field sorting (Roadmap: post-v1)
- **DevOps**: Kubernetes official deployment guide (Roadmap: post-v1)
- **DX**: Hot reload for server configuration (v1: server restart is minimum)
- **Strategic**: **Offline Support** (Local storage strategy, sync queue, client-side conflict resolution)
