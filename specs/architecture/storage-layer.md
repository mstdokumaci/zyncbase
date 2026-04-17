# Storage Layer

**Last Updated**: 2026-03-09

---

## Overview

ZyncBase uses SQLite in Write-Ahead Logging (WAL) mode as its storage layer. This provides zero-config deployment, ACID transactions, and parallel reads—all critical for vertical scaling.

**Key Innovation**: SQLite WAL mode + connection pool = parallel reads across all CPU cores. For the architectural decision, see [ADR-004](./adrs.md#adr-004-sqlite-wal-mode--concurrency).

---

## Why SQLite?

### Advantages

✅ **Zero-config** - Embedded database, no separate server  
✅ **ACID transactions** - Data integrity guarantees  
✅ **Full-text search** - Built-in FTS5 extension  
✅ **Proven reliability** - 20+ years, billions of devices  
✅ **WAL mode** - Parallel reads (critical for scaling)  
✅ **Single file** - Easy backup and deployment  

### Performance

- **70,000+ reads/second** (with WAL mode)
- **3,600+ writes/second** (with batching)
- **Sub-millisecond latency** (in-memory cache)
- **Scales with CPU cores** (parallel reads)

---

## WAL Mode: The Concurrency Engine

Write-Ahead Logging (WAL) transforms SQLite's concurrency model from a single-user system to a high-concurrency engine.

### Without WAL (Rollback Journal)

```
┌───────────────────────────────────────┐
│           Single Writer               │
│  ┌─────────────────────────────────┐  │
│  │      Blocks ALL Readers         │  │
│  └─────────────────────────────────┘  │
│                                       │
│          Random I/O patterns          │
│       Slower write performance        │
│          Limited concurrency          │
└───────────────────────────────────────┘
```

### With WAL

```
┌───────────────────────────────────────┐
│     Multiple Readers (Parallel)       │
│  ┌──────┐    ┌──────┐    ┌──────┐     │
│  │  R1  │    │  R2  │    │  RN  │     │
│  └──────┘    └──────┘    └──────┘     │
│                                       │
│     Single Writer (No blocking)       │
│  ┌─────────────────────────────────┐  │
│  │      Writes to WAL file         │  │
│  └─────────────────────────────────┘  │
│                                       │
│        Sequential I/O patterns        │
│       Faster write performance        │
│          True parallel reads          │
└───────────────────────────────────────┘
```

### How WAL Works

1. **Writes go to WAL file** - Not the main database, avoiding contention.
2. **Readers access both** - Main DB + WAL file, allowing concurrent read/write.
3. **Checkpoint merges** - WAL entries are merged back to the main DB periodically.
4. **No blocking** - Readers and writer operate independently.

### Performance Impact

```
16-core machine with WAL mode:
- Reads: 16 threads × 10k = 160k reads/sec
- Writes: 1 thread × 10k = 10k writes/sec
- Total: 170k ops/sec (90% read workload)
```

---

## Connection Pool Strategy

To utilize multiple CPU cores for reads, ZyncBase maintains a connection pool with one reader per core. All writes are queued and executed via a single writer connection to satisfy SQLite's serialization requirements. See [ADR-005](./adrs.md#adr-005-multi-threaded-core-engine).

- **One reader per core**: Maximizes parallel read throughput without connection contention.
- **Single writer**: Batched for efficiency to overcome `fsync()` overhead.
- **Thread-local selection**: Minimizes internal synchronization overhead when requesting a connection.

---

## Schema Design: Relational-Document Hybrid

ZyncBase generates SQLite tables from a declarative `schema.json`. This provides an abstraction where frontend developers work with paths (document-style), while the core maintains rigid relational integrity. See [ADR-019](./adrs.md#adr-019-relational-document-hybrid-path-conventions).

### Path-to-Table Mapping
The first segment of a path (e.g., `tasks`) maps to a database table. This simplifies indexing and query optimization.

> [!IMPORTANT]
> **Mandatory Schema Architecture**: ZyncBase enforces a strict-schema architecture. 
> 1. A valid JSON schema file is **mandatory** for server startup.
> 2. The server will fail to initialize if no schema is provided or if the schema is invalid.
> 3. All database tables and columns are strictly derived from the schema; ad-hoc table creation is prohibited.
> 4. Dynamic/schemaless storage fallbacks (like a global KV store) have been removed in favor of typed relational integrity.

### Relational Patterns
- **Flattening**: Simple nested objects are automatically flattened into relational columns.
    - **Example**: `address.city` → `address_city TEXT`.
- **References**: Document-style references are enforced via SQLite foreign keys with configurable actions.
    - **Actions**: `cascade`, `restrict`, `set_null`.
- **Arrays**: 
    - **Simple arrays** (primitives) are normalized as canonical sorted sets on write.
    - Canonical arrays are persisted and returned in sorted, unique form.
    - **Object arrays** are forbidden; developers must use separate store paths and references.

### Schema Example: Tasks and Projects

From a declarative schema, ZyncBase generates optimized DDL:

```sql
-- Projects table
CREATE TABLE projects (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL,
    name TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Tasks table with foreign key
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL,
    title TEXT,
    status TEXT,
    priority INTEGER,
    projectId TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (projectId) REFERENCES projects(id) ON DELETE CASCADE
);

CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_projectId ON tasks(projectId);
```

---

## Write Strategy: Batching for Throughput

SQLite's single-writer limitation is mitigated by an async ring-buffer queue and transaction batching.

### Why Batching?

**Without batching:** Each write is a separate transaction, requiring an `fsync()` call. This limits throughput to ~100 writes/sec (disk latency bound).

**With batching:** 100+ operations are grouped into one transaction, requiring only one `fsync()` call. This enables 10,000+ writes/sec, a 100x improvement.

### Batching Strategy
- **Batch Size**: Triggered when the queue reaches a threshold (e.g., 100 ops).
- **Timeout**: Triggered if operations have been queued for too long (e.g., 10ms) to maintain low latency.

### Batching Trade-off: Asynchronous Error Reporting
Because writes are asynchronous (fire-and-forget for low latency), the server returns an `ok` as soon as the operation is accepted into the memory queue. If a write fails during background persistence (e.g., disk full, constraint violation), the server is responsible for sending an asynchronous error message (NACK) to the client so the SDK can revert the optimistic update.

---

## Auto-Migration System

ZyncBase includes a structural detection system that manages schema evolution automatically.
- **Safe Additions**: Creating tables and adding columns are performed automatically.
- **Destructive Changes**: Type changes or column removals are gated behind environment configuration.
- **Execution**: Uses temporary table backups to work around SQLite's `ALTER TABLE` limitations.

---

## Checkpoint Management

WAL files require careful management to prevent disk bloat and read degradation:
1. **Passive**: Non-blocking merges during idle periods.
2. **Auto**: Triggered by WAL file page threshold (default 1000).
3. **Active**: Forced merges during maintenance windows.

---

## Comparison with Alternatives

| Database | Type | Concurrency | Setup | Performance | Use Case |
|----------|------|-------------|-------|-------------|----------|
| **SQLite (WAL)** | Embedded | Parallel reads | Zero-config | 70k reads/s | Vertical scaling |
| **PostgreSQL** | Server | Full parallel | Complex | 100k+ ops/s | Horizontal scaling |
| **Redis** | In-memory | Single-threaded | Simple | 100k+ ops/s | Caching only |
| **MongoDB** | Server | Full parallel | Medium | 50k+ ops/s | Document store |

---

## Limitations and Trade-offs

### Single Writer
SQLite allows only one writer at a time. While batching helps, it cannot scale to massive write-heavy workloads that require many concurrent writers.

### Checkpoint Starvation
Heavy read load can prevent WAL entries from being merged back to the main DB, leading to WAL file growth and read degradation. ZyncBase manages this with proactive checkpointing.

### No Horizontal Scaling (v1.0)
The storage layer is designed for vertical scaling on a single node. For distributed multi-node clusters, ZyncBase suggests LiteFS or Marmot in future iterations.

---

## See Also

- [Storage Implementation](../implementation/storage.md) - Zig code, PRAGMAs, and DDL generator
- [Threading Model](./threading-model.md) - How connection pool enables parallel reads
- [ADRs](./adrs.md) - Architectural Decision Records
- [Research](./research.md) - SQLite performance benchmarks
