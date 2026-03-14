# Request Handler

**Drivers**: [Memory Management](./memory-management.md), [Threading Implementation](./threading.md)

The `RequestHandler` owns the per-request memory lifecycle. It creates an arena allocator scoped to a single WebSocket message, processes the message using that arena, copies the response to GPA-backed memory, then resets the arena — freeing all temporary allocations in one operation.

---

## Interface / Contract

```zig
pub const RequestHandler = struct {
    memory: *MemoryStrategy,

    /// Process one WebSocket message.
    ///
    /// Guarantees:
    ///   - All temporary allocations (parse buffers, intermediate results) are
    ///     freed before this function returns, even on error.
    ///   - The returned Response.data is allocated from the GPA and must be
    ///     freed by the caller after the response is sent.
    ///   - Arena is reset via `defer` so it is always released on error paths.
    pub fn handleRequest(self: *RequestHandler, message: []const u8) !Response {
        defer self.memory.resetArena();
        const arena = self.memory.arenaAllocator();

        const parsed = try msgpack.decode(arena, message);
        const result  = try self.dispatch(arena, parsed);

        // Copy response out of arena before reset
        const gpa = self.memory.generalAllocator();
        const data = try gpa.dupe(u8, result);
        return Response{ .data = data, .status = .success };
    }
};

pub const Response = struct {
    data:   []u8,   // GPA-owned; caller must free
    status: Status,
};

pub const Status = enum { success, @"error" };
```

### Allocator Routing

| Allocation | Allocator | Freed by |
|------------|-----------|----------|
| Parse buffers, temp strings | Arena | `resetArena()` at end of `handleRequest` |
| Response bytes | GPA | Caller after `ws.send()` |
| Cache entries, subscriptions | GPA | On eviction / disconnect |
| Pooled objects (Message, Buffer) | Pool | `Pool.release()` |

### Thread Safety
Arena allocator is not thread-safe. Each uWebSockets worker thread owns its own `MemoryStrategy` instance (thread-local). `RequestHandler` must not be shared across threads.

---

## Invariants & Error Conditions

| Invariant | Description |
|-----------|-------------|
| Arena always reset | `defer resetArena()` fires even when `handleRequest` returns an error |
| Response outlives arena | `gpa.dupe` copies response bytes before arena reset |
| No arena allocation escapes | Nothing allocated from `arena` is stored in long-lived state |

| Error | Cause | Behaviour |
|-------|-------|-----------|
| `error.OutOfMemory` | Arena or GPA exhausted | Arena reset fires; `INTERNAL_ERROR` returned to client |
| `error.InvalidMessage` | MessagePack parse failure | Arena reset fires; `INVALID_MESSAGE` returned to client |
| `error.Unauthorized` | Auth check failed | Arena reset fires; `UNAUTHORIZED` returned to client |

---

## Validation & Success Criteria

- [ ] Arena is reset after every request, including error paths
- [ ] Response data is valid after arena reset (GPA copy confirmed)
- [ ] No memory leaks across 10,000 sequential requests (GPA leak check passes)

### Verification Commands
```bash
zig test src/request_handler_test.zig
zig test src/request_handler_test.zig -Dsanitize=thread
```

---

## See Also
- [Memory Management](./memory-management.md) — Arena and GPA strategy
- [Threading Implementation](./threading.md) — Per-thread memory isolation
- [Wire Protocol](./wire-protocol.md) — Message format handled by this handler
