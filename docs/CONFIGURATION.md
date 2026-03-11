# zyncBase Server Configuration

**Last Updated**: 2026-03-09

Complete guide to configuring the zyncBase server with JSON files.

---

## Table of Contents

1. [Configuration-First Approach](#configuration-first-approach)
2. [zyncBase.config.json](#zyncBaseconfigjson)
3. [schema.json](#schemajson)
4. [Schema Migrations](#schema-migrations)
5. [auth.json](#authjson)
6. [Environment Variables](#environment-variables)
7. [Examples](#examples)

---

## Configuration-First Approach

zyncBase uses **JSON configuration files** instead of requiring you to write server code. The Zig binary reads these configs and handles everything.

**Directory structure:**
```
my-app/
├── zyncBase-server          # Downloaded binary (or use Docker)
├── zyncBase.config.json     # Main server configuration
├── schema.json         # Your data schema (JSON Schema format)
├── auth.json           # Authentication & authorization rules
└── client/
    └── app.ts          # Your frontend code (TypeScript SDK)
```

---

## zyncBase.config.json

Main server configuration file.

### Minimal Configuration

```json
{
  "server": {
    "port": 3000
  },
  "schema": "./schema.json",
  "auth": {
    "jwt": {
      "secret": "${JWT_SECRET}"
    }
  },
  "dataDir": "./data"
}
```

### Complete Configuration

```json
{
  "server": {
    "port": 3000,
    "host": "0.0.0.0",
    "maxConnections": 100000
  },
  
  "schema": "./schema.json",
  
  "auth": {
    "jwt": {
      "secret": "${JWT_SECRET}",
      "algorithm": "HS256",
      "issuer": "your-app",
      "audience": "zyncBase-server"
    },
    "webhook": {
      "url": "http://localhost:4000/auth",
      "timeout": 1000,
      "headers": {
        "Authorization": "Bearer ${WEBHOOK_SECRET}"
      }
    }
  },
  
  "dataDir": "./data",
  
  "namespaces": {
    "patterns": [
      {
        "pattern": "public",
        "description": "Default public namespace"
      },
      {
        "pattern": "room:*",
        "description": "Collaborative rooms"
      },
      {
        "pattern": "tenant:*",
        "description": "Tenant-isolated data"
      }
    ]
  },
  
  "security": {
    "allowedOrigins": [
      "https://yourdomain.com",
      "https://app.yourdomain.com"
    ],
    "allowLocalhost": true,
    "rateLimit": {
      "messagesPerSecond": 100,
      "connectionsPerIP": 10,
      "maxMessageSize": 1048576
    }
  },
  
  "logging": {
    "level": "info",
    "format": "json"
  },
  
  "performance": {
    "messageBufferSize": 1000,
    "batchWrites": true,
    "batchTimeout": 10
  }
}
```

### Configuration Reference

#### `server`

Server network configuration.

```json
{
  "server": {
    "port": 3000,              // Port to listen on
    "host": "0.0.0.0",         // Host to bind to
    "maxConnections": 100000   // Max concurrent connections
  }
}
```

#### `schema`

Path to JSON Schema file and migration settings.

```json
{
  "schema": {
    "file": "./schema.json",
    "version": "1.0.0",
    "autoMigrate": true,
    "allowDestructive": false
  }
}
```

Or simple string format:
```json
{
  "schema": "./schema.json"
}
```

**Migration Settings:**

- `autoMigrate` (boolean or string)
  - `true` - Auto-migrate all changes (development default)
  - `"additive-only"` - Only auto-migrate additive changes (production default)
  - `false` - Require explicit migrations for all changes

- `allowDestructive` (boolean)
  - `true` - Allow destructive changes with confirmation (development)
  - `false` - Block destructive changes (production)

- `version` (string)
  - Semantic version of your schema
  - Major version changes require migrations
  - Minor/patch versions can auto-migrate

#### `auth`

Authentication and authorization configuration.

```json
{
  "auth": {
    "jwt": {
      "secret": "${JWT_SECRET}",     // JWT signing secret
      "algorithm": "HS256",           // Algorithm (HS256, RS256, etc.)
      "issuer": "your-app",           // Expected issuer
      "audience": "zyncBase-server"        // Expected audience
    },
    "webhook": {
      "url": "http://localhost:4000/auth",  // Custom auth webhook
      "timeout": 1000,                       // Timeout in ms
      "headers": {
        "Authorization": "Bearer ${WEBHOOK_SECRET}"
      }
    }
  }
}
```

#### `dataDir`

Directory for SQLite database and other data files.

```json
{
  "dataDir": "./data"
}
```

#### `namespaces`

Namespace pattern definitions.

```json
{
  "namespaces": {
    "patterns": [
      {
        "pattern": "room:*",
        "description": "Collaborative rooms"
      }
    ]
  }
}
```

#### `security`

Security settings.

```json
{
  "security": {
    "allowedOrigins": [
      "https://yourdomain.com"
    ],
    "allowLocalhost": true,
    "rateLimit": {
      "messagesPerSecond": 100,
      "connectionsPerIP": 10,
      "maxMessageSize": 1048576
    }
  }
}
```

#### `logging`

Logging configuration.

```json
{
  "logging": {
    "level": "info",    // debug, info, warn, error
    "format": "json"    // json, text
  }
}
```

#### `performance`

Performance tuning.

```json
{
  "performance": {
    "messageBufferSize": 1000,
    "batchWrites": true,
    "batchTimeout": 10
  }
}
```

---

## schema.json

Define your data structure using zyncBase's store-based schema format.

### Example: Collaborative Canvas

```json
{
  "version": "1.0.0",
  "store": {
    "elements": {
      "fields": {
        "type": { "type": "string", "enum": ["rect", "circle", "text"] },
        "x": { "type": "number" },
        "y": { "type": "number" },
        "width": { "type": "number" },
        "height": { "type": "number" },
        "color": { "type": "string", "pattern": "^#[0-9a-fA-F]{6}$" }
      },
      "required": ["type", "x", "y", "width", "height"]
    }
  }
}
```

### Example: Multi-tenant Projects with Relations

```json
{
  "version": "1.0.0",
  "store": {
    "projects": {
      "fields": {
        "name": { "type": "string", "minLength": 1, "maxLength": 100 },
        "status": { "type": "string", "enum": ["active", "archived", "deleted"] },
        "createdBy": { "type": "string" }
      },
      "required": ["name", "status", "createdBy"]
    },
    "tasks": {
      "fields": {
        "title": { "type": "string", "minLength": 1 },
        "description": { "type": "string" },
        "status": { "type": "string", "enum": ["todo", "in_progress", "done"] },
        "projectId": {
          "type": "string",
          "references": "projects"
        },
        "assignedTo": { "type": "string" }
      },
      "required": ["title", "status", "projectId"]
    }
  }
}
```

### Example: Nested Fields and Simple Arrays

```json
{
  "version": "1.0.0",
  "store": {
    "users": {
      "fields": {
        "name": { "type": "string" },
        "email": { "type": "string", "format": "email" },
        "address": {
          "type": "object",
          "properties": {
            "street": { "type": "string" },
            "city": { "type": "string" },
            "zipCode": { "type": "string" }
          }
        },
        "roles": {
          "type": "array",
          "items": "string"
        }
      },
      "required": ["name", "email"]
    }
  }
}
```

**What zyncBase generates (you don't need to know this):**
```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    address_street TEXT,
    address_city TEXT,
    address_zipCode TEXT,
    roles TEXT,  -- JSON: ["admin", "editor"]
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

### Schema Structure

zyncBase uses a **store-based** schema format. Define your data store structure:

```json
{
  "version": "1.0.0",
  "store": {
    "tasks": {
      "fields": {
        "title": { "type": "string" },
        "status": { "type": "string" },
        "priority": { "type": "integer" }
      }
    }
  }
}
```

### Nested Fields (Automatic Flattening)

zyncBase automatically flattens nested objects for efficient querying:

```json
{
  "store": {
    "users": {
      "fields": {
        "name": { "type": "string" },
        "address": {
          "type": "object",
          "properties": {
            "street": { "type": "string" },
            "city": { "type": "string" },
            "zipCode": { "type": "string" }
          }
        }
      }
    }
  }
}
```

**Client API (nested objects work naturally):**
```typescript
// Set nested field
await zyncBase.set('users.user-1', {
  name: 'Alice',
  address: {
    street: '123 Main St',
    city: 'San Francisco',
    zipCode: '94102'
  }
})

// Query nested field
const users = await zyncBase.query('users', {
  where: { 'address.city': 'San Francisco' }
})
```

**What happens under the hood:**
- Nested fields are flattened to columns: `address_street`, `address_city`, `address_zipCode`
- You can query them efficiently
- Frontend never needs to know about this

**Limitations:**
- Only one level of nesting supported
- Nested objects cannot contain arrays of objects
- For deeper nesting, use separate store paths with references

### Arrays

zyncBase supports arrays with specific constraints:

**✅ Simple arrays (primitives):**
```json
{
  "store": {
    "tasks": {
      "fields": {
        "tags": {
          "type": "array",
          "items": "string"
        }
      }
    }
  }
}
```

**Client API:**
```typescript
await zyncBase.set('tasks.task-1', {
  tags: ["urgent", "backend"]
})
```

**❌ Arrays of objects (not supported):**
```json
{
  "store": {
    "projects": {
      "fields": {
        "members": {
          "type": "array",
          "items": {
            "type": "object",  // ❌ Not allowed
            "properties": {
              "userId": { "type": "string" },
              "role": { "type": "string" }
            }
          }
        }
      }
    }
  }
}
```

**Instead, use a separate store path with references:**
```json
{
  "store": {
    "projects": {
      "fields": {
        "name": { "type": "string" }
      }
    },
    "project_members": {
      "fields": {
        "projectId": {
          "type": "string",
          "references": "projects"
        },
        "userId": { "type": "string" },
        "role": { "type": "string" }
      }
    }
  }
}
```

**Client API:**
```typescript
// Create project
await zyncBase.set('projects.proj-1', { name: 'My Project' })

// Add members
await zyncBase.set('project_members.member-1', {
  projectId: 'proj-1',
  userId: 'user-1',
  role: 'admin'
})

// Query members
const members = await zyncBase.query('project_members', {
  where: { projectId: 'proj-1' }
})
```

### References (Relations Between Paths)

zyncBase supports references between paths for relational data:

```json
{
  "store": {
    "projects": {
      "fields": {
        "name": { "type": "string" }
      }
    },
    "tasks": {
      "fields": {
        "title": { "type": "string" },
        "projectId": {
          "type": "string",
          "references": "projects",
          "onDelete": "cascade"
        }
      }
    }
  }
}
```

**Client API:**
```typescript
// Create project
await zyncBase.set('projects.proj-1', { name: 'My Project' })

// Create task that references project
await zyncBase.set('tasks.task-1', {
  title: 'Build feature',
  projectId: 'proj-1'
})

// Delete project (cascades to tasks)
await zyncBase.remove('projects.proj-1')
// task-1 is automatically deleted
```

**Reference Options:**

- `onDelete: "cascade"` - Delete tasks when project is deleted (default)
- `onDelete: "restrict"` - Prevent project deletion if tasks exist
- `onDelete: "set_null"` - Set projectId to null when project is deleted

**Benefits:**
- Data integrity enforced automatically
- Cascading deletes work as expected
- Efficient queries across related paths
- Frontend just uses IDs - zyncBase handles the rest

### JSON Schema Tips

**Use `enum` for fixed values:**
```json
{
  "status": { "type": "string", "enum": ["active", "pending", "deleted"] }
}
```

**Use `format` for validation:**
```json
{
  "email": { "type": "string", "format": "email" },
  "url": { "type": "string", "format": "uri" },
  "date": { "type": "string", "format": "date-time" }
}
```

**Use `pattern` for regex validation:**
```json
{
  "color": { "type": "string", "pattern": "^#[0-9a-fA-F]{6}$" }
}
```

**Use `minLength`/`maxLength` for strings:**
```json
{
  "name": { "type": "string", "minLength": 1, "maxLength": 100 }
}
```

**Use `minimum`/`maximum` for numbers:**
```json
{
  "priority": { "type": "integer", "minimum": 1, "maximum": 5 }
}
```

---

## Schema Migrations

zyncBase automatically generates SQLite tables from your schema.json and handles migrations intelligently based on your environment.

### How It Works

**Path-to-Table Mapping:**

```
Path: 'tasks' → Table: tasks
Path: 'tasks.task-1' → Table: tasks, row with id='task-1'
Path: 'users' → Table: users
```

**Generated DDL:**

From this schema:
```json
{
  "properties": {
    "tasks": {
      "type": "object",
      "patternProperties": {
        ".*": {
          "properties": {
            "title": { "type": "string" },
            "status": { "type": "string" },
            "priority": { "type": "integer" }
          }
        }
      }
    }
  }
}
```

zyncBase generates:
```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    namespace_id TEXT,
    title TEXT,
    status TEXT,
    priority INTEGER,
    created_at INTEGER,
    updated_at INTEGER
);

CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);
```

### Auto-Migration (Happy Path)

**Additive changes auto-migrate with zero friction:**

```json
// schema.json v1
{
  "properties": {
    "tasks": {
      "properties": {
        "title": { "type": "string" },
        "status": { "type": "string" }
      }
    }
  }
}

// schema.json v2 - add a field
{
  "properties": {
    "tasks": {
      "properties": {
        "title": { "type": "string" },
        "status": { "type": "string" },
        "assignee": { "type": "string" }  // ← New field
      }
    }
  }
}
```

**What happens:**
```bash
$ zyncBase-server start
✓ Schema change detected
✓ Adding column 'tasks.assignee'
✓ Creating index on 'tasks.assignee'
✓ Server started (2ms)
```

**No migration file needed. No friction.**

### Development vs Production

**Development Mode (Fast Iteration):**

```json
// zyncBase.config.json
{
  "environment": "development",
  "schema": {
    "file": "./schema.json",
    "autoMigrate": true,
    "allowDestructive": true
  }
}
```

Behavior:
```bash
# Change field type
$ vim schema.json  # priority: integer → string

$ zyncBase-server start
⚠ Destructive schema change detected
⚠ Field 'tasks.priority' type changed: integer → string
⚠ This will DROP and recreate the table (data loss!)

Continue? [y/N]: y

✓ Dropping table 'tasks'
✓ Creating table 'tasks' with new schema
✓ Server started

⚠ All data in 'tasks' was lost
```

**Production Mode (Safety First):**

```json
// zyncBase.config.json
{
  "environment": "production",
  "schema": {
    "file": "./schema.json",
    "autoMigrate": "additive-only",
    "allowDestructive": false
  }
}
```

Behavior:
```bash
# Same change in production
$ zyncBase-server start
✗ Cannot start: destructive schema change detected
✗ Field 'tasks.priority' type changed: integer → string

This requires a manual migration.

Options:
1. Revert schema.json to previous version
2. Create migration: zyncBase migrate create change_priority_type
3. Force (data loss): zyncBase-server start --force-schema

See: https://zyncBase.dev/docs/MIGRATIONS.md
```

### Schema Versioning

**Use semantic versioning to track breaking changes:**

```json
{
  "version": "1.2.0",
  "properties": {
    "tasks": { ... }
  }
}
```

**Version Rules:**
- **Patch (1.2.0 → 1.2.1)**: Additive only, auto-migrate
- **Minor (1.2.0 → 1.3.0)**: Additive only, auto-migrate
- **Major (1.2.0 → 2.0.0)**: Breaking changes, requires migration

```bash
# Patch/Minor - auto-migrates
$ zyncBase-server start
✓ Schema version: 1.2.0 → 1.3.0 (minor)
✓ Auto-migrating additive changes
✓ Server started

# Major - requires explicit migration
$ zyncBase-server start
✗ Schema version: 1.3.0 → 2.0.0 (major)
✗ Breaking changes require migration

Create migration:
  zyncBase migrate create v2_breaking_changes

Or force in development:
  zyncBase-server start --force-schema
```

### What Auto-Migrates

**Always safe (auto-migrates in all environments):**
- ✅ Add new field
- ✅ Add new table (path)
- ✅ Add index
- ✅ Make field optional (required → optional)

**Requires migration (production):**
- ❌ Change field type (integer → string)
- ❌ Remove field
- ❌ Rename field
- ❌ Make field required (optional → required)

### Migration Commands

```bash
# Check migration status
zyncBase migrate status

# Create new migration
zyncBase migrate create add_assignee_field

# Apply migrations
zyncBase migrate up

# Rollback last migration
zyncBase migrate down

# Dry run (see what would happen)
zyncBase migrate up --dry-run
```

### Environment-Specific Behavior

| Change Type | Development | Production |
|-------------|-------------|------------|
| Add field | ✓ Auto-migrate | ✓ Auto-migrate |
| Add table | ✓ Auto-migrate | ✓ Auto-migrate |
| Change type | ⚠ Allow with confirm | ✗ Require migration |
| Remove field | ⚠ Allow with confirm | ✗ Require migration |
| Major version | ⚠ Allow with confirm | ✗ Require migration |

### Quick Start Guide

**Adding a field (zero friction):**
```bash
# 1. Edit schema
$ vim schema.json  # Add 'assignee' field

# 2. Start server
$ zyncBase-server start
✓ Auto-migrated: added column 'tasks.assignee'
```

**Changing a type (development):**
```bash
# 1. Edit schema
$ vim schema.json  # priority: integer → string

# 2. Start server
$ zyncBase-server start --dev
⚠ Destructive change: field type changed
⚠ Data in 'tasks' will be lost
Continue? [y/N]: y
✓ Table recreated

# 3. Rebuild test data
$ node scripts/seed-dev-data.js
```

**Changing a type (production):**
```bash
# 1. Edit schema and bump version
$ vim schema.json  # version: "1.3.0" → "2.0.0"

# 2. Create migration
$ zyncBase migrate create v2_change_priority_type

# 3. Write migration
$ vim migrations/003_v2_change_priority_type.sql

# 4. Apply migration
$ zyncBase migrate up

# 5. Deploy
$ zyncBase-server start
✓ Migrations applied
✓ Server started
```

For detailed migration guides, see [MIGRATIONS.md](./MIGRATIONS.md).

---

## auth.json

Define authorization rules using a simple expression language.

### Simple Rules

```json
{
  "rules": [
    {
      "namespace": "room:*",
      "allow": {
        "read": "jwt.userId && isRoomMember(jwt.userId, namespace.roomId)",
        "write": "jwt.userId && isRoomMember(jwt.userId, namespace.roomId)"
      }
    },
    {
      "namespace": "tenant:*",
      "allow": {
        "read": "jwt.tenantId === namespace.tenantId",
        "write": "jwt.tenantId === namespace.tenantId && jwt.role === 'admin'"
      }
    }
  ],
  
  "functions": {
    "isRoomMember": {
      "type": "sql",
      "query": "SELECT 1 FROM room_members WHERE user_id = $1 AND room_id = $2",
      "params": ["userId", "roomId"]
    }
  }
}
```

### Expression Language

**Available variables:**
- `jwt.*` - Claims from JWT token (e.g., `jwt.userId`, `jwt.tenantId`, `jwt.role`)
- `namespace.*` - Parsed namespace parts (e.g., `namespace.tenantId`, `namespace.roomId`)
- `operation` - The operation being performed (`"read"` or `"write"`)

**Operators:**
- `===`, `!==` - Equality
- `&&`, `||` - Logical AND/OR
- `in` - Check if value is in array
- `!` - Logical NOT

**Examples:**

```json
{
  "rules": [
    {
      "namespace": "public:*",
      "allow": {
        "read": "true",
        "write": "jwt.userId !== null"
      }
    },
    {
      "namespace": "private:*",
      "allow": {
        "read": "isRoomMember(jwt.userId, namespace.roomId)",
        "write": "isRoomMember(jwt.userId, namespace.roomId) && jwt.role in ['admin', 'editor']"
      }
    }
  ]
}
```

### Custom Functions

Define reusable functions that execute SQL queries:

```json
{
  "functions": {
    "isRoomMember": {
      "type": "sql",
      "query": "SELECT 1 FROM room_members WHERE user_id = $1 AND room_id = $2",
      "params": ["userId", "roomId"]
    },
    "hasPermission": {
      "type": "sql",
      "query": "SELECT 1 FROM permissions WHERE user_id = $1 AND permission = $2",
      "params": ["userId", "permission"]
    }
  }
}
```

---

## Environment Variables

zyncBase supports environment variable substitution using `${VAR_NAME}` syntax.

### .env file

```bash
# Server
PORT=3000
HOST=0.0.0.0

# Authentication
JWT_SECRET=your-secret-key-here
WEBHOOK_SECRET=webhook-auth-token

# Database
DATA_DIR=./data

# Security
ALLOWED_ORIGINS=https://yourdomain.com,https://app.yourdomain.com
```

### Using in config

```json
{
  "server": {
    "port": "${PORT}",
    "host": "${HOST}"
  },
  "auth": {
    "jwt": {
      "secret": "${JWT_SECRET}"
    }
  },
  "dataDir": "${DATA_DIR}",
  "security": {
    "allowedOrigins": "${ALLOWED_ORIGINS}"
  }
}
```

---

## Examples

### Example 1: Collaborative Whiteboard

**zyncBase.config.json:**
```json
{
  "server": { "port": 3000 },
  "schema": "./schema.json",
  "auth": {
    "jwt": { "secret": "${JWT_SECRET}" }
  },
  "dataDir": "./data",
  "namespaces": {
    "patterns": [{ "pattern": "room:*" }]
  }
}
```

**schema.json:**
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "elements": {
      "type": "object",
      "patternProperties": {
        ".*": {
          "type": "object",
          "properties": {
            "x": { "type": "number" },
            "y": { "type": "number" },
            "width": { "type": "number" },
            "height": { "type": "number" }
          }
        }
      }
    }
  }
}
```

**auth.json:**
```json
{
  "rules": [
    {
      "namespace": "room:*",
      "allow": {
        "read": "jwt.userId",
        "write": "jwt.userId"
      }
    }
  ]
}
```

---

### Example 2: Multi-tenant SaaS

**zyncBase.config.json:**
```json
{
  "server": { "port": 3000 },
  "schema": "./schema.json",
  "auth": {
    "jwt": { "secret": "${JWT_SECRET}" }
  },
  "dataDir": "./data",
  "namespaces": {
    "patterns": [{ "pattern": "tenant:*" }]
  }
}
```

**auth.json:**
```json
{
  "rules": [
    {
      "namespace": "tenant:*",
      "allow": {
        "read": "jwt.tenantId === namespace.tenantId",
        "write": "jwt.tenantId === namespace.tenantId && jwt.role in ['admin', 'editor']"
      }
    }
  ]
}
```

---

### Example 3: Custom Auth Webhook

If JSON rules aren't enough, use a webhook for custom logic:

**zyncBase.config.json:**
```json
{
  "auth": {
    "jwt": {
      "secret": "${JWT_SECRET}"
    },
    "webhook": {
      "url": "http://localhost:4000/auth",
      "timeout": 1000
    }
  }
}
```

**Your webhook receives:**
```json
{
  "userId": "user-123",
  "namespace": "room:abc-123",
  "operation": "read",
  "jwt": { "userId": "user-123", "tenantId": "tenant-456" }
}
```

**And returns:**
```json
{
  "allowed": true
}
```

This way, you can write custom auth logic in **any language** (Node.js, Python, Go, etc.) without touching Zig.

---

## Hot Reload

zyncBase watches config files and reloads automatically when they change:

```bash
# Edit config
vim zyncBase.config.json

# Server automatically reloads
# No restart needed!
```

**What triggers reload:**
- `zyncBase.config.json` changes
- `schema.json` changes
- `auth.json` changes

**What doesn't trigger reload:**
- Environment variable changes (requires restart)
- Binary updates (requires restart)

---

## Validation

zyncBase validates all config files on startup and provides clear error messages:

```bash
$ ./zyncBase-server

Error: Invalid configuration
  File: zyncBase.config.json
  Line: 12
  Issue: Missing required field "schema"
  
Fix: Add "schema": "./schema.json" to your config
```

---

## Next Steps

- [API Reference](./API_REFERENCE.md) - Learn the client SDK
- [Deployment](./DEPLOYMENT.md) - Deploy to production
- [Examples](https://github.com/zyncBase/examples) - See complete examples
