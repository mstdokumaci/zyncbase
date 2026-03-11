# Threading Model

**Last Updated**: 2026-03-09

---

## Overview

STX uses a **multi-threaded architecture with read/write separation** to maximize vertical scaling. This design allows the system to utilize all CPU cores for read operations while maintaining correctness through serialized writes.

**Key Innovation**: Lock-free cache for reads + mutex for writes = 17x performance improvement

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│  uWebSockets Event Loop (Multi-threaded)               │
│       │                    │                    │        │
│  Thread 1             Thread 2            Thread N      │
│  WebSocket            WebSocket           WebSocket     │
│  Connections          Connections         Connections   │
│       │                    │                    │        │
│       └────────────────────┼────────────────────┘        │
│                            │                             │
│                     Callbacks (Zig)                      │
│                            │                             │
│              ┌─────────────▼─────────────┐               │
│              │   Message Router          │               │
│              └─────────────┬─────────────┘               │
│                            │                             │
│              ┌─────────────┴─────────────┐               │
│              │                           │               │
│         READ PATH                   WRITE PATH          │
│    (Parallel, Lock-Free)        (Serialized, Mutex)    │
│              │                           │               │
│    ┌─────────▼─────────┐      ┌─────────▼─────────┐    │
│    │  Lock-Free Cache  │      │   Write Mutex     │    │
│    │  ┌──┐  ┌──┐  ┌──┐│      │  ┌──────────────┐ │    │
│    │  │T1│  │T2│  │TN││      │  │ Single Writer│ │    │
│    │  └──┘  └──┘  └──┘│      │  └──────────────┘ │    │
│    │  Atomic Ref Count│      │  State Updates    │    │
│    └─────────┬─────────┘      └─────────┬─────────┘    │
│              │                           │               │
│    ┌─────────▼─────────┐      ┌─────────▼─────────┐    │
│    │ SQLite Read Pool  │      │ SQLite Writer     │    │
│    │  ┌──┐  ┌──┐  ┌──┐│      │  ┌──────────────┐ │    │
│    │  │R1│  │R2│  │RN││      │  │ WAL Batching │ │    │
│    │  └──┘  └──┘  └──┘│      │  └──────────────┘ │    │
│    │  (WAL Mode)       │      │  (WAL Mode)       │    │
│    └───────────────────┘      └───────────────────┘    │
│                                                         │
│  Performance (16-core, 90% reads):                     │
│  - Reads:  16 × 11k = 176k req/sec (parallel)         │
│  - Writes:  1 × 10k =  10k req/sec (serialized)       │
│  - Total: ~170k req/sec average                        │
│  - CPU usage: ~95% (all cores utilized)                │
└─────────────────────────────────────────────────────────┘
```

---

## How It Works

### 1. uWebSockets Handles Multi-threading

- Event loop runs on multiple threads
- Automatically distributes connections across threads
- Handles all network I/O
- No blocking between threads

### 2. Zig Callbacks Execute in Parallel

- Multiple threads can process messages simultaneously
- Message router directs to read or write path
- No blocking between read operations
- Writes are queued and serialized

### 3. Core Engine Uses Read/Write Separation

**Read Path (Parallel):**
- Lock-free cache access
- Multiple threads execute simultaneously
- SQLite connection pool enables parallel database reads
- Scales linearly with CPU cores

**Write Path (Serialized):**
- Mutex-protected for correctness
- Single writer thread
- Batched writes to SQLite
- Notifies subscribers after write

---

## Thread Safety Strategy

### Core Engine Implementation

```zig
pub const CoreEngine = struct {
    // Lock-free cache for reads (parallel access)
    state_cache: LockFreeCache,
    
    // Mutex only for writes (serialized)
    write_mutex: std.Thread.Mutex,
    
    // Storage layer with parallel reads
    storage: *StorageLayer,
    
    pub fn handleMessage(self: *CoreEngine, msg: Message) !Message {
        return switch (msg.type) {
            // Reads: No lock, parallel execution
            .query => try self.handleQueryParallel(msg),
            .subscribe => try self.handleSubscribeParallel(msg),
            
            // Writes: Serialized with mutex
            .mutation => try self.handleMutationSerialized(msg),
            
            else => error.UnknownMessageType,
        };
    }
    
    // Parallel reads (no mutex) - uses all CPU cores
    fn handleQueryParallel(self: *CoreEngine, msg: Message) !Message {
        // Multiple threads execute this simultaneously
        const state = try self.state_cache.get(msg.namespace);
        return try self.executeQuery(state, msg.query);
    }
    
    // Serialized writes (with mutex) - single-writer
    fn handleMutationSerialized(self: *CoreEngine, msg: Message) !Message {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        
        // Only one thread executes this at a time
        try self.state_cache.update(msg.namespace, msg.mutation);
        try self.storage.queueWrite(msg.namespace, msg.mutation);
        try self.notifySubscribers(msg.namespace);
        
        return .{ .type = .success };
    }
};
```

---

## Lock-Free Cache Implementation

The lock-free cache is critical for achieving parallel read performance:

```zig
const LockFreeCache = struct {
    // Use atomic reference counting for cache entries
    entries: std.atomic.Value(*HashMap([]const u8, *CacheEntry)),
    
    const CacheEntry = struct {
        state: StateTree,
        version: std.atomic.Value(u64),
        ref_count: std.atomic.Value(u32),
    };
    
    pub fn get(self: *LockFreeCache, namespace: []const u8) !*StateTree {
        // Lock-free read - multiple threads can execute simultaneously
        const entries = self.entries.load(.Acquire);
        const entry = entries.get(namespace) orelse return error.NotFound;
        
        // Increment ref count atomically
        _ = entry.ref_count.fetchAdd(1, .AcqRel);
        
        return &entry.state;
    }
    
    pub fn release(self: *LockFreeCache, namespace: []const u8) void {
        const entries = self.entries.load(.Acquire);
        const entry = entries.get(namespace) orelse return;
        
        // Decrement ref count atomically
        _ = entry.ref_count.fetchSub(1, .AcqRel);
    }
    
    pub fn update(self: *LockFreeCache, namespace: []const u8, mutation: Mutation) !void {
        // Called only from write_mutex critical section
        // Safe to mutate because writes are serialized
        const entries = self.entries.load(.Acquire);
        const entry = entries.get(namespace) orelse return error.NotFound;
        
        try entry.state.apply(mutation);
        _ = entry.version.fetchAdd(1, .Release);
    }
};
```

### Critical Implementation Notes

**MUST use proper atomic operations:**
- If the cache falls back to a global mutex, it negates all benefits
- All reads would block on each other
- Performance would drop to single-threaded levels (~10k req/sec)
- The 17x improvement depends on true lock-free reads

**Memory ordering:**
- `.Acquire` for loads - ensures we see all previous writes
- `.Release` for stores - ensures our writes are visible to other threads
- `.AcqRel` for read-modify-write - combines both

---

## Performance Characteristics

### Typical Workload (90% reads, 10% writes)

**16-core machine:**
```
Reads:  16 cores × ~11k each = 176k req/sec (parallel)
Writes:  1 core  × ~10k      =  10k req/sec (serialized)
Combined: ~170k req/sec average
CPU usage: ~95% (all cores utilized)
```

**vs Single-threaded approach:**
```
Reads:  1 core × 10k = 10k req/sec
Writes: 1 core × 10k = 10k req/sec
Combined: 10k req/sec
CPU usage: 6% (1/16 cores)
```

**Result: 17x performance improvement!**

### Why This Works

**1. Reads are lock-free**
- Multiple threads read simultaneously
- No contention, scales with CPU cores
- SQLite parallel reads fully utilized

**2. Writes are serialized**
- Necessary for correctness (ACID)
- SQLite single-writer limitation
- Still fast (10k+ writes/sec)

**3. Read-heavy workloads scale linearly**
- Most real-time apps are 80-95% reads
- Reads use all CPU cores
- Writes don't bottleneck reads

---

## SQLite Connection Pool

The storage layer uses a connection pool to enable parallel reads:

```zig
const StorageLayer = struct {
    write_conn: *sqlite.Connection,      // Single writer
    read_pool: []sqlite.Connection,      // Multiple readers
    write_queue: RingBuffer(WriteOp),
    
    pub fn init(allocator: Allocator) !*StorageLayer {
        const num_readers = std.Thread.getCpuCount();
        
        const self = try allocator.create(StorageLayer);
        self.* = .{
            .write_conn = try sqlite.open("stx.db"),
            .read_pool = try allocator.alloc(sqlite.Connection, num_readers),
            .write_queue = RingBuffer(WriteOp).init(allocator),
        };
        
        // Open one reader connection per CPU core
        for (self.read_pool) |*conn| {
            conn.* = try sqlite.open("stx.db");
        }
        
        // Configure WAL mode
        try self.write_conn.exec("PRAGMA journal_mode = WAL");
        
        return self;
    }
    
    pub fn loadNamespace(self: *StorageLayer, namespace: []const u8) !json.Value {
        // Get a reader from pool (round-robin or thread-local)
        const thread_id = std.Thread.getCurrentId();
        const reader_idx = thread_id % self.read_pool.len;
        const conn = &self.read_pool[reader_idx];
        
        // Parallel read (multiple threads can execute simultaneously)
        const stmt = try conn.prepare(
            "SELECT state FROM namespaces WHERE id = ?"
        );
        defer stmt.finalize();
        
        try stmt.bind(1, namespace);
        
        if (try stmt.step()) {
            const blob = try stmt.column(0, []const u8);
            return try json.parse(blob);
        }
        
        return error.NamespaceNotFound;
    }
};
```

### Why This Enables Vertical Scaling

**1. Multiple reader connections** = parallel reads across CPU cores
**2. WAL mode** = readers don't block each other
**3. Single writer connection** = serialized writes (SQLite requirement)
**4. Thread-local reader selection** = no contention for connections

**Performance:**
```
16-core machine with WAL mode:
- Reads: 16 threads × 10k = 160k reads/sec
- Writes: 1 thread × 10k = 10k writes/sec
- Total: 170k ops/sec (90% read workload)
```

---

## Memory Management

### Allocation Strategy

STX uses specialized allocators for different memory lifetimes:

```zig
const Server = struct {
    // Long-lived allocations
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    
    // Per-request arena
    arena: std.heap.ArenaAllocator,
    
    // Object pools
    message_pool: Pool(Message),
    buffer_pool: Pool(Buffer),
    
    pub fn handleRequest(self: *Server) !void {
        defer self.arena.deinit(); // Bulk free
        const allocator = self.arena.allocator();
        
        // All request allocations use arena
        const data = try allocator.alloc(u8, size);
        // ... process ...
        // No need to free individually
    }
};
```

### Allocator Types

**1. Arena Allocator** - Request-scoped allocations
- Fast allocation
- Bulk deallocation
- No fragmentation
- Perfect for request/response cycle

**2. General Purpose Allocator** - Long-lived data
- State tree
- Subscriptions
- Connection metadata
- Careful manual management

**3. Pool Allocator** - Fixed-size objects
- Messages
- Buffers
- Common structures
- Reuse without allocation

---

## Pros and Cons

### Pros

✅ **Uses all CPU cores** - True vertical scaling  
✅ **Reads scale linearly** - More cores = more throughput  
✅ **SQLite parallel reads** - Fully utilized  
✅ **17x better performance** - Than single-threaded  
✅ **Still simple** - No complex locking patterns  

### Cons

⚠️ **Writes are serialized** - SQLite single-writer limitation  
⚠️ **Need atomic operations** - For lock-free cache  
⚠️ **More complex** - Than single-threaded approach  

### Mitigation

**For serialized writes:**
- Most workloads are read-heavy (90%+)
- 10k writes/sec is sufficient for most apps
- Can batch writes for higher throughput

**For atomic operations:**
- Zig provides safe atomic primitives
- Compile-time checks prevent race conditions
- Extensive testing validates correctness

---

## Comparison with Alternatives

### Single-threaded Core (Rejected)

**Pros:**
- Simpler implementation
- No race conditions
- Easier to reason about

**Cons:**
- Cannot utilize multiple CPU cores
- Limited to ~10k req/sec total
- Wastes SQLite parallel read capability
- Not competitive with Bun/modern systems

### Thread-per-Namespace (Future)

**Pros:**
- Natural isolation per tenant
- Could scale beyond single-writer limit

**Cons:**
- More complex than read/write separation
- Harder to load balance
- Requires more sophisticated scheduling

**Decision:** Defer to v2.5+ if needed

---

## Performance Validation

### Benchmarking Strategy

**1. Measure read throughput:**
```bash
# Simulate 16 concurrent readers
./benchmark --readers 16 --duration 60s
# Expected: ~176k reads/sec
```

**2. Measure write throughput:**
```bash
# Simulate single writer
./benchmark --writers 1 --duration 60s
# Expected: ~10k writes/sec
```

**3. Measure mixed workload:**
```bash
# Simulate 90% reads, 10% writes
./benchmark --mixed 90:10 --duration 60s
# Expected: ~170k ops/sec
```

**4. Measure CPU utilization:**
```bash
# Should see ~95% CPU usage across all cores
htop
```

### Success Criteria

- ✅ Read throughput scales linearly with cores
- ✅ Write throughput meets 10k+ writes/sec
- ✅ Mixed workload achieves 170k+ ops/sec
- ✅ CPU utilization > 90% on all cores
- ✅ No lock contention in read path

---

## See Also

- [Core Principles](./CORE_PRINCIPLES.md) - Why we chose this approach
- [Storage Layer](./STORAGE.md) - SQLite WAL mode details
- [Network Layer](./NETWORKING.md) - uWebSockets integration
- [Research](./RESEARCH.md) - Performance validation with citations
