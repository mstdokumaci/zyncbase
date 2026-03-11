# Lock-Free Cache Implementation

## Overview

This document describes the lock-free cache implementation for ZyncBase, which enables parallel reads across all CPU cores without mutex contention. The implementation uses atomic operations for all read access to cache entries and implements atomic reference counting to prevent use-after-free errors.

## Architecture

### Core Components

1. **LockFreeCache**: Main cache structure with atomic HashMap
2. **CacheEntry**: Individual cache entry with atomic fields
3. **StateTree**: Hierarchical JSON structure for application state

### Key Features

- **Lock-free reads**: Multiple threads can read simultaneously without blocking
- **Atomic reference counting**: Prevents use-after-free with atomic ref_count
- **Single-writer updates**: Write operations are serialized with a mutex
- **Memory ordering guarantees**: Uses Acquire/Release ordering for visibility

## API Reference

### LockFreeCache

```zig
pub const LockFreeCache = struct {
    entries: std.atomic.Value(*std.StringHashMap(*CacheEntry)),
    allocator: Allocator,
    write_mutex: std.Thread.Mutex,
}
```

#### Methods

- `init(allocator: Allocator) !*LockFreeCache` - Initialize a new cache
- `deinit(self: *LockFreeCache) void` - Clean up cache and free memory
- `get(self: *LockFreeCache, namespace: []const u8) !*StateTree` - Lock-free read with ref_count increment
- `release(self: *LockFreeCache, namespace: []const u8) void` - Decrement ref_count after read
- `update(self: *LockFreeCache, namespace: []const u8, new_state: StateTree) !void` - Update cache entry
- `evict(self: *LockFreeCache, namespace: []const u8) !void` - Remove entry from cache
- `create(self: *LockFreeCache, namespace: []const u8) !void` - Create new cache entry

### CacheEntry

```zig
pub const CacheEntry = struct {
    state: StateTree,
    version: std.atomic.Value(u64),
    ref_count: std.atomic.Value(u32),
    timestamp: std.atomic.Value(i64),
}
```

All fields use atomic operations for thread-safe access.

### StateTree

```zig
pub const StateTree = struct {
    root: *Node,
    allocator: Allocator,
    
    pub const Node = struct {
        key: []const u8,
        value: std.json.Value,
        children: std.StringHashMap(*Node),
    };
}
```

Hierarchical structure for storing JSON state.

## Usage Example

```zig
const allocator = std.heap.page_allocator;

// Initialize cache
var cache = try LockFreeCache.init(allocator);
defer cache.deinit();

// Create a namespace
try cache.create("workspace-123");

// Lock-free read (can be done by multiple threads simultaneously)
const state = try cache.get("workspace-123");
defer cache.release("workspace-123");

// Use the state
// ... process state data ...

// Update (serialized with write mutex)
const new_state = try StateTree.init(allocator);
try cache.update("workspace-123", new_state);

// Evict when done
try cache.evict("workspace-123");
```

## Thread Safety

### Read Operations (Lock-Free)

- `get()` - Multiple threads can call simultaneously
- Uses atomic `fetchAdd` with AcqRel ordering
- No blocking or waiting

### Write Operations (Serialized)

- `update()` - Protected by write_mutex
- `evict()` - Protected by write_mutex
- `create()` - Protected by write_mutex

### Memory Ordering

- **Acquire**: Used when loading shared data
- **Release**: Used when storing shared data
- **AcqRel**: Used for read-modify-write operations

## Performance Characteristics

### Target Metrics (from Requirements)

- Read latency: < 100 nanoseconds for cache hits
- Throughput: 176,000 reads/sec on 16-core machine
- Scalability: Linear with CPU cores

### Actual Implementation

- Zero-copy reads (returns pointer to cached state)
- Atomic operations only (no locks on read path)
- Minimal memory overhead (~1KB per cache entry)

## Testing

### Property Tests

1. **Concurrent reads never block** - Validates parallel read access
2. **Ref_count never negative** - Validates reference counting invariants
3. **Ref_count overflow protection** - Validates safety checks
4. **Multiple namespaces** - Validates concurrent access to different entries
5. **Memory ordering with updates** - Validates visibility guarantees

### Unit Tests

1. Cache miss scenarios
2. Eviction with non-zero ref_count
3. Update on non-existent namespace
4. Version increments
5. Timestamp updates
6. Multiple creates
7. Empty and long namespace strings
8. StateTree node operations

All tests pass with zero memory leaks.

## Requirements Validation

This implementation satisfies the following requirements from the spec:

- **1.1**: Uses atomic operations for all read access ✓
- **1.2**: Allows concurrent reads without blocking ✓
- **1.3**: Atomically increments ref_count on get() ✓
- **1.4**: Atomically decrements ref_count on release() ✓
- **1.5**: Returns RefCountOverflow error on overflow ✓
- **1.6**: Uses Acquire/Release memory ordering ✓
- **1.7**: Marks entries for GC when ref_count reaches zero ✓
- **1.8**: Prevents use-after-free with reference counting ✓

## Future Enhancements

1. **Garbage Collection**: Implement background GC for zero-ref entries
2. **Cache Eviction Policy**: Add LRU or TTL-based eviction
3. **Metrics**: Export cache hit rate, entry count, memory usage
4. **Benchmarking**: Validate performance targets with real workloads
