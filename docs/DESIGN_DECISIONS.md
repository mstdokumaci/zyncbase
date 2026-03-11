# ZyncBase Design Decisions

**Last Updated**: 2026-03-09

This document explains the architectural and design decisions behind ZyncBase.

---

## Table of Contents

1. [Design Philosophy](#design-philosophy)
2. [Query Language Design](#query-language-design)
3. [Architecture Decisions](#architecture-decisions)
4. [Implementation Roadmap](#implementation-roadmap)
5. [Resolved Implementation Questions](#resolved-implementation-questions)
6. [Open Design Work](#open-design-work)

---

## Design Philosophy

### Core Principles

1. **Real-time First**: ZyncBase is a real-time collaborative database, not a general-purpose state manager or sync layer.
2. **Collaboration is Built-in**: Presence, conflict resolution, and sync are core features, not plugins.
3. **Self-Hosting First**: Designed to be self-hosted from day one. No vendor lock-in.
4. **Predictable Costs**: No per-operation pricing. You control the infrastructure, you control the costs.
5. **TypeScript-First**: Types are not an afterthought. The API should be impossible to misuse.
6. **Framework-Agnostic Core**: Works everywhere, integrates beautifully with React/Vue/Svelte.
7. **Declarative Security**: All authorization and validation rules are defined in version-controlled JSON (`auth.json`), ensuring high-performance, consistent enforcement by the Zig core.
8. **Predictable Performance**: No hidden O(n²) algorithms, clear performance characteristics.
9. **Secure by Default**: No prototype pollution, input validation built-in, safe defaults.

---

## Query Language Design

### Why Prisma-inspired?

We evaluated MongoDB, GraphQL/Hasura, Prisma, and custom approaches. We chose Prisma-inspired syntax because:

1. **TypeScript-first** - Matches our target audience (modern web developers)
2. **Clean syntax** - No `$` or `_` prefixes that feel like workarounds
3. **Growing adoption** - Developers are already learning Prisma
4. **Well-designed** - Learned from MongoDB's mistakes over 15+ years

### Our improvements over Prisma

| Aspect | Prisma | ZyncBase | Why |
|--------|--------|-----|-----|
| AND operator | `AND: [...]` | Implicit at root | Simpler for common case |
| OR operator | `OR: [...]` | `or: [...]` | Consistent lowercase |
| Equality | `equals: value` | `eq: value` | Shorter, clearer |
| Not equal | `not: value` | `ne: value` | Explicit operator |
| Pagination | `take`/`skip` | `limit`/`offset` | Standard SQL terms |

### Comparison with alternatives

```typescript
// MongoDB style
{ $and: [{ age: { $gte: 18 } }, { status: { $eq: 'active' } }] }

// GraphQL/Hasura style
{ _and: [{ age: { _gte: 18 } }, { status: { _eq: 'active' } }] }

// Prisma style
{ AND: [{ age: { gte: 18 } }, { status: { equals: 'active' } }] }

// ZyncBase style (implicit AND)
{ age: { gte: 18 }, status: { eq: 'active' } }
```

**Result:** Familiar to Prisma users, cleaner than all alternatives, no learning curve for simple queries.

---

## Architecture Decisions

### ADR-001: Zig + uWebSockets

**Date**: 2026-03-08  
**Status**: Accepted

**Context**: Need maximum performance for real-time state sync.

**Decision**: Use Zig for application logic and uWebSockets for networking.

**Rationale**:
- Zig: 3-4x faster than Node.js, no GC pauses, native multi-threading
- uWebSockets: 200k+ req/sec, powers Bun and Discord
- Proven combination (Bun uses same stack)

**Consequences**:
- ✅ Best-in-class performance
- ✅ Predictable latency (no GC)
- ✅ Single binary deployment
- ⚠️ Longer development time (12-15 months vs 6 for Node.js)
- ⚠️ Smaller ecosystem than Node.js

---

### ADR-002: SQLite Only

**Date**: 2026-03-08  
**Status**: Accepted

**Context**: Need embedded database for zero-config deployment.

**Decision**: Use SQLite exclusively, no other database adapters.

**Rationale**:
- Zero-config (embedded)
- Good enough performance (10k+ writes/sec with WAL)
- Vertical scaling with WAL mode (parallel reads)
- Single file deployment

**Consequences**:
- ✅ Simplest deployment
- ✅ No database setup required
- ✅ Vertical scaling sufficient for most use cases
- ❌ No horizontal scaling (by design)
- ❌ Single-writer limitation

---

### ADR-003: Multi-threaded Core Engine

**Date**: 2026-03-08  
**Status**: Accepted

**Context**: Single-threaded core cannot utilize SQLite's parallel read capability.

**Decision**: Implement multi-threaded core with read/write separation:
- Lock-free cache for parallel reads
- Mutex-protected writes for correctness
- SQLite connection pool (one reader per CPU core)

**Rationale**:
- 17x performance improvement (10k → 170k req/sec on 16-core machine)
- True vertical scaling - uses all CPU cores
- SQLite parallel reads fully utilized

**Consequences**:
- ✅ 17x better performance
- ✅ Uses all CPU cores
- ✅ Competitive with Bun
- ⚠️ More complex than single-threaded
- ⚠️ Writes still serialized (SQLite limitation)

---

### ADR-004: No Horizontal Scaling

**Date**: 2026-03-08  
**Status**: Accepted

**Context**: Should v1.0 support horizontal scaling?

**Decision**: No. ZyncBase is designed exclusively for vertical scaling (single server, all CPU cores). In order to efficiently optimize performance, horizontal scaling is completely removed from the vision for now.

**Rationale**:
- Most collaborative apps don't reach 100k concurrent users per server
- Simpler architecture = faster development and better reliability
- Vertical scaling to 100k+ connections is sufficient for 99% of use cases
- No distributed state complexity (no raft/paxos)

**Consequences**:
- ✅ Best-in-class single-node performance
- ✅ Simplest operational model
- ✅ High reliability
- ❌ Hard limit of ~100k concurrent users per node
- ❌ Requires vertical scaling for growth

---

### ADR-005: Optimistic Writes by Default

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: How should the Client SDK handle real-time state updates?

**Decision**: All writes (`store.set`, `store.remove`) are optimistic by default. Changes are applied immediately to the local cache and synchronized with the server asynchronously.

**Rationale**:
- Zero-latency perceived performance for users
- Matches standard real-time collaboration patterns (Firebase model)
- Simplifies UI code (no waiting for API responses)

**Consequences**:
- ✅ Instant UI feedback
- ✅ Simplified frontend code
- ⚠️ Requires automatic local state revert on server rejection
- ⚠️ Errors must be handled via global event listeners

---

### ADR-006: Server-side Only Validation

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: Should the Client SDK replicate the server's validation logic?

**Decision**: No. Validation is enforced strictly on the server. The Client SDK uses TypeScript types generated from the schema for developer experience (DX), but does not run schema validation at runtime.

**Rationale**:
- Prevents version-coupling between server and client
- Keeps the Client SDK lightweight
- Server must validate anyway for security; client validation is redundant

**Consequences**:
- ✅ Smaller SDK bundle size
- ✅ No "stale schema" bugs on clients
- ⚠️ Errors only discovered after server round-trip (handled via optimistic revert)
---

### ADR-007: Configuration-First (Zero-Zig)

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: How should developers configure the server?

**Decision**: JSON configuration files only, no server code required.

**Rationale**:
- Like Nginx, PostgreSQL, Redis - configure, don't code
- Lowers barrier to entry
- Version control friendly
- No Zig knowledge required

**Consequences**:
- ✅ Easier to get started
- ✅ Familiar pattern (like nginx.conf)
- ✅ No compilation needed
- ⚠️ Less flexible than code
- ⚠️ Need webhook for complex auth logic

---

### ADR-008: Prisma-Inspired Query Language

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: Which query language should we use?

**Decision**: Prisma-inspired with improvements (implicit AND, lowercase operators).

**Rationale**:
- TypeScript-first (matches audience)
- Clean syntax (no prefixes)
- Growing adoption
- Well-designed

**Consequences**:
- ✅ Familiar to Prisma users
- ✅ Cleaner than MongoDB/GraphQL
- ✅ Easy to learn
- ⚠️ Not a standard (custom)

---

## Implementation Roadmap

### Phase 1: Core

**Goal**: Basic real-time state sync

- [ ] uWebSockets integration
- [ ] Multi-threaded core engine
- [ ] Lock-free cache implementation
- [ ] SQLite integration with WAL
- [ ] MessagePack serialization

**Deliverable**: Echo server with real-time sync

---

### Phase 2: Store API

**Goal**: Path-based state access

- [ ] Store.get() implementation
- [ ] Store.set() and Store.remove() implementation
- [ ] Store.subscribe() implementation
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
- [ ] Graceful shutdown
- [ ] Documentation
- [ ] Examples

**Deliverable**: v1.0.0 release

---

## Out of V1 Scope

To focus on a rock-solid core, the following features are explicitly deferred:

- **Frameworks**: Vue and Svelte integrations (Roadmap: post-v1)
- **Tooling**: Admin UI & detailed Firebase/Supabase migration guides (Roadmap: post-v1)
- **Features**: Offline support, Full-text search (FTS5), and Aggregation queries (Roadmap: post-v1)
- **Advanced Queries**: Multi-field sorting (Roadmap: post-v1)
- **DevOps**: Kubernetes official deployment guide (Roadmap: post-v1)
- **DX**: Hot reload for server configuration (v1: server restart is minimum)


---

## Resolved Implementation Questions

The following items were previously listed as "Open Questions" and have now been resolved.

### ADR-009: Lock-Free Cache — Atomic Reference Counting

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: Which lock-free data structure for the in-memory cache?

**Decision**: Start with atomic reference counting. Optimize to RCU or hazard pointers only if profiling shows it is the bottleneck.

**Critical Note**: The lock-free cache MUST use proper atomic operations. A global mutex fallback would negate all multi-threading benefits (~10k req/sec instead of 170k req/sec).

---

### ADR-010: Iterative MessagePack Parser

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: How to prevent stack overflow from malicious client payloads?

**Decision**: Use an iterative (not recursive) parser with hard limits on nesting depth and payload size. The parser must be security-hardened against untrusted client input.

---

### ADR-011: MessagePack for Production, JSON for Debug

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: Binary protocol or text protocol for the wire format?

**Decision**: MessagePack for production (smaller, faster). JSON mode available via a debug flag for development and troubleshooting.

---

### ADR-012: No WebSocket Compression (v1.0)

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: Should we enable per-message deflate compression on WebSocket connections?

**Decision**: No compression in v1.0. MessagePack is already compact. Compression adds CPU overhead and latency. Revisit based on real-world bandwidth measurements post-launch.

---

### ADR-013: Strict Client API Namespaces (`store` vs `presence`)

**Date**: 2026-03-09  
**Status**: Accepted

**Context**: How should the Client SDK organize methods for data synchronization vs user awareness?

**Decision**: The SDK explicitly separates data methods into `client.store.*` (persistent database state, including queries) and `client.presence.*` (ephemeral, in-memory user awareness). There are no top-level methods for data access.

**Rationale**:
- Persistent state requires schema validation, disk I/O, offline queuing (planned), and complex queries.
- Presence state is ephemeral, memory-only, never hits the disk, and is wiped on disconnect.
- Forcing the user to type `.store` or `.presence` creates a hard mental boundary, preventing them from treating user awareness data as durable state.

**Consequences**:
- ✅ Extremely clear mental model for developers.
- ✅ Prevents accidental misuse of presence for durable data.
- ❌ Slightly more verbose (`client.store.set` instead of `client.set`).

---

## Open Design Work

For items still requiring dedicated design work, see [design_todo.md](./design_todo.md).

---

## Contributing

This is a living document. If you have feedback or suggestions, please:

1. Open an issue on GitHub
2. Join the discussion on Discord
3. Submit a PR with your proposal

---

## References

- [Architecture](./architecture/README.md) - Technical architecture
- [Research](./architecture/RESEARCH.md) - Technical research and validation
- [API Reference](./API_REFERENCE.md) - Client SDK documentation
- [Comparison](./COMPARISON.md) - vs Firebase/Supabase/PocketBase
