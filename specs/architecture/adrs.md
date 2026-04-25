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
- **Paths**: SDK accepts `'users.u1.name'`, wire sends `[0, 'u1', 2]` (mapped via ADR-025 dictionary indices).
- **Query conditions**: SDK accepts `{ age: { gte: 18 } }`, wire sends `[3, 4, 18]` (positional tuple: `[field_index, op_code, value]`).
- **Sort descriptors**: SDK accepts `{ created_at: 'desc' }`, wire sends `[8, 1]` (positional tuple: `[field_index, desc_flag]`).
- **Nested Fields**: SDK accepts `'users.u1.address.city'`, internally flattens to `address__city`, and sends the mapped integer `field_index`.

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

---

## ADR-024: Canonical Sorted-Set Semantics for Typed Array Fields

**Date**: 2026-04-17  
**Status**: Accepted  

**Context**:  
Typed array fields are commonly used for tags, labels, and roles. During implementation, ZyncBase introduced canonicalization (sort + dedupe) for typed arrays to improve developer experience, determinism, and runtime performance. This behavior is now a formal architectural contract.

**Decision**:  
ZyncBase treats schema-defined typed arrays (`type: "array"` + primitive `items`) as canonical sorted sets.

1. **Write-path normalization**
   - Validate each element against `items` type.
   - Reject `null`, nested arrays, and objects.
   - Sort elements with a type-aware comparator.
   - Remove duplicates.

2. **Persistence contract**
   - Persist only the canonicalized representation to SQLite.

3. **Read contract**
   - Return canonicalized arrays (sorted, unique) on reads.

4. **Query contract**
   - `contains` on array fields is membership over canonical set content.
   - `eq` / `ne` on array fields use canonical equality semantics (set-equivalent for valid typed arrays).
   - `in` / `notIn` operand arrays are canonicalized during parsing (order-insensitive, duplicate-insensitive semantics).

5. **Scope**
   - Arrays of objects remain unsupported.
   - Unsupported operators for array fields remain invalid (e.g., `gt`, `startsWith`).

**Rationale**:
- Better DX for tag-like fields.
- Deterministic storage and comparisons.
- Faster membership/equality behavior in SQL and in-memory evaluation.

**Principles Alignment**:  
- #5 TypeScript-First  
- #8 Predictable Performance

---

## ADR-025: Schema Dictionary Compression (Integer Routing)

**Date**: 2026-04-18  
**Status**: Accepted  

**Context**:  
ZyncBase handles extremely high message throughput. Server-side routing using string-based collection names and field names requires allocating strings, computing hashes, and performing hash map lookups for every read and write operation. Sending repeated strings over the wire also increases bandwidth usage substantially.

**Decision**:  
Replace all schema-defined string identifiers with dense integer mappings over the wire protocol for `Store` operations. 

1. **SchemaSync Handshake**: Immediately after connection, the server pushes a `SchemaSync` message containing positional arrays of tables and fields (including system columns). 
2. **SDK Runtime Dictionary**: The client SDK dynamically builds an in-memory string-to-integer mapping at runtime from this payload.
3. **Payload Translation**: The SDK resolves all developer-provided logical string paths (`'users.u1.address.city'`) into integer arrays representing `[table_index, id, field_index]` before sending them to the server. Operation values use integer-keyed maps (`{ 2: "Alice" }`) to safely permit sparse updates without payload ambiguity.
4. **Presence Exemptions**: `Presence` APIs are explicitly exempt from this optimization and continue to use string-based properties, as they lack formal schema definitions.
5. **Offline Safety**: The SDK hashes the `SchemaSync` payload to detect unexpected schema modifications across server restarts, safeguarding offline operation queues against catastrophic index shifting.

**Rationale**:
- **Performance**: Transforms O(N) string hashing and map lookups in Zig into O(1) direct array assignments. Memory allocations for strings in parsing logic are completely removed.
- **Bandwidth**: Exchanging 1-byte integers via MessagePack instead of repetitive strings massively reduces typical payload footprint.
- **Forward Compatibility**: Sending the dictionary arrays from the server dynamically guarantees that older, stale mobile clients can automatically adapt to newly injected fields without breaking. 

**Principles Alignment**:  
- #8 Predictable Performance
- #1 Real-time First
- #5 TypeScript-First

---

## ADR-026: Internal Namespace Dictionary (Integer Routing for Namespaces)

**Date**: 2026-04-24  
**Status**: Accepted  

**Context**:  
Namespaces are highly dynamic strings (e.g., `tenant:acme:project-123`). Storing these strings directly in SQLite for every row wastes massive amounts of space (up to 300MB per 10 million rows) and makes index lookups much slower than integers. However, pushing namespace mapping to `config.json` is impossible due to their dynamic nature.

**Decision**:  
Implement a hidden internal system table `_zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)`. Reserve ID `0` for the global namespace (`$global`); client-created/runtime namespaces use positive IDs. The wire protocol remains untouched (the client sends the string namespace once via `StoreSetNamespace` or `PresenceSetNamespace`). The Zig engine implicitly upserts the namespace string into this table on connection, caches the integer ID on the WebSocket connection state, and uses this integer for all SQLite `namespace_id` reads and writes.

