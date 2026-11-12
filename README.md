# ZyncBase

High-performance, multi-threaded real-time database built with Zig.

## Features

- **Multi-threaded Core**: Lock-free cache and high-concurrency architecture.
- **MessagePack Serialization**: Compact binary protocol for low latency.
- **SQLite Integration**: Reliable persistence with WAL mode.
- **uWebSockets Backend**: Industry-leading WebSocket performance.

## Production

See [OPERATIONS.md](OPERATIONS.md) for backup, restore, durability, and upgrade guidance.

- `storage.synchronous` defaults to `full`; committed writes survive process crashes and power loss (assuming the disk honors flush).
- Backups are not automatic. Schedule `zyncbase backup` with cron or a systemd timer.
- `zyncbase restore` requires the server to be stopped and keeps a safety copy by default.

## Getting Started

See [BUILD.md](BUILD.md) for build instructions and prerequisites.

## License

ZyncBase is licensed under the **Business Source License 1.1**.

- **Source code is available** for everyone to view, modify, and use for non-production purposes.
- **Production use is permitted** as long as you are not offering ZyncBase as a managed cloud service.
- **Automatic Open Source**: On **January 1, 2032**, this project will automatically transition to the **Apache License 2.0**.
- **TypeScript SDK** (`sdk/typescript/`): **Apache License 2.0** — see [sdk/typescript/LICENSE](sdk/typescript/LICENSE).

For full terms, see the [LICENSE](LICENSE) file.
