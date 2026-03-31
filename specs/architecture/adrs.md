# Architecture Decision Records

All architectural decisions for ZyncBase, consolidated from multiple sources and organized chronologically.

---

## ADR-001: Choice of Zig as Primary Language

**Date**: 2026-03-08  
**Status**: Accepted  

**Context**: 
Need maximum performance, predictable latency, and native multi-threading for a real-time collaborative database. Existing runtimes like Node.js introduce garbage collection pauses that are unacceptable for 100,000+ concurrent connections.

**Decision**: 
Use Zig as the primary implementation language for the core engine.

**Rationale**:
- **Performance**: 3-4x faster than Node.js, competitive with Go. No GC = predictable latency.
- **Multi-threading**: Native support for using all CPU cores with direct mapping to system threads.
- **Memory Efficiency**: Manual control with specialized allocators (Arena, Pool) ensures zero-cost abstractions and predictable memory usage.
- **Single Binary**: Statically linked binary (< 15MB) with no runtime dependencies simplifies deployment.
- **C/C++ Interop**: Zero-cost FFI allows seamless integration with uWebSockets and other battle-tested C/C++ libraries.

**Principles Alignment**: 
- #1 Real-time First
- #8 Predictable Performance

**Consequences**:
- ✅ Best-in-class performance and predictable latency.
- ✅ Single binary deployment.
- ⚠️ Longer development time compared to high-level languages.
- ⚠️ Manual memory management requires high attention to correctness.

---

## ADR-002: Choice of uWebSockets for Networking

**Date**: 2026-03-08  
**Status**: Accepted  

**Context**: 
Standard networking libraries in many languages struggle with microsecond-scale latency and the memory overhead of hundreds of thousands of concurrent WebSocket connections.

**Decision**: 
Use uWebSockets (written in C++) as the networking foundation.

**Rationale**:
- **Best-in-Class Performance**: Supports 200,000+ requests/second with microsecond-scale latency.
- **Battle-Tested**: Powers Bun runtime and used by Discord for millions of connections.
- **Memory Efficient**: Minimal overhead (< 1KB per connection), allowing vertical scaling to millions of connections.
- **Proven with Zig**: Successful integration demonstrated by Bun; direct C++ integration via Zig FFI has zero wrapper overhead.

**Principles Alignment**: 
- #1 Real-time First
- #8 Predictable Performance

**Consequences**:
- ✅ Extremely low latency and high throughput.
- ✅ Efficient resource usage per connection.
- ⚠️ Requires C++ integration layer (handled via Zig FFI).

---

## ADR-003: Choice of SQLite Only

**Date**: 2026-03-08  
**Status**: Accepted  

**Context**: 
Need an embedded database for zero-config deployment that still provides ACID guarantees and high reliability for vertical scaling.

**Decision**: 
Use SQLite exclusively as the storage layer, with no other database adapters.

**Rationale**:
- **Zero-Config**: Embedded database with single-file storage; no installation or external server required.
- **ACID Transactions**: Full transactional support and data integrity guarantees proven over 20+ years.
- **Simplicity**: Easy backup (copy file) and simple deployment.
- **Full-Text Search**: Built-in FTS5 extension provides efficient text indexing without external engines.

**Principles Alignment**: 
- #3 Self-Hosting First
- #4 Predictable Costs
- #8 Predictable Performance

**Consequences**:
- ✅ Simplest operational model and deployment.
- ✅ No "hidden" database infrastructure costs.
- ❌ No horizontal scaling for storage (by design).
- ⚠️ Requires careful management of the single-writer constraint (see ADR-004).

---

## ADR-004: SQLite WAL Mode & Concurrency

**Date**: 2026-03-08  
**Status**: Accepted  

**Context**: 
By default, SQLite's single writer blocks all readers, which limits throughput on multi-core systems.

**Decision**: 
Exclusively use SQLite in Write-Ahead Logging (WAL) mode.

