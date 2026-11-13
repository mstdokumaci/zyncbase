# Operations: Backup, Restore & Durability

This guide is for a single-node ZyncBase deployment. The database is one SQLite file (`zyncbase.db`) plus its WAL, so a backup is a consistent snapshot of that file, and a restore is an offline file replacement.

Backups are **not automatic**. The server ships the commands; your scheduler decides when they run.

---

## Durability and recovery points

`storage.synchronous` in `zyncbase-config.json` controls the live database:

| Mode | Process crash | Power loss / hard reset |
|------|---------------|-------------------------|
| `full` (default) | Committed writes survive. | Committed writes survive, assuming the OS and disk honor flush. |
| `normal` | Committed writes survive. | Recently committed transactions may roll back. |

`full` fsyncs once per write batch (not per operation when batching is enabled). Use `normal` only when throughput matters more than the last few milliseconds of committed data.

Two different recovery points matter:

- **Live durability RPO**: `full` is zero for committed writes; `normal` can lose the last committed transactions on power loss.
- **Backup RPO**: everything after the last successful snapshot is lost on restore. A 15-minute schedule means up to 15 minutes of data loss; Litestream can reduce that to seconds.

---

## Commands

```bash
# Consistent snapshot while the server is running.
zyncbase backup /var/backups/zyncbase/zyncbase-$(date -u +%Y%m%dT%H%M%SZ).db \
  --config /etc/zyncbase/zyncbase-config.json

# Check a snapshot without touching the live database.
zyncbase verify /var/backups/zyncbase/zyncbase-20260101T000000Z.db

# Replace the database. The server must be stopped.
zyncbase restore /var/backups/zyncbase/zyncbase-20260101T000000Z.db \
  --config /etc/zyncbase/zyncbase-config.json

# Restore into a fresh directory for a drill or disaster recovery.
zyncbase restore /backups/latest.db --data-dir /tmp/zyncbase-drill
```

Useful flags:

- `--data-dir <dir>` resolves the database location without loading a full deployment config.
- `--no-safety-copy` skips keeping the previous database. The default is to keep it at
  `zyncbase.db.pre-restore-<timestamp>`.

`backup` refuses to overwrite an existing output and holds a shared data-directory lock, so a
restore cannot start mid-backup. `restore` requires the exclusive lock on
`<dataDir>/zyncbase.lock`, so it refuses to run while the server or a backup is active. A server
started while a backup is running also fails with `DataDirLocked`; retry after the backup finishes.

---

## Scheduling with cron

Create `/usr/local/bin/zyncbase-backup.sh`:

```sh
#!/bin/sh
set -eu
umask 077

BACKUP_DIR=/var/backups/zyncbase
CONFIG=/etc/zyncbase/zyncbase-config.json
mkdir -p "$BACKUP_DIR"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
zyncbase backup "$BACKUP_DIR/zyncbase-$stamp.db" --config "$CONFIG"

# Keep seven days locally. Adjust to your retention policy.
find "$BACKUP_DIR" -name 'zyncbase-*.db' -type f -mtime +7 -delete
```

```cron
*/15 * * * * /usr/local/bin/zyncbase-backup.sh >> /var/log/zyncbase-backup.log 2>&1
```

A non-zero exit means the backup failed. Alert on it.

---

## Scheduling with systemd

`/etc/systemd/system/zyncbase-backup.service`:

```ini
[Unit]
Description=ZyncBase snapshot backup
After=zyncbase.service

[Service]
Type=oneshot
User=zyncbase
Group=zyncbase
ExecStart=/usr/local/bin/zyncbase-backup.sh
```

`/etc/systemd/system/zyncbase-backup.timer`:

```ini
[Unit]
Description=Run ZyncBase backup every 15 minutes

[Timer]
OnCalendar=*:0/15
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now zyncbase-backup.timer
```

---

## Retention and offsite copies

Keep at least:

- Hourly or 15-minute snapshots for short-term recovery.
- Daily snapshots for a week or more.
- A monthly copy for compliance if required.
- At least one copy off the host (S3, restic, borg, rclone). A snapshot on the same disk does not survive disk failure or ransomware.

Example:

```bash
restic -r s3:s3.amazonaws.com/my-bucket backup /var/backups/zyncbase
```

Encrypt backups at rest and restrict access. A backup contains every namespace, every user, and every row; it bypasses `authorization.json` entirely.

---

## Continuous replication with Litestream

