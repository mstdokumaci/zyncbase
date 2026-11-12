# Backup & Restore

**Drivers**: [Core Principles](../architecture/core-principles.md) (P-SHF self-hosting, P-SBD secure by default), [Storage](./storage.md)

This document defines the operator-facing backup, restore, and durability contract for a single-node ZyncBase deployment.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/backup.zig` | Snapshot creation (`VACUUM INTO`), integrity verification, restore and rollback, safety copy. |
| `src/cli.zig` | `backup`, `restore`, and `verify` commands; config/data-dir resolution. |
| `src/data_lock.zig` | Exclusive advisory lock on `<dataDir>/zyncbase.lock`. |
| `src/server.zig` | Acquires the data lock for the server's lifetime. |
| `src/config/state.zig`, `src/config/loader.zig` | `storage.synchronous` configuration. |
| `src/storage_engine/connection.zig` | Applies the `synchronous` pragma to the writer connection. |

---

## CLI Contract

| Command | Behavior |
|---------|----------|
| `zyncbase backup <out.db> [--config <path>] [--data-dir <dir>]` | Writes a consistent snapshot while the server is running. Refuses to overwrite an existing output. |
| `zyncbase restore <in.db> [--config <path>] [--data-dir <dir>] [--no-safety-copy]` | Replaces `<dataDir>/zyncbase.db` with the snapshot. Requires the data lock, so the server must be stopped. |
| `zyncbase verify <in.db>` | Runs `PRAGMA integrity_check` and the ZyncBase marker check. |

`--data-dir` allows a restore into a fresh directory for drills or disaster recovery without loading a full deployment config.

---

## Snapshot Semantics

- The snapshot runs in a read transaction on a separate SQLite connection. In WAL mode it sees a consistent committed state while writers continue.
- `VACUUM INTO` produces one compact database file and includes committed WAL frames.
- The snapshot is written to `<out>.partial`, verified with `PRAGMA quick_check`, fsynced, then renamed into place. A failed or interrupted backup never appears as a valid output.
- The source database is opened read-write without create, so SQLite can recover a hot WAL after a crash before snapshotting.
- The snapshot contains all namespaces, users, and store data. It does not contain `schema.json`, `authorization.json`, or secrets; those stay in version control.

---

## Restore Semantics

1. Acquire the exclusive data-directory lock. Fails with `DataDirLocked` if the server is running.
2. Run `PRAGMA integrity_check` and the ZyncBase marker check on the input.
3. Copy the input to `<db>.restore-tmp` and fsync it.
4. Move the current `zyncbase.db` and its `-wal`/`-shm` aside to `<db>.pre-restore-<timestamp>`.
5. Rename the temp file into place.
6. On failure, move the previous database and WAL/SHM back.
7. Keep the previous database unless `--no-safety-copy` is set.

The restore is offline by design. A single-node SQLite deployment cannot safely replace the database under a live writer.

---

## Data-Directory Lock

`<dataDir>/zyncbase.lock` is opened with a non-blocking exclusive advisory lock and held for the process lifetime. It:

- Prevents two servers from opening the same data directory.
- Lets `restore` distinguish a stopped server from a running one.
- Is released automatically by the OS when the process exits or is killed.

The lock is advisory: tools that bypass it (for example, a manual `sqlite3` shell) can still access the database.

---

## Durability Contract

`storage.synchronous` controls SQLite's commit fsync behavior:

| Mode | Process crash | Power loss / hard reset |
|------|---------------|-------------------------|
| `full` (default) | Committed writes survive. | Committed writes survive, assuming the OS and disk honor flush. |
| `normal` | Committed writes survive. | Recently committed transactions may roll back. |

`full` costs one fsync per write batch, not per operation when write batching is enabled. `normal` is an explicit throughput/durability trade-off.

The backup schedule determines a separate recovery point: a restore loses everything after the last snapshot, regardless of the synchronous mode.

---

## Operational Expectations

- **Snapshot RPO**: the backup interval (for example, 15 minutes with a cron or systemd timer).
- **Continuous RPO**: seconds when using Litestream as a sidecar against the same WAL database.
- **RTO**: server stop + restore + start, bounded by database size and disk throughput.
- **Retention and offsite copies** are owned by the operator's scheduler and storage tools, not the server.
- **Backups are not automatic**. The server does not write snapshots on its own.

See [OPERATIONS.md](../../OPERATIONS.md) for the runbook, cron/systemd examples, Litestream recipe, and restore drill.

---

## Non-Goals

- Built-in point-in-time recovery, WAL archiving, or incremental backup chains. Use Litestream.
- Built-in S3 clients, encryption, retention policies, or scheduling.
- Restore while the server is running, or cross-node consistency.
- Backing up configuration files or secrets.

---

## Related Specifications

- [Storage](./storage.md)
- [Config Grammar](./config-grammar.md)
- [Security](./security.md)
