# ZyncBase - Architecture Documentation

**Status**: Draft  
**Last Updated**: 2026-03-09  
**Language**: Zig  
**Approach**: Performance-first, self-hosted, real-time collaboration

---

## Overview

ZyncBase is a self-hosted, real-time collaborative database built in Zig for maximum performance and efficiency. It competes with Firebase/Supabase by providing similar developer experience with better performance, predictable costs, and no vendor lock-in.

### Target Performance

- **100,000+ concurrent WebSocket connections**
- **200,000+ requests/second** (powered by uWebSockets, same as Bun)
- **Sub-millisecond latency** for real-time updates
- **Single binary** < 15MB
- **Memory usage** < 100MB for 100k connections

---

## Architecture Documentation

### [Core Principles](./CORE_PRINCIPLES.md)
Design philosophy, technology choices, and why we chose Zig + uWebSockets + SQLite.

**Topics:**
- Why Zig over Node.js, Go, and Rust
- Why uWebSockets for networking
- Why SQLite for storage
- Performance-first approach
- Zero-Zig philosophy

---

### [Threading Model](./THREADING.md)
Multi-threaded architecture with read/write separation for vertical scaling.

**Topics:**
- Multi-threaded core engine
- Lock-free cache for parallel reads
- Write serialization with mutex
- SQLite connection pooling
- 17x performance improvement

---

### [Storage Layer](./STORAGE.md)
SQLite integration with WAL mode for parallel reads and efficient writes.

**Topics:**
- SQLite WAL mode
- Connection pooling strategy
- Write batching and queuing
- Checkpoint management
- Schema design

---

### [Network Layer](./NETWORKING.md)
uWebSockets integration for high-performance WebSocket connections.

**Topics:**
- uWebSockets architecture
- Zig + C++ integration
- WebSocket protocol
- MessagePack serialization
- Connection management

---

### [Query Engine](./QUERY_ENGINE.md)
Query execution, real-time subscriptions, and change detection.

**Topics:**
- Query AST and execution
- Subscription tracking
- Change detection
- Presence system (in-memory, 5-second history, batching)
- Authorization optimization

---

### [Research & Validation](./RESEARCH.md)
Technical analysis validating all architectural assumptions with citations.

**Topics:**
- Performance benchmarks
- Technology comparisons
- Security considerations
- Academic validation
- 55+ technical references

---

## System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    1. **zyncbase-config.json** - Server settings, auth, namespaceskets)          │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │         uWebSockets (C++) - Network Layer             │ │
│  │              (Multi-threaded Event Loop)              │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │ │
│  │  │  Thread 1   │  │  Thread 2   │  │  Thread N   │  │ │
│  │  │  WebSocket  │  │  WebSocket  │  │  WebSocket  │  │ │
│  │  │  + HTTP     │  │  + HTTP     │  │  + HTTP     │  │ │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  │ │
│  │         │                 │                 │         │ │
│  │         └─────────────────┼─────────────────┘         │ │
│  │                           │                           │ │
│  │                    Callbacks (Zig)                    │ │
│  └───────────────────────────┬───────────────────────────┘ │
│                              │                             │
│  ┌───────────────────────────▼───────────────────────────┐ │
│  │       ZyncBase Core Engine (Zig) - MULTI-THREADED         │ │
│  │                                                       │ │
│  │  ┌──────────────────────────────────────────────┐   │ │
│  │  │  Lock-Free Cache (Parallel Reads)            │   │ │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐   │   │ │
│  │  │  │ Thread 1 │  │ Thread 2 │  │ Thread N │   │   │ │
│  │  │  │  Query   │  │  Query   │  │  Query   │   │   │ │
│  │  │  │Subscribe │  │Subscribe │  │Subscribe │   │   │ │
│  │  │  └────┬─────┘  └────┬─────┘  └────┬─────┘   │   │ │
│  │  │       │             │             │          │   │ │
│  │  │       └─────────────┼─────────────┘          │   │ │
│  │  │                     │                        │   │ │
│  │  │              Atomic Ref Count                │   │ │
│  │  └──────────────────────────────────────────────┘   │ │
│  │                                                       │ │
│  │  ┌──────────────────────────────────────────────┐   │ │
│  │  │  Write Mutex (Serialized Writes)             │   │ │
│  │  │  ┌──────────────────────────────────────┐   │   │ │
│  │  │  │  Single Writer Thread                │   │   │ │
│  │  │  │  - State updates                     │   │   │ │
│  │  │  │  - Subscription notifications        │   │   │ │
│  │  │  │  - Queue writes to SQLite            │   │   │ │
│  │  │  └──────────────────────────────────────┘   │   │ │
│  │  └──────────────────────────────────────────────┘   │ │
│  └───────────────────────────┬───────────────────────────┘ │
│                              │                             │
│  ┌───────────────────────────▼───────────────────────────┐ │
│  │         Storage Layer (Zig + SQLite)                  │ │
│  │  ┌─────────────────────────────────────────────────┐  │ │
│  │  │  SQLite Connection Pool (Parallel Reads)       │  │ │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐     │  │ │
│  │  │  │ Reader 1 │  │ Reader 2 │  │ Reader N │     │  │ │
│  │  │  │  (WAL)   │  │  (WAL)   │  │  (WAL)   │     │  │ │
│  │  │  └──────────┘  └──────────┘  └──────────┘     │  │ │
│  │  └─────────────────────────────────────────────────┘  │ │
│  │  ┌─────────────────────────────────────────────────┐  │ │
│  │  │  Single Writer Connection                      │  │ │
│  │  │  - Batched writes                              │  │ │
│  │  │  - WAL mode                                    │  │ │
│  │  └─────────────────────────────────────────────────┘  │ │
│  │  ┌─────────────────────────────────────────────────┐  │ │
│  │  │  SQLite (C) - Embedded Database                │  │ │
│  │  │  - ACID transactions                           │  │ │
│  │  │  - Full-text search                            │  │ │
│  │  └─────────────────────────────────────────────────┘  │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘

