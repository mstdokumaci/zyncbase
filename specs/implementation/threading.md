# Threading Implementation

**Drivers**: [Threading Model Architecture](../../architecture/threading-model.md)

This document contains the implementation specifics for the ZyncBase threading model.

## Core Engine Implementation

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

## Lock-Free Cache Coordination

The interaction between the CoreEngine and the Lock-Free Cache is critical for performance:

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

## Performance Validation

### Benchmarking Strategy

**1. Measure read throughput:**
```bash
./benchmark --readers 16 --duration 60s
```

**2. Measure write throughput:**
```bash
./benchmark --writers 1 --duration 60s
```

**3. Measure mixed workload:**
```bash
# Simulate 90% reads, 10% writes
./benchmark --mixed 90:10 --duration 60s
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
