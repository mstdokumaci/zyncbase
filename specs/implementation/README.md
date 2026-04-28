# Implementation Specifications

This directory contains the technical details, internal implementations, and low-level specifications for the ZyncBase core engine.

## Core Systems
- [Networking & Protocol](./networking.md) — uWebSockets integration and event loop.
- [Wire Protocol](./wire-protocol.md) — The binary MessagePack contract.
- [Threading & Concurrency](./threading.md) — Multi-threaded core and task scheduling.
- [Memory Management](./memory-management.md) — Tiered allocator and object pooling strategies.

## Engine Internals
- [Storage Engine](./storage.md) — SQLite WAL integration and schema management.
- [Lock-Free Cache](./lock-free-cache.md) — Atomic wait-free read cache.
- [Query Engine](./query-engine.md) — AST parsing and query execution logic.
- [Presence Internals](./presence-internals.md) — History buffers and broadcast batching.

## SDK Internals
- [TypeScript SDK](./typescript-sdk.md) — Internal module ownership, wire flow, subscription materialization, and verification rules for the TypeScript SDK.

## Security & Reliability
- [Security Model](./security.md) — Comprehensive security audit and threat model.
- [Auth System](./auth-system.md) — JSON-declarative rules (`authorization.json`).
- [Auth Exchange](./auth-exchange.md) — Ticket-based handshake and session enrichment.
- [Error Taxonomy](./error-taxonomy.md) — Formal classification for retries and monitoring.
- [Sanitizers](./sanitizers.md) — Reliability strategies using TSan/ASan.

## Operations
- [Version Compatibility](./version-compatibility.md) — uWebSockets wrapper stability.
- [Request Handler](./request-handler.md) — Arena lifecycle and message routing.
