# Storage Layer

---

## Overview

ZyncBase uses SQLite in Write-Ahead Logging (WAL) mode as its storage layer. This provides zero-config deployment, ACID transactions, and parallel reads—all critical for vertical scaling.

---

## Why SQLite?

### Advantages

✅ **Zero-config** - Embedded database, no separate server  
✅ **ACID transactions** - Data integrity guarantees  
✅ **Proven reliability** - 20+ years, billions of devices  
✅ **WAL mode** - Parallel reads (critical for scaling)  
✅ **Single file** - Easy backup and deployment  

### Performance

- **70,000+ reads/second** (with WAL mode)
- **3,600+ writes/second** (with batching)
- **Sub-millisecond latency** (in-memory cache)
- **Scales with CPU cores** (parallel reads)

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

### No Horizontal Scaling
The storage layer is designed for vertical scaling on a single node. Distributed multi-node clustering is out of scope (ADR-002).

---

## Related Specifications

- [Threading Model](./threading-model.md) - How the reader pool enables parallel reads
- [ADRs](./adrs.md) - Architectural Decision Records
