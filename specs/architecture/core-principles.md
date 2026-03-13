# Core Principles

**Last Updated**: 2026-03-13

---

## Design Philosophy

ZyncBase is built on nine core principles that guide every architectural decision:

1. **Real-time First**: ZyncBase is a real-time collaborative database, not a general-purpose state manager or sync layer.
2. **Collaboration is Built-in**: Presence, conflict resolution, and sync are core features, not plugins.
3. **Self-Hosting First**: Designed to be self-hosted from day one. No vendor lock-in.
4. **Predictable Costs**: No per-operation pricing. You control the infrastructure, you control the costs.
5. **TypeScript-First**: Types are not an afterthought. The API should be impossible to misuse.
6. **Framework-Agnostic Core**: Works everywhere, integrates beautifully with React/Vue/Svelte.
7. **Declarative Security**: All authorization and validation rules are defined in version-controlled JSON (`authorization.json`), ensuring high-performance, consistent enforcement by the Zig core.
8. **Predictable Performance**: No hidden O(n²) algorithms, clear performance characteristics.
9. **Secure by Default**: No prototype pollution, input validation built-in, safe defaults.

---

## Technology Choice (The "Why")

Detailed technical rationales for our stack are documented in our Architecture Decision Records:

- **Zig**: Chosen for predictable latency and manual memory control. See [ADR-001](./adrs.md#adr-001-choice-of-zig-as-primary-language).
- **uWebSockets**: Chosen for microsecond-scale latency and high concurrency. See [ADR-002](./adrs.md#adr-002-choice-of-uwebsockets-for-networking).
- **SQLite**: Chosen for zero-config ACID reliability and VAL-mode performance. See [ADR-003](./adrs.md#adr-003-choice-of-sqlite-only) and [ADR-004](./adrs.md#adr-004-sqlite-wal-mode--concurrency).

---

## Zero-Zig Philosophy

ZyncBase follows a "configuration-first" approach inspired by infrastructure tools:

**Think of ZyncBase like Nginx or PostgreSQL**: You don't write C (or Zig), you edit JSON configuration files and connect from your JavaScript/TypeScript app.

- **zyncbase-config.json**: Server settings.
- **schema.json**: Data validation.
- **authorization.json**: Declarative authorization.

For advanced logic, the **Hook Server** allows extending ZyncBase using full TypeScript. See [ADR-009](./adrs.md#adr-009-configuration-first-zero-zig) and [ADR-016](./adrs.md#adr-016-bun-hook-server).

---

## Performance Targets

We maintain a strict performance budget to ensure ZyncBase remains competitive and reliable. Detailed metrics and rationale are found in [ADR-020](./adrs.md#adr-020-performance-targets).

---

## Design Principles in Practice

### Example: Performance First + Correctness
We use specialized allocators (Arena, Pool) to prevent memory leaks while maintaining predictable sub-millisecond latency. This is applied in our [Lock-Free Cache](./lock-free-cache.md).

### Example: Simplicity + Scalability
Our threading model separates reads and writes, allowing linear vertical scaling across all CPU cores while keeping the record-level logic simple. See [ADR-005](./adrs.md#adr-005-multi-threaded-core-engine).

---

## See Also

- [ADRs](./adrs.md) - All architectural decision records
- [Threading Model](./threading-model.md) - Detailed threading implementation
- [Storage Layer](./storage-layer.md) - SQLite optimization details
- [Research](./research.md) - Technical validation with citations
