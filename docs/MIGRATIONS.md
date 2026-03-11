# Schema Migrations Guide

**Last Updated**: 2026-03-09

Complete guide to managing schema changes and data migrations in ZyncBase.

---

## Table of Contents

1. [Overview](#overview)
2. [When Migrations Are Needed](#when-migrations-are-needed)
3. [Development Workflow](#development-workflow)
4. [Production Workflow](#production-workflow)
5. [Migration Commands](#migration-commands)
6. [Writing Migrations](#writing-migrations)
7. [Complex Migrations](#complex-migrations)
8. [Rollback Strategies](#rollback-strategies)
9. [Best Practices](#best-practices)
10. [Troubleshooting](#troubleshooting)

---

## Overview

ZyncBase automatically generates SQLite tables from your `schema.json` and intelligently handles schema changes based on your environment.

### Key Concepts

**Auto-Migration**: Additive changes (new fields, new tables) auto-migrate with zero friction.

**Manual Migration**: Breaking changes (type changes, field removal) require explicit migrations in production.

**Environment-Aware**: Development allows destructive changes for fast iteration. Production requires safety.

---

## When Migrations Are Needed

### Auto-Migrates (No Migration Needed)

These changes work automatically in all environments:

✅ **Add new field**
```json
// Before
{
  "store": {
    "tasks": {
      "fields": {
        "title": { "type": "string" }
      }
    }
  }
}

// After
{
  "store": {
    "tasks": {
      "fields": {
        "title": { "type": "string" },
        "assignee": { "type": "string" }  // ← Auto-migrates
      }
    }
  }
}
```

✅ **Add new table (path)**
```json
{
  "tasks": { ... },
  "users": { ... }  // ← Auto-migrates
}
```

✅ **Add index**
```json
{
  "store": {
    "tasks": {
      "fields": {
        "status": { 
          "type": "string",
          "index": true  // ← Auto-migrates
        }
      }
    }
  }
}
```

✅ **Make field optional**
```json
// Before
{
  "title": { "type": "string" }
}

// After (removing from required)
{
  "title": { "type": "string" }  // ← Auto-migrates
}
```

### Requires Migration (Production)

These changes require explicit migrations in production:

❌ **Change field type**
```json
// Before
{
  "priority": { "type": "integer" }
}

// After
{
  "priority": { "type": "string" }  // ← Requires migration
}
```

❌ **Remove field**
```json
// Before
{
  "title": { "type": "string" },
  "description": { "type": "string" }
}

// After
{
  "title": { "type": "string" }
  // description removed ← Requires migration
}
```

❌ **Rename field**
```json
// Before
{
  "createdAt": { "type": "string" }
}

// After
{
  "created_at": { "type": "string" }  // ← Requires migration
}
```

❌ **Make field required**
```json
// Before
{
  "email": { "type": "string" }
}

// After
{
  "email": { "type": "string" },
  "required": ["email"]  // ← Requires migration
}
```

---

## Development Workflow

### Fast Iteration Mode

In development, ZyncBase allows destructive changes for rapid iteration.

**Configuration:**
```json
// zyncbase-config.json
{
  "environment": "development",
  "schema": {
    "file": "./schema.json",
    "autoMigrate": true,
    "allowDestructive": true
  }
}
```

### Example: Changing Field Type

```bash
# 1. Edit schema
$ vim schema.json
# Change: priority: integer → string

# 2. Start server
$ zyncbase-server start --dev

⚠ Destructive schema change detected
⚠ Field 'tasks.priority' type changed: integer → string
⚠ This will DROP and recreate the table (data loss!)

Continue? [y/N]: y

✓ Dropping table 'tasks'
✓ Creating table 'tasks' with new schema
✓ Server started

⚠ All data in 'tasks' was lost

# 3. Rebuild test data
$ node scripts/seed-dev-data.js
✓ Test data created
```

### Skip Confirmation

For automated workflows:

```bash
$ zyncbase-server start --dev --force-schema
✓ Table recreated (no confirmation)
```

### Development Best Practices

1. **Use seed scripts** - Rebuild test data quickly
2. **Commit schema changes** - Track in git
3. **Test migrations locally** - Before production
4. **Use separate dev database** - Don't test on production data

---

## Production Workflow

### Safety First

In production, ZyncBase blocks destructive changes and requires explicit migrations.

**Configuration:**
```json
// zyncbase-config.json
{
  "environment": "production",
  "schema": {
    "file": "./schema.json",
    "autoMigrate": "additive-only",
    "allowDestructive": false
  }
}
```

### Example: Changing Field Type

```bash
# 1. Edit schema and bump version
$ vim schema.json
```

```json
{
  "version": "2.0.0",  // ← Bump major version
  "store": {
    "tasks": {
      "fields": {
        "priority": { "type": "string" }  // ← Changed from integer
      }
    }
  }
}
```

```bash
# 2. Create migration
$ zyncbase migrate create v2_change_priority_type

Created: migrations/003_v2_change_priority_type.sql

# 3. Write migration
$ vim migrations/003_v2_change_priority_type.sql
```

```sql
-- migrations/003_v2_change_priority_type.sql
BEGIN TRANSACTION;

-- Add new column
ALTER TABLE tasks ADD COLUMN priority_new TEXT;

-- Copy and transform data
UPDATE tasks SET priority_new = CAST(priority AS TEXT);

-- Recreate table (SQLite doesn't support DROP COLUMN)
CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    namespace_id TEXT,
    title TEXT,
    status TEXT,
    priority TEXT,  -- New type
    created_at INTEGER,
    updated_at INTEGER
);

-- Copy data
INSERT INTO tasks_new 
SELECT id, namespace_id, title, status, priority_new, created_at, updated_at
FROM tasks;

-- Swap tables
DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;

-- Recreate indexes
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);

COMMIT;
```

```bash
# 4. Test migration (dry run)
$ zyncbase migrate up --dry-run

Would apply:
  003_v2_change_priority_type.sql

# 5. Apply migration
$ zyncbase migrate up

✓ Applied: 003_v2_change_priority_type.sql
✓ Schema version: 1.3.0 → 2.0.0

# 6. Deploy
$ zyncbase-server start
✓ Migrations applied
✓ Server started
```

---

## Migration Commands

### Check Status

```bash
$ zyncbase migrate status

Current schema version: 1.3.0
Database version: 1.3.0

Pending migrations: 0
Applied migrations: 2
  001_initial_schema.sql
  002_add_assignee_field.sql
```

### Create Migration

```bash
$ zyncbase migrate create <name>

# Examples
$ zyncbase migrate create add_assignee_field
$ zyncbase migrate create v2_change_priority_type
$ zyncbase migrate create remove_deprecated_fields
```

Creates: `migrations/<timestamp>_<name>.sql`

### Apply Migrations

```bash
# Apply all pending migrations
$ zyncbase migrate up

# Apply specific number of migrations
$ zyncbase migrate up --steps 1

# Dry run (see what would happen)
$ zyncbase migrate up --dry-run
```

### Rollback Migrations

```bash
# Rollback last migration
$ zyncbase migrate down

# Rollback specific number of migrations
$ zyncbase migrate down --steps 2

# Dry run
$ zyncbase migrate down --dry-run
```

### Reset Database

```bash
# Drop all tables and reapply migrations
$ zyncbase migrate reset

⚠ This will delete all data!
Continue? [y/N]: y

✓ Database reset
✓ Migrations reapplied
```

---

## Writing Migrations

### Migration File Format and Naming Conventions

ZyncBase uses a structured naming convention for migration files to ensure proper ordering and clarity.

#### File Naming Convention

```
migrations/<timestamp>_<descriptive_name>.sql
```

**Components:**
- **Timestamp**: Sequential number (001, 002, 003...) or Unix timestamp
- **Descriptive Name**: Snake_case description of the change
- **Extension**: Always `.sql`

**Examples:**
```
migrations/001_initial_schema.sql
migrations/002_add_assignee_field.sql
migrations/003_v2_change_priority_type.sql
migrations/004_add_users_table.sql
migrations/005_create_indexes.sql
```

#### Creating Migration Files

```bash
# Automatic naming with timestamp
$ zyncbase migrate create add_assignee_field
Created: migrations/20260309143022_add_assignee_field.sql

# Or use sequential numbering
$ zyncbase migrate create add_users_table
Created: migrations/003_add_users_table.sql
```

#### Migration File Structure

```sql
-- migrations/003_add_assignee_field.sql
--
-- Description: Add assignee field to tasks table for user assignment
-- Author: developer@example.com
-- Date: 2026-03-09
-- Breaking: No
-- Rollback: Supported (see DOWN section)
--

-- UP: Apply migration
BEGIN TRANSACTION;

ALTER TABLE tasks ADD COLUMN assignee TEXT;
CREATE INDEX idx_tasks_assignee ON tasks(assignee);

COMMIT;

-- DOWN: Rollback migration
-- Note: SQLite doesn't support DROP COLUMN directly
-- To rollback, would need to recreate table without assignee column
-- See: https://www.sqlite.org/lang_altertable.html
```

#### Migration Metadata

Include these metadata comments in each migration:

- **Description**: What the migration does
- **Author**: Who created the migration
- **Date**: When it was created
- **Breaking**: Whether it's a breaking change (Yes/No)
- **Rollback**: Whether rollback is supported
- **Dependencies**: Any required migrations or external scripts

### Simple Migrations

**Add column:**
```sql
BEGIN TRANSACTION;
ALTER TABLE tasks ADD COLUMN assignee TEXT;
COMMIT;
```

**Add index:**
```sql
BEGIN TRANSACTION;
CREATE INDEX idx_tasks_status ON tasks(status);
COMMIT;
```

**Add table:**
```sql
BEGIN TRANSACTION;

CREATE TABLE users (
    id TEXT PRIMARY KEY,
    namespace_id TEXT,
    name TEXT,
    email TEXT,
    created_at INTEGER,
    updated_at INTEGER
);

CREATE INDEX idx_users_namespace ON users(namespace_id);
CREATE INDEX idx_users_email ON users(email);

COMMIT;
```

### Complex Migrations

**Change column type:**
```sql
BEGIN TRANSACTION;

-- Create new table with correct schema
CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    namespace_id TEXT,
    title TEXT,
    status TEXT,
    priority TEXT,  -- Changed from INTEGER
    created_at INTEGER,
    updated_at INTEGER
);

-- Copy and transform data
INSERT INTO tasks_new 
SELECT 
    id, 
    namespace_id, 
    title, 
    status, 
    CAST(priority AS TEXT),  -- Transform
    created_at, 
    updated_at
FROM tasks;

-- Swap tables
DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;

-- Recreate indexes
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);

COMMIT;
```

**Rename column:**
```sql
BEGIN TRANSACTION;

-- SQLite doesn't support RENAME COLUMN directly
-- Need to recreate table

CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    namespace_id TEXT,
    title TEXT,
    status TEXT,
    created_at INTEGER,  -- Renamed from createdAt
    updated_at INTEGER
);

INSERT INTO tasks_new 
SELECT id, namespace_id, title, status, createdAt, updatedAt
FROM tasks;

DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;

COMMIT;
```

---

## Complex Migrations

For complex data transformations, use ZyncBase Admin API with external scripts.

### Admin API

ZyncBase provides HTTP endpoints for data export/import:

```bash
# Enable admin API
```

```json
// zyncbase-config.json
{
  "admin": {
    "enabled": true,
    "token": "${ADMIN_TOKEN}",
    "allowedIPs": ["127.0.0.1"]
  }
}
```

### Admin API Endpoints

```
POST /admin/export/:path
POST /admin/import/:path
POST /admin/query
POST /admin/execute
```

### Example: Complex Transformation

**Scenario**: Transform priority from integer (1-5) to string (low/medium/high)

**Step 1: SQL Migration (schema change)**
```sql
-- migrations/004_priority_to_string.sql
BEGIN TRANSACTION;

-- Add new column
ALTER TABLE tasks ADD COLUMN priority_new TEXT;

-- Note: Data transformation done externally
-- See: scripts/migrate_priority.ts

CREATE TABLE tasks_backup AS SELECT * FROM tasks;

COMMIT;
```

**Step 2: External Script (data transformation)**
```typescript
// scripts/migrate_priority.ts
import { ZyncBaseAdmin } from '@zyncbase/admin'

const admin = new ZyncBaseAdmin('http://localhost:3000', {
  token: process.env.ADMIN_TOKEN
})

async function migratePriority() {
  // Export data
  const tasks = await admin.query('SELECT * FROM tasks_backup')
  
  console.log(`Migrating ${tasks.length} tasks...`)
  
  // Transform
  for (const task of tasks) {
    let priorityStr: string
    
    if (task.priority <= 2) {
      priorityStr = 'low'
    } else if (task.priority <= 4) {
      priorityStr = 'medium'
    } else {
      priorityStr = 'high'
    }
    
    // Update
    await admin.execute(
      'UPDATE tasks SET priority_new = ? WHERE id = ?',
      [priorityStr, task.id]
    )
  }
  
  console.log('✓ Migration complete')
}

migratePriority().catch(console.error)
```

**Step 3: SQL Migration (finalize)**
```sql
-- migrations/005_priority_finalize.sql
BEGIN TRANSACTION;

-- Recreate table with new schema
CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    namespace_id TEXT,
    title TEXT,
    status TEXT,
    priority TEXT,  -- New type
    created_at INTEGER,
    updated_at INTEGER
);

-- Copy transformed data
INSERT INTO tasks_new 
SELECT id, namespace_id, title, status, priority_new, created_at, updated_at
FROM tasks;

-- Swap tables
DROP TABLE tasks;
DROP TABLE tasks_backup;
ALTER TABLE tasks_new RENAME TO tasks;

-- Recreate indexes
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);

COMMIT;
```

**Step 4: Run Migration**
```bash
# Apply first migration (schema change)
$ zyncbase migrate up

# Run transformation script
$ node scripts/migrate_priority.ts
✓ Migrating 1523 tasks...
✓ Migration complete

# Apply final migration (cleanup)
$ zyncbase migrate up

# Verify
$ zyncbase migrate status
✓ All migrations applied
```

---

## Rollback Strategies

### Automatic Rollback

ZyncBase tracks applied migrations and can rollback:

```bash
# Rollback last migration
$ zyncbase migrate down

Rolling back: 003_v2_change_priority_type.sql
✓ Rolled back

# Rollback multiple migrations
$ zyncbase migrate down --steps 2
```

### Manual Rollback

For complex migrations, write explicit rollback logic:

```sql
-- migrations/003_v2_change_priority_type.sql

-- UP
BEGIN TRANSACTION;
-- ... migration logic ...
COMMIT;

-- DOWN
BEGIN TRANSACTION;
-- Reverse the changes
CREATE TABLE tasks_old AS SELECT * FROM tasks;
-- ... restore old schema ...
COMMIT;
```

### Backup Before Migration

**Always backup before production migrations:**

```bash
# Backup database
$ sqlite3 data/zyncbase.db ".backup data/zyncbase-backup-$(date +%Y%m%d).db"

# Apply migration
$ zyncbase migrate up

# If something goes wrong, restore
$ cp data/zyncbase-backup-20260309.db data/zyncbase.db
```

### Point-in-Time Recovery

For production, use continuous backup:

```bash
# Enable WAL mode (already default in ZyncBase)
PRAGMA journal_mode = WAL;

# Backup WAL file periodically
$ cp data/zyncbase.db-wal data/backups/zyncBase-wal-$(date +%Y%m%d-%H%M%S)
```

---

## Safe Migration Patterns

### Additive vs Destructive Changes

Understanding the difference between additive and destructive changes is crucial for safe migrations.

#### Additive Changes (Safe)

These changes add new functionality without breaking existing code:

✅ **Add new column (nullable)**
```sql
BEGIN TRANSACTION;
ALTER TABLE tasks ADD COLUMN priority TEXT;
COMMIT;
```
- **Safe**: Existing queries continue to work
- **Rollback**: Can be ignored or removed
- **Zero downtime**: Yes

✅ **Add new table**
```sql
BEGIN TRANSACTION;
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    name TEXT,
    email TEXT
);
COMMIT;
```
- **Safe**: No impact on existing tables
- **Rollback**: DROP TABLE
- **Zero downtime**: Yes

✅ **Add index**
```sql
BEGIN TRANSACTION;
CREATE INDEX idx_tasks_status ON tasks(status);
COMMIT;
```
- **Safe**: Only improves performance
- **Rollback**: DROP INDEX
- **Zero downtime**: Yes (may cause brief lock)

#### Destructive Changes (Requires Care)

These changes can break existing code or lose data:

❌ **Remove column**
```sql
-- Requires table recreation in SQLite
BEGIN TRANSACTION;

CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    title TEXT,
    status TEXT
    -- assignee column removed
);

INSERT INTO tasks_new SELECT id, title, status FROM tasks;
DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;

COMMIT;
```
- **Breaking**: Queries referencing removed column will fail
- **Data loss**: Column data is deleted
- **Zero downtime**: No (requires application update first)

❌ **Change column type**
```sql
-- Requires data transformation
BEGIN TRANSACTION;

ALTER TABLE tasks ADD COLUMN priority_new TEXT;
UPDATE tasks SET priority_new = CAST(priority AS TEXT);

-- Recreate table with new type
CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    title TEXT,
    priority TEXT  -- Changed from INTEGER
);

INSERT INTO tasks_new SELECT id, title, priority_new FROM tasks;
DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;

COMMIT;
```
- **Breaking**: Application code may expect different type
- **Data transformation**: May lose precision or fail
- **Zero downtime**: No

❌ **Rename column**
```sql
-- Requires table recreation
BEGIN TRANSACTION;

CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    title TEXT,
    created_at INTEGER  -- Renamed from createdAt
);

INSERT INTO tasks_new SELECT id, title, createdAt FROM tasks;
DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;

COMMIT;
```
- **Breaking**: All queries using old name will fail
- **Zero downtime**: No

### Multi-Step Migration Pattern

For destructive changes, use a multi-step approach to achieve zero downtime:

#### Step 1: Add New Column (Additive)

```sql
-- Migration 001: Add new column
BEGIN TRANSACTION;
ALTER TABLE tasks ADD COLUMN created_at INTEGER;
COMMIT;
```

Deploy this migration. Application still uses `createdAt`.

#### Step 2: Dual-Write (Application Change)

Update application to write to both columns:

```typescript
// Write to both old and new columns
await db.execute(
  'UPDATE tasks SET createdAt = ?, created_at = ? WHERE id = ?',
  [timestamp, timestamp, taskId]
)
```

Deploy application update.

#### Step 3: Backfill Data (Migration)

```sql
-- Migration 002: Backfill new column
BEGIN TRANSACTION;
UPDATE tasks SET created_at = createdAt WHERE created_at IS NULL;
COMMIT;
```

#### Step 4: Switch Reads (Application Change)

Update application to read from new column:

```typescript
// Read from new column
const task = await db.query('SELECT id, title, created_at FROM tasks WHERE id = ?', [taskId])
```

Deploy application update.

#### Step 5: Remove Old Column (Migration)

```sql
-- Migration 003: Remove old column
BEGIN TRANSACTION;

CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY,
    title TEXT,
    created_at INTEGER
);

INSERT INTO tasks_new SELECT id, title, created_at FROM tasks;
DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;

COMMIT;
```

Deploy final migration.

### Rollback-Safe Patterns

#### Pattern 1: Feature Flags

Use feature flags to control which column is used:

```typescript
const useNewColumn = featureFlags.get('use_created_at_column')

const query = useNewColumn
  ? 'SELECT created_at FROM tasks'
  : 'SELECT createdAt FROM tasks'
```

#### Pattern 2: Graceful Degradation

Handle both old and new schemas:

```typescript
const task = await db.query('SELECT * FROM tasks WHERE id = ?', [taskId])

// Support both column names
const createdAt = task.created_at || task.createdAt
```

#### Pattern 3: Version Checks

Check schema version before executing queries:

```typescript
const schemaVersion = await db.query('PRAGMA user_version')

if (schemaVersion >= 2) {
  // Use new schema
} else {
  // Use old schema
}
```

### Common Migration Pitfalls

#### Pitfall 1: Not Testing Rollback

```sql
-- Bad: No rollback plan
ALTER TABLE tasks ADD COLUMN priority TEXT;

-- Good: Document rollback
-- UP
ALTER TABLE tasks ADD COLUMN priority TEXT;

-- DOWN
-- SQLite doesn't support DROP COLUMN
-- To rollback: Recreate table without priority column
```

#### Pitfall 2: Large Data Transformations

```sql
-- Bad: Transform millions of rows in one transaction
UPDATE tasks SET priority = CASE
  WHEN priority_int <= 2 THEN 'low'
  WHEN priority_int <= 4 THEN 'medium'
  ELSE 'high'
END;

-- Good: Batch updates
-- Process in chunks of 1000 rows
UPDATE tasks SET priority = CASE
  WHEN priority_int <= 2 THEN 'low'
  WHEN priority_int <= 4 THEN 'medium'
  ELSE 'high'
END
WHERE id IN (SELECT id FROM tasks WHERE priority IS NULL LIMIT 1000);
```

#### Pitfall 3: Missing Indexes

```sql
-- Bad: Add column without index
ALTER TABLE tasks ADD COLUMN assignee TEXT;

-- Good: Add column with index
ALTER TABLE tasks ADD COLUMN assignee TEXT;
CREATE INDEX idx_tasks_assignee ON tasks(assignee);
```

#### Pitfall 4: Not Handling NULLs

```sql
-- Bad: Assume column has values
UPDATE tasks SET priority = UPPER(priority);

-- Good: Handle NULLs
UPDATE tasks SET priority = UPPER(priority) WHERE priority IS NOT NULL;
```

---

## Best Practices

### 1. Always Test Migrations

```bash
# Test in development first
$ zyncbase migrate up --dry-run
$ zyncbase migrate up

# Test rollback
$ zyncbase migrate down
$ zyncbase migrate up

# Then apply to staging
# Then apply to production
```

### 2. Use Semantic Versioning

```json
{
  "version": "1.2.0",
  "store": { ... }
}
```

- **Patch (1.2.0 → 1.2.1)**: Bug fixes, no schema changes
- **Minor (1.2.0 → 1.3.0)**: Additive changes (new fields)
- **Major (1.2.0 → 2.0.0)**: Breaking changes (type changes, removals)

### 3. Keep Migrations Small

```bash
# Good - one change per migration
$ zyncbase migrate create add_assignee_field
$ zyncbase migrate create add_priority_field

# Bad - multiple unrelated changes
$ zyncbase migrate create add_many_fields
```

### 4. Document Complex Migrations

```sql
-- migrations/003_v2_change_priority_type.sql
-- 
-- Changes priority from integer (1-5) to string (low/medium/high)
-- 
-- Requires external script: scripts/migrate_priority.ts
-- 
-- Rollback: Not supported (breaking change)
--

BEGIN TRANSACTION;
-- ...
COMMIT;
```

### 5. Backup Before Production Migrations

```bash
# Always backup first
$ sqlite3 data/zyncbase.db ".backup data/zyncbase-backup.db"

# Then migrate
$ zyncbase migrate up
```

### 6. Use Transactions

```sql
-- Always wrap in transaction
BEGIN TRANSACTION;

-- Migration logic here

COMMIT;
```

If anything fails, the entire migration rolls back.

### 7. Test Rollback

```bash
# Apply migration
$ zyncbase migrate up

# Test rollback
$ zyncbase migrate down

# Reapply
$ zyncbase migrate up
```

---

## Troubleshooting

### Migration Failed

```bash
$ zyncbase migrate up

Error: Migration failed
  File: migrations/003_change_priority.sql
  Line: 12
  Error: no such column: priority_new
```

**Solution:**
1. Check migration SQL syntax
2. Verify table/column names
3. Run `zyncbase migrate down` to rollback
4. Fix migration file
5. Run `zyncbase migrate up` again

### Schema Out of Sync

```bash
$ zyncbase-server start

Error: Schema version mismatch
  schema.json: 2.0.0
  database: 1.3.0
  
Apply migrations: zyncbase migrate up
```

**Solution:**
```bash
$ zyncbase migrate up
✓ Migrations applied
$ zyncbase-server start
✓ Server started
```

### Destructive Change in Production

```bash
$ zyncbase-server start

Error: Destructive schema change detected
  Field 'tasks.priority' type changed
  
This requires a migration.
```

**Solution:**
1. Revert schema.json to previous version, OR
2. Create migration: `zyncbase migrate create change_priority_type`
3. Write migration SQL
4. Apply migration: `zyncbase migrate up`

### Data Loss After Migration

**Prevention:**
- Always backup before migrations
- Test in development first
- Use staging environment
- Review migration SQL carefully

**Recovery:**
```bash
# Restore from backup
$ cp data/zyncbase-backup.db data/zyncbase.db

# Rollback migration
$ zyncbase migrate down

# Fix migration
$ vim migrations/003_change_priority.sql

# Reapply
$ zyncbase migrate up
```

---

## See Also

- [Configuration](./CONFIGURATION.md) - Schema configuration settings
- [Storage Architecture](./architecture/STORAGE.md) - Technical implementation
- [Deployment](./DEPLOYMENT.md) - Production deployment guide
