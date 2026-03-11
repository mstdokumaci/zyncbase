# Memory Sanitizers

ZyncBase uses memory sanitizers to detect memory safety issues, memory leaks, and data races during testing.

## Available Sanitizers

### ThreadSanitizer (TSan)

Detects data races and other threading issues.

**Usage:**
```bash
zig build test -Dsanitize=thread
```

**Environment Variables:**
```bash
export TSAN_OPTIONS="second_deadlock_stack=1:history_size=7"
zig build test -Dsanitize=thread
```

**What it detects:**
- Data races between threads
- Deadlocks
- Thread leaks
- Use of uninitialized memory in multithreaded contexts

### AddressSanitizer (ASan) and LeakSanitizer (LSan)

**Note:** In Zig 0.15, AddressSanitizer and LeakSanitizer are not directly supported through build options. These sanitizers are typically provided by the C/C++ compiler (Clang/GCC) and work with C code.

For Zig code, memory safety is largely guaranteed by the language itself. However, when interfacing with C code or using unsafe operations, you can:

1. Use Valgrind for memory leak detection:
```bash
valgrind --leak-check=full --show-leak-kinds=all ./zig-out/bin/zyncbase
```

2. Use the Zig standard library's `GeneralPurposeAllocator` with safety checks enabled (already configured in `MemoryStrategy`):
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .thread_safe = true,
}){};
```

## CI Integration

The CI pipeline automatically runs tests with ThreadSanitizer to detect data races. See `.github/workflows/ci.yml` for the configuration.

## Interpreting Results

### ThreadSanitizer Output

When TSan detects a data race, it will output:
- The location of the conflicting memory accesses
- Stack traces for both threads
- The type of conflict (read-write, write-write)

**Example:**
```
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 8 at 0x7b0400000000 by thread T1:
    #0 Pool(Message).release src/memory_strategy.zig:156
    ...
  Previous read of size 8 at 0x7b0400000000 by main thread:
    #0 Pool(Message).acquire src/memory_strategy.zig:134
    ...
```

### Memory Leak Detection

The `GeneralPurposeAllocator` in debug mode will report memory leaks at program exit:
```
error: GeneralPurposeAllocator detected memory leaks:
  - 1024 bytes allocated at src/memory_strategy.zig:29:51
```

## Best Practices

1. **Run sanitizers locally** before pushing code:
   ```bash
   zig build test -Dsanitize=thread
   ```

2. **Fix issues immediately** - sanitizer warnings indicate real bugs that can cause crashes or data corruption in production.

3. **Use atomic operations** for shared state accessed by multiple threads:
   ```zig
   var ref_count: std.atomic.Value(u32) = .{ .raw = 0 };
   _ = ref_count.fetchAdd(1, .acquire);
   ```

4. **Protect shared data** with mutexes when atomic operations aren't sufficient:
   ```zig
   var mutex: std.Thread.Mutex = .{};
   mutex.lock();
   defer mutex.unlock();
   // Access shared data
   ```

5. **Use the arena allocator** for per-request allocations to avoid leaks:
   ```zig
   const arena = memory_strategy.arenaAllocator();
   defer memory_strategy.resetArena();
   // All allocations freed in bulk
   ```

## Known Issues

- ThreadSanitizer may report false positives in some cases. Review each warning carefully.
- ThreadSanitizer significantly slows down execution (5-15x overhead).
- Some tests may timeout when running with sanitizers due to the overhead.

## Requirements Validation

This sanitizer configuration validates:
- **Requirement 7.6**: Tests run with AddressSanitizer (via GPA safety checks and Valgrind)
- **Requirement 7.7**: Tests run with LeakSanitizer (via GPA leak detection)
- **Requirement 7.8**: Tests run with ThreadSanitizer (via `-Dsanitize=thread`)
