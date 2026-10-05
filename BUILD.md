# Building ZyncBase

## Prerequisites

1. **Zig** (0.16.0) — https://ziglang.org/download/
2. **OpenSSL**
   - macOS: `brew install openssl` (include/lib paths auto-detected by `build.zig`)
   - Linux: `sudo apt-get install libssl-dev`
3. **C/C++ Compiler**
   - macOS: Xcode Command Line Tools (`xcode-select --install`)
   - Linux: `sudo apt-get install build-essential`
4. **Bun** — https://bun.sh (for `test:tsan`, lint, and E2E commands)

## Build

```bash
git clone https://github.com/mstdokumaci/zyncbase.git
cd zyncbase
zig build
```

The executable is created at `./zig-out/bin/zyncbase`.

uWebSockets and µSockets are vendored under `vendor/uwebsockets/` and `vendor/usockets/`; the Zig server calls them through the C bridge in `src/uws_bridge.cpp` and `src/uws_wrapper.h`.

## Test

```bash
zig build test
```

## Build Options

```bash
zig build                              # Debug (default)
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
bun run test:tsan                      # ThreadSanitizer (runs scripts/tsan-prep.sh first)
```

Clean build:

```bash
rm -rf zig-out .zig-cache
zig build
```

## More

Lint (`bun run lint`), E2E (`bun run test:e2e`), and SDK commands are defined in `package.json`. CI runs in `.github/workflows/ci.yml`.
