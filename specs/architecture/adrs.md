# Architecture Decision Records

## ADR-001: Zig as the Implementation Language

ZyncBase requires maximum throughput, predictable latency under all load conditions, and native multi-threading — none of which can be achieved in runtimes with garbage collectors.

**Decision**: Use Zig as the primary implementation language for the core engine.

**Rationale**:
- **No GC**: Compiled to native code with no garbage collector. Zero GC pauses means deterministic sub-millisecond latency regardless of heap pressure.
- **Native multi-threading**: Direct OS thread model maps one-to-one onto CPU cores. No green threads, no runtime scheduler overhead.
- **Manual memory control**: Specialized allocators (Arena, Pool) enable predictable allocation patterns and zero-cost abstractions at hot paths.
- **Single binary**: Statically linked output under 15MB with no runtime dependencies. Deployment is a file copy.
- **C/C++ interop**: Zero-cost FFI enables seamless integration with uWebSockets, SQLite, and other battle-tested C/C++ libraries without wrapper overhead.

**Consequences**:
- Best-in-class throughput and tail latency on server hardware.
- Single binary deployment with no external dependency management.
- Manual memory management requires address sanitizer and thread sanitizer discipline to verify correctness.

**Principles**: P-RTF, P-PPF

---

## ADR-002: Vertical Scaling as the Scaling Strategy

The foundational question for any database is: how does it grow? Answering it drives every storage, threading, and consistency decision that follows.

**Decision**: ZyncBase scales exclusively by using all CPU cores on a single node. Horizontal scaling — clustering, replication, distributed state — is out of scope.

**Rationale**:
- The overwhelming majority of collaborative applications never reach 100,000 concurrent users per server — the level achievable on a single well-configured node.
- A single server provides **total write ordering for free**. There is no need for vector clocks, consensus protocols, or merge strategies. This property is load-bearing for the conflict resolution model.
- Eliminating distributed state avoids the performance overhead of Raft/Paxos and the operational complexity of multi-node deployments.
- A vertically-scaled single-node architecture makes SQLite viable as the storage engine — something impossible in a multi-writer distributed system.

**Consequences**:
- Best-in-class single-node performance with minimal operational surface area.
- Hard upper limit of approximately 100,000 concurrent users per node.
- Applications that genuinely outgrow a single node require external routing; ZyncBase does not provide this.

**Principles**: P-PPF, P-SHF, P-VSF

---

## ADR-003: Configuration-First Design (Zero-Zig)

A real-time database should not require systems programming expertise to deploy or operate. The target audience is TypeScript/JavaScript developers, not Zig programmers.

**Decision**: All ZyncBase behavior is controlled through JSON configuration files. No knowledge of Zig is required to deploy, configure, or operate the server. The three configuration files are:

- **`config.json`** — server settings: networking, logging, resource limits.
- **`schema.json`** — collection schemas, field types, and presence field definitions.
- **`authorization.json`** — declarative access control rules.

**Rationale**:
- Infrastructure tools like Nginx and PostgreSQL demonstrate that configuration-driven systems can be both powerful and approachable. You edit config, not source code.
- Keeping application logic out of the Zig core preserves a clean boundary: ZyncBase is a configurable engine, not an embeddable library.
- JSON configuration is version-controlled, diffable, and auditable by anyone on the team.

The trade-off is deliberate: what JSON cannot express, ZyncBase deliberately does not support at the configuration layer. Authorization logic that requires joins or dynamic computation must be encoded in trusted identity claims before reaching the server.

**Consequences**:
- Zero compilation step; instant setup from a pre-built binary.
- Applications that exceed the expressiveness of JSON configuration handle the excess in their own layer, not inside ZyncBase.

**Principles**: P-SHF, P-TSF, P-DES

---

## ADR-004: Performance Targets

These metrics are binding architectural constraints for ZyncBase, not aspirational benchmarks. Any design decision that cannot be achieved within these bounds is redesigned or deferred.

**Decision**: Enforce the following hard targets:

| Metric | Target | Measurement |
| :--- | :--- | :--- |
| Concurrent connections | 100,000+ | Sustained |
| Requests/second | 200,000+ | Mixed workload |
| Latency (p50) | < 1ms | In-memory ops |
| Latency (p99) | < 10ms | Including disk |
| Memory per connection | < 1KB | Excluding buffers |
| Binary size | < 15MB | Stripped |
| Cold start time | < 100ms | To ready state |

**Principles**: P-PPF, P-VSF

---

## ADR-005: SQLite as the Storage Engine

ZyncBase needs zero-infrastructure ACID persistence that is operationally simple, deployable as a single file, and capable of saturating all CPU cores on a single machine.

**Decision**: SQLite is the sole persistent store, configured exclusively in WAL (Write-Ahead Logging) mode. No other storage backends or adapters are supported.

### Why SQLite

- Zero configuration: embedded, single-file, no external server required.
- Full ACID guarantees with a 20+ year production track record.
- Operational simplicity: backup is a file copy; disaster recovery is immediate.
- Built-in FTS5 extension for full-text indexing without external search engines.
- On a single machine, SQLite saturates disk I/O before it saturates CPU — exactly the profile needed for vertical scaling.

### WAL Mode is Mandatory

WAL mode is not a tuning option — it is what "using SQLite in a concurrent system" means. In the default rollback journal mode, any write blocks all readers. In WAL mode, multiple readers operate concurrently alongside a single writer. This property makes the multi-threaded core engine viable (ADR-006).

WAL mode implications:
- Multiple readers can serve queries in parallel while the writer thread commits — the reader pool (one connection per CPU core) is fully active under write load.
- Write throughput is improved through sequential I/O patterns.
- Writes are serialized through a single writer thread; throughput is achieved through batching, not write parallelism.

No other storage backends will be added. The Zero-Zig deployment model (ADR-003) requires zero infrastructure dependencies; adding Postgres or Redis support would contradict this constraint.

