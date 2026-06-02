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
**Status**: Superseded by ADR-031  

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
- Less flexible than code-based config by design; application-specific authorization inputs must come from trusted identity claims.

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
**Status**: Superseded by [ADR-032](#adr-032-config-driven-authentication-and-external-permission-claims)  

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
- ⚠️ Developers must rely on computed properties or application-side search for complex search.

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
**Status**: Accepted (Modified by ADR-032)  

**Decision**: 
Implement a 6-category error taxonomy (Connection, Auth, AuthZ, Validation, Rate-Limit, Server) that dictates automatic SDK behavior.

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
Replaces the current split between `StorageEngine` (reads) and `SubscriptionManager`. On `StoreQuery`: if collection is warm (has active subscriptions), evaluate from memory; if cold, query SQLite directly — one-shot queries do not warm the engine. On `StoreSubscribe`: warm from SQLite if cold, register subscriber, push deltas via edge-transition evaluation on `RecordChange` events. On `RecordChange`: update in-memory state, evaluate against subscriber groups, push `StoreDelta` to matches.

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
Need to provide secure multi-tenancy and object-level ownership authorization out of the box. We also need to draw a hard line on the complexity of JSON-based authorization rules to maintain real-time performance.

**Decision**:  
1. Add `owner_id` as a built-in system column to all storage tables, alongside `id`, `namespace_id`, `created_at`, and `updated_at`.
2. Store `owner_id` as the same packed `doc_id` representation as `id` (`BLOB(16)` UUIDv7), never as an external identity string.
3. Implement an implicit `users` system table that maps external string identity claims (e.g., Auth0 `sub`) in its `external_id` (`TEXT`) column to an internal ZyncBase `id` (`BLOB(16)` UUIDv7).
4. Keep `owner_id` on `users` for table-shape consistency; for each `users` row, `owner_id` is equal to `id`.
5. During scoped session resolution, the Zig engine maps the external identity string (SDK anonymous client ID or authenticated JWT `sub`) to this internal UUIDv7, storing it in `$session.userId` to ensure `owner_id` on all tables is safely typed as `BLOB(16)`.
6. Automatically populate `owner_id` with the internal `$session.userId` upon document creation.
7. Treat `id` as the document identity for a collection. It is expected to be unique across the whole collection/table; `namespace_id` is not part of the primary key and is only a routing/filtering column.
8. Strictly limit `authorization.json` evaluation in Zig to five variables: `$session` (resolved session context), `$namespace` (parsed active namespace), `$path` (target table/collection), `$doc` (same-row SQLite column predicates via AST injection), and `$value` (incoming mutation).
9. `$doc` may only reference columns on the target row being selected, updated, or deleted. Any rule requiring a relational join, relationship traversal, or lookup of another table (e.g., checking a separate `project_members` table) is explicitly forbidden in JSON. Those permissions must be represented in trusted external identity claims or encoded on the same row being authorized.

**Rationale**:
- `owner_id` enables code-free, object-level security (`$doc.owner_id == $session.userId`).
- The `users` mapping table guarantees `owner_id` remains a compact 16-byte binary format, perfectly matching ZyncBase's standard `doc_id` representation and saving ~20 bytes per row compared to storing external string IDs.
- Keeping `owner_id` on `users` avoids table-shape exceptions in DDL generation, authorization defaults, replication payloads, and query planning while preserving self-ownership semantics.
- Keeping identity as `PRIMARY KEY(id)` avoids composite key fan-out in foreign keys, caches, cursor tie-breakers, and SDK APIs. Namespaces constrain visibility; they do not redefine document identity.
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
6. `users` MAY be configured with `"namespaced": true` for tenant-isolated identity realms. In that mode, external identity mapping is scoped by `(namespace_id, external_id)`, and store/presence namespace switching requires re-resolving the affected scoped `$session.userId`.

**Rationale**:  
- Provides developers with the flexibility to define multiple global data collections without opinionated server-side logic.
- Avoids the anti-pattern of duplicating static master data across thousands of tenant namespaces.
- Maintains strict "Secure by Default" semantics by enforcing namespacing unless explicitly opted-out.
- Preserves a uniform physical table shape, avoiding null-heavy special cases and keeping field indexes, DDL generation, migrations, and authorization predicates consistent.
- Avoids broad `namespace_id = :active_namespace_id OR namespace_id = 0` predicates in hot paths. Each table has exactly one namespace predicate selected from schema metadata: active namespace for namespaced tables, `0` for global tables.

**Principles Alignment**:  
- #1 Primitives over Magic
- #3 SQLite as the Source of Truth

---

## ADR-029: Scoped Session Readiness Gate

**Date**: 2026-05-05  
**Status**: Accepted  

**Context**:  
ADR-026 established integer namespace routing, ADR-027 established `owner_id` as an internal `users.id`, and ADR-028 allowed `users.namespaced = true`. Implementing these together exposed a missing invariant: a WebSocket transport can be open before the server has enough scoped context to safely process store or presence operations. In particular, when `users.namespaced = true`, the same external identity string can resolve to a different `users.id` per namespace. Therefore identity resolution cannot be treated as a hardcoded anonymous UUID or as transport-only state.

**Decision**:  
1. Distinguish transport connectivity from scoped session readiness.
2. Store the external identity string on the connection. For anonymous clients this is the SDK-generated anonymous subject; for authenticated clients this is the JWT subject.
3. Resolve every operation-domain scope through SQLite before accepting scoped operations. A scope consists of:
   - the namespace string resolved to `_zync_namespaces.id`
   - the external identity resolved to `users.id`
   - the resolved `users.id` stored as the scope's `$session.userId`
4. Store and presence maintain separate scopes because their namespaces can differ. Store operations require the store scope to be ready. Presence operations require the presence scope to be ready.
5. If `users.namespaced = false`, identity resolution always uses reserved global namespace ID `0`, so store and presence scopes usually share the same `users.id`.
6. If `users.namespaced = true`, identity resolution uses the namespace ID of the scope being resolved. Store namespace switching re-resolves the store user ID; presence namespace switching re-resolves the presence user ID.
7. Before a scope is ready, the server only accepts lifecycle messages needed to establish or refresh scope: authentication/identity refresh, store namespace selection, presence namespace selection, ping/pong, and close. Store, query, subscription, and presence data messages are rejected with `SESSION_NOT_READY`.
8. Namespace or identity changes invalidate dependent scoped state. Store namespace changes clear store subscriptions. Presence namespace changes clear old presence and presence subscriptions. Auth refresh re-resolves all active scopes before they become ready again.

**Rationale**:
- Preserves the `users.namespaced = true` feature without making identity ambiguous.
- Ensures `owner_id` and presence `userId` always correspond to persisted `users.id` rows.
- Keeps SDK ergonomics simple: `connect({ storeNamespace, presenceNamespace })` can still resolve only after both initial scopes are ready.
- Avoids special anonymous-user shortcuts that bypass SQLite and later break foreign keys, authorization, or auditability.

**Principles Alignment**:  
- #1 Primitives over Magic
- #3 SQLite as the Source of Truth
- #7 Secure by Default

---

## ADR-030: Async Session Resolution (Non-Blocking Reactor Handoff)

**Date**: 2026-05-06  
**Status**: Proposed  

**Context**:  
ADR-029 established the scoped session readiness gate, where `StoreSetNamespace` triggers namespace and user identity resolution through the writer thread. The initial implementation uses `CompletionSignal.wait()` — a Mutex+Condition blocking call — on the uWS event loop thread to synchronously wait for the writer thread's result. This blocks the entire reactor for 500μs–2ms per resolution, stalling all concurrent WebSocket connections and violating the p50 < 1ms latency target (ADR-020).

The problem is specific to `StoreSetNamespace` (and the future `PresenceSetNamespace` / `AuthRefresh`). All other operations are either accepted/eventual writes (ADR-031) or fast reader-pool reads. Resolution is the only code path that performs a blocking round-trip to the writer thread from the uWS reactor.

**Decision**:  
Replace blocking `CompletionSignal.wait()` resolution with a two-tier strategy: an in-memory identity cache for the common case, and an async SPSC ring buffer + event loop wakeup handoff for cache misses.

1. **Two-tier resolution**:
   - **Tier 1 (sync, ~1μs)**: Check lock-free namespace and user identity caches on the uWS thread. If both hit, set scope and respond immediately — zero I/O, zero blocking.
   - **Tier 2 (async, non-blocking)**: On cache miss, enqueue a combined `resolve_session` WriteOp to the writer thread and return immediately without sending a response. The uWS reactor is free.

2. **Identity caches**: Two new `lockFreeCache` instances on `StorageEngine`:
   - `namespace_cache`: Maps `hash(namespace_string)` → `namespace_id` (i64). Populated by the writer thread after `INSERT OR IGNORE INTO _zync_namespaces ... RETURNING id`. Immutable once set (namespace IDs never change).
   - `identity_cache`: Maps `hash(identity_namespace_id, external_user_id)` → `users.id` (DocId). Populated by the writer thread after `INSERT OR IGNORE INTO users ... RETURNING id`. Immutable once set (user ID mappings never change).
   - Both caches reuse the existing `lockFreeCache` generic with epoch-based reclamation, atomic ref-counting, and COW map swaps. Values are trivial (no heap allocations), so `deinit` is a no-op.

3. **Combined `resolve_session` WriteOp**: Replaces the separate `upsert_namespace` and `resolve_user` WriteOp variants. Performs both namespace and user resolution in a single writer-thread pass, reducing two sequential round-trips to zero blocking round-trips.

4. **`SessionResolutionBuffer`**: An SPSC ring buffer (capacity 256) following the same pattern as `ChangeBuffer`. The writer thread pushes `SessionResolutionResult` structs; the uWS post_handler drains them.

5. **`SessionResolver`**: A new component (parallel to `NotificationDispatcher`) that runs in the uWS post_handler. It drains the `SessionResolutionBuffer`, acquires the target connection by ID, applies the resolved scope, encodes the success/error response, and calls `ws.send()`.

6. **`scope_seq` monotonic counter**: A per-connection counter incremented on each store scope reset (under `Connection.mutex`). Carried in the `resolve_session` WriteOp and checked at delivery time. If the connection's current `scope_seq` doesn't match the result's `scope_seq`, the result is stale (client sent another `StoreSetNamespace` in the meantime) and is discarded.

7. **Buffer capacity rationale (256)**:
   - `StoreSetNamespace` is a lifecycle message sent ~1x per connection session, not in hot data paths.
   - The writer thread processes ~5,000–10,000 resolutions/second; the post_handler drains every uWS loop iteration (~1ms).
   - Worst-case thundering herd (100k reconnections): the buffer accumulates at most ~10–50 results between drain cycles.
   - 256 provides 25x headroom over the realistic worst case. On overflow, the writer logs an error and the client retries via SDK timeout.

**Rationale**:
- **Tier 1 eliminates I/O for the common case**: After the first resolution of a given (namespace, user) pair, all subsequent connections with the same pair resolve in ~1μs from the lock-free cache — no reader pool mutex, no SQLite, no writer thread.
- **Tier 2 eliminates reactor blocking for cold starts**: New (namespace, user) pairs resolve on the writer thread without blocking the uWS reactor. The response is delivered asynchronously via the same battle-tested `ChangeBuffer` + `us_wakeup_loop()` + `post_handler` pattern used by `NotificationDispatcher`.
- **Single WriteOp**: Combining namespace + user resolution reduces the number of WriteOp variants (2 → 1) and eliminates the need for two sequential writer thread round-trips on cache miss.
- **ADR-029 correctness preserved**: `store_ready` remains `false` until the resolver delivers the result (or the cache fast-path sets it synchronously). Messages arriving before resolution still receive `SESSION_NOT_READY`.
- **Connection safety**: Connections may disconnect during async resolution. The `SessionResolver` uses `ConnectionManager.acquireConnection()` (ref-counted) to safely discard results for disconnected clients — identical to `NotificationDispatcher`'s pattern.

**Supersedes / Modifies**:  
- Extends ADR-026: Namespace string → integer resolution now happens through a lock-free cache first, writer thread second.
- Extends ADR-029: Scoped session resolution is now non-blocking on the uWS reactor.
- Extends ADR-011: Lock-free cache role expanded to include namespace and user identity mappings alongside auth/schema metadata.

**Consequences**:  
- ✅ Zero blocking on the uWS reactor thread for session resolution.
- ✅ Common case (warm cache) resolves in ~1μs — 500x faster than the blocking path.
- ✅ Simpler WriteOp surface: `upsert_namespace` + `resolve_user` consolidated into `resolve_session`.
- ✅ Other connections completely unaffected during cold-start resolution.
- ⚠️ Async response delivery adds ~1 event loop iteration of latency for cache misses (negligible in practice).
- ⚠️ Two new lock-free cache instances add memory proportional to the number of unique (namespace, user) pairs — typically small.

---

## ADR-031: Mutation Acknowledgement and Realtime Consistency Semantics

**Date**: 2026-05-25  
**Status**: Accepted  
**Supersedes**: ADR-007: Optimistic Writes by Default  

**Context**:
ZyncBase is a realtime-first database. Client-visible state is observed through subscriptions, and committed changes become visible through server-pushed subscription deltas.

Mutation acknowledgement semantics must be explicit because writes pass through an asynchronous server-side write pipeline. A mutation can be accepted by the server before the writer thread has committed it. Separately, a subscription update can arrive after the mutation response. These are related but distinct events.

The TypeScript SDK does not optimistically update local subscription data for mutating operations such as `store.set`, `store.remove`, and `store.batch`. Local subscription state changes only when the server emits subscription updates. Therefore, write failure reporting is not needed for rollback. It is needed for user feedback, diagnostics, and workflows that require precise write outcome reporting.

**Decision**:
ZyncBase uses subscription-first eventual state propagation as the default consistency model for client-visible data.

Default mutation methods are accepted/eventual writes:

- `store.set`, `store.remove`, and `store.batch` do not optimistically mutate local subscription state.
- A successful default mutation response means the server accepted the mutation request into the write pipeline.
- A successful default mutation response does not mean the write has committed.
- Subscription callbacks are the authoritative source of committed observable state.
- Clients must not infer write failure solely from the absence of a subscription delta.

ZyncBase distinguishes two confirmation levels:

```ts
await store.set(path, value);
await store.set(path, value, { confirm: "accepted" });
// Resolves when the server accepts the mutation into the write pipeline.

await store.set(path, value, { confirm: "committed" });
// Resolves when the writer commits the mutation or an accepted no-op.
// Rejects when the writer reports failure.
```

`confirm: "accepted"` is the default and may be represented in SDK types, but ordinary examples should prefer the no-options form. `confirm: "committed"` applies only to mutating operations: `store.set`, `store.remove`, and `store.batch`.

**Terminology**:

- **accepted**: the server parsed, validated, authorized as far as possible before enqueue, and accepted the mutation into the write pipeline.
- **committed**: the writer-thread result succeeded, including accepted no-op outcomes.
- **request id**: the existing request/response correlation id for immediate `ok` or `error` responses.
- **writeId**: the correlation id for tracked or confirmed writer-thread outcomes.
- **WriteError**: an asynchronous writer failure message or SDK event.

The public protocol and SDK documentation must not use "NACK" for this feature. Writer failures are write errors, not rollback commands.

**Immediate Request Errors**:
Immediate request errors reject the mutation before the writer owns the operation.

Examples include:

- malformed messages
- invalid paths
- invalid payload shapes
- unknown tables or fields detected before enqueue
- session not ready
- authorization failures detected before enqueue
- queue admission failure
- other request handling failures before writer ownership

Confirmed write failures and immediate request failures use the same SDK error type, `ZyncBaseError`, with metadata identifying the phase:

```ts
{
  phase: "accept" | "write"
}
```

**Write Outcome Reporting**:
Writer-thread failures are exposed as write errors, not as subscription state and not as rollback instructions.

Tracked or confirmed writes use `writeId` to correlate writer outcomes. The existing request `id` remains scoped to the immediate request response.

For confirmed writes, the SDK promise is the public success signal. ZyncBase does not expose a public `WriteCommitted` event as part of the core API. If the confirmed write promise resolves, the write committed or produced an accepted no-op. If it rejects, the writer reported failure or confirmation was not received.

`WriteError` is the public async failure name:

```ts
{
  type: "WriteError",
  writeId: "...",
  code: "PERMISSION_DENIED",
  message: "...",
  details: {
    phase: "write"
  }
}
```

`path` is best-effort metadata:

- single `set` or `remove`: include `path` when available
- batch failure with known operation: include `path` and `batchIndex`
- transaction-level or systemic failure: `path` may be omitted

Global write-error events are for tracked writes or systemic writer failures. Default untracked writes do not receive guaranteed per-operation async error delivery after acceptance.

**Subscription Ordering**:
Commit confirmation and subscription delivery are not ordered relative to each other.

If a confirmed write resolves, matching active subscriptions will eventually receive the corresponding state change, subject to normal subscription filtering and connection state. The SDK must not guarantee that a subscription callback has already run before the confirmed write promise resolves.

Subscriptions remain the authoritative committed-state channel. Write confirmation is outcome reporting, not state delivery.

**Batch Semantics**:
`store.batch(..., { confirm: "committed" })` is atomic:

- resolves only if the full batch commits or produces accepted no-op outcomes
- rejects if any operation fails
- exposes no partial success result in the public API
- does not commit partial writes on failure

Batch failures include `batchIndex` when the failing operation can be identified:

```ts
{
  code: "PERMISSION_DENIED",
  message: "...",
  details: {
    batchIndex: 2,
    phase: "write"
  }
}
```

For transaction-level failures where no single operation caused the failure, `batchIndex` is omitted.

Default `store.batch()` follows the same accepted/eventual contract as individual writes.

**Authorization Semantics**:
Write authorization rules must preserve this invariant:

> A client must not be able to create a document that the same session could not later update under the same write rules.

For `StoreSet`, `$doc` in write rules is interpreted by write kind:

- **Create**: `$doc` is the candidate document being created.
- **Update**: `$doc` is the existing stored document.
- **Delete**: `$doc` is the existing stored document.

Create authorization is evaluated in RAM against the candidate document. The candidate document includes:

- document id
- injected `owner_id = $session.userId`
- incoming normalized fields
- server-managed fields and defaults when applicable

Because `owner_id` is injected by the server, ownership rules such as the following naturally pass for creates by the owning session:

```json
{ "$doc.owner_id": { "eq": "$session.userId" } }
```

If a create rule references a `$doc` field that is absent from the candidate document and is not server-injected or defaulted, the create is denied.

Update and delete authorization remains guarded against existing stored rows. ZyncBase does not require general post-image authorization for updates. A user may update a document they are currently allowed to write into a state that they cannot later update under the same rule.

For example, a write rule that allows writes only while `status == "draft"` can allow an update from `draft` to `published`; after that transition, the same rule no longer allows further updates.

**No-Op Semantics**:

Deleting a missing document is success/no-op.

Setting a field or document to the same canonical stored value is success. ZyncBase may suppress deltas when the canonical stored value did not change. Applications must not rely on a delta for same-value writes.

A committed write that does not match one of the client's active subscriptions is not a write error. A write may produce no delta for a subscription because it is filtered out, targets data the client is not subscribed to, or does not change the subscription result.

Default accepted writes do not perform extra storage reads solely to classify writer zero-row outcomes. Confirmed writes may classify guarded zero-row outcomes to produce precise errors:

- existing row fails write guard: `PERMISSION_DENIED`
- absent row for idempotent delete: success/no-op
- storage or transaction failure: appropriate storage error

**Connection And Failure Semantics**:
Operation status is retained in memory and scoped to the originating live connection for tracked or confirmed writes. ZyncBase does not retain durable write-status records across disconnects.

If the connection drops before a confirmed write result is delivered, the SDK rejects the promise with a connection error. The write may still later commit. After reconnect, subscriptions remain the source of truth for final state.

Confirmed writes need a timeout. A timeout means confirmation was not received; it does not imply the write was aborted or failed to commit.

ZyncBase does not guarantee abort after a write has been accepted into the writer pipeline.

Automatic idempotency keys for retried writes are outside this decision. Some operations are naturally idempotent, but exactly-once retry behavior requires a separate idempotency design.

Systemic writer or storage failures are engine health events, not only individual write failures. If the writer encounters a condition that prevents reliable write processing, new writes should fail during acceptance once the engine is marked unhealthy. Confirmed writes reject with `ZyncBaseError`, and server or connection status should surface the degraded state.

Write errors classify retryability conservatively:

- transient operational failures may be retryable
- access denied, invalid values, schema errors, and constraint violations are not retryable
- operator-action conditions such as disk full should not encourage automatic client retry loops

**Rationale**:
This decision separates three concepts:

- request acceptance: the server accepted the mutation into the write pipeline
- state observation: subscriptions delivered committed observable state
- write outcome reporting: optional operation status and error feedback for user workflows

This preserves ZyncBase's realtime-first model while giving applications precise feedback when user-facing actions require it.

Making every mutation wait for writer commit would push ZyncBase toward request/response database semantics and increase latency for writes that only require eventual subscription propagation. Restoring optimistic local writes would require rollback and conflict handling complexity that the current subscription-first model avoids.

Write errors remain valuable, but their purpose is user feedback and diagnostics, not local state repair.

**Consequences**:

Positive:

- Keeps default writes low latency.
- Preserves subscriptions as the authority for committed client-visible state.
- Avoids optimistic rollback machinery.
- Gives UI-critical workflows precise committed-write confirmation.
- Gives tracked writes a clear async failure reporting model.
- Keeps request ids and writer outcome ids conceptually separate.

Negative:

- `await store.set()` does not mean "committed"; documentation must be explicit.
- Applications that need save confirmation must request committed confirmation.
- Confirmed writes add writer-result correlation and timeout handling.
- Confirmed authorization errors may require additional classification work.

**Rejected Alternatives**:

### Make every mutation wait for writer commit

Rejected as the default because it changes the default programming model from realtime/eventual to strongly confirmed request/response writes, increasing latency for all writes.

### Restore optimistic local writes

Rejected for default SDK behavior. Optimistic local writes require rollback, conflict handling, and more complex local materialized-view semantics.

### Do not report writer-thread failures to clients

Rejected as the complete model. Missing subscription deltas are ambiguous and cannot support user-facing save failure feedback.

### Use eventual NACKs as rollback messages

Rejected. There is no speculative local subscription state to roll back. Writer failures are write-status errors, not rollback commands.

### Reuse request id as the writer outcome id

Rejected. Request ids correlate immediate request responses. Writer outcomes need a separate `writeId` for tracked or confirmed writes.

---

## ADR-032: Config-Driven Authentication and External Permission Claims

**Date**: 2026-06-02  
**Status**: Accepted  

**Supersedes / Modifies**:
- Supersedes [ADR-016: Bun Hook Server](#adr-016-bun-hook-server).
- Modifies [ADR-027: The `owner_id` System Column and Stateless Authorization Limits](#adr-027-the-owner_id-system-column-and-stateless-authorization-limits).
- Modifies [ADR-029: Scoped Session Readiness Gate](#adr-029-scoped-session-readiness-gate).

**Context**:
ZyncBase needs secure authentication, anonymous access, tenant/project authorization, and object ownership without becoming an identity provider or embedding arbitrary application logic into the database. The previous Bun Hook Server design allowed TypeScript functions to enrich sessions and perform relational permission checks, but it added an extra runtime, an internal protocol, latency, circuit-breaker behavior, and a blurred product boundary.

The clearer boundary is that ZyncBase is a resource server. It validates external identity material and enforces declarative rules. It does not compute the source of truth for user accounts, memberships, billing state, or permission grants.

**Decision**:
1. Remove Bun Hook Server support from the active design.
2. Keep the HTTP ticket exchange, but make it fully native and configuration-driven.
3. ZyncBase validates external JWTs from configured issuers, audiences, algorithms, shared secrets, or JWKS sources.
4. ZyncBase projects verified JWT claims into `$session` according to configuration. The configuration file defines the mapping of JWT claim names to `$session` variables. Permission claims such as `role`, `permissions`, `read_projects`, `write_projects`, `tenant_id`, and `org_id` are trusted only because the token signature and registered constraints were validated.
5. Anonymous access uses the same ticket pipeline. The SDK generates a high-entropy anonymous subject, persists it locally, and presents it as an anonymous external identity when anonymous auth is enabled.
6. The `users` table remains the internal identity mapping and optional profile/display-data table. It maps the external subject to an internal `BLOB(16)` UUIDv7 used by `owner_id`, `$session.userId`, presence identity, and foreign keys. User-row fields are not loaded for authorization and are not part of `$session`.
7. `authorization.json` remains limited to RAM checks over `$session`, `$namespace`, `$path`, and `$value`, plus same-row `$doc` predicates lowered to the store query predicate model.
8. Any permission requiring joins, relationship traversal, external API calls, billing lookups, or permission graph computation must be represented before ZyncBase receives the request: in the trusted token, in same-row data, or in application code that mints/refreshed the token.
9. Token refresh is the revocation and permission-update mechanism. ZyncBase revalidates the replacement JWT and re-resolves active scoped sessions; it does not maintain a server-side revocation list by default. Tokens SHOULD be short-lived (e.g., ≤15 minutes), and the SDK is expected to refresh them before expiry. If a session token expires and no refresh is received within a configurable grace period, the server terminates the connection's active scopes.
10. Tenant or project switching does not require a new JWT if the active JWT contains compatible scoped grant arrays. For very large or frequently changing permission sets, the application should mint narrower active-context tokens.

**Principles Alignment**:
- #3 Self-Hosting First: no required Bun process or extra runtime.
- #5 TypeScript-First: applications can still use any JS/TS identity layer, but ZyncBase does not run it.
- #7 Declarative Security: all ZyncBase-side authorization remains in JSON.
- #8 Predictable Performance: authorization has no foreign calls, joins, or hidden database reads.

**Consequences**:

Positive:
- Removes the Hook Server runtime, internal hook protocol, and circuit-breaker failure mode.
- Keeps WebSocket authentication safe by avoiding JWTs in URLs.
- Keeps authorization deterministic and fast.
- Makes permission ownership explicit: the external identity provider/application owns permission truth; ZyncBase enforces trusted claims.
- Makes anonymous users low-friction without special database tables.

Negative:
- ZyncBase cannot answer permission questions that are not present in the token, namespace, target row, or incoming value.
- Immediate revocation depends on short-lived tokens and refresh behavior unless a future design adds introspection or revocation.
- Large permission graphs must be compressed into human-manageable claims, groups, roles, or active-context tokens before reaching ZyncBase. To prevent payload and parsing bloat, ZyncBase enforces a maximum limit on claim array elements (e.g., up to 1000 items) when processing JWTs.

**Rejected Alternatives**:

### Keep the Bun Hook Server for advanced authorization

Rejected because it makes ZyncBase depend on a second runtime for correctness, adds latency and availability modes, and encourages applications to hide permission computation inside the database boundary.

### Load `users` row fields into `$session` during authorization

Rejected because it introduces hidden database reads, refresh semantics, and a second permission source. The `users` table is for identity mapping, ownership references, and optional profile data, not authorization input.

### Add richer JSON relationship queries

Rejected because it would turn `authorization.json` into a query engine and undermine the same-row predicate limit that keeps authorization predictable.

### Require a new JWT for every namespace switch

Rejected as too strict. A token may contain scoped grants such as `read_projects` and `write_projects`, and `authorization.json` can check namespace parts or same-row fields against those arrays. Applications can still choose narrower active-context tokens when token size or staleness matters.