Litestream is a separate sidecar that continuously replicates the SQLite WAL and gives second-level RPO and point-in-time restore. ZyncBase uses standard SQLite WAL, so it works without code changes.

`/etc/litestream.yml`:

```yaml
dbs:
  - path: /var/lib/zyncbase/zyncbase.db
    replicas:
      - url: s3://my-bucket/zyncbase
```

Run it as a systemd service alongside the server, as the same user that owns the data directory:

```ini
[Service]
ExecStart=/usr/local/bin/litestream replicate -config /etc/litestream.yml
Restart=always
User=zyncbase
```

Restore while the server is stopped. Restore Litestream into a temporary directory first, then
install it through `zyncbase restore`. `set -e` ensures the server starts only if both commands
succeed; the trap removes the temporary directory on any exit.

```bash
systemctl stop zyncbase
set -e
tmpdir=$(mktemp -d /var/lib/zyncbase/zyncbase-litestream-XXXXXX)
tmp="$tmpdir/restore.db"
trap 'rm -rf "$tmpdir"' EXIT
litestream restore -o "$tmp" s3://my-bucket/zyncbase
zyncbase restore "$tmp" --config /etc/zyncbase/zyncbase-config.json
systemctl start zyncbase
```

Keep periodic `zyncbase backup` snapshots too. Litestream protects against host loss; snapshots protect against operator error and give you a simple file to inspect.

---

## Restore runbook

1. Stop the server (`systemctl stop zyncbase`).
2. Verify the snapshot:
   ```bash
   zyncbase verify /var/backups/zyncbase/zyncbase-<stamp>.db
   ```
3. Restore:
   ```bash
   zyncbase restore /var/backups/zyncbase/zyncbase-<stamp>.db \
     --config /etc/zyncbase/zyncbase-config.json
   ```
4. Start the server and check `/health` and `/stats`.
5. Verify application data (sign in, query a known record).
6. Keep `zyncbase.db.pre-restore-<timestamp>` until the restored instance is validated.

If the restore itself fails, the previous database is moved back automatically. If the restored data is wrong, stop the server and roll back manually:

```bash
rm -f /var/lib/zyncbase/zyncbase.db /var/lib/zyncbase/zyncbase.db-wal /var/lib/zyncbase/zyncbase.db-shm
mv /var/lib/zyncbase/zyncbase.db.pre-restore-<timestamp> /var/lib/zyncbase/zyncbase.db
mv /var/lib/zyncbase/zyncbase.db.pre-restore-<timestamp>-wal /var/lib/zyncbase/zyncbase.db-wal 2>/dev/null || true
mv /var/lib/zyncbase/zyncbase.db.pre-restore-<timestamp>-shm /var/lib/zyncbase/zyncbase.db-shm 2>/dev/null || true
systemctl start zyncbase
```

### Restore drill

Run this quarterly, and after any change to the backup setup:

```bash
zyncbase restore /var/backups/zyncbase/zyncbase-<stamp>.db --data-dir /tmp/zyncbase-drill
```

Start a server against `/tmp/zyncbase-drill` on a non-public port and verify a few records. A backup you have never restored is not a backup.

---

## Disk space

- `backup` rewrites the database, so it needs free space at the destination roughly equal to the database size. It also compacts the copy.
- `restore` copies the snapshot into the data directory, so it needs roughly the snapshot size there.
- Keep the safety copy until you have validated the restore.
- Monitor free space and `wal_size_bytes` from `/stats`.

## Monitoring

- Alert on a non-zero exit from the backup script or systemd unit.
- `/health` is the liveness probe; it returns `503` once the write engine has degraded (every mutation is rejected in that state, so restart the process). `/stats` exposes WAL size, checkpoint count, checkpoint failures, connections, and message counters.
- Watch `failed_checkpoint_count` and a growing WAL file.

## Upgrades

1. Take a snapshot before changing the binary or `schema.json`.
2. Additive schema changes (new table, new field, new index) migrate automatically at startup.
3. Destructive schema changes are refused in production. Plan a manual migration and test it against a restored copy first.
4. Keep the previous binary. If the new binary cannot start, restore the snapshot and roll the binary back.

## Security notes

- Backups contain all tenant data; treat them as production secrets.
- Use `umask 077`, disk encryption, and bucket-side encryption.
- Do not commit snapshots to source control.
- Backups bypass authorization rules; anyone with the file has the data.