**Rationale**:
- **Parallel Reads**: Multiple readers can operate alongside one writer, which is critical for vertical scaling.
- **Sequential I/O**: WAL optimizes I/O patterns, improving write performance.

**Principles Alignment**: 
- #8 Predictable Performance

**Consequences**:
- ✅ True parallel reads utilizing all CPU cores.
- ✅ Faster write performance compared to traditional rollback journals.
- ⚠️ Writes are still serialized; batching is used to increase throughput.

---

## ADR-005: Multi-threaded Core Engine

**Date**: 2026-03-08  
**Status**: Accepted  

**Context**: 
A single-threaded core cannot utilize SQLite's parallel read capability (ADR-004) or the multi-threaded event loop of uWebSockets (ADR-002).

**Decision**: 
Implement a multi-threaded core with read/write separation:
- Lock-free cache for parallel reads.
- Mutex-protected writes for correctness.
- SQLite connection pool (one reader per CPU core).

**Rationale**:
- 17x performance improvement (10k → 170k req/sec) on multi-core machines.
- Matches the performance characteristics of Bun and uWebSockets.

**Principles Alignment**: 
- #8 Predictable Performance

**Consequences**:
- ✅ Full utilization of system resources.
- ✅ Predictable vertical scaling.
- ⚠️ Significant architectural complexity compared to single-threaded designs.

---

## ADR-006: No Horizontal Scaling

**Date**: 2026-03-08  
**Status**: Accepted  

**Context**: 
Question of whether v1.0 should support clustering/horizontal scaling.

**Decision**: 
No. ZyncBase is designed exclusively for vertical scaling (single server, all CPU cores). Distributed state complexity is out of scope for v1.

**Rationale**:
- Most collaborative apps don't reach 100k concurrent users per server.
- Simpler architecture = faster development and better reliability.
- Vertical scaling to 100k+ connections is sufficient for 99% of use cases.
- Avoids the performance and consistency overhead of P2P/Raft/Paxos.

**Principles Alignment**: 
- #8 Predictable Performance
- #3 Self-Hosting First

**Consequences**:
- ✅ Best-in-class single-node performance.
- ✅ Simplest operational model.
- ❌ Hard limit of ~100k concurrent users per node.
- ❌ Future horizontal scaling would require external tools (LiteFS/Marmot).

---

## ADR-007: Optimistic Writes by Default

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
How should the Client SDK handle real-time state updates for a fluid user experience?

**Decision**: 
All writes (`store.set`, `store.remove`) are optimistic by default.

**Rationale**:
- Zero-latency perceived performance for users.
- Matches standard real-time collaboration patterns (Firebase model).
- Simplifies UI code (no waiting for API responses).

**Principles Alignment**: 
- #1 Real-time First

**Consequences**:
- ✅ Instant UI feedback.
- ⚠️ Requires automatic local state revert on server rejection.
- ⚠️ Errors must be handled via global event listeners.

---

## ADR-008: Server-side Only Validation

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
Should the Client SDK replicate the server's validation logic to catch errors earlier?

**Decision**: 
No. Validation is enforced strictly on the server. The Client SDK uses TypeScript types for development, but does not run runtime validation.

**Rationale**:
- Prevents version-coupling between server and client.
- Keeps the Client SDK lightweight.
- Server must validate anyway for security; client validation is redundant.

**Principles Alignment**: 
- #9 Secure by Default
- #5 TypeScript-First

**Consequences**:
- ✅ Smaller SDK bundle size.
- ✅ No "stale schema" bugs on clients.
- ⚠️ Errors only discovered after server round-trip.

---

## ADR-009: Configuration-First (Zero-Zig)

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
High barrier to entry if users have to learn Zig to build a backend.

**Decision**: 
ZyncBase follows a "Zero-Zig" philosophy where all core functionality is managed via JSON configuration files. No Zig knowledge is required to deploy or manage the server.