**Consequences**:
- Zero-infrastructure deployment — the database is a file.
- No horizontal scaling for storage — a direct consequence of the vertical-scaling-only strategy (ADR-002).

**Principles**: P-SHF, P-PRC, P-PPF, P-SOT

---

## ADR-006: Deterministic Thread Budget Architecture

A single-threaded core cannot utilize SQLite's parallel read capability (ADR-005) or the multi-core capacity available on modern server hardware. Configuration-driven thread counts introduce performance cliffs and support burden from misconfiguration.

**Decision**: The engine runs six deterministic thread domains computed from CPU core count using a hardcoded formula. The server refuses to start on machines with fewer than 3 CPU cores. There are no configuration overrides for thread counts. Background worker domains may encode outbound messages, but uWebSockets sends are event-loop-only and cross-thread delivery goes through `SendQueue`.

### Minimum Hardware Requirement

The server requires at least 3 CPU cores. This is a hard constraint enforced at startup. Machines with fewer cores cannot run ZyncBase. At 3 cores the logical topology still uses the minimum six threads: event loop, writer, checkpoint, presence, one reader, and one subscription worker.

### Thread Budget Formula

```
if cpu_count < 3 → server refuses to start

fixed:
  event_loop   = 1
  writer       = 1
  checkpoint   = 1
  presence     = 1

variable:
  remaining    = max(cpu_count, 4) - 4
  readers      = min(4, max(1, remaining / 2))
  notification = max(1, remaining - readers)
```

### Threading Topology

| CPU Cores | Event Loop | Writer | Checkpoint | Presence | Readers | Notification | Total |
|-----------|------------|--------|------------|----------|---------|--------------|-------|
| 3         | 1          | 1      | 1          | 1        | 1       | 1            | 6     |
| 4         | 1          | 1      | 1          | 1        | 1       | 1            | 6     |
| 8         | 1          | 1      | 1          | 1        | 2       | 2            | 8     |
| 16        | 1          | 1      | 1          | 1        | 4       | 8            | 16    |
| 32        | 1          | 1      | 1          | 1        | 4       | 24           | 32    |

**Event loop thread** — runs the uWebSockets reactor, handles all WebSocket I/O and message dispatch, and drains `SendQueue` to call `Connection.send()`. Must never block.

**Writer thread** — receives mutations from the write queue, commits them to SQLite, and publishes durable outcomes/change events for downstream delivery. Serialization is by design: SQLite supports only one concurrent writer, and total write ordering is architecturally valuable (ADR-002).

**Checkpoint thread** — background WAL→main database flush, decoupled from the write path.

**Presence thread** — encodes presence broadcasts from batched state and pushes to the send queue.

**Reader pool** — up to 4 threads, each holding its own SQLite connection opened in WAL read mode. Used for cold queries (subscriptions to collections with no active warm state) and `loadMore` operations.

**Notification threads** — drain the change buffer after storage commits, evaluate subscription filters (CPU-heavy), encode delta messages, and push to the send queue.

### Lock-Free Cache

Metadata shared across all thread domains is served from a lock-free cache using epoch-based reclamation and atomic reference counting. Copy-on-write map swaps allow the writer thread to publish updated versions without acquiring a reader lock. Atomic reference counting over RCU or hazard pointers: simpler to implement correctly, sufficient for the metadata access patterns involved.

**The lock-free cache holds**:
- Authentication snapshots (validated JWT claim sets)
- Schema metadata (field definitions, collection shapes)
- Namespace ID mappings (namespace string → integer, immutable once created)
- User identity mappings (external_id → internal `users.id`, immutable once created)
- Per-document records keyed by `(namespace_id, table_index, doc_id)` — used for authorization guard lookups (reading the existing row before a write to evaluate `$doc` predicates)

Collection query results and subscription state are managed exclusively by the Subscription Engine; the lock-free cache does not participate in collection reads or write propagation.

**Consequences**:
- Deterministic resource usage — no configuration-induced performance cliffs.
- Fail-fast on machines with fewer than 3 CPU cores — clear error at startup while still supporting constrained CI runners.
- Full CPU core utilization — benchmarks show ~Nx throughput improvement on a cpu with N cores, moving from a single-threaded to a multi-threaded core.
- uWS reactor thread remains non-blocking at all times; all I/O-dependent work is dispatched and returned asynchronously.
- Background workers never call uWS send APIs directly; they enqueue owned encoded bytes and wake the event loop after successful enqueue.

**Principles**: P-PPF, P-VSF

---

## ADR-007: uWebSockets as the Network Layer

Standard WebSocket libraries cannot support the combination of microsecond-scale latency and hundreds of thousands of concurrent connections required by ADR-004.

**Decision**: uWebSockets (C++ library) provides the WebSocket transport, connection management, and event-loop reactor.

**Rationale**:
- **Performance**: Handles 200,000+ requests/second with microsecond-scale latency — the only WebSocket implementation capable of matching ZyncBase's throughput targets.
- **Memory efficiency**: Under 1KB of overhead per connection, enabling 100,000+ concurrent connections on standard hardware.
- **Battle-tested**: Powers the Bun runtime and is used by Discord in production for millions of connections.
- **Zig interop**: Zero-cost FFI integration; the same integration path is proven by Bun's own architecture.

The uWS event-loop threads are the entry point for all network events. These threads own the reactor and must not block. All operations requiring I/O or cross-thread coordination are dispatched asynchronously; results are delivered back to the reactor via `us_wakeup_loop()`. This constraint governs session resolution design and any future blocking operation.

**Consequences**:
- All WebSocket handling (framing, ping/pong, compression negotiation, connection lifecycle) is handled by the library.
- C++ integration layer required; maintained through Zig FFI.

**Principles**: P-RTF, P-PPF

---

## ADR-008: Wire Encoding

A real-time database processing 200,000+ messages per second cannot afford the overhead of text serialization, recursive parsers, or CPU-intensive compression on the critical path.

