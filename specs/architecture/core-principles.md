# Core Principles

---

## Design Philosophy

ZyncBase is built on thirteen core principles that guide every architectural decision. These are organized into four thematic groups and referenced throughout our ADRs by stable `P-XXX` identifiers.

---

### Foundation (Identity & Business Model)

1. **P-RTF — Real-time First**: ZyncBase is a real-time collaborative database, not a general-purpose state manager or sync layer. Every architectural decision prioritizes low-latency, event-driven state propagation before batching, persistence, or convenience features.

2. **P-CIB — Collaboration is Built-in**: Presence, conflict resolution, and real-time sync are first-class architectural primitives, not optional plugins or afterthoughts. Every layer of the system — wire protocol, storage, authorization — is designed with multi-user collaboration as a hard constraint, not a feature flag.

3. **P-SHF — Self-Hosting First**: Designed to be self-hosted from day one. No vendor lock-in. A single binary, zero runtime dependencies, and SQLite-based persistence mean deployment is as simple as copying a file.

4. **P-PRC — Predictable Costs**: No per-operation pricing. You control the infrastructure, you control the costs. Flat-rate hosting on a single VPS should be viable from prototype to production.

### Performance & Scale

5. **P-PPF — Predictable Performance**: No hidden O(n²) algorithms, clear performance characteristics. Every operation has documented latency bounds. If it can't be made predictable, it is excluded from the engine.

6. **P-VSF — Vertical Scaling First**: Optimize for single-node performance before considering distribution. ZyncBase saturates a single machine's CPU cores, memory, and I/O before introducing the complexity of clustering. Horizontal scaling is a future concern, not a current abstraction.

7. **P-SBD — Secure by Default**: No prototype pollution, input validation built-in, safe defaults. The default configuration should be secure; weakening security must be an explicit opt-in.

### Developer Experience

8. **P-TSF — TypeScript-First**: Types are not an afterthought. The API should be impossible to misuse. The SDK generates precise types from the schema, and the wire protocol enables those types to be statically analyzed at build time.

9. **P-FAC — Framework-Agnostic Core**: The wire protocol is framework-agnostic and language-neutral. The TypeScript SDK is the primary target with first-class type generation, but the protocol does not assume any specific frontend framework. Integrations with React, Vue, and Svelte should be thin, idiomatic wrappers over the core SDK.

10. **P-DES — Declarative Security**: All authorization and validation rules are defined in version-controlled JSON (`authorization.json`), ensuring high-performance, consistent enforcement by the Zig core. Complex relational authorization is pushed to the identity provider — ZyncBase is a resource server, not an authorization compute engine.

### Trust & Correctness

11. **P-POM — Primitives over Magic**: Expose system capabilities as standard, composable primitives rather than hidden configuration or implicit behavior. `users` is a regular collection, `owner_id` is a regular column, namespaces are regular routing — no hidden tables, no magical short-circuits, no behavior that can't be reasoned about from the schema.

12. **P-SOT — SQLite as the Source of Truth**: All persistent state lives in SQLite. In-memory structures (subscription engine, lock-free cache, namespace maps) are performance derivatives, never independent sources of truth. On restart, SQLite alone must be sufficient to reconstruct all application state.

13. **P-SAT — Subscriptions as Authority for Client State**: Client-visible committed state is observed through subscriptions, not through write confirmations. Write confirmations are outcome reporting (accepted / committed), not state delivery. The SDK must not mutate local subscription state speculatively — subscriptions are the source of truth for what the server has committed.

---

## Technology Choice (The "Why")

Detailed technical rationales for our stack are documented in our Architecture Decision Records:

- **Zig**: Chosen for predictable latency and manual memory control.
- **uWebSockets**: Chosen for microsecond-scale latency and high concurrency.
- **SQLite**: Chosen for zero-config ACID reliability and WAL-mode performance.

---

## Zero-Zig Philosophy

ZyncBase follows a "configuration-first" approach inspired by infrastructure tools:

**Think of ZyncBase like Nginx or PostgreSQL**: You don't write C (or Zig), you edit JSON configuration files and connect from your JavaScript/TypeScript app.

- **zyncbase-config.json**: Server settings.
- **schema.json**: Data validation and presence fields.
- **authorization.json**: Declarative authorization.


---

## Performance Targets

| Metric | Target | Measurement |
| :--- | :--- | :--- |
| Concurrent connections | 100,000+ | Sustained |
| Requests/second | 200,000+ | Mixed workload |
| Latency (p50) | < 1ms | In-memory ops |
| Latency (p99) | < 10ms | Including disk |
| Memory per connection | < 1KB | Excluding buffers |
| Binary size | < 15MB | Stripped |
| Cold start time | < 100ms | To ready state |

## Related Specifications

- [ADRs](./adrs.md) - All architectural decision records
- [Threading Model](./threading-model.md) - Detailed threading implementation
