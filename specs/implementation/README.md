# Implementation Specifications

This directory documents how the current ZyncBase implementation is organized. These files are not a second copy of the source code. They should explain stable contracts, ownership, dependencies, and invariants.

## Documentation Contract

Implementation specs should keep:

- Source modules and important structs/types.
- Ownership boundaries and dependency direction.
- Runtime lifecycle, concurrency, memory, durability, and security invariants.
- Wire, schema, auth, config, and SDK contracts that clients or operators observe.
- Links to ADRs when an implementation choice is decision-driven.
- Performance contracts: Observable limits, thresholds, buffer sizes, and latency targets that operators or clients may depend on.
- Threading model: Which subsystem runs on which thread, what synchronization primitives are used, and what the ownership boundaries are.

Implementation specs should avoid:

- Zig or TypeScript snippets that duplicate production code.
- Public error-code tables outside [Error Taxonomy](./error-taxonomy.md).
- Repeating grammar catalogs outside their owner files.
- Historical compatibility notes that no longer apply to the green-field implementation.
- Step-by-step implementation narratives that belong in code comments.

Canonical catalogs:

- Error codes and retry behavior: [Error Taxonomy](./error-taxonomy.md).
- Message names, envelope shape, and server push names: [Wire Protocol](./wire-protocol.md).
- Schema fields and validation rules: [Schema Grammar](./schema-grammar.md).
- Query operators and translation rules: [Query Grammar](./query-grammar.md).
- Authorization config grammar: [Auth Grammar](./auth-grammar.md) and [Auth System](./auth-system.md).
- Runtime configuration keys: [Config Grammar](./config-grammar.md).

## Keeping Specs Current

- ADRs remain the source of truth for architectural decisions. When behavior changes because of a decision, update `specs/architecture/adrs.md` first, then update the affected implementation specs.
- Every implementation spec should name the source files/types it describes. A code change that renames, removes, or changes one of those types should update the matching doc in the same change.
- Public contracts should be documented as tables or bullets. Use code fences only for stable external examples such as JSON config, wire payload examples, SQL shape, or command lines.
- Public error codes must be added to `src/wire/errors.zig`, `sdk/typescript/src/errors.ts`, and [Error Taxonomy](./error-taxonomy.md) together.
- After editing Markdown under `specs/`, run `npm run specs:compress` so `specs_llm/` stays aligned.

## Cross-Cutting Ownership

Some concerns span multiple subsystems. The canonical owner for each flow is:

| Concern | Canonical Owner | Key Mechanism | Thread Boundary |
|---------|----------------|---------------|-----------------|
| Namespace resolution | `connection/session_resolver.zig` | `SessionResolutionBuffer` (lock-free ring) | Writer thread → Event loop |
| Subscription lifecycle | `subscription_engine.zig` | `ChangeBuffer` (lock-free ring, 8192 cap) | Writer thread → Event loop |
| Write acknowledgement | `storage_engine/write_worker.zig` | `SendQueue` (lock-free MPSC) | Writer thread (producer) → Event loop (consumer, drains in post-handler) |
| Notification fanout | `notification_worker_pool.zig` | `ChangeQueue` (sharded SPMC blocking queue) | Writer thread (producer) → `NotificationWorkerPool` workers (consumers) |
| Error propagation | `wire/errors.zig` | `getWireError()` switch table | Synchronous + async via `SendQueue` |
| Schema sync | `wire/encode.zig` + `connection/manager.zig` | Pre-encoded `[]const u8` at startup | Startup only, sent on `onOpen` |

Each owner file documents the full flow; other files link rather than duplicate.

## Testing Expectations

- Wire protocol changes require E2E test updates in `tests/e2e/`.
- New error codes require updates to `src/wire/errors.zig`, `sdk/typescript/src/errors.ts`, and [Error Taxonomy](./error-taxonomy.md) in the same change.
- Performance-sensitive changes (buffer sizes, timeouts, batch limits) should include benchmark coverage or justification.
- Threading changes require sanitizer coverage; data-race freedom is part of the API contract. See [Sanitizers](./sanitizers.md).

## Core Systems

- [Networking](./networking.md) - uWebSockets binding, server lifecycle, connection callbacks, and transport rules.
- [Wire Protocol](./wire-protocol.md) - MessagePack envelope, message names, response/push names, and compatibility rules.
- [Message Handler](./message-handler.md) - WebSocket message routing, scoped session gates, and response/error flow.
- [Threading](./threading.md) - Worker topology, serialized writes, cross-thread notification, and synchronization ownership.
- [Memory Strategy](./memory-strategy.md) - Allocator ownership, request arenas, connection state, and leak checks.

## Engine Internals

- [Storage](./storage.md) - SQLite WAL setup, connection roles, schema-to-SQL generation, write queue, and query execution.
- [Lock-Free Cache](./lock-free-cache.md) - Read-mostly cache contract and handle lifetime.
- [Query Engine](./query-engine.md) - Query AST, parser, SQL lowering, pagination, and subscription filtering.
- [Presence Internals](./presence-internals.md) - Typed two-tier presence state, subscriptions, snapshots, and broadcasts.
- [Cursor Pagination](./cursor-pagination.md) - Cursor determinism and live window behavior.

## SDK Internals

- [TypeScript SDK](./typescript-sdk.md) - Client module ownership, pending requests, stores, presence, and SDK-local errors.

## Security & Reliability

- [Security](./security.md) - Parser limits, rate limiting, origin policy, and authorization fail-closed behavior.
- [Auth Exchange](./auth-exchange.md) - HTTP ticket exchange, WebSocket connection, and session projection.
- [Auth System](./auth-system.md) - Declarative authorization model and presence authorization boundary.
- [Error Taxonomy](./error-taxonomy.md) - Canonical public error catalog and retry categories.
- [Sanitizers](./sanitizers.md) - TSan/GPA/ASan expectations and CI pass/fail rules.