Key: ═══ Parallel execution paths (scales with CPU cores)
     ─── Serialized execution (single-writer pattern)
```

---

## Technology Stack

| Layer | Technology | Why |
|-------|------------|-----|
| **Network** | uWebSockets (C++) | 200k+ req/sec, same as Bun |
| **Logic** | Zig | No GC, manual memory control, C interop |
| **Storage** | SQLite (WAL mode) | Zero-config, parallel reads, ACID |
| **Protocol** | WebSocket + MessagePack | Binary efficiency, real-time |

---

## Storage Architecture

ZyncBase uses different storage strategies for different data types:

### Store Data → SQLite
- **Persistent** - Survives server restarts
- **ACID transactions** - Data integrity guarantees
- **Queryable** - Full SQL query capabilities
- **Indexed** - Fast lookups and joins
- **Use cases**: Documents, users, tasks, messages, etc.

### Presence Data → In-Memory
- **Ephemeral** - Cleared on disconnect
- **Ultra-low latency** - Sub-100ms updates
- **High frequency** - Cursor moves, typing indicators
- **Automatic cleanup** - No manual management
- **Use cases**: Cursors, selections, online status, typing indicators

**Why this split?**
- Presence updates happen 60+ times/second (cursor moves)
- Writing to SQLite would exhaust the single-writer lock
- Presence data doesn't need persistence (meaningless after disconnect)
- In-memory storage provides nanosecond latency vs milliseconds for disk

---

## Performance Comparison

| Solution | Req/Sec | Connections | Architecture | Notes |
|----------|---------|-------------|--------------|-------|
| **ZyncBase (Zig + uWebSockets)** | 200k+ | 100k+ | Multi-threaded core | Our target (17x vs single-threaded) |
| **Bun (Zig + uWebSockets)** | 200k+ | Millions | Multi-threaded | Same stack as us |
| **PocketBase (Go)** | 10k | 100k+ | Single-threaded | Proven baseline |
| **Firebase** | Unknown | Millions | Distributed | Proprietary |
| **Zig (ZyncBase)** | Manual / Explicit | Native Threads | None | Zero-cost ABI | ~15MB | **Supabase** | ~5k | 10k+ | Postgres-based | Postgres bottleneck |

---

## Key Design Decisions

### 1. Multi-threaded Core Engine
- **Decision**: Lock-free cache for reads, mutex for writes
- **Impact**: 17x performance improvement (10k → 170k req/sec)
- **Trade-off**: More complexity, but necessary for vertical scaling

### 2. SQLite Connection Pool
- **Decision**: One reader per CPU core, single writer
- **Impact**: Parallel reads fully utilize WAL mode
- **Trade-off**: Writes still serialized (SQLite limitation)

### 3. uWebSockets Integration
- **Decision**: Direct C++ integration via Zig FFI
- **Impact**: Same performance as Bun (200k+ req/sec)
- **Trade-off**: C++ build complexity

### 4. Zero-Zig Philosophy
- **Decision**: JSON configuration, no Zig knowledge required
- **Impact**: Nginx-like deployment experience
- **Trade-off**: Less flexibility than code-based config

---

## Next Steps

1. **Read [Core Principles](./CORE_PRINCIPLES.md)** - Understand the "why" behind technology choices
2. **Review [Threading Model](./THREADING.md)** - See how we achieve 17x performance
3. **Explore [Storage Layer](./STORAGE.md)** - Learn about SQLite optimization
4. **Check [Research](./RESEARCH.md)** - Validate assumptions with citations

---

## See Also

- [API Reference](../API_REFERENCE.md) - Client SDK documentation
- [Configuration](../CONFIGURATION.md) - Server setup
- [Deployment](../DEPLOYMENT.md) - Production deployment
- [Design Decisions](../DESIGN_DECISIONS.md) - High-level architecture decisions