**Rationale**:
- Mimics successful infrastructure tools like Nginx and PostgreSQL.
- Lowers barrier to entry for JS/TS developers.

For the full philosophy and its impact on architectural decisions, see the [Zero-Zig Philosophy in Core Principles](./core-principles.md#zero-zig-philosophy).

**Principles Alignment**: 
- #3 Self-Hosting First
- #5 TypeScript-First

**Consequences**:
- ✅ No compilation needed; instant setup.
- ⚠️ Less flexible than code-based config (mitigated by Hook Server).

---

## ADR-010: Prisma-Inspired Query Language

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
Need a query language that feels natural to modern web developers.

**Decision**: 
Use a Prisma-inspired JSON syntax (implicit AND, lowercase operators).

**Rationale**:
- TypeScript-first (perfect for the target audience).
- Clean syntax with no prefixes or complex nesting required for simple queries.

**Principles Alignment**: 
- #5 TypeScript-First

**Consequences**:
- ✅ Familiarity and ease of use.
- ⚠️ Custom format rather than a standard like SQL or GraphQL.

---

## ADR-011: Lock-Free Cache — Atomic Reference Counting

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
In-memory cache needs to support high-frequency reads from multiple threads without contention.

**Decision**: 
Utilize atomic reference counting for the in-memory cache.

**Rationale**:
- Provides high-performance parallel reads.
- Simple to implement correctly compared to RCU or hazard pointers.
- Note: Must use proper atomic operations; global mutex fallbacks are unacceptable.

**Principles Alignment**: 
- #8 Predictable Performance

---

## ADR-012: Iterative MessagePack Parser

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
Risk of stack overflow from malicious client payloads with deep nesting.

**Decision**: 
Use an iterative (not recursive) MessagePack parser with hard limits on nesting depth and payload size.

**Principles Alignment**: 
- #9 Secure by Default
- #8 Predictable Performance

---

## ADR-013: MessagePack for Production, JSON for Debug

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
Wire protocol needs to be both efficient and accessible for debugging.

**Decision**: 
MessagePack for production (smaller, faster), JSON mode for debug.

**Principles Alignment**: 
- #8 Predictable Performance

---

## ADR-014: No WebSocket Compression (v1.0)

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
Should we enable per-message deflate compression?

**Decision**: 
No compression in v1.0. MessagePack is already compact. Compression adds CPU overhead and latency.

**Principles Alignment**: 
- #8 Predictable Performance

---

## ADR-015: Strict Client API Namespaces (`store` vs `presence`)

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
Developers often confuse ephemeral awareness data with durable state.

**Decision**: 
SDK explicitly separates methods into `client.store.*` and `client.presence.*`.

**Rationale**:
- Forcing a choice creates a hard mental boundary.
- Prevents accidental misuse of presence for durable data.

**Principles Alignment**: 
- #5 TypeScript-First

---

## ADR-016: Bun Hook Server

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
How to handle complex relational authorization without bloating the Zig core?

**Decision**: 
Provide an out-of-the-box Bun-based Hook Server for complex logic. Stateless checks remain in `authorization.json`.

**Principles Alignment**: 
- #7 Declarative Security
- #5 TypeScript-First

**Consequences**:
- ✅ Unlimited flexibility using full TypeScript.
- ✅ Protects the Zig core from business logic complexity.
- ⚠️ Small latency penalty (~1-2ms) for delegated checks.

---

## ADR-017: Conflict Resolution Strategy

**Date**: 2026-03-09  
**Status**: Accepted  

**Context**: 
Fundamental semantics of `store.set()` for concurrent users.

**Decision**: 
Server-Time Last-Write-Wins (LWW) at the Path Level.

**Rationale**:
- **Simplicity**: Matches standard REST/Firebase semantics.
- **Performance**: Eliminates costly deep field-level merging in the core engine.
- **Order Guarantee**: Single vertically-scaled server guarantees total global order (ADR-006).

**Principles Alignment**: 
- #1 Real-time First
- #8 Predictable Performance

---

## ADR-018: Query API MVP Scope

**Date**: 2026-03-09  
**Status**: Accepted  

**Decision**: 
MVP supports specific operators (eq, ne, gt, etc.) but excludes Regex, FTS, and complex joins in v1.

**Rationale**:
- **Security**: Regex introduces ReDoS limits.
- **Simplicity**: Guarantees predictable performance for the writer loop.

**Principles Alignment**: 
- #8 Predictable Performance
- #9 Secure by Default

**Consequences**:
- ⚠️ Developers must rely on Computed Properties or Hook Servers for complex search.

---

## ADR-019: SDK-Friendly Syntax, Compact Wire Format

**Date**: 2026-03-09  
**Updated**: 2026-03-31  
**Status**: Accepted  

**Context**:  
The SDK targets TypeScript developers who benefit from expressive, nested syntax (dot-notation paths, Prisma-style query objects). The Zig server benefits from flat, positional data that can be parsed without recursive descent or string-keyed map inspection.

**Decision**:  
The SDK provides developer-friendly syntax. The wire protocol uses compact positional arrays. The SDK is responsible for transforming one into the other before transmission.

This principle applies to:
- **Paths**: SDK accepts `'users.u1.name'`, wire sends `['users', 'u1', 'name']`.
- **Query conditions**: SDK accepts `{ age: { gte: 18 } }`, wire sends `['age', 4, 18]` (positional tuple: `[field, op_code, value]`).
- **Sort descriptors**: SDK accepts `{ created_at: 'desc' }`, wire sends `['created_at', 1]` (positional tuple: `[field, desc_flag]`).

See [Query Grammar](../implementation/query-grammar.md) for the full wire encoding specification including operator codes.

**Rationale**:
- Paths map directly to SQLite row lookups; eliminates ambiguity in IDs containing dots.
- Flat condition tuples eliminate recursive JSON parsing in Zig — the server reads fixed-position array elements.
- Integer operator codes avoid string comparison; map 1:1 to the Zig `Operator` enum.
- Nested path flattening (`address.city` → `address__city`) happens in TypeScript where it's trivial.

**Principles Alignment**: 
- #5 TypeScript-First
- #8 Predictable Performance

---

## ADR-020: Performance Targets

**Date**: 2026-03-13  
**Status**: Accepted  

**Context**: 
Need formal benchmarks to guide development and prevent performance regressions.

**Decision**: 
Establish strict targets for ZyncBase v1.0.

| Metric | Target | Measurement |
| :--- | :--- | :--- |
| Concurrent connections | 100,000+ | Sustained |
| Requests/second | 200,000+ | Mixed workload |
| Latency (p50) | < 1ms | In-memory ops |
| Latency (p99) | < 10ms | Including disk |
| Memory per connection | < 1KB | Excluding buffers |
| Binary size | < 15MB | Stripped |
| Cold start time | < 100ms | To ready state |

**Principles Alignment**: 
- #8 Predictable Performance

---

## ADR-021: Fine-Grained Subscription Invalidation

**Date**: 2026-03-09  
**Status**: Accepted  

**Decision**: 
Exclusively use fine-grained change detection with in-memory AST evaluation.

**Rationale**:
- Avoids O(N) scaling issues of re-running SQL queries for every write.
- Sub-100ms sync requires avoiding disk loop during broadcast phase.

**Principles Alignment**: 
- #1 Real-time First
- #8 Predictable Performance

---

## ADR-022: Formal Error Taxonomy and Handling Strategy

**Date**: 2026-03-13  
**Status**: Accepted  

**Decision**: 
Implement a 7-category error taxonomy (Connection, Auth, AuthZ, Validation, Rate-Limit, Server, Hook) that dictates automatic SDK behavior.

**Principles Alignment**: 
- #5 TypeScript-First
- #9 Secure by Default

---

## ADR-023: Unified Subscription Engine for All Read Operations

**Date**: 2026-03-31  
**Status**: Accepted  

**Context**:  
ZyncBase defines 4 SDK read commands (`get`, `listen`, `query`, `subscribe`) mapped to 4 wire message types. The message handler splits reads between `StorageEngine` and `SubscriptionManager`, creating dual code paths for semantically overlapping operations. The path-based commands are strict subsets of the collection-based ones. ADR-021 already mandates in-memory AST evaluation for subscriptions; this ADR extends that into a unified read architecture.

**Decision**:  
Introduce a single Subscription Engine as the sole entry point for all server-side read operations.

**Wire Protocol — 4 → 2 Read Message Types**:  
Remove `StoreGet`, `StoreListen`, `StoreUnlisten`. All reads go through `StoreQuery` (one-shot: return results, done) and `StoreSubscribe` (ongoing: return snapshot, push `StoreDelta` until `StoreUnsubscribe`). Retained: `StoreUnsubscribe`, `StoreLoadMore`, `StoreDelta`.

**SDK Path Decomposition**:  
The SDK translates `get(path)`/`listen(path, cb)` into `StoreQuery`/`StoreSubscribe` by decomposing paths into collection-level queries with id filters. For example, `get('users.u1.name')` becomes `StoreQuery('users', { where: { id: { eq: 'u1' } } })` with SDK-side field extraction. The SDK maintains a local value cache for field-level change detection and serves exact-match queries from cache when an active subscription already covers the data.

**Subscription Engine**:  
Replaces the current split between `StorageEngine` (reads) and `SubscriptionManager`. On `StoreQuery`: if collection is warm (has active subscriptions), evaluate from memory; if cold, query SQLite directly — one-shot queries do not warm the engine. On `StoreSubscribe`: warm from SQLite if cold, register subscriber, push deltas via edge-transition evaluation on `RowChange` events. On `RowChange`: update in-memory state, evaluate against subscriber groups, push `StoreDelta` to matches.

**Subscriber Grouping**:  
Clients with identical `(namespace, collection, where, orderBy)` share one internal evaluation. `limit` is per-subscriber metadata. New subscribers joining an existing group receive the current snapshot immediately.

**Record-Level Deltas Only**:  
Server broadcasts `set` (full record — covers both add and update) and `remove` (record ID only) at record granularity. No field-level patches from server. SDK handles field projection.

**Lock-Free Cache Coexistence**:  
Subscription engine replaces the lock-free cache for application data reads. Lock-free cache continues for permission snapshots and schema metadata.

**Eviction**: Collection state evicted on last unsubscribe. Disconnect triggers auto-unsubscription.

**Memory Budget**: Configurable `subscriptionEngine.maxMemoryMB`. New subscriptions rejected with `RESOURCE_EXHAUSTED` when limit approached.

**`loadMore`**: Always hits SQLite on disk in v1.

**Deferred**: In-memory SQLite for warm-start/fast `loadMore`; SDK subset query matching; specialized per-field index structures (interval trees, trigrams, tries).

**Principles Alignment**:  
- #1 Real-time First
- #5 TypeScript-First
- #8 Predictable Performance

**Supersedes / Modifies**:  
- Narrows ADR-005: Lock-free cache role reduced to auth/schema metadata.
- Extends ADR-021: In-memory AST evaluation now covers all reads.

**Consequences**:  
- ✅ Wire protocol reads halved (4 → 2). Single server-side code path.
- ✅ Subscriber grouping: O(1) evaluation per unique subscription, not per client.
- ✅ SDK local cache eliminates redundant round-trips.
- ⚠️ First subscribe to cold collection incurs SQLite read.
- ⚠️ `loadMore` always hits disk.
- ⚠️ Subscription engine is significant implementation effort.
