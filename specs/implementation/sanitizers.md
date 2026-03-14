# Sanitizer Configuration

**Drivers**: [Threading Implementation](./threading.md), [Memory Management](./memory-management.md)

This document specifies which sanitizers run against which test targets, what invariants each sanitizer enforces, and what a passing CI run looks like.

---

## Purpose

ZyncBase uses two sanitizer strategies to enforce memory and concurrency correctness:

1. **ThreadSanitizer (TSan)** — enforces the lock-free cache's SWMR invariant: no unsynchronized concurrent writes, no read/write races on shared state.
2. **GeneralPurposeAllocator safety mode** — enforces the arena/GPA invariant: every GPA allocation is freed exactly once; no use-after-free, no double-free.

Valgrind is available as a supplementary tool for C interop paths (uWebSockets, SQLite) where Zig's GPA does not cover allocations.

---

## Invariants Enforced

| Sanitizer | Invariant |
|-----------|-----------|
| TSan | No data race on `LockFreeCache.entries` pointer or any `CacheEntry` field |
| TSan | `write_mutex` is always held when mutating cache entries |
| TSan | `PresenceManager.pending_updates` is only written from the single flush goroutine |
| GPA safety | Every `alloc` from the GPA has exactly one matching `free` |
| GPA safety | Arena memory is never accessed after `resetArena()` |
| GPA safety | Pool `release` is never called on an item not currently acquired |

---

## Test Targets & Sanitizer Matrix

| Test file | TSan | GPA safety |
|-----------|------|------------|
| `src/cache_stress_test.zig` | ✓ required | ✓ |
| `src/core_engine_test.zig` | ✓ required | ✓ |
| `src/presence_manager_test.zig` | ✓ required | ✓ |
| `src/memory_strategy_test.zig` | — | ✓ required |
| `src/request_handler_test.zig` | — | ✓ required |
| `src/memory_strategy_test.zig` | — | ✓ |
| `src/query_engine_test.zig` | — | ✓ |

TSan is required on all tests that exercise shared mutable state across threads. GPA safety is always on in debug builds.

---

## CI Pass / Fail Contract

A CI run passes when:
- `zig build test -Dsanitize=thread` exits 0 with no TSan warnings in stderr.
- `zig build test` (debug, no TSan) exits 0 with no GPA leak report at program exit.

A CI run fails when:
- Any TSan warning appears, regardless of test exit code. TSan warnings are treated as build failures.
- GPA reports any leak at exit (`error: GeneralPurposeAllocator detected memory leaks`).
- Any test panics or returns a non-zero exit code.

TSan warnings that are confirmed false positives must be suppressed via a `tsan_suppressions.txt` file checked into the repo, with a comment explaining the suppression.

---

## Verification Commands

```bash
# TSan — must be clean
zig build test -Dsanitize=thread

# GPA leak check — must be clean (debug build, default)
zig build test

# Supplementary: Valgrind for C interop paths
valgrind --leak-check=full --error-exitcode=1 ./zig-out/bin/zyncbase-test
```

---

## See Also
- [Threading Implementation](./threading.md) — lock-free cache SWMR model
- [Memory Management](./memory-management.md) — GPA / arena / pool strategy
- [Lock-Free Cache](./lock-free-cache.md) — ref_count invariants
