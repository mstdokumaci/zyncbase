# ZyncBase Server Configuration

Complete guide to configuring the ZyncBase server with JSON files.

---

## Table of Contents

1. [Configuration-First Approach](#configuration-first-approach)
2. [zyncbase-config.json](#zyncbase-configjson)
3. [schema.json](#schemajson)
4. [Schema Migrations](#schema-migrations)
5. [authorization.json](#authorizationjson)
6. [Environment Variables](#environment-variables)
7. [Examples](#examples)

---

## Configuration-First Approach

ZyncBase follows a **"Zero-Zig" philosophy**, meaning you don't write server code. Everything from data validation to security rules is defined in declarative JSON files.

For more details on the rationale behind this approach, see the [Zero-Zig Philosophy](../architecture/core-principles.md#zero-zig-philosophy).

**Core configuration files:**
- `zyncbase-config.json`: Main server settings
- `schema.json`: Data validation
- `authorization.json`: Security rules

---

## zyncbase-config.json

Main server configuration file.

### Minimal Configuration

```json
{
  "server": {
    "port": 3000
  },
  "schema": "./schema.json",
  "authorization": "./authorization.json",
  "authentication": {
    "jwt": {
      "secret": "${JWT_SECRET}"
    },
    "ticket": {
      "secret": "${TICKET_SECRET}"
    }
  },
  "dataDir": "./data"
}
```

### Complete Configuration

```json
{
  "environment": "development",
  "server": {
    "port": 3000,
    "host": "0.0.0.0"
  },
  
  "schema": "./schema.json",
  
  "authentication": {
    "ticket": {
      "secret": "${TICKET_SECRET}",
      "ttlSeconds": 60,
      "singleUse": true
    },
    "jwt": {
      "secret": "${JWT_SECRET}",
      "algorithm": "HS256",
      "issuer": "your-app",
      "audience": "zyncbase-server"
    },
    "session": {
      "claims": {
        "tenant_id": "tenant_id",
        "role": "role",
        "permissions": "permissions",
        "org_id": "org_id",
        "read_projects": "read_projects",
        "write_projects": "write_projects"
      }
    },
    "anonymous": {
      "enabled": true,
      "subjectPrefix": "anon:"
    }
  },
  
  "dataDir": "./data",
  
  "security": {
    "allowedOrigins": [
      "https://yourdomain.com",
      "https://app.yourdomain.com"
    ],
    "allowLocalhost": true,
    "maxMessagesPerSecond": 100,
    "maxConnections": 100000,
    "maxMessageSize": 1048576,
    "violationThreshold": 10
  },
  
  "logging": {
    "level": "info",
    "format": "json"
  },
  
  "performance": {
    "messageBufferSize": 1000,
    "batchWrites": true,
    "batchSize": 200,
    "batchTimeout": 10,
    "statementCacheSize": 100
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
    "host": "0.0.0.0"          // Host to bind to
  }
}
```

#### `schema`

Path to JSON Schema file and migration settings. If omitted or the configured file is missing, the server boots with the implicit users-only schema; if a provided schema exists but is invalid, startup fails.

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

#### `authorization`

Path to the `authorization.json` file. If omitted or the file is missing, the server boots with a safe "public playground" default.

```json
{
  "authorization": "./authorization.json"
}
```

#### `authentication`

Authentication source and ticket settings. ZyncBase validates external identity material and issues short-lived tickets for WebSocket connection establishment. It does not manage user accounts or compute permissions.

```json
{
  "authentication": {
    "ticket": {
      "secret": "${TICKET_SECRET}",
      "ttlSeconds": 60,
      "singleUse": true
    },
    "jwt": {
      "secret": "${JWT_SECRET}",
      "algorithm": "HS256",
      "issuer": "your-app",
      "audience": "zyncbase-server",
      "subjectClaim": "sub"
    },
    "session": {
      "claims": {
        "tenant_id": "tenant_id",
        "role": "role",
        "permissions": "permissions",
        "org_id": "org_id",
        "read_projects": "read_projects",
        "write_projects": "write_projects"
      },
      "tokenGracePeriodSeconds": 30
    },
    "anonymous": {
      "enabled": true,
      "subjectPrefix": "anon:"
    }
  }
}
```

**Ticket Settings:**

- `secret` - Signing secret for ZyncBase tickets. If omitted, the server may generate an ephemeral secret, which invalidates outstanding tickets on restart.
- `ttlSeconds` - Ticket lifetime before WebSocket upgrade. Tickets should be short-lived because they travel in the WebSocket URL.
- `singleUse` - Whether a ticket can be redeemed only once. Production deployments should keep this enabled.

**JWT Settings:**

- `secret` - Shared secret for symmetric JWT algorithms.
- `jwksUrl` - URL for public keys when using asymmetric JWT algorithms.
- `algorithm` - Expected JWT algorithm.
- `issuer` - Expected `iss` claim.
- `audience` - Expected `aud` claim.
- `subjectClaim` - Claim used as the external identity string, defaulting to `sub`.

**Session Claim Projection:**

`session.claims` maps `$session` property names to verified JWT claim names. These projected claims are the only permission inputs ZyncBase receives from the identity provider.

The `users` row is not loaded into `$session` for authorization. The reserved `users` collection maps the external subject to an internal `users.id` for `owner_id`, presence identity, and profile/display data.

- `session.tokenGracePeriodSeconds` - Grace period after JWT expiry before the server terminates the connection. The SDK is expected to refresh tokens before expiry; this grace period is a safety net for slow refreshes. Default: 30 seconds.

**Anonymous Auth:**

When `anonymous.enabled` is true, the SDK may request a ticket using a high-entropy, client-generated anonymous subject. Anonymous subjects use the same `users.id` mapping and authorization flow as authenticated subjects.

---

## See Also
- [README](./README.md) - API overview and entry point
- [Store API Reference](./store-api.md) - For how to use the store once configured
- [Presence API Reference](./presence-api.md) - For presence configuration context

#### `dataDir`

Directory for SQLite database and other data files.

```json
{
  "dataDir": "./data"
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
    "maxMessagesPerSecond": 100,
    "maxConnections": 100000,
    "maxMessageSize": 1048576,
    "violationThreshold": 10
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
    "batchSize": 200,
    "batchTimeout": 10,
    "statementCacheSize": 100
  }
}
```

---

## schema.json

Define your data structure using ZyncBase schema format. The schema file has two top-level keys: `store` for persistent relational data and `presence` for typed ephemeral presence state.

> [!IMPORTANT]
> **Naming Restriction**: Field names are forbidden from containing the double underscore sequence (`__`) or using reserved system field names (`id`, `namespace_id`, `owner_id`, `created_at`, `updated_at`). The `__` sequence is reserved for internal flattening of nested objects. Invalid names are rejected by the server with `error.InvalidFieldName`.

---

## Presence Schema (`presence`)

The optional `presence` key defines typed ephemeral presence fields. When present, its definition is authoritative — the server rejects messages referencing unknown field indices or mismatched types. There is no schemaless fallback.

Two tiers are supported:

| Key | Description |
|---|---|
| `presence.user` | Fields owned per connected user. One record per user per namespace. Cleaned up on disconnect. |
| `presence.shared` | Fields representing namespace-level state. One record for the entire namespace. Persists until all users leave (5-second grace period). |

### Presence field constraints

- **Nesting**: Arbitrary depth of object nesting is supported (`cursor: { x, y }`). A hard limit of 500 flat fields is enforced per presence tier at server startup.
- **Flattening**: Nested objects are flattened on the wire using `__` (`cursor__x`, `cursor__y`). The SDK handles this transparently.
- **Required**: Presence fields are never required. Both tiers use field-level merge semantics.
- **Supported types**: `string`, `number`, `integer`, `boolean`. All standard constraints apply (`enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`).
- **`presence.shared` is optional**: Omit if your application has no room-level shared state.

### Example: Collaborative Editor with Shared Slide

```json
{
  "version": "1.0.0",
  "store": {
    "documents": {
      "fields": {
        "title": { "type": "string" }
      }
    }
  },
  "presence": {
    "user": {
      "cursor": {
        "type": "object",
        "fields": {
          "x": { "type": "number" },
          "y": { "type": "number" }
        }
      },
      "status": { "type": "string", "enum": ["active", "idle", "away"] },
      "typing": { "type": "boolean" },
      "name":   { "type": "string", "maxLength": 64 },
      "color":  { "type": "string", "pattern": "^#[0-9a-fA-F]{6}$" }
    },
    "shared": {
      "slide":   { "type": "integer", "minimum": 0 },
      "playing": { "type": "boolean" }
    }
  }
}
```

### Presence schema and SchemaSync

When the server loads a schema with a `presence` section, it derives two flat arrays by flattening nested fields with `__`:

```
presenceUserFields:   ["cursor__x", "cursor__y", "status", "typing", "name"]
presenceSharedFields: ["slide", "playing"]
```

These are included in the `SchemaSync` message pushed to every connecting client. The SDK builds index maps from these arrays and uses them to encode/decode all presence messages. The integer at position N in the array is the wire key for that field.

### Presence authorization

Presence auth rules are defined in `authorization.json` alongside store rules:

```json
{
  "namespaces": [
    {
      "pattern": "workspace:*",
      "storeFilter":        true,
      "presenceRead":        { "$session.userId": { "ne": null } },
      "presenceWrite":       { "$session.userId": { "ne": null } },
      "presenceSharedWrite": { "$session.role":   { "in": ["host", "presenter"] } }
    }
  ],
  "store": []
}
```

| Rule | Applies to |
|---|---|
| `presenceRead` | `presence.subscribe()` and `presence.subscribeShared()` |
| `presenceWrite` | `presence.set()` and `presence.remove()` |
| `presenceSharedWrite` | `presence.setShared()` — defaults to same value as `presenceWrite` when omitted |

The `$data` variable is available in both `presenceWrite` and `presenceSharedWrite` rules and exposes the incoming field values.

See [Presence API Reference](./presence-api.md) for full usage details.

---

## store

> [!IMPORTANT]
> **Naming Restriction**: Field names are forbidden from containing the double underscore sequence (`__`) or using reserved system field names (`id`, `namespace_id`, `owner_id`, `created_at`, `updated_at`). The `__` sequence is reserved for internal flattening of nested objects. Invalid names are rejected by the server with `error.InvalidFieldName`.

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

### Example: Global Master Data (`namespaced: false`)

```json
{
  "version": "1.0.0",
  "store": {
    "pricing_tiers": {
      "namespaced": false,
      "fields": {
        "tier_name": { "type": "string" },
        "monthly_price": { "type": "number" },
        "features": { "type": "array", "items": "string" }
      }
    }
  }
}
```

### Example: The Reserved `users` Collection

The `users` collection is a reserved hybrid table that is automatically managed by ZyncBase. It defaults to `"namespaced": false`; its `external_id` column maps the external identity string (SDK-generated anonymous subject or authenticated JWT subject) to an internal `BLOB(16)` UUIDv7 used by `owner_id`, `$session.userId`, presence `userId`, and foreign keys. You can extend it with optional custom fields:

```json
{
  "version": "1.0.0",
  "store": {
    "users": {
      "namespaced": false,
      "fields": {
        "name": { "type": "string" },
        "email": { "type": "string", "format": "email" },
        "preferences": {
          "type": "object",
          "fields": {
            "notifications": {
              "type": "object",
              "fields": {
                "email": { "type": "boolean" },
                "browser": { "type": "boolean" }
              }
            },
            "theme": { "type": "string" }
          }
        },
        "roles": {
          "type": "array",
          "items": "string"
        }
      }
    }
  }
}
```

Custom fields on `users` cannot be listed in `required`. The server auto-creates identity rows as soon as a scoped session needs an internal user ID, before application profile data is available. If `users.namespaced = true`, the same external identity may resolve to different internal user IDs for different store or presence namespaces.

**What ZyncBase generates (automatic flattening):**

ZyncBase flattens nested objects into column names using a double underscore (`__`) separator. This allows efficient standard SQL queries while maintaining a natural document-like structure for the client.

```sql
CREATE TABLE users (
    id BLOB NOT NULL CHECK(length(id) = 16),
    namespace_id INTEGER NOT NULL, -- 0 for the default global users collection
    owner_id BLOB NOT NULL CHECK(length(owner_id) = 16), -- equal to id for users
    external_id TEXT NOT NULL,
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    preferences__notifications__email INTEGER, -- Boolean stored as int
    preferences__notifications__browser INTEGER,
    preferences__theme TEXT,
    roles BLOB,  -- canonical array storage
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (id)
);

CREATE UNIQUE INDEX idx_users_namespace_external_id ON users(namespace_id, external_id);
```

`id` is the primary key by itself. It is expected to be unique across the whole collection/table; `namespace_id` scopes visibility and identity-provider lookup, but it does not permit duplicate document IDs in different namespaces.

### Schema Structure

ZyncBase uses a **store-based** schema format. Define your data store structure:

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

ZyncBase automatically flattens nested objects of any depth for efficient querying:

```json
{
  "store": {
    "users": {
      "fields": {
        "name": { "type": "string" },
        "address": {
          "type": "object",
          "fields": {
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

**Client API (recursive nested objects work naturally):**
```typescript
// Set nested fields (at any depth)
await zyncbase.set('users.user-1', {
  name: 'Alice',
  address: {
    street: '123 Main St',
    location: {
      lat: 37.7749,
      lng: -122.4194
    }
  }
})

// Field-level updates also support recursion
await zyncbase.set(['users', 'user-1', 'address', 'location', 'lat'], 37.8)

// Query nested fields using dot notation
const users = await zyncbase.query('users', {
  where: { 'address.location.lat': { gte: 37 } }
})
```

**What happens under the hood:**
- Nested fields are recursively flattened to columns using a double underscore separator: `address__location__lat`, etc.
- Base field names in the schema are forbidden from containing `__` to prevent collisions.
- The server reconstructs the nested structure for the client automatically on `get` and `query` operations.
- *Note: On the wire, these string identifiers are entirely replaced by numeric index mappings transparently by the SDK.*

**Benefits:**
- Efficient querying (standard SQLite indexes work on flattened columns)
- Unlimited nesting depth for `store` fields (up to SQLite's column limit of ~2000)
- Clean client-side experience (no manual flattening required)

**Limitations:**
- Nested objects cannot contain arrays of objects (arrays must be at the leaf level)
- Total recursion depth is limited by the maximum number of SQLite columns (typically 2000)
- Field names must not contain `__` — that sequence is reserved for the flattening separator
- `presence` fields support **arbitrary nesting depth** (bounded to 500 flat fields total per tier)

### Arrays

ZyncBase supports arrays with specific constraints:

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
await zyncbase.set(tasks.task-1', {
  tags: ["urgent", "backend"]
})
```

**Typed array behavior (canonical sorted-set):**
- Elements must match the schema `items` primitive type.
- `null`, nested arrays, and objects are rejected.
- Arrays are normalized to sorted unique form on write.
- Reads and query equality observe this canonical sorted unique representation.

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
            "fields": {
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
await zyncbase.set(projects.proj-1', { name: 'My Project' })

// Add members
await zyncbase.set(project_members.member-1', {
  projectId: 'proj-1',
  userId: 'user-1',
  role: 'admin'
})

// Query members
const members = await zyncbase.query(project_members', {
  where: { projectId: 'proj-1' }
})
```

### References (Relations Between Paths)

ZyncBase supports references between paths for relational data:

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
await zyncbase.set(projects.proj-1', { name: 'My Project' })

// Create task that references project
await zyncbase.set(tasks.task-1', {
  title: 'Build feature',
  projectId: 'proj-1'
})

// Delete project (cascades to tasks)
await zyncbase.remove(projects.proj-1')
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
- Frontend just uses IDs - ZyncBase handles the rest

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

ZyncBase automatically generates SQLite tables from your schema.json and handles migrations intelligently based on your environment.

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

ZyncBase generates:
```sql
CREATE TABLE tasks (
    id BLOB NOT NULL CHECK(length(id) = 16),
    namespace_id INTEGER NOT NULL,
    owner_id BLOB NOT NULL CHECK(length(owner_id) = 16),
    title TEXT,
    status TEXT,
    priority INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (id)
);

CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);
```

The primary key remains `id`, not `(namespace_id, id)`. Namespace-aware tables still require collection-wide unique document IDs; this keeps references, cursors, caches, and SDK addressing single-key.

### Auto-Migration (Happy Path)

**Additive changes auto-migrate with zero friction:**

```json
// Initial schema.json
{
  "store": {
    "tasks": {
      "fields": {
        "title": { "type": "string" },
        "status": { "type": "string" }
      }
    }
  }
}

// Updated schema.json - add a field
{
  "store": {
    "tasks": {
      "fields": {
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
$ zyncbase-server start
✓ Schema change detected
✓ Adding column 'tasks.assignee'
✓ Creating index on 'tasks.assignee'
✓ Server started (2ms)
```

**No migration file needed. No friction.**

### Development vs Production

**Development Mode (Fast Iteration):**

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

Behavior:
```bash
# Change field type
$ vim schema.json  # priority: integer → string

$ zyncbase-server start
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

Behavior:
```bash
# Same change in production
$ zyncbase-server start
✗ Cannot start: destructive schema change detected
✗ Field 'tasks.priority' type changed: integer → string

This requires a manual migration.

Options:
1. Revert schema.json to previous version
2. Create migration: zyncbase migrate create change_priority_type
3. Force (data loss): zyncbase-server start --force-schema

See: https://zyncbase.dev/docs/MIGRATIONS.md
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
$ zyncbase-server start
✓ Schema version: 1.2.0 → 1.3.0 (minor)
✓ Auto-migrating additive changes
✓ Server started

# Major - requires explicit migration
$ zyncbase-server start
✗ Schema version: 1.3.0 → 2.0.0 (major)
✗ Breaking changes require migration

Create migration:
  zyncbase migrate create v2_breaking_changes

Or force in development:
  zyncbase-server start --force-schema
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
zyncbase migrate status

# Create new migration
zyncbase migrate create add_assignee_field

# Apply migrations
zyncbase migrate up

# Rollback last migration
zyncbase migrate down

# Dry run (see what would happen)
zyncbase migrate up --dry-run
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
$ zyncbase-server start
✓ Auto-migrated: added column 'tasks.assignee'
```

**Changing a type (development):**
```bash
# 1. Edit schema
$ vim schema.json  # priority: integer → string

# 2. Start server
$ zyncbase-server start --dev
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
$ zyncbase migrate create v2_change_priority_type

# 3. Write migration
$ vim migrations/003_v2_change_priority_type.sql

# 4. Apply migration
$ zyncbase migrate up

# 5. Deploy
$ zyncbase-server start
✓ Migrations applied
✓ Server started
```

For detailed migration guides, see the ZyncBase documentation (MIGRATIONS.md was removed as aspirational content).

---

## authorization.json

Define authorization rules using the declarative JSON condition grammar documented in [Auth Grammar](../implementation/auth-grammar.md). If `authorization.json` is omitted or missing, the server boots with the implicit safe public playground rules from that grammar.

### Simple Rules

```json
{
  "namespaces": [
    {
      "pattern": "tenant:{tenant_id}",
      "storeFilter": { "$session.tenant_id": { "eq": "$namespace.tenant_id" } },
      "presenceRead": { "$session.tenant_id": { "eq": "$namespace.tenant_id" } },
      "presenceWrite": { "$session.role": { "in": ["admin", "editor"] } }
    }
  ],
  "store": [
    {
      "collection": "tasks",
      "read": true,
      "write": {
        "or": [
          { "$session.role": { "eq": "admin" } },
          { "$doc.owner_id": { "eq": "$session.userId" } }
        ]
      }
    },
    {
      "collection": "audit_logs",
      "read": { "$session.role": { "eq": "admin" } },
      "write": false
    }
  ]
}
```

### Condition Grammar

**Available variables:**
- `$session.*` - Resolved session context projected from a validated JWT or anonymous identity (e.g., `$session.userId`, `$session.tenant_id`, `$session.role`)
- `$namespace.*` - Parsed namespace parts (e.g., `$namespace.tenant_id`, `$namespace.room_id`)
- `$path` - Target table/collection name
- `$value.*` - Incoming mutation payload, available for writes
- `$doc.*` - Same-row SQLite columns, injected into SQL for reads and existing-row updates/removes

**Operators:**
- `eq`, `ne` - Equality
- `in`, `notIn` - Set membership
- `contains` - Array/string containment
- `and`, `or` - Explicit logical composition; object fields compose with implicit AND

**Examples:**

```json
{
  "namespaces": [
    {
      "pattern": "public",
      "storeFilter": true,
      "presenceRead": true,
      "presenceWrite": true
    }
  ],
  "store": [
    {
      "collection": "*",
      "read": true,
      "write": { "$doc.owner_id": { "eq": "$session.userId" } }
    },
    {
      "collection": "admin_notes",
      "read": { "$session.role": { "eq": "admin" } },
      "write": { "$session.role": { "eq": "admin" } }
    }
  ]
}
```

### Permission Claims

Complex permission computation happens before ZyncBase receives a request. The identity provider or application auth layer encodes human-manageable grants into JWT claims, and `authorization.json` enforces those claims natively.

**JWT claims:**
```json
{
  "sub": "user_123",
  "org_id": "acme",
  "role": "editor",
  "read_projects": ["docs", "wiki", "planning"],
  "write_projects": ["docs"]
}
```

**authorization.json:**
```json
{
  "namespaces": [
    {
      "pattern": "org:{org_id}:project:{project_id}",
      "storeFilter": {
        "and": [
          { "$namespace.org_id": { "eq": "$session.org_id" } },
          { "$namespace.project_id": { "in": "$session.read_projects" } }
        ]
      },
      "presenceRead": { "$namespace.project_id": { "in": "$session.read_projects" } },
      "presenceWrite": { "$namespace.project_id": { "in": "$session.write_projects" } }
    }
  ],
  "store": [
    {
      "collection": "pages",
      "read": { "$doc.project_id": { "in": "$session.read_projects" } },
      "write": { "$doc.project_id": { "in": "$session.write_projects" } }
    }
  ]
}
```

Rules that require database joins, membership-table lookups, billing checks, or external API calls are outside ZyncBase's authorization boundary. Applications must represent those decisions in trusted token claims or same-row data before ZyncBase evaluates the request.

---

## Environment Variables

ZyncBase supports environment variable substitution using `${VAR_NAME}` syntax.

### .env file

```bash
# Server
PORT=3000
HOST=0.0.0.0

# Authentication
JWT_SECRET=your-secret-key-here
TICKET_SECRET=your-ticket-signing-secret-here

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
  "authentication": {
    "ticket": {
      "secret": "${TICKET_SECRET}"
    },
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

**zyncbase-config.json:**
```json
{
  "server": { "port": 3000 },
  "schema": "./schema.json",
  "authentication": {
    "ticket": { "secret": "${TICKET_SECRET}" },
    "jwt": { "secret": "${JWT_SECRET}" },
    "anonymous": { "enabled": true }
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
  "store": {
    "elements": {
      "fields": {
        "x": { "type": "number" },
        "y": { "type": "number" },
        "width": { "type": "number" },
        "height": { "type": "number" }
      }
    }
  }
}
```

**authorization.json:**
```json
{
  "namespaces": [
    {
      "pattern": "room:{room_id}",
      "storeFilter": { "$session.userId": { "ne": null } },
      "presenceRead": true,
      "presenceWrite": { "$session.userId": { "ne": null } }
    }
  ],
  "store": [
    {
      "collection": "elements",
      "read": true,
      "write": { "$session.userId": { "ne": null } }
    }
  ]
}
```

---

### Example 2: Multi-tenant SaaS

**zyncbase-config.json:**
```json
{
  "server": { "port": 3000 },
  "schema": "./schema.json",
  "authentication": {
    "ticket": { "secret": "${TICKET_SECRET}" },
    "jwt": { "secret": "${JWT_SECRET}" }
  },
  "dataDir": "./data",
  "namespaces": {
    "patterns": [{ "pattern": "tenant:*" }]
  }
}
```

**authorization.json:**
```json
{
  "namespaces": [
    {
      "pattern": "tenant:{tenant_id}",
      "storeFilter": { "$session.tenant_id": { "eq": "$namespace.tenant_id" } },
      "presenceRead": { "$session.tenant_id": { "eq": "$namespace.tenant_id" } },
      "presenceWrite": { "$session.role": { "in": ["admin", "editor"] } }
    }
  ],
  "store": [
    {
      "collection": "*",
      "read": true,
      "write": { "$session.role": { "in": ["admin", "editor"] } }
    }
  ]
}
```

---

### Example 3: Project Grants from JWT Claims

If an application has Jira- or Confluence-style projects inside an organization, the identity provider can issue project grants as JWT claims:

```json
{
  "sub": "user_123",
  "org_id": "acme",
  "read_projects": ["docs", "wiki", "planning"],
  "write_projects": ["docs"]
}
```

ZyncBase enforces those grants without database lookups:

```json
{
  "namespaces": [
    {
      "pattern": "org:{org_id}:project:{project_id}",
      "storeFilter": {
        "and": [
          { "$namespace.org_id": { "eq": "$session.org_id" } },
          { "$namespace.project_id": { "in": "$session.read_projects" } }
        ]
      },
      "presenceRead": { "$namespace.project_id": { "in": "$session.read_projects" } },
      "presenceWrite": { "$namespace.project_id": { "in": "$session.write_projects" } }
    }
  ],
  "store": [
    {
      "collection": "pages",
      "read": { "$doc.project_id": { "in": "$session.read_projects" } },
      "write": { "$doc.project_id": { "in": "$session.write_projects" } }
    }
  ]
}
```

For checks that require joins, inherited ACL traversal, billing state, or external API calls, the application must compute the result before minting or refreshing the JWT.

---

# Server restart is required for config changes.
# No automatic hot reload is supported.
```

**What triggers reload:**
- `zyncbase-config.json` changes (requires restart)
- `schema.json` changes (requires restart)
- `authorization.json` changes (requires restart)

**What doesn't trigger reload:**
- Environment variable changes (requires restart)
- Binary updates (requires restart)

---

## Validation

ZyncBase evaluates all config files on startup and provides clear error messages:

```bash
$ ./zyncbase-server

Error: Invalid configuration
  File: zyncbase-config.json
  Line: 12
  Issue: Missing required field "schema"
  
Fix: Add "schema": "./schema.json" to your config
```

---

## Next Steps

- [Store API](./store-api.md) - Learn the data sync API
-  - Deploy to production (removed - aspirational content)
- [Examples](https://github.com/zyncbase/examples) - See complete examples
