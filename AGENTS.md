# ZyncBase Project Overview

High-performance, multi-threaded real-time database built with Zig.

Important: Project is still in early development stage. Give no consideration to legacy support or backward compatibility, assume green field. Implement everything as a clean cut-off!

## Tech Stack
- **Core:** Zig (0.15.2 or later)
- **Database:** SQLite (integrated with WAL mode)
- **Networking:** uWebSockets (forked by Bun), BoringSSL
- **Serialization:** MessagePack (`zig-msgpack`)
- **Infrastructure:** CMake (for BoringSSL), Go (for BoringSSL build), Python (for spec compression)

## Codebase Structure
- `src/`: Core Zig source code.
    - `main.zig`: Entry point.
    - `server.zig`: WebSocket server implementation.
    - `storage_engine.zig`: SQLite persistence layer.
    - `message_handler.zig`: Protocol and message processing logic.
    - `uwebsockets_wrapper.zig`: Integration with the uWebSockets C library.
- `tests/`: End-to-end and integration tests.
- `specs/`: Human-readable architectural and implementation specifications.
- `specs_llm/`: Compressed/TXT versions of specs used as the source of truth for architectural decisions.
- `vendor/`: Third-party dependencies (BoringSSL, Bun's uWebSockets/uSockets).
- `scripts/`: Build, patch, and utility scripts.
- `patches/`: Custom patches applied to vendor code.
- `sdk/typescript`: Typescript SDK

# Code Style and Conventions

## Architectural Source of Truth
- The `specs_llm/` directory contains the authoritative architectural design decisions and implementation specs.
- When updating design, modify the Markdown files in `specs/`, then run `npm run specs:compress` to update `specs_llm/`.

## Zig Coding Style
- Follow standard Zig conventions (CamelCase for types, snake_case for functions and variables).
- Use `std.Build` for project configuration.
- Heavy use of error unions and explicit memory management (standard Zig patterns).
- **ArrayList Initialization (Zig 0.15):** Prefer initializing with `.empty` (e.g., `var list = std.ArrayListUnmanaged(T).empty;`). Note that this results in an unmanaged-style list where the `Allocator` must be provided to methods like `append(allocator, item)` and `deinit(allocator)`.

## Linting and Formatting
- **Linter:** Use `bun run lint` (via `zwanzig`) to maintain code quality and catch common pitfalls.

# Suggested Commands for ZyncBase

## Building
- **Debug Build:** `zig build`
- **Release Build:** `zig build -Doptimize=ReleaseFast`

## Testing
- **Run All Tests:** `zig build test`
- **Filter Tests:** `zig build test -Doptimize=Debug -Dtest-filter="test_name"`
- **E2E Tests:** `bun run test:e2e` (Run after every set of zig code changes to ensure that the server-client communication is not broken)
- **Thread Safety:** `bun run test:tsan` (Run after every set of zig code changes to ensure thread safety is still ensured)
- **Safe Mode:** `bun run test:safe` (Run after every set of zig code changes to ensure memory safety is still ensured)

## Maintenance & Setup
- **Build BoringSSL:** `./scripts/build-boringssl.sh` (Required before first build or after submodule update)
- **Apply Patches:** `./scripts/apply-patches.sh` (Applies patches to vendor dependencies)
- **Compress Specs:** `npm run specs:compress` (Syncs `specs/` to `specs_llm/`)

## Linting
- **Run Linter:** `bun run lint` (Run after every small zig code change, so the errors won't accumulate)

# Actions Upon Task Completion

Before submitting a task or notifying the user, ensure the following steps are performed to maintain codebase health:

1. **Run Linter:**
   - Run `bun run lint` to ensure no new linting issues were introduced. Fix or suppress as necessary.

2. **Run relevant tests:**
   - If core logic was changed, run `zig build test`.
   - If specific modules were touched, run the corresponding unit test (e.g., `zig build -Doptimize=Debug test-unit -Dtest-filter="module_name"`).
   - If protocol-level changes were made, run `npm run test:e2e`.

4. **Check for Sanitizer Regressions:**
   - Occasionally run `bun run test:safe` to ensure no new race conditions were introduced.

5. **Check for Client-Server Communication:**
   - Occasionally run `bun run test:e2e` to ensure the server-client communication is not broken.
