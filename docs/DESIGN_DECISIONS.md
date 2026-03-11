# zyncBase Design Decisions

**Last Updated**: 2026-03-09

This document explains the architectural and design decisions behind ZyncBase.

---

## Table of Contents

1. [Design Philosophy](#design-philosophy)
2. [Query Language Design](#query-language-design)
3. [Architecture Decisions](#architecture-decisions)
4. [Implementation Roadmap](#implementation-roadmap)
5. [Open Questions](#open-questions)

---

## Design Philosophy

### Core Principles

1. **Real-time First**: This is NOT a general-purpose state manager. It's for real-time collaboration.
2. **Collaboration is Built-in**: Presence, conflict resolution, and sync are core features, not plugins.
3. **Self-Hosting First**: Designed to be self-hosted from day one. No vendor lock-in.
4. **Predictable Costs**: No per-operation pricing. You control the infrastructure, you control the costs.
5. **TypeScript-First**: Types are not an afterthought. The API should be impossible to misuse.
6. **Framework-Agnostic Core**: Works everywhere, integrates beautifully with React/Vue/Svelte.
7. **Logic in Code**: All authorization, validation, and business logic in version-controlled TypeScript.
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

| Aspect | Prisma | zyncBase | Why |
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

// zyncBase style (implicit AND)
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

**Context**: Should v2.0 support horizontal scaling?

**Decision**: No. zyncBase is designed exclusively for vertical scaling (single server, all CPU cores).

**Rationale**:
- Horizontal scaling adds significant complexity
- Distributed consensus, data sharding, network overhead
- Contradicts core principles of simplicity and performance
- Vertical scaling sufficient for 100k+ connections

**Consequences**:
- ✅ Simpler architecture
- ✅ Better performance (no network overhead)
- ✅ Easier to deploy and maintain
- ❌ Limited to single server capacity
- ❌ No geographic distribution

**Alternative**: If you need horizontal scaling, use a distributed database like CockroachDB or Cassandra instead.

---

### ADR-005: Configuration-First (Zero-Zig)

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

### ADR-006: Prisma-Inspired Query Language

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

### Phase 1: Core (Weeks 1-4)

**Goal**: Basic real-time state sync

- [ ] uWebSockets integration
- [ ] Multi-threaded core engine
- [ ] Lock-free cache implementation
- [ ] SQLite integration with WAL
- [ ] MessagePack serialization
- [ ] Basic authentication (JWT)

**Deliverable**: Echo server with real-time sync

---

### Phase 2: Store API (Weeks 5-8)

**Goal**: Path-based state access

- [ ] Store.get() implementation
- [ ] Store.set() implementation
- [ ] Store.subscribe() implementation
- [ ] Schema validation (JSON Schema)
- [ ] Namespace isolation
- [ ] Authorization rules (auth.json)

**Deliverable**: Collaborative whiteboard demo

---

### Phase 3: Query API (Weeks 9-12)

**Goal**: Collection filtering and sorting

- [ ] Query parser
- [ ] Query executor (SQLite)
- [ ] All operators (eq, gte, contains, etc.)
- [ ] OR conditions
- [ ] Sorting
- [ ] Pagination
- [ ] Real-time query subscriptions

**Deliverable**: Multi-tenant dashboard demo

---

### Phase 4: Presence API (Weeks 13-16)

**Goal**: User awareness

- [ ] Presence.set() implementation
- [ ] Presence.get() implementation
- [ ] Presence.getAll() implementation
- [ ] Presence.subscribe() implementation
- [ ] Ephemeral storage (RAM only)
- [ ] Automatic cleanup on disconnect

**Deliverable**: Collaborative editor with cursors

---

### Phase 5: Client SDK (Weeks 17-20)

**Goal**: TypeScript client library

- [ ] Core client implementation
- [ ] Connection management
- [ ] Reconnection logic
- [ ] TypeScript types
- [ ] React integration
- [ ] Vue integration
- [ ] Svelte integration

**Deliverable**: npm package @zyncBase/client

---

### Phase 6: Production Ready (Weeks 21-24)

**Goal**: Production hardening

- [ ] Security audit
- [ ] Performance optimization
- [ ] Monitoring (Prometheus metrics)
- [ ] Health check endpoint
- [ ] Graceful shutdown
- [ ] Hot reload for config
- [ ] Documentation
- [ ] Examples

**Deliverable**: v2.0.0 release

---

## Open Questions

### 1. Lock-Free Cache Implementation?

**Question**: Which lock-free data structure for the cache?

**Options:**
- **RCU (Read-Copy-Update)**: Linux kernel approach, complex
- **Atomic reference counting**: Simpler, good enough
- **Hazard pointers**: More complex, better performance

**Decision**: Start with atomic reference counting, optimize later if needed

**Critical Note**: The lock-free cache MUST use proper atomic operations. If it falls back to a global mutex, it will negate all benefits of the multi-threaded architecture and limit performance to single-threaded levels (~10k req/sec instead of 170k req/sec).

---

### 2. MessagePack Parser Security

**Question**: How to prevent stack overflow from malicious payloads?

**Decision**: Use iterative parser (not recursive) to prevent:
- **Stack overflow** from deeply nested objects
- **Size bombs** from excessive data
- **Depth bombs** from nested structures

The parser must be security-hardened against untrusted client input.

---

### 3. uWebSockets Compression?

**Question**: Should we enable per-message deflate compression?

**Options:**
- No compression (faster, more bandwidth)
- Per-message deflate (standard, slower)
- Custom compression (optimized for our use case)

**Decision**: TBD based on bandwidth measurements

---

### 4. MessagePack vs JSON?

**Question**: Binary protocol or text protocol?

**Options:**
- MessagePack (smaller, faster, binary)
- JSON (human-readable, easier debugging)
- Both (let client choose)

**Decision**: MessagePack for production, JSON for debugging

---

### 5. Admin UI?

**Question**: Should we build an admin UI?

**Options:**
- Web-based UI (like PocketBase)
- CLI only
- Both

**Decision**: CLI first, web UI in v2.1

---

### 6. Bun Integration?

**Question**: Should we provide Bun-specific optimizations?

**Considerations:**
- Bun uses same uWebSockets engine
- Could share code/learnings
- Potential collaboration opportunity

**Decision**: TBD - reach out to Bun team for feedback

---

### 7. Complex Query Patterns?

**Question**: How to handle complex nested queries?

**Examples:**
- Multiple OR conditions
- NOT operator
- Nested AND/OR combinations
- Subqueries

**Status**: Needs more design work

---

### 8. Conflict Resolution Strategy?

**Question**: How to handle concurrent edits?

**Options:**
- Last-write-wins (simple)
- CRDTs (complex, automatic)
- Operational Transform (complex, precise)
- Custom merge functions (flexible)

**Decision**: TBD - depends on use case

---

### 9. Offline Support?

**Question**: How to handle offline clients?

**Options:**
- Queue mutations locally
- Sync on reconnect
- Conflict resolution
- Delta sync

**Decision**: TBD - Phase 2 feature

---

### 10. Schema Evolution?

**Question**: How to handle schema changes?

**Options:**
- Migrations (like SQL)
- Versioning (multiple schemas)
- Automatic (best effort)

**Decision**: TBD - needs more thought

---

## Contributing

This is a living document. If you have feedback or suggestions, please:

1. Open an issue on GitHub
2. Join the discussion on Discord
3. Submit a PR with your proposal

---

## References

- [ARCHITECTURE.md](../ARCHITECTURE.md) - Technical architecture
- [research.md](../research.md) - Technical research and validation
- [API Reference](./API_REFERENCE.md) - Client SDK documentation
- [Comparison](./COMPARISON.md) - vs Firebase/Supabase/PocketBase
