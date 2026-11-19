# Schema Migrations

**Drivers**: [ADR-024](../architecture/adrs.md#adr-024-developer-owned-schema-migrations), [ADR-021](../architecture/adrs.md#adr-021-namespace-scoped-user-unique-constraints), [ADR-005](../architecture/adrs.md#adr-005-sqlite-as-the-storage-engine), [Storage](./storage.md), [Schema Grammar](./schema-grammar.md), [Backup & Restore](./backup-restore.md)

This document defines how a database moves from its applied schema to the schema in `schema.json`:
- the schema snapshot stored in the database
- change classification
- the migration directory format
- the startup procedure
- the contract for developer-written migration SQL
- verification
- the CLI

ZyncBase owns the shape and the developer owns the data. Every DDL statement is generated. Developer SQL only moves data.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/schema/canonical.zig` | Whitespace-free schema JSON (key order preserved) and its SHA-256 hash. |
| `src/schema/version.zig` | Strict `X.Y.Z` parsing and ordering. |
| `src/schema/diff.zig` | Pure logical diff of two schemas and per-change classification. |
| `src/migration/state.zig` | `_zync_schema` and `_zync_migrations`: reading the applied snapshot, writing the snapshot and ledger rows. |
| `src/migration/catalog.zig` | SQLite introspection and comparison with the layout a schema implies; reserved managed-index names. |
| `src/migration/source.zig` | Loads and validates the migrations directory. |
| `src/migration/target.zig` | Loads the target schema from configuration; shared by the server and the CLI. |
| `src/migration/step.zig` | Executes one step: staging, fill, row guard, indexes, validation, catalog check, persistence. |
| `src/migration/sql_runner.zig` | Splits, pre-checks and runs `migration.sql` under the authorizer; records the set of written tables. |
| `src/migration/functions.zig` | `zync_*` helper SQL functions for migration connections. |
| `src/migration/validate.zig` | Row validation against the target schema. |
| `src/migration/diagnostics.zig` | Owned, line-oriented diagnostics for startup and CLI reporting. |
| `src/migration/startup.zig` | Public entry point used by the server, `migrate apply`, and test helpers. Builds the run (history checks, bridge, migration and final steps, version rules) and executes it. |
| `src/migration/scaffold.zig` | Generates `migration.sql` scaffolds from a diff. |
| `src/migration/cli.zig` | `migrate status`, `new`, `check` and `apply`. |
| `src/backup.zig` | `snapshotHeld` pre-migration snapshot and `reset`. |
| `src/sql/ddl.zig` | STRICT table DDL, managed index DDL, `ADD COLUMN` DDL. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `Target` | `Schema`, minified JSON | The schema to reach, plus the text stored as its snapshot. |
| `SchemaDiff` / `Change` | two `Schema` values | Table and field changes, each with a bucket and a physical action. |
| `Bucket` | — | `auto`, `checked`, `migration_required`. |
| `Migration` | `Schema` (before/after), SQL bytes | One loaded migration folder, with hashes. |
| `Run` / `Step` | `SchemaDiff`, optional `Migration` | Ordered transitions executed in one transaction. |
| `Report` | — | Per-step tables, rows before/after/dropped, and durations. |
| `Diagnostics` | allocator | Human-readable lines attached to a returned error. |

---

## Applied Schema Snapshot

System tables. All are STRICT, and all use the reserved `_zync_` prefix:

| Table | Columns | Notes |
|---|---|---|
| `_zync_namespaces` | `id INTEGER PRIMARY KEY`, `name TEXT NOT NULL UNIQUE` | Created by `StorageEngine.init`. |
| `_zync_schema` | `id` (always 1), `layout`, `version`, `hash`, `schema`, `applied_at` (µs) | One row. `schema` is the minified schema JSON. `layout` is the physical layout generation (1). |
| `_zync_migrations` | `id`, `mode` (`applied`/`baseline`), `before_version`, `after_version`, `after_hash`, `sql_hash`, `applied_at` | One row per migration folder known to this database. |

Schema identity:
- `minify(json)` parses the JSON and writes it back compactly. Object key order and array order are preserved, because table, field and action order define wire indexes (ADR-009).
- `hash` is `"sha256:" ++ hex(sha256(minify(json)))`.
- Whitespace never changes the hash. An edit that only spells out a default value changes the hash but produces a run that only rewrites the snapshot.
- Every stored snapshot must stay parseable by later binaries. A grammar change that breaks this must ship a snapshot upgrade together with a `layout` bump. Unknown `layout` values are refused.

---

## Change Classification

`schema/diff.zig` matches tables by name and fields by flattened name, so a rename is a removal plus an addition. The result depends only on the two schemas.

| Change | Bucket | Physical action |
|---|---|---|
| Add table | auto | create |
| Remove table | migration-required | rename to prev |
| `namespaced` changed | migration-required | rebuild |
| Unique constraint added or changed | checked | reconcile indexes |
| Unique constraint removed or reordered | auto | reconcile indexes |
| Table metadata or table order changed | auto | none |
| Add optional field (including `references`) | auto | `ADD COLUMN` |
| Add required field | checked | rebuild; fails if the table has rows |
| Remove field | migration-required | rebuild |
| Declared or storage type changed, including adding or removing `references` | migration-required | rebuild |
| Array `items` changed | migration-required | rebuild |
| required → optional | auto | rebuild |
| optional → required | checked | rebuild; fails on NULLs |
| `references` target changed | checked | rebuild; fails on FK violations |
| `onDelete` changed | auto | rebuild |
| `indexed` changed | auto | reconcile indexes |
| Constraint added or tightened | checked | validate column |
| Constraint removed or loosened | auto | none |
| Field metadata or field order changed | auto | none |
| Presence, actions, root metadata, or version changed | auto | snapshot only |

A constraint counts as tightened when:
- the new enum set is not a superset of the old one
- a pattern or format is added or changed
- `minLength` or `minimum` is added or raised
- `maxLength` or `maximum` is added or lowered

A checked change applies automatically when the data complies. Otherwise startup fails with counts and sample ids. The fix is a migration, which may be data-only.

## Version Rules

- `version` is strict `X.Y.Z`. The schema parser rejects anything else with `error.InvalidVersion`.
- Versions never decrease along a run: applied ≤ each migration's `before` ≤ its `after` ≤ target. A decrease returns `error.SchemaVersionDowngrade`.
- If any step contains a migration-required change, the target's major version must exceed the applied major version. Otherwise the run returns `error.MajorVersionBumpRequired`. This rule is evaluated per deployment, not per migration file.
- Auto and checked changes carry no version requirement.

---

## Migration Directory

`migrations.dir` defaults to `<directory of the schema file>/migrations`, or `./migrations` for inline schemas.

```
migrations/
  20261117T140500Z_priority_to_string/
    before.json     generated; do not edit
    after.json      generated; do not edit
    migration.sql   developer-owned
```

| Rule | Detail |
|---|---|
| Folder name | `^\d{8}T\d{6}Z_[a-z0-9_]{1,64}$` (UTC). Folders are applied in lexicographic order. |
| Other entries | Top-level regular files and dot-entries are ignored. Any other directory is `error.InvalidMigration`. |
| Folder contents | Exactly the three files. Dotfiles are ignored. Anything else is `error.InvalidMigration`. |
| JSON files | Pretty-printed schema JSON (tab indentation). Hashes use `minify(file)`, so reformatting is harmless. |

---

## Startup Procedure

`migration.startup.run` runs during the setup window:
- `server.zig` holds the exclusive `DataLock`.
- `StorageEngine` is in `.setup`.
- No worker thread exists yet.

1. Load and validate the migrations directory.
2. Read the database state:
   - **Fresh database:** there is no `_zync_schema` and no tables other than `_zync_*` and `sqlite_*`. The run is one auto step from the empty schema to the target, and every migration found is recorded as `baseline`.
   - **Unrecognized database:** there is no `_zync_schema`, but other tables exist. The run returns `error.UnrecognizedDatabase`.
   - **Otherwise:**
     - Parse the applied snapshot and check `layout`.
     - Compare the catalog with the applied layout. Column, foreign-key or STRICT drift returns `error.SchemaDriftDetected`. Managed-index drift is repaired in the first step.
3. History:
   - An applied (not baseline) migration whose folder still exists must match `after_hash` and `sql_hash`. Otherwise the run returns `error.AppliedMigrationModified`.
   - A pending folder that sorts before the newest ledger entry returns `error.MigrationOutOfOrder`.
   - Deleting applied folders is allowed.
4. Plan. Start from the applied schema. For each pending migration:
   - If the current hash differs from the migration's `before`, add an auto bridge step. The bridge must not contain migration-required changes; if it does, the run returns `error.MigrationBaseMismatch`.
   - Add the migration step.

   Then:
   - Add a final auto step if the result differs from the target. A migration-required change in it returns `error.MigrationRequired`.
   - Apply the version rules.
   - With no steps and no index drift, the run writes nothing.
5. If a migration step is pending, `migrations.snapshot` is true, and the database is on disk, write the pre-migration snapshot.
6. Set `PRAGMA foreign_keys = OFF` and `PRAGMA legacy_alter_table = ON`, then run every step inside one `BEGIN IMMEDIATE` transaction.
7. Run `PRAGMA foreign_key_check`, then `COMMIT`.
8. Restore both pragmas on every path.
9. After a run that rebuilt tables, run `PRAGMA wal_checkpoint(TRUNCATE)`.
10. Log one line per step. `StorageEngine.start()` then continues as described in [Storage](./storage.md).

Any failure rolls back the whole run. The database is left exactly as it was, so the previous release can still start against it.

## Step Execution

| Table state | Staging | Fill | After the fill |
|---|---|---|---|
| created | `CREATE TABLE … STRICT` without indexes | none (developer may insert) | managed indexes |
| rebuilt | drop its managed indexes; `ALTER TABLE t RENAME TO _zync_prev_t`; create `t` without indexes | generated `INSERT … SELECT` or developer SQL | row guard; drop prev; managed indexes |
| removed | drop its managed indexes; rename to prev | developer moves or deletes rows | row guard (prev must be empty); drop prev |
| altered | `ALTER TABLE t ADD COLUMN …` (type, `CHECK`, `REFERENCES`) | developer may update | reconcile managed indexes |
| unchanged | none | developer may update | none |

Each step then runs row validation and a catalog check against its target layout, and writes `_zync_schema`. A migration step also inserts its ledger row.

- Renaming requires `legacy_alter_table = ON`. Without it, SQLite rewrites child foreign keys to reference `_zync_prev_t`.
- The primary-key autoindex follows a rename. Managed indexes keep their names and are dropped before the target creates its own.
- A generated fill copies:
  - the system columns (`id`, `namespace_id`, `owner_id`, `external_id` on `users`, `created_at`, `updated_at`)
  - every user field present on both sides
- Before an auto step fills a table:
  - A required field added to a populated table returns `error.RequiredFieldNeedsValues`.
  - Existing NULLs for a newly required field return `error.DataValidationFailed`.
- Unique index failures report up to five duplicate groups.
- If a target name already exists as an unmanaged table, the run returns `error.UnmanagedTableConflict`.

---

## Developer SQL Contract

### State When `migration.sql` Starts

- Created and rebuilt tables are empty, in the `after` shape, without indexes.
- `_zync_prev_<table>` holds the rows of rebuilt and removed tables, typed as in `before`.
- Altered tables already have their new columns. The new columns are NULL.
- Foreign keys are off. Cascades and `SET NULL` do not run. Integrity is checked once at the end.

### Rules

- Inserted rows supply every system column. `created_at` must stay unique per table.
- **Row guard:** after the file runs, every row left in a prev table must exist, matched by `id`, in the same-named target table. A removed table's prev table must be empty. Rows are dropped on purpose by deleting them from the prev table.
- Deleting rows from a target table is always explicit and is not guarded.
- No DDL. Use common table expressions for lookup data.

### Authorizer

The authorizer is installed with `sqlite3_set_authorizer` and evaluated when each statement is prepared.

| Action | Policy |
|---|---|
| `SELECT`, `READ`, `RECURSIVE` | Allowed. |
| `FUNCTION` | Allowed, except `zync_todo` (reported as an unresolved decision) and `load_extension`. |
| `INSERT`, `UPDATE`, `DELETE` | Allowed on the step's target managed tables and its prev tables. `INSERT` is also allowed on `_zync_namespaces`. |
| Anything else | Denied. This covers DDL, `PRAGMA`, transactions, savepoints, `ATTACH`/`DETACH`, `ANALYZE`, `REINDEX`, virtual tables, and unknown codes. |

The tables written by the file are recorded and become validated tables.

### Helper Functions

Helpers are registered only on the migration connection for the duration of the run, with `SQLITE_DIRECTONLY`. They and the authorizer are removed on every exit path.

| Function | Returns | Behavior |
|---|---|---|
| `zync_todo(message)` | — | Marks a decision. Any use is rejected before the file runs. |
| `zync_new_id()` | `BLOB(16)` | A new UUIDv7 id. |
| `zync_now()` | `INTEGER` | Microseconds. Strictly increasing per call, and above both the wall clock and every existing `created_at`. |
| `zync_array(json, items)` | `TEXT` | Canonical array JSON from the runtime codec: validated against `items` (`string`, `integer`, `number`, `boolean`), sorted, de-duplicated. Store it with `jsonb(zync_array(…))`. |

There is no helper that converts SDK document-id strings to stored ids. The packed id layout stays private to the server and the SDK. A string field that holds ids becomes a reference by expand/contract: add a new optional reference field, backfill it through the SDK, then remove the old field in a later migration. The scaffold's suggestion for a string → reference type change says exactly this.

### Execution

- Statements are split with `sqlite3_prepare_v2` and its tail pointer.
- A pre-pass prepares every statement without running it. It reports every `zync_todo` and authorizer violation, then stops at the first syntax or name-resolution error.
- Statements then run in order. Rows returned by a statement are discarded.
- Errors name the migration folder, `migration.sql`, the line of the statement's first token, and SQLite's message.

---

## Verification

Validated tables are:
- created tables
- rebuilt tables
- tables written by `migration.sql`
- in auto steps, the columns with tightened constraints

| Check | Scope | Mechanism |
|---|---|---|
| Storage type, `NOT NULL`, 16-byte id length | Every write | STRICT tables and DDL `CHECK`s. |
| Row carry-over | Prev tables | `NOT EXISTS` against the target primary key; count plus up to five ids. |
| Unique constraints, `created_at`, users identity | Created and rebuilt tables, and tables with index changes | Managed index creation. |
| Foreign keys | Whole database | `PRAGMA foreign_key_check`. |
| Booleans are 0 or 1 | Validated tables | SQL predicate. |
| Arrays canonical, item types correct | Validated tables | Decode `json(col)` and compare with the runtime encoding. |
| `enum`, `pattern`, `format`, lengths, ranges | Validated tables | `schema/constraints.zig` scalar validation. |
| Catalog matches layout | Every managed table, before and after | `PRAGMA table_list` (strict), `table_info`, `foreign_key_list`, `index_list`, `index_info`. |

These are not verified:
- `CHECK` expression text
- physical column order
- whether a developer conversion is semantically correct
- precision lost when developer SQL converts integers to `REAL`

---

## Snapshot and Rollback

- `backup.snapshotHeld` writes `VACUUM INTO` on the setup connection to `<database file>.pre-migration-<first-pending-id>-<utc-timestamp>` (for the server, `<dataDir>/zyncbase.db.pre-migration-…`). A name taken within the same second gets a `-<n>` suffix. It then verifies the copy, fsyncs it, and publishes it with a non-replacing rename. The caller already holds the exclusive data lock.
- The snapshot runs only when a developer migration is pending. A failed snapshot aborts startup before any change (`error.SnapshotFailed`).
- Snapshots are never deleted automatically.
- Rollback: stop the server, `zyncbase restore <snapshot>`, and roll back the binary, `schema.json` and the migrations directory together.

---

## Diagnostics

Every startup error carries diagnostic lines. The server logs them one record per line. These are startup errors, not wire errors, so [Error Taxonomy](./error-taxonomy.md) is unchanged.

| Error | Meaning |
|---|---|
| `UnrecognizedDatabase` | Tables exist without a ZyncBase schema record. |
| `UnsupportedLayout` | The stored `layout` is unknown to this binary. |
| `SchemaDriftDetected` | The catalog differs from the applied snapshot in columns, foreign keys or STRICT mode. |
| `SchemaVersionDowngrade` | A version decreases along the run. |
| `MajorVersionBumpRequired` | The run contains a migration-required change without a major version bump. |
| `MigrationRequired` | The final step contains a migration-required change. |
| `MigrationBaseMismatch` | The bridge to a migration's `before` would need a migration. |
| `MigrationOutOfOrder` | A pending migration sorts before an applied one. |
| `AppliedMigrationModified` | An applied migration's files changed. |
| `InvalidMigration` | Malformed folder name, contents, or JSON. |
| `MigrationSqlRejected` | The pre-pass found `zync_todo`, authorizer violations, or a syntax error. |
| `MigrationSqlFailed` | A statement failed while running. |
| `RowsNotCarriedOver` | The row guard failed. |
| `RequiredFieldNeedsValues` | An auto step adds a required field to a populated table. |
| `DataValidationFailed` | Row validation failed. |
| `UnmanagedTableConflict` | A target table name is taken by an unmanaged table. |
| `SnapshotFailed` | The pre-migration snapshot could not be written. |

---

## CLI Contract

| Command | Behavior | Lock |
|---|---|---|
| `zyncbase migrate status [--config <path>] [--data-dir <dir>] [--db <file>]` | Shows the applied and target schemas, the ledger, pending migrations, planned steps, the bucket of each change, and blockers. Exits 0 when planning succeeds; it does not execute steps or validate rows (use `migrate apply --dry-run` for that). | shared |
| `zyncbase migrate new <name> [--from <file.db\|schema.json>] [--amend] [--config <path>] [--data-dir <dir>]` | Writes a migration folder with a scaffold. | shared (exclusive with `--amend`) |
| `zyncbase migrate check [--config <path>]` | Validates every migration without a database: folders, versions, the chain to `schema.json`, and a pre-pass against an in-memory database built at each `before`. | none |
| `zyncbase migrate apply [--dry-run] [--config <path>] [--data-dir <dir>] [--db <file>]` | Runs the startup procedure without serving. `--dry-run` rolls back, skips the snapshot, and prints the report. | exclusive |
| `zyncbase reset --yes [--config <path>] [--data-dir <dir>] [--no-safety-copy]` | Moves `zyncbase.db` and its sidecars to `zyncbase.db.pre-reset-<timestamp>` and retains them by default. `--no-safety-copy` deletes them instead. The next start creates a fresh database. | exclusive |

All commands read the configuration from `--config` (default `zyncbase-config.json`). `--data-dir` overrides `dataDir`. `--db` names a database file directly; locks are then taken in that file's directory, and `apply` writes the snapshot next to it. Reports go to stdout. A failing command, or a `status`/`check` that finds a blocker, exits non-zero.

`migrate status` opens the database read-only. A missing database is planned as a fresh one.

`migrate apply` recovers an interrupted restore first (data directory only), then configures the connection like `StorageEngine.init`. `--db` requires the file to exist. Step details are logged.

`migrate check` runs, for each migration, `startup.run` on an empty in-memory database built at its `before`, then the migration with `dry_run`. These per-migration runs skip the major-version rule and the foreign-key check, because both apply to a deployment, not a file. If they all pass, it runs the whole chain from the first migration's `before` to `schema.json`, with every rule.

`migrate new` picks its base like this:
- If the newest migration is not applied to the data directory's database (or there is no database), the base is that migration's `after.json`.
- Otherwise the base is the database's applied snapshot.
- `--from` overrides both: a `.json` file is the base schema; any other path is a database whose applied snapshot is the base. The chain must reach that base automatically: a version decrease or a migration-required bridge is refused.
- With no database, no migrations, and no `--from`, it refuses: the next start creates the database from `schema.json` directly.

It refuses to write anything when:
- the base is a pending migration that already produces `schema.json` (edit that migration instead)
- `schema.json`'s version is lower than the base's
- the deployment version rule would fail against the base database. The pending migrations before the new one count as part of the deployment. Without a database the rule is left to startup.
- the base database's storage layout is unknown to this build
- the new id (`<utc now>_<name>`) would not sort after the newest migration folder or ledger entry

The folder is written under a dot-prefixed temporary name, which the loader ignores, and then renamed into place. Both JSON files are pretty-printed. The report lists the changes and the number of `zync_todo` decisions.

`--amend` reworks the newest migration:
- If it is pending, its folder is rewritten in place.
- If it is the latest ledger entry (mode `applied`), a snapshot amend can restore must exist: either the pre-`<id>` snapshot `<database file>.pre-migration-<id>-*`, or the snapshot for the first migration of the batch that applied it. In the batch case the snapshot's ledger must be an exact prefix of the current chain and that first migration must replay from the snapshot; earlier migrations then replay before the amended one. The version rule is checked against that snapshot. The snapshot is restored with `backup.restore`, keeping a safety copy.
- Otherwise it refuses.

The migration keeps its timestamp and takes `<name>`. `after.json` and the scaffold are regenerated from `before.json` to `schema.json`, and the previous `migration.sql` is appended as a comment block. It refuses when the migration already produces `schema.json`. `--amend` cannot be combined with `--from`.

The replaced folder is moved to a dot-prefixed backup before the new folder is renamed into place, and moved back if the swap fails. An interrupted amend leaves that backup next to the migrations; the next `--amend` refuses and names it so the folder can be restored.

`reset` without `--yes` explains what it would do and exits non-zero.

---

## Invariants

- All DDL for managed tables is generated by `sql/ddl.zig` and executed by a migration step.
- One run is one transaction. A failed run leaves the database unchanged.
- A run with no changes writes nothing.
- Helper functions and the authorizer never remain installed on the runtime writer connection.
- Every managed table is STRICT.

---

## Related Specifications

- [Storage](./storage.md)
- [Schema Grammar](./schema-grammar.md)
- [Config Grammar](./config-grammar.md)
- [Backup & Restore](./backup-restore.md)
- [Configuration Guide](../api-design/configuration.md#schema-migrations)
