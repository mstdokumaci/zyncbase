# Memory Strategy

**Drivers**: [Threading](./threading.md), [Message Handler](./message-handler.md), [Sanitizers](./sanitizers.md)

`MemoryStrategy` centralizes allocator ownership for the server. The implementation separates long-lived server state from per-request temporary allocations and high-churn connection objects.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/memory_strategy.zig` | General allocator, arena pool, connection pool, and `IndexPool(T)`. |
| `src/connection/state.zig` | Pooled `Connection` state and teardown behavior. |
| `src/message_handler.zig` | Per-message arena acquisition/release. |
| `src/server.zig` | Server-lifetime ownership of `MemoryStrategy`. |
| `src/*_test.zig` memory tests | Leak, pool, and request-lifetime coverage. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `MemoryStrategy` | parent allocator, `Connection` | Owns the thread-safe GPA plus pooled arenas and pooled connection objects. |
| `MemoryStrategy.Config` | pool capacities | Defines production/test pool sizing. |
| `IndexPool(T)` | atomics, allocator callbacks | Fixed-capacity pool with tagged free-stack and active-count leak assertion. |
| `std.heap.ArenaAllocator` | GPA allocator | Handles request-temporary allocations released in bulk. |
| `Connection` | connection allocator | High-churn transport/session state reused through the connection pool. |

## Allocation Classes

| Allocation class | Owner | Lifetime |
|------------------|-------|----------|
| Server subsystems, schemas, caches, subscription registries | `MemoryStrategy.generalAllocator()` | Server lifetime or explicit subsystem lifetime. |
| Message decode trees, temporary query/auth buffers, response encoding buffers | Request arena from `acquireArena` | One `handleMessage` call or dispatcher operation. |
| Connection objects | `connection_pool` | Active WebSocket connection; reset before returning to pool. |
| Connection-owned strings/session state | Connection allocator/state | Until scope reset, disconnect, or connection release. |
| Background bounded buffers | Owning subsystem | Fixed capacity; overflow policy must be explicit. |

## Rules

- Acquire/release request arenas in the same lifecycle block; release must reset retained capacity before returning to the pool.
- Do not store arena-owned memory in connection, storage, subscription, or presence state.
- Any pointer handed across subsystem or thread boundaries must be owned by a long-lived allocator or copied into the receiver's allocator.
- `IndexPool(T).deinit` requires zero active items; an active item at shutdown is a leak.
- Pool capacity exhaustion is an implementation error unless the caller has a documented bounded-drop policy.
- Background buffers that intentionally drop work under pressure must document why the drop is safe.

## Failure Behavior

- Public error codes are owned by [Error Taxonomy](./error-taxonomy.md).
- Request-path allocation failure should fail the request and release all temporary state.
- Storage/write-engine allocation failure during deferred work should surface through the write-outcome path when a caller requested committed acknowledgement.
- Test builds should treat GPA leak reports as failures.

## See Also

- [Message Handler](./message-handler.md)
- [Threading](./threading.md)
- [Sanitizers](./sanitizers.md)