**Decision**: The production wire format is MessagePack. A JSON debug mode is available. The parser is iterative, never recursive. WebSocket per-message compression is disabled.

### MessagePack as the Production Format

MessagePack is a binary serialization format that is smaller and faster to parse than JSON, with no schema pre-compilation required. For a system targeting 200,000+ messages/second, the difference between text and binary encoding is material.

A JSON debug mode is available for development and tooling — not as a production option, but to keep the protocol inspectable during development.

MessagePack was chosen over Protobuf and FlatBuffers because it requires no pre-generated stubs and integrates naturally with the dynamic schema dictionary. The schema is not known at compile time on the client.

### Iterative Parser (Security Constraint)

The MessagePack parser is iterative, not recursive. This is a hard security requirement: a malicious client can send a payload with thousands of levels of nesting. A recursive parser would overflow the call stack. The iterative parser enforces hard limits on nesting depth and total payload size before processing begins.

### No Compression

WebSocket per-message deflate compression is disabled. MessagePack is already compact — typical payloads are 30–60% smaller than equivalent JSON. Adding compression would introduce CPU overhead and latency that conflicts with the p50 < 1ms target (ADR-004).

**Consequences**:
- Smaller wire payloads than JSON without pre-compiled stubs.
- Stack-overflow attacks via deeply nested payloads are impossible by construction.
- No compression overhead on the critical path.

**Principles**: P-PPF, P-SBD

---

## ADR-009: Integer Routing Architecture

At high message throughput, string-based identifiers — collection names, field names, namespace strings — dominate wire bandwidth and server-side parsing cost. Every message that repeats the string `"users"` or `"created_at"` is waste.

**Decision**: ZyncBase replaces all repetitive string identifiers with dense integers on the wire. Two routing systems serve different identifier types: a static dictionary for schema-defined names and a dynamic dictionary for runtime namespace strings. The SDK transparently translates developer-facing string APIs into integers before transmission.

### Static Schema Dictionary (SchemaSync)

Immediately after connection, the server pushes a `SchemaSync` message containing positional arrays of collection names and field names, including system columns. The SDK builds an in-memory string-to-integer mapping from this payload at runtime.

From this point, all store operations over the wire use:
- Collection names → integer table indices
- Field names → integer field indices
- Operation values → pair-arrays of `[field_index, value]` (e.g., `[[2, "Alice"]]` to update field index 2)

The SDK hashes the `SchemaSync` payload to detect schema changes across reconnects, guarding against catastrophic index shifting for any locally queued offline operations.

### Dynamic Namespace Dictionary

Namespace strings are runtime values (e.g., `tenant:acme:project-123`) — they cannot be pre-compiled into a static dictionary. The engine maintains a hidden system table `_zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)` with reserved ID `0` for the global namespace (`$global`). Runtime-created namespaces use positive IDs assigned on first use.

On first use of a namespace string, the engine upserts it into this table and caches the resulting integer ID in the lock-free cache (ADR-006). All subsequent SQLite reads and writes use the integer `namespace_id` column. The SDK sends namespace strings once (via `StoreSetNamespace` or `PresenceSetNamespace`); the engine handles the mapping transparently.

This reduces namespace lookup cost from O(N string comparison) to O(1) integer comparison, and saves substantial storage: 8 bytes per row (integer) vs. up to 300+ bytes for long namespace strings at scale.

### SDK Translation Contract

The SDK is responsible for translating developer-facing syntax into compact wire format. Developers never write wire format directly.

| Developer writes | Wire sends |
| :--- | :--- |
| `'users.u1.name'` (path) | `[table_index, 'u1', field_index]` |
| `{ age: { gte: 18 } }` (query condition) | `[field_index, op_code, 18]` (positional tuple) |
| `{ created_at: 'desc' }` (sort) | `[field_index, 1]` (positional tuple, desc flag) |
| `'address.city'` (nested field) | field index for `address__city` (flattened with `__`) |

Nested field paths are flattened in the SDK using the `__` separator convention before being mapped to integer indices. The server sees only flat field names.

Presence fields participate in the same integer-routing architecture, using additional field index arrays appended to the `SchemaSync` message. The presence-specific field index arrays (`presenceUserFields`, `presenceSharedFields`) are defined as part of the Typed Two-Tier Presence System.

**Consequences**:
- O(1) server-side field resolution — direct array index access instead of string hash map lookups.
- Substantial bandwidth reduction — 1–2 byte integers per field reference vs. repeated string names.
- Forward compatibility: older SDK clients automatically adapt when the server sends updated `SchemaSync` payloads.
- Namespace storage reduced dramatically — integer per row vs. full string in every record at scale.

**Principles**: P-PPF, P-RTF, P-TSF, P-SOT

---

## ADR-010: Conflict Resolution — Last Write Wins

Multi-user collaboration requires a defined answer to: "what happens when two clients write to the same location simultaneously?"

A write target in ZyncBase is always a `(collection, document_id, field)` triple — all fields are flat (nested paths are flattened with `__` by the SDK). There are no sub-field partial updates; a write sets the entire field value.

**Decision**: Concurrent writes to the same field are resolved by server-assigned timestamp. The last write wins.

**Rationale**:
- The single-node architecture (ADR-002) provides total write ordering for free: the writer thread processes all mutations serially, so "last" is unambiguous with zero coordination overhead.
- Field-level LWW is O(1). Deep field-level merge would require equality traversal on every write — a cost that conflicts with p99 < 10ms at high write throughput.
- LWW matches the semantics of standard REST PUT and Firebase — familiar to the target audience with no learning curve.

**Consequences**:
- Two clients editing the same field will overwrite each other; the server timestamp determines the winner.
- Applications requiring merge semantics (collaborative text editing, CRDT-based merges) must use separate documents per collaborator or handle merging at the application layer.
- Writing the same canonical value to a field is a no-op; the server may suppress subscription deltas for same-value writes.

