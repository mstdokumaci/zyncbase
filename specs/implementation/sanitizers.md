# Sanitizers

**Drivers**: [Threading](./threading.md), [Memory Strategy](./memory-strategy.md), [Lock-Free Cache](./lock-free-cache.md)

ZyncBase uses runtime sanitizers to enforce concurrency safety, prevent data races, and guarantee leak-free memory operations during testing and CI execution.

---

## Source Files

| File/Context | Responsibility |
|------|----------------|
| `build.zig` | Configures compiler instrumentation options for sanitizers (`-fsanitize=thread`). |
| `src/memory_safety_property_test.zig` | Fuzzes boundary conditions to trigger GPA leak detection. |
| `src/lock_free_cache_leak_test.zig` | Validates that retired cache nodes are correctly destroyed under stress load. |
| `src/subscription/engine_thread_safety_test.zig` | Stresses subscription engines to detect concurrency races under TSan. |

---

## Sanitizer Invariants

- **ThreadSanitizer (TSan)**: Enforces serialized writes (SWMR model) on the lock-free cache, detecting unsynchronized memory access between parallel read threads and the writer thread.
- **GeneralPurposeAllocator (GPA)**: Enforces leak-free execution in debug builds. The allocator logs an error if memory is not released before program exit.
- **Address Stability**: Live threads/mutexes must remain at stable heap/arena addresses. Live synchronization objects must never be bit-copied, which triggers panic failures.
- **Self-Healing Pools**: Releasing non-acquired items back to the `IndexPool` must cause immediate runtime assertions.

---

## CI Verification Rules

- **Zero Race Tolerance**: Any TSan warning emitted to `stderr` during testing is treated as a CI failure.
- **Zero Leak Tolerance**: The presence of any memory leak report from GPA at exit fails the build pipeline.
- **Valgrind coverage**: Exercised on the C interop interface boundaries (uWebSockets, SQLite) to trace allocations outside the Zig runtime.

---

## See Also

- [Threading](./threading.md)
- [Memory Strategy](./memory-strategy.md)
- [Lock-Free Cache](./lock-free-cache.md)
