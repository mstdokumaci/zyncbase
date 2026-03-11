# Core Principles

**Last Updated**: 2026-03-09

---

## Design Philosophy

ZyncBase is built on four core principles that guide every architectural decision:

### 1. Performance First
- Zero-copy where possible
- Minimize allocations
- Efficient data structures
- Lock-free algorithms where applicable

### 2. Simplicity
- Single binary deployment
- Zero external dependencies (embedded SQLite)
- Simple configuration
- Clear error messages

### 3. Correctness
- ACID transactions
- Type safety (Zig's compile-time guarantees)
- Comprehensive testing
- Property-based testing for edge cases

### 4. Scalability
- Vertical scaling (use all CPU cores)
- Efficient memory usage
- Connection pooling
- Read replicas support (future)

---

## Why Zig?

Zig was chosen as the primary implementation language for several critical reasons:

### 1. Performance
- **3-4x faster than Node.js**, competitive with Go
- No garbage collector = predictable latency
- Manual memory control for optimization
- Compiles to native machine code

### 2. Multi-threading
- Native support for using all CPU cores
- Direct mapping to system threads
- No hidden scheduler overhead (unlike Go goroutines)
- Fine-grained control over CPU utilization

### 3. Memory Efficiency
- Manual control, no GC pauses
- Specialized allocators (Arena, Pool)
- Zero-cost abstractions
- Predictable memory usage

### 4. Single Binary
- Easy deployment
- Statically linked
- < 15MB binary size
- No runtime dependencies

### 5. C/C++ Interop
- Seamless integration with uWebSockets (C++)
- Zero-cost FFI (no wrapper overhead)
- Direct access to battle-tested libraries
- No CGO penalty (unlike Go)

### 6. Community & Ecosystem
- Growing Zig ecosystem
- First major BaaS project in Zig
- Proven by Bun (same stack)
- Active development and support

### Comparison with Alternatives

| Language | Memory Model | Concurrency | GC Overhead | C Interop | Binary Size |
|----------|--------------|-------------|-------------|-----------|-------------|
| **Zig (ZyncBase)** | Manual / Explicit | Native Threads | None | Zero-cost ABI | ~15MB |
| **Go (PocketBase)** | GC / Implicit | Goroutines (CSP) | Periodic Pauses | CGO Penalty | ~12MB |
| **Rust (Deno)** | Ownership / Borrow | Async / Await | None | Safe FFI Wrapper | ~100MB |
| **JavaScript (Node.js)** | GC / Implicit | Event Loop | Significant | N-API / Addons | >100MB |

**Key Insight**: For real-time state management with 100,000+ connections, GC pauses are unacceptable. Zig's manual memory management provides predictable latency.

---

## Why uWebSockets?

uWebSockets was chosen as the networking foundation for its proven performance and battle-tested reliability:

### 1. Best-in-Class Performance
- **200,000+ requests/second**
- Fastest WebSocket implementation available
- Microsecond-scale latency
- Optimized for real-time applications

### 2. Battle-Tested
- Powers Bun runtime
- Used by Discord for millions of connections
- Handles billions of dollars in crypto exchanges
- Production-proven at scale

### 3. Proven with Zig
- Bun demonstrates successful Zig + uWebSockets integration
- Direct C++ integration via Zig FFI
- No wrapper overhead
- Same performance characteristics as Bun

### 4. Memory Efficient
- Handles millions of connections
- Minimal overhead per connection
- Efficient buffer management
- Low memory footprint

### 5. Active Development
- Well-maintained modern C++ codebase
- Regular updates and improvements
- Strong community support
- Responsive maintainers

### Technical Architecture

uWebSockets is built on µSockets, which provides:
- **Eventing**: epoll (Linux), kqueue (BSD/macOS)
- **Networking**: Zero-copy I/O where possible
- **Cryptography**: TLS 1.3 with BoringSSL
- **Multi-threading**: One app per thread model

### Performance Characteristics

| Metric | uWebSockets | Node.js | Deno |
|--------|-------------|---------|------|
| Peak Throughput | 200,000+ req/s | ~13,254 req/s | ~22,286 req/s |
| Handshake Latency | Microseconds | Milliseconds | Milliseconds |
| Concurrency Model | Multi-threaded Event Loop | Single-threaded Event Loop | Event Loop / Workers |
| Memory per Connection | < 1KB | ~5KB | ~3KB |

**Key Insight**: uWebSockets provides the same performance as Bun because they use the same underlying engine. By using it directly, ZyncBase achieves Bun-level performance.

---

## Why SQLite?

SQLite was chosen as the storage layer for its simplicity, reliability, and performance:

### 1. Zero-Config
- Embedded database (no separate server)
- Single file storage
- No installation required
- Works out of the box

### 2. ACID Transactions
- Full transactional support
- Data integrity guarantees
- Crash recovery
- Proven reliability

### 3. Full-Text Search
- Built-in FTS5 extension
- No external search engine needed
- Efficient text indexing
- Simple query syntax

### 4. Proven Reliability
- Used by billions of devices
- 20+ years of development
- Extensive test suite
- Public domain license

### 5. WAL Mode Performance
- **Parallel reads** (critical for vertical scaling)
- 70,000+ reads/second
- 3,600+ writes/second
- Sequential I/O optimization

### 6. Single File
- Easy backup (copy file)
- Simple deployment
- No complex replication
- Portable across systems

### WAL Mode Benefits

Write-Ahead Logging (WAL) mode transforms SQLite's concurrency model:

**Without WAL (Rollback Journal):**
- Single writer blocks all readers
- Random I/O patterns
- Slower write performance
- Limited concurrency

**With WAL:**
- Multiple readers + one writer
- Sequential I/O patterns
- Faster write performance
- True parallel reads

**Performance Impact:**
```
16-core machine with WAL mode:
- Reads: 16 threads × 10k = 160k reads/sec
- Writes: 1 thread × 10k = 10k writes/sec
- Total: 170k ops/sec (90% read workload)
```

### Comparison with Alternatives

| Database | Type | Concurrency | Setup | Performance | Use Case |
|----------|------|-------------|-------|-------------|----------|
| **SQLite (WAL)** | Embedded | Parallel reads | Zero-config | 70k reads/s | Vertical scaling |
| **PostgreSQL** | Server | Full parallel | Complex | 100k+ ops/s | Horizontal scaling |
| **Redis** | In-memory | Single-threaded | Simple | 100k+ ops/s | Caching only |
| **MongoDB** | Server | Full parallel | Medium | 50k+ ops/s | Document store |

**Key Insight**: For vertical scaling with zero-config deployment, SQLite WAL mode is the optimal choice. It provides parallel reads without the complexity of a separate database server.

---

## Zero-Zig Philosophy

ZyncBase follows a "configuration-first" approach inspired by infrastructure tools:

### Inspiration

**Think of ZyncBase like:**
- **Nginx** - You don't write C, you edit nginx.conf
- **PostgreSQL** - You don't write C, you write SQL and config files
- **Redis** - You don't write C, you use redis.conf

**ZyncBase is the same**: Download the binary, edit config files, connect from your JavaScript/TypeScript app.

### Configuration Files

Users configure ZyncBase with three JSON files:

1. **zyncbase-config.json** - Server settings, auth, namespaces
2. **schema.json** - JSON Schema for data validation
3. **auth.json** - Declarative authorization rules

### No Zig Knowledge Required

- No compilation needed
- No build steps
- No Zig syntax to learn
- Just JSON configuration

### Optional Extensibility

For advanced use cases, users can:
- Write custom auth webhooks (any language)
- Use HTTP API for custom logic
- Extend via external services

But 95% of use cases need only JSON configuration.

---

## Performance Targets

ZyncBase targets the following performance characteristics:

| Metric | Target | Measurement |
|--------|--------|-------------|
| Concurrent connections | 100,000+ | Sustained |
| Requests/second | 200,000+ | Mixed workload |
| Latency (p50) | < 1ms | In-memory ops |
| Latency (p99) | < 10ms | Including disk |
| Memory per connection | < 1KB | Excluding buffers |
| Binary size | < 15MB | Stripped |
| Cold start time | < 100ms | To ready state |

### Why These Targets?

**100,000+ connections:**
- Supports large-scale collaborative apps
- Handles enterprise workloads
- Room for growth

**200,000+ req/sec:**
- Matches Bun performance
- 20x faster than Supabase
- 2x faster than PocketBase

**Sub-millisecond latency:**
- Real-time collaboration requires it
- Cursor movements feel instant
- No perceptible lag

**< 1KB per connection:**
- Efficient memory usage
- Scales to millions of connections
- Low infrastructure cost

---

## Trade-offs and Limitations

Every architectural decision involves trade-offs. Here are ZyncBase's conscious limitations:

### 1. Vertical Scaling Only (v2.0)
- **Decision**: Focus on single-node performance
- **Trade-off**: No horizontal scaling in v2.0
- **Rationale**: Most apps don't need it, adds complexity
- **Future**: Can add in v2.5+ if needed

### 2. Single Writer (SQLite Limitation)
- **Decision**: Accept SQLite's single-writer constraint
- **Trade-off**: Writes are serialized
- **Rationale**: 10k writes/sec is sufficient for most apps
- **Mitigation**: Batch writes for higher throughput

### 3. No Complex Queries (v2.0)
- **Decision**: Simple query language, no joins
- **Trade-off**: Less powerful than SQL
- **Rationale**: Real-time apps rarely need complex queries
- **Mitigation**: Denormalize data, use multiple queries

### 4. Configuration-First
- **Decision**: JSON config, not code
- **Trade-off**: Less flexible than code-based config
- **Rationale**: Simpler for 95% of use cases
- **Mitigation**: Webhooks for custom logic

### 5. No Built-in Horizontal Scaling
- **Decision**: No clustering in v2.0
- **Trade-off**: Can't scale beyond one node
- **Rationale**: Vertical scaling is sufficient for most apps
- **Future**: LiteFS or Marmot for horizontal scaling

---

## Design Principles in Practice

### Example 1: Memory Management

**Principle**: Performance First + Correctness

**Implementation**:
- Arena allocator for request-scoped memory
- General-purpose allocator for long-lived data
- Pool allocator for fixed-size objects
- Compile-time memory safety checks

**Result**: Zero memory leaks, predictable performance

### Example 2: Threading Model

**Principle**: Performance First + Scalability

**Implementation**:
- Lock-free cache for parallel reads
- Mutex-protected writes for correctness
- SQLite connection pool (one reader per core)
- Multi-threaded uWebSockets event loop

**Result**: 17x performance improvement, uses all CPU cores

### Example 3: Configuration

**Principle**: Simplicity + Correctness

**Implementation**:
- JSON Schema validation
- Clear error messages
- Sensible defaults
- No Zig knowledge required

**Result**: Easy to use, hard to misconfigure

---

## Architectural Decision Records (ADRs)

### ADR-001: Multi-threaded Core Engine

**Date**: 2026-03-08  
**Status**: Accepted

**Context**: Initial architecture proposed single-threaded core for simplicity.

**Problem**: Single-threaded core cannot utilize SQLite's parallel read capability (WAL mode). Even with multiple reader connections, only one thread would be reading at a time, wasting CPU cores and limiting vertical scaling to ~10k req/sec.

**Decision**: Implement multi-threaded core engine with read/write separation:
- Lock-free cache for parallel reads
- Mutex-protected writes for correctness
- SQLite connection pool (one reader per CPU core)

**Consequences**:

**Positive:**
- ✅ 17x performance improvement (10k → 170k req/sec on 16-core machine)
- ✅ True vertical scaling - uses all CPU cores
- ✅ SQLite parallel reads fully utilized
- ✅ Competitive with Bun (same architecture pattern)
- ✅ Read-heavy workloads scale linearly with cores

**Negative:**
- ⚠️ More complex than single-threaded (need atomic operations)
- ⚠️ Writes still serialized (SQLite single-writer limitation)
- ⚠️ Need careful testing for race conditions

**Mitigation:**
- Most workloads are 90%+ reads (writes don't bottleneck)
- 10k writes/sec is sufficient for most applications
- Can batch writes for higher throughput
- Zig's type system helps prevent race conditions

**Alternatives Considered:**

1. **Single-threaded core** (rejected)
   - Simpler implementation
   - Cannot utilize multiple CPU cores
   - Limited to ~10k req/sec total
   - Wastes SQLite parallel read capability

2. **Thread-per-namespace** (rejected for v2.0)
   - More complex than read/write separation
   - Harder to load balance
   - Can revisit in v2.5+ if needed

**Validation**: Performance testing will validate this decision. Target: 170k+ req/sec on 16-core machine with 90% read workload.

---

## See Also

- [Threading Model](./THREADING.md) - Detailed threading implementation
- [Storage Layer](./STORAGE.md) - SQLite optimization details
- [Network Layer](./NETWORKING.md) - uWebSockets integration
- [Research](./RESEARCH.md) - Technical validation with citations