**Principles**: P-RTF, P-PPF

---

## ADR-011: Data Ownership and Namespace Tenancy

Multi-tenant collaborative applications need object-level ownership and namespace partitioning built into the data model, not bolted on as application-layer conventions.

**Decision**: Every document carries `owner_id` (the internal identity of its creator) and `namespace_id` (its tenant partition) as built-in system columns. Collections may opt out of namespace partitioning to become global master data. Authorization rules are strictly limited to same-row predicates.

### System Columns

All storage tables carry the same fixed set of system columns: `id`, `namespace_id`, `owner_id`, `created_at`, `updated_at`. No exceptions. This uniformity keeps DDL generation, migration logic, and authorization predicates consistent across all collections.

- `id` — document identity. Expected unique across the entire collection; `namespace_id` is not part of the primary key.
- `namespace_id` — tenant routing column. Partitions reads and writes by active namespace.
- `owner_id` — stored as `BLOB(16)` UUIDv7 (same representation as `id`). Automatically populated on document creation from `$session.userId`.

### The users Collection and Identity Mapping

The `users` system collection maps external string identities (e.g., Auth0 `sub` claims, SDK-generated anonymous subjects) in its `external_id` column to internal UUIDv7 identities in its `id` column. This is a standard collection with standard columns — not a hidden auth table.

During session resolution, the engine maps the external identity string to `users.id` and stores it as `$session.userId`. All `owner_id` values across the database reference a real `users.id` row.

On the `users` row itself, `owner_id` equals `id` (self-ownership) — preserving uniform table shape without exceptions.

### Global Master Data (`namespaced: false`)

By default, all collections are namespace-partitioned (`namespaced: true`). Setting `"namespaced": false` on a collection causes the engine to store `namespace_id = 0` (the reserved global namespace) and route all queries through that global namespace, regardless of the client's active namespace.

This is the pattern for master data that must be visible across all tenant namespaces: the `users` collection, pricing tiers, global configuration. `users` defaults to `namespaced: false`.

Setting `"namespaced": true` on the `users` collection creates fully isolated identity realms per namespace — the same external identity string maps to a distinct `users.id` in each namespace. This mode is intended for applications where users belong to exactly one namespace (e.g., strict per-tenant isolation). In this mode, namespace switching is not a supported usage pattern: a user's identity is resolved in the context of their home namespace, and accessing a different namespace would create a new, unrelated identity row in that namespace's partition. Applications using `users.namespaced = true` should ensure their JWT grants access to a single namespace.

The `namespace_id = 0` routing is transparent to the developer and invisible in the API.

### Authorization Scope Limits

`authorization.json` rules are evaluated in RAM against five variables: `$session`, `$namespace`, `$path`, `$doc` (same-row columns only via AST injection into the query predicate), and `$value` (incoming mutation value).

Cross-table joins, relationship traversal, and lookups of other collections are explicitly forbidden in authorization rules. Any permission requiring this information must be encoded either:
- In the validated JWT as a trusted claim, or
- On the same row being authorized.

This limit is a deliberate architectural boundary that keeps authorization evaluation at nanosecond/microsecond latency with zero hidden database reads.

**Consequences**:
- `$doc.owner_id == $session.userId` authorization rules work out of the box for ownership-based access control.
- The `users` collection is inspectable, queryable, and subscribable like any other collection.
- Complex relational authorization (membership graphs, permission trees) must live in the identity provider, not in ZyncBase.

**Principles**: P-POM, P-PPF, P-SBD, P-SOT

---

## ADR-012: Typed Array Fields as Canonical Sorted Sets

Schema-defined typed array fields are used most commonly for tags, roles, and labels — data where element order is irrelevant and duplicates are nonsensical.

**Decision**: Schema-defined typed array fields behave as canonical sorted sets. Insertion order is discarded; the server normalizes every array to its sorted, deduplicated form on every write.

**Write path normalization**: Validate each element against the field's `items` type, reject null elements and nested arrays/objects, sort using a type-aware comparator, remove duplicates.

**Persistence contract**: Only the canonicalized representation is stored in SQLite.

**Read contract**: Arrays are always returned in canonical (sorted, unique) form.

**Query semantics**:
- `contains` on an array field is membership over the canonical set.
- `eq` / `ne` use canonical equality — `["A", "B"]` and `["B", "A"]` are equal for valid typed arrays.
- `in` / `notIn` operand arrays are also canonicalized (order-insensitive, duplicate-insensitive).

**Scope**: Arrays of objects remain unsupported. Operators that are semantically undefined for sets (`gt`, `startsWith`) are invalid on array fields.

**Rationale**:
- Eliminates the "is `[A, B]` equal to `[B, A]`?" ambiguity at the storage layer.
- Enables faster membership and equality checks in both SQL and in-memory AST evaluation.
- Directly serves the dominant array use case without any developer opt-in.

**Consequences**:
- Applications relying on insertion-order semantics for array fields must model ordered lists differently (e.g., as an object with position keys).

**Principles**: P-TSF, P-PPF

---

## ADR-013: Query Language

The SDK targets TypeScript developers who benefit from expressive, type-safe syntax. The query language must be familiar, safe, and performant within scope.

**Decision**: ZyncBase uses a Prisma-inspired JSON query syntax — implicit AND, lowercase operators, that supports a defined set of comparison, membership, and string operators. Regex, full-text search, and cross-collection joins are excluded from scope.

### Syntax Design

Query conditions are expressed as JSON objects with implicit AND semantics:

```ts
// Single condition
{ status: { eq: "active" } }

// Compound condition (implicit AND)
{ age: { gte: 18 }, status: { eq: "active" } }

// Array membership
{ tags: { contains: "typescript" } }
```

Prisma-style syntax is chosen because TypeScript developers already know it — it is the most widely used query API in the ecosystem. Implicit AND covers the dominant case; explicit OR structures are composable. No prefix notation; no custom string parsing.