**Rationale**:
- Drastically reduces database size.
- Significant performance gain on SQLite index lookups.
- Zero added friction for the developer or the Client SDK (strings are still used externally).
- Wire protocol remains stateful and optimized (no strings sent per data message).

**Principles Alignment**:  
- #8 Predictable Performance  
- #5 TypeScript-First

---

## ADR-027: The `owner_id` System Column and Stateless Authorization Limits

**Date**: 2026-04-24  
**Status**: Accepted  

**Context**:  
Need to provide secure multi-tenancy and object-level ownership authorization out of the box without forcing the developer to immediately write Hook Server code. We also need to draw a hard line on the complexity of JSON-based authorization rules to maintain real-time performance.

**Decision**:  
1. Add `owner_id` as a built-in system column to all storage tables, alongside `id`, `namespace_id`, `created_at`, and `updated_at`.
2. Store `owner_id` as the same packed `doc_id` representation as `id` (`BLOB(16)` UUIDv7), never as an external identity string.
3. Implement an implicit `users` system table that maps external string identity claims (e.g., Auth0 `sub`) in its `external_id` (`TEXT`) column to an internal ZyncBase `id` (`BLOB(16)` UUIDv7).
4. Keep `owner_id` on `users` for table-shape consistency; for each `users` row, `owner_id` is equal to `id`.
5. On WebSocket connection, the Zig engine maps the JWT's `sub` to this internal UUIDv7, storing it in `$session.userId` to ensure `owner_id` on all tables is safely typed as `BLOB(16)`.
6. Automatically populate `owner_id` with the internal `$session.userId` upon document creation.
7. Strictly limit `authorization.json` evaluation in Zig to five variables: `$session` (resolved session context), `$namespace` (parsed active namespace), `$path` (target table/collection), `$doc` (same-row SQLite column predicates via AST injection), and `$value` (incoming mutation).
8. `$doc` may only reference columns on the target row being selected, updated, or deleted. Any rule requiring a relational join, relationship traversal, or lookup of another table (e.g., checking a separate `project_members` table) is explicitly forbidden in JSON and MUST be delegated to the Hook Server.

**Rationale**:
- `owner_id` enables code-free, object-level security (`$doc.owner_id == $session.userId`).
- The `users` mapping table guarantees `owner_id` remains a compact 16-byte binary format, perfectly matching ZyncBase's standard `doc_id` representation and saving ~20 bytes per row compared to storing external string IDs.
- Keeping `owner_id` on `users` avoids table-shape exceptions in DDL generation, authorization defaults, replication payloads, and query planning while preserving self-ownership semantics.
- Strict limits on the evaluation context guarantee predictable nanosecond/microsecond rule evaluation and same-row SQL predicate injection, preventing the "slow query" problem in the auth layer.

**Principles Alignment**:  
- #1 Primitives over Magic (Exposing `users` as a standard collection instead of a hidden config)
- #8 Predictable Performance  
- #9 Secure by Default

---

## ADR-028: Global Master Data (namespaced: false)

**Date**: 2026-04-25  
**Status**: Accepted  

**Context**:  
By default, all ZyncBase collections are horizontally partitioned by a `namespace_id`. However, SaaS applications frequently require master data tables (e.g. `users`, `pricing_tiers`, `global_settings`) that must transcend namespace boundaries and be visible globally.

**Decision**:  
1. Introduce a `"namespaced": boolean` primitive in `schema.json` collection definitions.
2. All storage tables retain the standard system columns, including `namespace_id` and `owner_id`; `namespaced` changes how `namespace_id` is assigned and filtered, not whether the column exists.
3. If `namespaced` is omitted, it defaults to `true`, and Zig stores the active namespace ID in `namespace_id` and filters reads/writes by that active namespace.
4. If `namespaced` is set to `false`, Zig stores reserved global namespace ID `0` in `namespace_id` and routes queries through that global namespace instead of the client's active namespace.
5. The reserved `users` system collection defaults to `"namespaced": false`.
6. `users` MAY be configured with `"namespaced": true` for tenant-isolated identity realms. In that mode, external identity mapping is scoped by `(namespace_id, external_id)`, `$session.userId` is resolved for the active namespace, and namespace switching requires re-resolving or re-authenticating the session.

**Rationale**:  
- Provides developers with the flexibility to define multiple global data collections without opinionated server-side logic.
- Avoids the anti-pattern of duplicating static master data across thousands of tenant namespaces.
- Maintains strict "Secure by Default" semantics by enforcing namespacing unless explicitly opted-out.
- Preserves a uniform physical table shape, avoiding null-heavy special cases and keeping field indexes, DDL generation, migrations, and authorization predicates consistent.
- Avoids broad `namespace_id = :active_namespace_id OR namespace_id = 0` predicates in hot paths. Each table has exactly one namespace predicate selected from schema metadata: active namespace for namespaced tables, `0` for global tables.

**Principles Alignment**:  
- #1 Primitives over Magic
- #3 SQLite as the Source of Truth