### Supported Operators

`eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `notIn`, `contains`, `startsWith`, `endsWith`

### Excluded

- **Regex** — Introduces ReDoS risk. Pattern matching on untrusted input with arbitrary regex is a denial-of-service vector.
- **Full-text search (FTS)** — Requires FTS5 query planning incompatible with the Subscription Engine's in-memory AST evaluation model.
- **Cross-collection joins** — Joins break the subscriber grouping model that makes subscription evaluation O(unique groups) rather than O(subscribers).
- **Computed/derived fields** — Application-side concern.

**Consequences**:
- Developers needing full-text or fuzzy search use computed fields or client-side filtering.

**Principles**: P-TSF, P-PPF, P-SBD

---

## ADR-014: Unified Subscription Engine

**Decision**: The Subscription Engine is the sole entry point for all server-side read operations. It maintains warm in-memory state for active subscriptions and evaluates change propagation using in-memory AST evaluation — never by re-running SQL queries on write events.

**Rejected alternative — SQL re-evaluation per write**: Re-running a SQL query for every write to determine which subscribers are affected scales as O(subscribers × writes). At high connection counts this is untenable and was rejected outright.

**Rejected alternative — separate code paths for one-shot reads and subscriptions**: A `StorageEngine` read path separate from a `SubscriptionManager` would duplicate query evaluation logic and create inconsistencies between what a one-shot query returns and what a subscriber observes. A unified engine with a single read contract eliminates this class of bug.

### Read Message Types

Two read message types exist:
- **`StoreQuery`** — one-shot: execute against warm memory or cold SQLite, return results, done. One-shot queries do not warm the engine.
- **`StoreSubscribe`** — ongoing: warm from SQLite if needed, return current snapshot, register subscriber, push `StoreDelta` events until `StoreUnsubscribe`.

Additional messages: `StoreUnsubscribe`, `StoreLoadMore`, `StoreDelta`.

### SDK and Server Read Model

All server reads are collection-level with optional filters. The server has no concept of sub-document paths. Path-based SDK methods (`get`, `listen`) are SDK conveniences that decompose into collection queries with id filters before transmission; field extraction from the result record happens in the SDK.

### Engine Lifecycle

- **Cold query**: Hit SQLite through the reader pool. Return results. No state retained in the engine.
- **Subscribe (cold collection)**: Warm from SQLite, register subscriber, return snapshot.
- **Subscribe (warm collection)**: Register subscriber immediately, return current in-memory snapshot.
- **RecordChange event**: Update in-memory collection state, evaluate all subscriber groups against the change, push `StoreDelta` to matching subscribers.

### Subscriber Grouping

Subscribers with identical `(namespace, collection, where, orderBy)` share one evaluation group. A `RecordChange` event evaluates each unique group exactly once — not once per subscriber. `limit` is per-subscriber metadata, applied after group evaluation. New subscribers joining an existing warm group receive the current snapshot immediately.

### In-Memory AST Evaluation

Change propagation never re-runs SQL. When a `RecordChange` event arrives, the engine evaluates the changed record against each subscriber group's AST (the parsed query condition tree) in RAM. This makes subscription propagation scale to O(unique subscription groups), not O(subscribers × writes).

### Record-Level Deltas

The server pushes `set` (full record — covers both add and update) and `remove` (record ID only) at record granularity. No field-level patches from the server. The SDK handles field projection and local cache updates.

### Eviction and Resource Limits

Collection state is evicted when the last subscriber unsubscribes. Disconnect triggers automatic unsubscription. A configurable `subscriptionEngine.maxMemoryMB` limit causes new subscriptions to be rejected with `RESOURCE_EXHAUSTED` when approached.

`loadMore` always hits SQLite.

**Consequences**:
- Single code path for all reads.
- O(unique subscription groups) evaluation per write — the dominant cost is not subscriber count.
- First subscribe to a cold collection incurs one SQLite read; all subsequent reads from that group are in-memory.

**Principles**: P-RTF, P-SAT, P-TSF, P-PPF, P-SOT

---

## ADR-015: Scoped Session Management

A WebSocket transport can be open before the server has enough context to safely process data operations. Identity resolution must be complete before any store or presence operation is accepted.

**Decision**: A WebSocket connection must complete identity and namespace resolution before the server accepts any data operations. Resolution is non-blocking on the uWS reactor through a two-tier cache + async handoff strategy.

### The Invariant: Transport Open ≠ Session Ready

Transport connectivity and scoped session readiness are distinct states. Store and presence maintain independent scopes — they can be resolved in different namespaces when `users.namespaced = false`.

Before a scope is ready, the server accepts only lifecycle messages: authentication, namespace selection, ping/pong, and close. All data messages — subscriptions, queries, mutations, presence operations — are rejected with `SESSION_NOT_READY`.

### What a Scope Consists Of

A scope is the resolved pair:
1. **Namespace ID** — the namespace string resolved to `_zync_namespaces.id` (integer)
2. **`$session.userId`** — the external identity string (JWT `sub` or anonymous subject) resolved to an internal `BLOB(16)` UUIDv7 from the `users` table

Store and presence resolve independently — each scope maintains its own resolved namespace ID and user ID.

When `users.namespaced = false` (the default), `users` is a global table and the same external identity always maps to the same `users.id` regardless of which namespace is active — namespace switching carries the same identity forward. When `users.namespaced = true`, identity resolution is scoped to the active namespace. This mode is designed for single-namespace users; the server enforces that a connection is locked to a single namespace for both store and presence scopes. Specifically, the first `SetNamespace` (store or presence) establishes the connection's namespace. Any subsequent `SetNamespace` for either scope is rejected with `NAMESPACE_SWITCH_REJECTED` if the namespace string differs from the established one.

### Non-Blocking Resolution (Two-Tier)

Blocking the uWS reactor during resolution would stall all concurrent connections and violate the p50 < 1ms latency target (ADR-004).

**Tier 1 — Synchronous cache hit (~1μs)**: Check the namespace cache and identity cache in the lock-free cache (ADR-006). If both hit, set scope and respond immediately. Zero I/O, zero blocking. After first resolution of a `(namespace, external_id)` pair, all subsequent connections with the same pair resolve via this path.

**Tier 2 — Async writer handoff (cache miss)**: Enqueue a combined `resolve_session` WriteOp to the writer thread and return immediately — the reactor is free. The writer thread performs `INSERT OR IGNORE INTO _zync_namespaces` and `INSERT OR IGNORE INTO users`, populates both caches, and pushes a `SessionResolutionResult` to the `SessionResolutionBuffer`. The `SessionResolver` (running in the uWS `post_handler`) drains this buffer, acquires the target connection by ref-counted ID, applies the resolved scope, and sends the response.

Combining namespace + user resolution into a single `resolve_session` WriteOp eliminates two sequential round-trips in favor of one.

### Scope Invalidation

- **Namespace change**: Clears subscriptions for the affected domain.
- **Auth refresh (success)**: Updates `$session` in-place; active scopes continue without interruption.
- **Auth refresh (failure)**: Connection is terminated.

### Stale Result Guard (`scope_seq`)

A per-connection monotonic counter is incremented on each scope reset. Carried in every `resolve_session` WriteOp and checked at delivery — if the connection's current `scope_seq` does not match the result's `scope_seq`, the result is stale (a subsequent namespace change was issued) and is silently discarded.

**Consequences**:
- The uWS reactor is never blocked during identity or namespace resolution.
- Warm-cache resolution (~1μs) makes repeated connections and namespace switches essentially free.
- The full TCP handshake → data-ready path is async with no reactor blocking.

**Principles**: P-POM, P-SOT, P-SBD, P-PPF

---

## ADR-016: Authentication, Authorization, and the Trust Boundary

ZyncBase needs secure authentication, multi-tenant authorization, and object ownership without becoming an identity provider or embedding arbitrary application logic into the database.

**Decision**: ZyncBase is a resource server. It validates external JWTs, projects verified claims into `$session` via configuration, and enforces declarative JSON authorization rules. It does not run application logic, perform joins in the auth layer, or act as an identity provider. All runtime validation is server-side only.

### JWT Authentication

ZyncBase validates tokens from configured external issuers. Configuration specifies: issuer, audience, allowed algorithms, and either a shared secret or a JWKS endpoint. The JWT claim-to-`$session` mapping is defined in configuration — permission claims (`role`, `permissions`, `tenant_id`, `read_projects`, etc.) are trusted only because the token signature and registered constraints were validated.

Anonymous access uses the same pipeline. The SDK generates a high-entropy anonymous subject, persists it locally, and presents it as an anonymous external identity when anonymous auth is enabled. No special database tables or code paths are required.

### The Trust Boundary

ZyncBase trusts only what it can verify. Permission decisions that require joins, relationship traversal, billing lookups, or permission graph computation cannot be made inside ZyncBase. They must be encoded before the request reaches the server — in the verified JWT as trusted claims, or in same-row data on the record being authorized (see ADR-011 authorization scope limits).

This is a product boundary decision. ZyncBase deliberately declines to compute permission truth — that belongs to the application and its identity provider.

### `authorization.json` — Declarative RAM Rules

Authorization rules evaluate in RAM against `$session`, `$namespace`, `$path`, `$doc` (same-row columns via AST injection), and `$value` (incoming mutation value). No database reads are performed during authorization evaluation. Rules are JSON — version-controlled, diffable, and auditable.

### Token Lifecycle and Revocation

Tokens should be short-lived (≤15 minutes recommended). The SDK is expected to refresh tokens before expiry. On successful auth refresh, `$session` is updated in-place — active scopes continue without interruption. On refresh failure, the connection is terminated.

ZyncBase does not maintain a server-side revocation list by default. Token expiry is the primary revocation mechanism. If a token expires without a valid replacement within a configurable grace period, the connection is terminated.

ZyncBase enforces a maximum limit on JWT claim array element counts to prevent payload and parsing bloat.

### Server-Side Validation Only

Schema validation, field type enforcement, and authorization rules are enforced exclusively by the server. The SDK uses TypeScript types generated from `schema.json` for development-time safety, but performs no runtime validation.

This keeps the SDK lightweight and eliminates the class of bugs where client-side validation diverges from server-side schema.

**Rejected alternative — delegating authorization to an external process**: Running application logic in a sidecar process (e.g., a TypeScript hook server) would make ZyncBase's correctness dependent on a second runtime, add per-check latency, introduce availability failure modes, and encourage embedding application-layer permission computation inside the database boundary. ZyncBase is a resource server; permission truth belongs in the identity provider.

**Consequences**:
- Authorization has no foreign calls, joins, or hidden database reads — nanosecond evaluation on the critical path.
- The external identity provider owns permission truth; ZyncBase enforces trusted claims.
- Applications with large or frequently changing permission sets must compress them into manageable claim structures or mint narrower active-context tokens.

**Principles**: P-SHF, P-TSF, P-DES, P-PPF, P-SBD

---

## ADR-017: Strict SDK API Surface — `store` vs `presence`

Durable state and ephemeral awareness state have fundamentally different consistency guarantees, lifetime semantics, and storage backends. Conflating them at the API level causes subtle bugs.

**Decision**: The SDK enforces a hard namespace boundary between `client.store.*` (durable, persisted state) and `client.presence.*` (ephemeral, in-memory awareness state). These namespaces are not interchangeable.

This is a structural boundary, not a convention. A developer cannot accidentally use presence for durable data because the SDK has no API path that does so. The choice is forced at the call site.

**Consequences**:
- The store/presence distinction is visible in every code example and every type signature.
- Presence state is explicitly scoped to the Typed Two-Tier Presence System, which builds on this namespace boundary.

**Principles**: P-TSF, P-CIB

---

## ADR-018: Mutation Acknowledgement and Consistency Semantics

Client-visible state in a real-time system is observed through subscriptions, not through write responses. These are related but distinct events. Their semantics must be explicit.

**Decision**: Default writes (`store.set`, `store.remove`, `store.batch`) are accepted/eventual. Subscriptions are the authoritative source of committed client-visible state. Clients may opt in to committed confirmation. There is no optimistic local state and no local rollback.

### The Three-Concept Separation

Three concerns are deliberately kept distinct:

1. **Request acceptance** — the server parsed, validated, and accepted the mutation into the write pipeline.
2. **State observation** — subscriptions delivered committed observable state.
3. **Write outcome reporting** — optional operation-level status and error feedback.

Default writes participate in (1) and eventually produce (2). They do not block on (3). This is the model that keeps default writes low-latency.

### Confirmation Levels

```ts
await store.set(path, value);
// await store.set(path, value, { confirm: 'accepted' });
// Resolves when the server accepts the mutation into the write pipeline.

await store.set(path, value, { confirm: 'committed' });
// Resolves when the writer commits the mutation (or produces an accepted no-op).
// Rejects when the writer reports failure.
```

`confirm: 'accepted'` is the default. `confirm: 'committed'` applies to `store.set`, `store.remove`, and `store.batch`.

### Terminology

- **accepted** — server parsed, validated, authorized pre-enqueue, and admitted the mutation.
- **committed** — writer-thread result succeeded, including accepted no-ops.
- **writeId** — correlation ID for tracked or confirmed writer-thread outcomes. Distinct from the request `id`, which correlates only the immediate accept/reject response.
- **WriteError** — the name for async writer failure messages. Not "NACK" — there is no speculative local state to roll back.

### Error Phases

Errors fall into two phases:
- **accept** — rejection before the writer owns the operation (malformed message, invalid path/field, schema validation failure, session not ready, pre-enqueue authorization failure, queue admission failure).
- **write** — writer-thread failure after acceptance (storage error, constraint violation, post-read authorization failure against a stored row).

Both use `ZyncBaseError` with a `details.phase: 'accept' | 'write'` discriminant.

### Batch Semantics

`store.batch(..., { confirm: 'committed' })` is atomic: resolves only if the full batch commits; rejects if any operation fails; no partial success; no partial writes on failure.

Failed batch operations include `batchIndex` when the failing operation is identifiable. For transaction-level failures where no single operation is culpable, `batchIndex` is omitted.

### Authorization Semantics for Creates

`$doc` in write authorization rules is interpreted by operation kind:
- **Create**: `$doc` is the candidate document being created (including server-injected `owner_id`).
- **Update**: `$doc` is the existing stored document.
- **Delete**: `$doc` is the existing stored document.

Ownership rules such as `{ "$doc.owner_id": { "eq": "$session.userId" } }` naturally pass for creates by the owning session, because `owner_id` is injected by the server before the rule is evaluated.

### No-Op Semantics

- Deleting a missing document is success/no-op.
- Writing the same canonical value to a field is success. The server may suppress subscription deltas for same-value writes.

### Connection Failures

Confirmed write promises are scoped to the originating live connection. On disconnect, the SDK rejects pending confirmed promises with a connection error. The write may still commit. After reconnect, subscriptions are the source of truth for final state.

Confirmed writes require a timeout. A timeout means confirmation was not received — not that the write failed to commit.

**Rejected alternatives**:
- **Make every write block until committed** — rejected as the default; changes the programming model to request/response semantics and adds latency for all writes that only require eventual propagation.
- **Optimistic local writes** — rejected; requires rollback machinery, conflict handling, and speculative materialized-view logic that the subscription-first model avoids entirely.
- **NACK messages as rollback commands** — rejected; there is no speculative local state to roll back.
- **No writer failure reporting** — rejected; ambiguous missing deltas cannot support user-facing save-failure feedback.
- **Reuse request id for writer outcomes** — rejected; request ids correlate immediate responses; writer outcomes need a distinct `writeId`.

**Consequences**:
- Default writes resolve fast with accepted semantics; subscriptions deliver committed state.
- Applications needing precise save confirmation use `confirm: 'committed'`.
- The SDK never speculatively mutates local state; subscriptions are the single source of truth.

**Principles**: P-RTF, P-SAT, P-TSF, P-SOT

---

## ADR-019: Error Taxonomy and SDK Error Handling

Errors from a real-time system span connection failures, authorization denials, schema violations, and storage errors — each requiring different automatic behavior from the SDK.

**Decision**: All ZyncBase errors are classified into 8 categories. The category dictates automatic SDK retry and escalation behavior.

| Category | Examples | SDK Auto-Behavior |
| :--- | :--- | :--- |
| **Connection** | Network drop, server restart | Auto-reconnect with exponential backoff |
| **Authentication** | Invalid JWT, expired token | Trigger token refresh; reconnect if refresh succeeds |
| **Authorization** | Permission denied | Surface to application; do not retry |
| **State** | Session not ready, namespace switch rejected | Surface to application; do not retry |
| **Validation** | Schema violation, invalid payload shape | Surface to application; do not retry |
| **Client** | Path format invalid, message too large | Surface to application; do not retry |
| **Rate-Limit** | Too many requests | Respect server `retry-after`; retry after indicated delay |
| **Server** | Storage failure, engine error | Surface to application; optional retry |

Every ZyncBase error is typed as `ZyncBaseError` with `code` (machine-readable string), `message` (human-readable), `category`, and optional `details` (including `phase`, `batchIndex`, etc., as applicable).

The 8-category model is a server-side classification. The SDK maps it to typed error objects via `deriveCategory`. The SDK consumer categories are: `authentication`, `authorization`, `state`, `validation`, `client`, `rate_limit`, `server`, `network`, and `unknown`. Application code receives a fully classified, actionable error at every error boundary.

**Consequences**:
- Application developers handle semantically meaningful error categories, not raw status codes or opaque strings.
- The SDK implements correct automatic retry behavior — including token refresh, reconnect, and respecting `retry-after` — without application involvement.

**Principles**: P-TSF, P-SBD

---

## ADR-020: Typed Two-Tier Presence System

Presence is the real-time awareness layer of ZyncBase. Treating it as a freeform JSON blob would sacrifice the performance and type safety that the rest of the system is designed to provide.

**Decision**: Presence is typed, schema-driven, and integer-encoded. Two tiers serve different collaboration patterns: per-user state and namespace-level shared state. All presence messages participate in the same integer-routing architecture as store messages (ADR-009).

### Typed Presence Schema

Presence is always validated against a schema. When `schema.json` contains an explicit `presence` top-level key, that definition is authoritative. When the key is absent, the server synthesizes an implicit minimal schema:

```json
{
  "user": {
    "status": { "type": "string", "enum": ["active", "idle", "away"] }
  },
  "shared": {}
}
```

There is no schemaless or freeform presence mode. Presence data is always typed, whether against an implicit or explicit schema.

### Two-Tier Field Model

**`presence.user`** — fields owned by each user individually. One in-memory record per connected user per namespace. Automatically cleaned up on disconnect.

**`presence.shared`** — fields representing namespace-level ephemeral state. One in-memory record for the entire namespace. Survives for the namespace session lifetime (see Grace Period below).

The two tiers address a genuine product gap: not all ephemeral state is user-owned. "Current slide in a presentation," "shared video playback position," and "active viewport for all participants" are namespace-level state — one value for the room, not one per user. Without a second tier, developers either misuse the store (paying SQLite write overhead and accumulating stale data) or build out-of-band coordination mechanisms.

### Flat Wire Format and Integer Encoding

Nested presence fields are flattened using the `__` separator convention, consistent with the store. `cursor: { x, y }` becomes `cursor__x` and `cursor__y`. The SDK transparently flattens outbound and reconstructs inbound data. Developers interact with the nested object form.

`SchemaSync` includes two arrays for presence field index encoding:
- `presenceUserFields: string[]` — flattened user field names in index order
- `presenceSharedFields: string[]` — flattened shared field names in index order

`PresenceSet` and `PresenceSetShared` send pair-arrays of `[field_index, value]`. `PresenceBroadcast` and `SharedStateBroadcast` deliver pair-array data. `SharedStateBroadcast.data` is always an array of pair-array patches. A hard limit of 500 flat fields per presence tier is enforced at server startup.

Payload savings are substantial at high frequency: a cursor update with status shrinks from ~50 bytes to ~22 bytes. At 60fps from many users fan-outing to many subscribers, this difference compounds dramatically across the broadcast path.

### Merge Semantics

Both `PresenceSet` and `PresenceSetShared` perform field-level merges, not full replacements. Sending `{ 0: 101.0 }` updates only `cursor__x`; all other fields in the accumulated record are preserved.

### Separate Push Message Types

`PresenceBroadcast` carries user presence events (`join`, `update`, `leave`). `SharedStateBroadcast` carries namespace-level shared state changes. These have different SDK handling paths and different local cache targets; they must remain separate message types.

### Shared State Lifetime and Grace Period

Shared state is cleared when all users leave the namespace, with a 5-second grace period. The grace period prevents transient disconnections (mobile network flap, brief tab hide/restore) from wiping shared state unexpectedly.

The grace period is implemented by piggybacking on the existing 50ms batch flush loop — a `namespace_empty_at` map records when a namespace's user count drops to zero; each flush cycle evicts entries older than the threshold. No additional timer infrastructure is required.

Shared state is RAM-only. It does not survive server restart, regardless of grace period state.

### Authorization

`presenceSharedWrite` is a rule key in `authorization.json` controlling who may write namespace-level shared state. Evaluated identically to `presenceWrite` — RAM-only predicate against `$session`, `$namespace`, and `$data`. `$data` exposes incoming field values, enabling content-gated authorization (e.g., only hosts may set `status: "presenting"`).

`presenceSharedWrite` defaults to the same value as `presenceWrite` when omitted — consistent with safe defaults.

### Presence Writes are Fire-and-Forget

Neither `PresenceSet` nor `PresenceSetShared` accepts a `confirm` option. Presence writes are always accepted/eventual. Type and field index validation occurs at accept time; invalid payloads are rejected with `SCHEMA_VALIDATION_FAILED`. Write pipeline confirmation is not meaningful for ephemeral state.

### Wire Protocol Summary

| Message | Description |
| :--- | :--- |
| `SchemaSync` | Includes `presenceUserFields: string[]` and `presenceSharedFields: string[]` |
| `PresenceSet` | C→S; `data` is pair-array merge delta for user fields |
| `PresenceSetShared` | C→S; pair-array merge delta for shared fields |
| `PresenceSubscribe` ok | Returns current user presence snapshot for the namespace |
| `PresenceBroadcast` | S→C; `data` is pair-array; `userId` encoded as `bin16` |
| `SharedStateBroadcast` | S→C; always array of pair-array patches |

**Consequences**:
- Full integer wire compression for all presence messages — same performance profile as store operations.
- Server-side field type validation at accept time for all presence operations.
- Namespace-level shared state enables room-wide ephemeral coordination without store pollution.
- `$data` in auth rules enables content-gated presence writes.
- Shared state is RAM-only — it does not survive server restart.
- Presence schema field changes trigger `schemaChange` on connected clients — same reconnect requirement as store schema changes.
- A hard limit of 500 flat fields per presence tier is enforced at server startup to guard against pathological schemas.

**Principles**: P-RTF, P-TSF, P-PPF, P-SBD, P-CIB
