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
  "server": {
    "port": 3000,
    "host": "0.0.0.0"
  },
  
  "schema": "./schema.json",
  
  "migrations": {
    "dir": "./migrations",
    "snapshot": true
  },
  
  "authentication": {
    "ticket": {
      "secret": "${TICKET_SECRET}",
      "ttlSeconds": 60
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
    "batchSize": 500,
    "batchTimeout": 8,
    "presenceBatchTimeoutMs": 8,
    "presenceBatchMaxUpdates": 512,
    "statementCacheSize": 100
  },

  "storage": {
    "synchronous": "full"
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
    "idleTimeoutSeconds": 15,  // Inbound WebSocket idle timeout
    "tls": {                   // Optional; omit for plaintext HTTP/WS
      "certFile": "./origin.pem",
      "keyFile": "./origin.key"
    }
  }
}
```

- `port` - Port to listen on (1-65535).
- `host` - Host to bind to.
- `idleTimeoutSeconds` - Total WebSocket idle timeout in seconds (2-239, default 15). The server sends a native WebSocket Ping before expiry and closes the connection if the peer does not respond within the remaining timeout.
- `tls` (object, optional) - Enables HTTPS ticket exchange and WSS on the same listener. When omitted, the server uses plaintext HTTP/WS.

**`server.tls`:**

- `certFile` - Path to the PEM certificate-chain file. Supports `${VAR_NAME}` expansion.
- `keyFile` - Path to the PEM private-key file. Supports `${VAR_NAME}` expansion.
- Paths are relative to the server's working directory unless absolute.
- Both `certFile` and `keyFile` must be set together and non-empty; an incomplete or empty pair is rejected at startup.
- Certificate loading failures stop startup rather than falling back to plaintext.
- Restart the server after replacing certificates.

#### `schema`

Path to the schema JSON file, or an inline schema object. If omitted or the configured file is missing, the server boots with the implicit users-only schema; if a provided schema exists but is invalid, startup fails.

```json
{
  "schema": "./schema.json"
}
```

#### `migrations`

Where migration folders live, and whether a snapshot is written before a developer migration runs. See [Schema Migrations](#schema-migrations).

```json
{
  "migrations": {
    "dir": "./migrations",
    "snapshot": true
  }
}
```

- `dir` (string): defaults to a `migrations` directory next to the schema file (`./migrations` for an inline schema). A missing directory means there are no migrations.
- `snapshot` (boolean, default `true`): write `zyncbase.db.pre-migration-<id>-<timestamp>` in the data directory before applying a pending migration. Turn it off only if you have another restore point, such as Litestream.

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
      "ttlSeconds": 60
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

- `session.tokenGracePeriodSeconds` - Refresh window opened when a JWT expires. The client is notified and may replace the token in place; the server terminates the connection only if no valid replacement arrives within the window. Default: 30 seconds.

**Anonymous Auth:**

When `anonymous.enabled` is true, the SDK may request a ticket using a high-entropy, client-generated anonymous subject. Anonymous subjects use the same `users.id` mapping and authorization flow as authenticated subjects.

---

## Related Specifications
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
    "batchSize": 500,
    "batchTimeout": 8,
    "presenceBatchTimeoutMs": 8,
    "presenceBatchMaxUpdates": 512,
    "statementCacheSize": 100
  }
}
```

#### `storage`

Durability settings for the SQLite write path.

```json
{
  "storage": {
    "synchronous": "full"   // full (default) or normal
  }
}
```

- `synchronous` - `full` fsyncs each write batch, so committed writes survive a power loss (assuming the OS and disk honor flush). `normal` is faster, but a power loss or hard reset can roll back recently committed transactions. Process crashes are safe in both modes. See [OPERATIONS.md](../../OPERATIONS.md) for the RPO contract.

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
- **Strict grammar**: Only `user` and `shared` are accepted under `presence`. Presence fields reject store-only or unknown properties at startup.
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

## Actions Schema (`actions`)

Actions define schema-validated client-to-worker messages. The execution tier is derived from the declaration: a `returns` object declares a synchronous RPC; `null` or omitted declares an asynchronous stream. See [Actions API Reference](./actions-api.md) for the full contract.

```json
{
  "actions": {
    "player_move": {
      "params": {
        "direction": { "type": "string", "enum": ["up", "down", "left", "right"] },
        "seq": { "type": "integer", "minimum": 0 }
      },
      "required": ["direction"],
      "returns": null,
      "scope": "presence"
    },
    "checkout": {
      "params": { "cart_id": { "type": "string", "minLength": 1 } },
      "required": ["cart_id"],
      "returns": {
        "order_id": { "type": "string" },
        "remaining_coins": { "type": "integer", "minimum": 0 }
      }
    }
  }
}
```

| Key | Description |
|---|---|
| `params` | Input field definitions using the standard field grammar; nested objects flatten with `__`. |
| `required` | Required param paths (dot notation). |
| `returns` | Output field definitions for sync actions; `null`/omitted declares an async action. |
| `scope` | `"store"` (default) or `"presence"` — the scope that resolves the action's namespace and user identity. |

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

### Unique Constraints

Tables may declare uniqueness over one field (single-field constraint) or an ordered set of fields (compound constraint) using the table-level `unique` array. Nested paths use dot notation, like `required`.

```json
{
  "version": "1.1.0",
  "store": {
    "projects": {
      "required": ["slug", "provider", "externalId"],
      "fields": {
        "slug": { "type": "string" },
        "provider": { "type": "string" },
        "externalId": { "type": "string" },
        "profile": {
          "type": "object",
          "fields": {
            "handle": { "type": "string" }
          }
        }
      },
      "unique": [
        ["slug"],
        ["provider", "externalId"],
        ["profile.handle"]
      ]
    }
  }
}
```

This generates namespace-scoped SQLite unique indexes (`namespace_id` is always the first indexed column):

```sql
CREATE UNIQUE INDEX "uidx__projects__constraint__0"
ON "projects"("namespace_id", "slug");

CREATE UNIQUE INDEX "uidx__projects__constraint__1"
ON "projects"("namespace_id", "provider", "externalId");

CREATE UNIQUE INDEX "uidx__projects__constraint__2"
ON "projects"("namespace_id", "profile__handle");
```

Rules and behavior:

- **Namespace scoping**: Equal values may exist in different namespaces but never within the same namespace. For `"namespaced": false` tables all rows share namespace ID `0`, so uniqueness becomes global. There is no global-uniqueness override for a namespaced table.
- **Required plus unique**: Constrained components may be `NULL`, and SQLite permits multiple such rows. A field that must be present-and-unique must also be listed in `required`.
- **Case sensitivity**: Text equality follows the default SQLite collation — case-sensitive.
- **Writes**: A duplicate create or update aborts the write; it never updates the other row. The write rejects with public code `UNIQUE_CONSTRAINT_VIOLATED` (`validation`, non-retryable) (see [Store API](./store-api.md)).
- **Migrations**: ZyncBase applies constraint changes automatically at startup, inside the startup transaction. Adding or changing a constraint is a checked change. If the new or changed constraint meets existing duplicate rows, startup fails before anything is applied and shows sample duplicates. Remove or merge the duplicates in a [migration](#schema-migrations); ZyncBase never deletes rows automatically.
- **Grammar**: `unique` entries must be non-empty arrays of existing stored user-field paths; system fields cannot be named, fields cannot repeat within one entry, and the same field set cannot be declared twice. There is no per-field `"unique": true` alias.

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

### Automatic Column Flattening

ZyncBase flattens nested objects into column names using a double underscore (`__`) separator. This enables standard SQL queries while maintaining a document-like structure for the client.

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

CREATE UNIQUE INDEX uidx__users__identity ON users(namespace_id, external_id);
CREATE UNIQUE INDEX uidx__users__created_at ON users(created_at);
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

### Nested Fields

ZyncBase flattens nested objects of any depth for querying:

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

#### Client API Usage
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
await zyncbase.set(['users', 'user-1', 'address.location.lat'], 37.8)

// Query nested fields using dot notation
const users = await zyncbase.query('users', {
  where: { 'address.location.lat': { gte: 37 } }
})
```

#### Implementation Details
- Nested fields are recursively flattened to columns using a double underscore separator: `address__location__lat`, etc.
- Base field names in the schema cannot contain `__` to prevent collisions.
- The server reconstructs the nested structure for the client on `get` and `query` operations.
- On the wire, string identifiers are replaced by numeric index mappings transparently by the SDK.

#### Capabilities
- Standard SQLite indexes operate directly on flattened columns.
- Deeply nested `store` fields support up to 1024 fields per table.
- Client applications use standard JavaScript nested objects without manual flattening.

#### Constraints
- Nested objects cannot contain arrays of objects (arrays must be at leaf positions).
- Total recursion depth is limited by the maximum fields per table (1024).
- Field names must not contain `__` (reserved for column flattening).
- `presence` fields support arbitrary nesting depth (bounded to 500 flat fields total per tier).

### Arrays

ZyncBase supports arrays with specific type constraints.

#### Primitive Arrays
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

#### Client API Usage
```typescript
await zyncbase.set('tasks.task-1', {
  tags: ["urgent", "backend"]
})
```

#### Array Normalization
- Elements must match the schema `items` primitive type.
- `null`, nested arrays, and objects are rejected.
- Arrays are normalized to sorted unique form on write.
- Reads and query equality observe this canonical sorted unique representation.

#### Unsupported: Arrays of Objects
```json
{
  "store": {
    "projects": {
      "fields": {
        "members": {
          "type": "array",
          "items": {
            "type": "object",  // Not allowed
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

**Use `bytes` for raw binary data:**
```json
{
  "avatar": { "type": "bytes", "maxLength": 65536 }
}
```
*Note: `bytes` fields store binary data as SQLite `BLOB` and map to `Uint8Array` in the TypeScript SDK. Constraints `minLength` and `maxLength` enforce byte length. `bytes` cannot be indexed (`indexed: true`), cannot be part of `unique` constraints, cannot be used inside `array` items, and cannot be used in `presence` schemas.*

---

## Schema Migrations

ZyncBase creates and evolves its SQLite tables from `schema.json`. You never write DDL. When a schema change can lose or reinterpret stored data, you write a migration: a SQL file that decides what happens to the data. ZyncBase prepares the tables, runs your SQL, checks the result, and commits it all in one transaction when the server starts.

The full contract lives in [Schema Migrations](../implementation/schema-migrations.md). This section is the developer guide.

### Generated tables

From this schema:

```json
{
  "version": "1.0.0",
  "store": {
    "tasks": {
      "fields": {
        "title": { "type": "string" },
        "status": { "type": "string", "indexed": true },
        "priority": { "type": "integer" }
      }
    }
  }
}
```

ZyncBase generates:

```sql
CREATE TABLE "tasks" (
  "id" BLOB NOT NULL CHECK(length("id") = 16),
  "namespace_id" INTEGER NOT NULL,
  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16),
  "title" TEXT,
  "status" TEXT,
  "priority" INTEGER,
  "created_at" INTEGER NOT NULL,
  "updated_at" INTEGER NOT NULL,
  PRIMARY KEY ("id")
) STRICT;
CREATE INDEX "idx__tasks__namespace" ON "tasks"("namespace_id");
CREATE INDEX "idx__tasks__owner" ON "tasks"("owner_id");
CREATE UNIQUE INDEX "uidx__tasks__created_at" ON "tasks"("created_at");
CREATE INDEX "idx__tasks__field__status" ON "tasks"("status");
```

The primary key is `id`, not `(namespace_id, id)`. Namespace-aware tables still require document IDs that are unique across the whole collection. That keeps references, cursors, caches, and SDK addressing single-key. Tables are `STRICT`: a value that can't be stored in a column's type fails the statement that wrote it.

### What happens at startup

The database remembers the schema it was last migrated to. At startup, ZyncBase compares it with `schema.json` field by field and puts every difference into one of three buckets:

| Bucket | Examples | What happens |
|---|---|---|
| Auto | Add a table, add an optional field, change `indexed`, remove a unique constraint, make a field optional, change `onDelete`, relax a constraint | Applied automatically. |
| Checked | Add a unique constraint, add a required field, make a field required, point a reference at another table, tighten `enum`/`pattern`/`format`/lengths/ranges | Applied automatically if the existing data complies. Otherwise startup stops and shows counts and sample IDs. Fix the data with a migration. |
| Migration required | Remove a field or table, change a field's type (including adding or removing `references` and changing array `items`), change `namespaced` | Startup refuses until a migration exists. The schema's major version must go up. |

Renaming is a removal plus an addition, so it needs a migration.

```
Cannot start: schema.json needs a migration.
  applied 1.4.0 (sha256:3f9a…), target 2.0.0 (sha256:b71c…)
  tasks.priority   integer -> string   migration required
  tasks.assignee   removed             migration required
Create one with: zyncbase migrate new <name>
Nothing was changed.
```

Startup is all or nothing. Either the database reaches the new schema, or it stays exactly as it was and the previous release can start against it.

### Versions

`version` must be `X.Y.Z` and must never go down. If a deployment contains a migration-required change, its major version must be higher than the version the database was on. Clients see this version, so a major bump tells them the data shape broke. Other changes have no version requirement. A minor or patch bump is a good habit.

### Writing a migration

1. Edit `schema.json`. Bump the major version if the change is migration-required.
2. Run `zyncbase migrate new priority_to_string`. This writes a folder next to your schema:

   ```
   migrations/20261117T140500Z_priority_to_string/
     before.json     generated; do not edit
     after.json      generated; do not edit
     migration.sql   yours
   ```

3. Edit `migration.sql`. The scaffold already copies every unchanged column. Each decision you need to make is a `zync_todo('…')` with a suggestion, and the migration won't run until you replace every one of them.
4. Check it with `zyncbase migrate check`, and run it against a copy of real data with `zyncbase migrate apply --dry-run --db copy.db`.
5. Commit `schema.json` and the migration folder together. The next server start applies it.

When `migration.sql` runs:

- Rebuilt tables are empty and already have the new shape. Their old rows are in `"_zync_prev_<table>"`.
- Altered tables keep their rows; new columns start as `NULL`.
- Removed tables exist only as `"_zync_prev_<table>"`.
- Every other table is already up to date, and you can read or update it.
- Foreign keys are off and cascades don't run. Integrity is checked once at the end.
- You can't run DDL, `PRAGMA`, transactions, or `ATTACH`. Use `WITH` (common table expressions) for lookup data.

After your SQL runs, every row left in `"_zync_prev_<table>"` must exist, matched by `id`, in `"<table>"`. To drop rows on purpose, delete them from `"_zync_prev_<table>"`. An `INSERT` that accidentally loses rows fails:

```
Cannot start: migration 20261117T140500Z_priority_to_string left 42 rows of "tasks" behind
  (e.g. id 0196c1f2-7a3e-7c4d-9a51-2f6b8e0d1c33).
  To drop rows on purpose, DELETE them from "_zync_prev_tasks".
Nothing was changed.
```

ZyncBase then checks unique constraints, foreign keys, types, booleans, canonical arrays, and every `enum`/`pattern`/`format`/length/range constraint on the rows you wrote, before committing.

Helper functions available in `migration.sql`:

| Function | Use |
|---|---|
| `zync_new_id()` | A new document ID for rows you create. |
| `zync_now()` | A unique, increasing microsecond timestamp for `created_at`/`updated_at` of rows you create. |
| `jsonb(zync_array(json, items))` | A canonical array value (`items` is `'string'`, `'integer'`, `'number'`, or `'boolean'`). |
| `zync_todo(message)` | Placeholder that blocks the migration until you replace it. |

### Examples

Change a type:

```sql
INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "status", "priority", "created_at", "updated_at")
SELECT "id", "namespace_id", "owner_id", "title", "status",
       CASE "priority" WHEN 1 THEN 'low' WHEN 2 THEN 'medium' ELSE 'high' END,
       "created_at", "updated_at"
FROM "_zync_prev_tasks";
```

Drop rows on purpose while rebuilding:

```sql
DELETE FROM "_zync_prev_tasks" WHERE "status" = 'archived';
INSERT INTO "tasks" (...) SELECT ... FROM "_zync_prev_tasks";
```

Remove a table, keeping recent rows elsewhere:

```sql
INSERT INTO "archive" (...) SELECT ... FROM "_zync_prev_comments" WHERE "created_at" > 1767225600000000;
DELETE FROM "_zync_prev_comments";
```

Remove duplicates before adding a unique constraint (a data-only migration; the table isn't rebuilt):

```sql
DELETE FROM "projects"
WHERE "slug" IS NOT NULL
  AND rowid NOT IN (SELECT min(rowid) FROM "projects" WHERE "slug" IS NOT NULL GROUP BY "namespace_id", "slug");
```

Backfill a new optional field:

```sql
UPDATE "posts" SET "slug" = lower(replace("title", ' ', '-')) WHERE "slug" IS NULL;
```

Turn a string field that holds document IDs into a reference: SQL can't convert the SDK's ID strings to stored IDs, so expand and contract instead.
1. Add a new optional `references` field next to the old one. This is an auto change.
2. Backfill it from your app through the SDK.
3. Remove the old field in a later migration.

### Rolling back

There are no down migrations. When `migrations.snapshot` is enabled (the default), the server writes a verified snapshot to `<dataDir>/zyncbase.db.pre-migration-<id>-<timestamp>` before a migration runs. To undo a migration, stop the server and restore that snapshot with `zyncbase restore`. Then roll back the binary, `schema.json`, and the migrations folder together. When snapshots are disabled, restore from the external restore point taken before the release.

To rework your newest migration before sharing it, edit `schema.json` and run `zyncbase migrate new <name> --amend`. This restores your local database from that migration's snapshot and regenerates the migration.

To throw away local development data instead of migrating it, run `zyncbase reset --yes`. The old database is kept as `zyncbase.db.pre-reset-<timestamp>`.

### Commands

| Command | Purpose |
|---|---|
| `zyncbase migrate status` | Applied vs target schema, pending migrations, and what the next start would do. Exits non-zero if the next start would fail. |
| `zyncbase migrate new <name> [--from <db \| schema.json>] [--amend]` | Scaffold a migration. |
| `zyncbase migrate check` | Validate every migration without a database. Suitable for CI. |
| `zyncbase migrate apply [--dry-run] [--db <file>]` | Run pending work without starting the server. With `--dry-run`, everything is rolled back and a report is printed. |
| `zyncbase reset --yes` | Start over with an empty database, keeping the old one aside. |

---

## authorization.json

Define authorization rules using the declarative JSON condition grammar. If `authorization.json` is omitted or missing, the server boots with the implicit safe public playground rules from that grammar.

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
  ],
  "actions": [
    {
      "action": "checkout",
      "invoke": { "$session.role": { "eq": "member" } },
      "register": { "$session.role": { "eq": "worker" } }
    },
    { "action": "*", "invoke": false, "register": false }
  ]
}
```

The top-level `actions` array controls action invocation (`invoke`) and worker registration (`register`) per action, with `*` as a catch-all fallback. Rules are fail-closed. Grant `register` only to trusted backend service identities: a worker receives action params and replies on the action's behalf.

### Condition Grammar

**Available variables:**
- `$session.*` - Resolved session context projected from a validated JWT or anonymous identity (e.g., `$session.userId`, `$session.tenant_id`, `$session.role`)
- `$namespace.*` - Parsed namespace parts (e.g., `$namespace.tenant_id`, `$namespace.room_id`)
- `$path` - Target table/collection name
- `$value.*` - Incoming mutation payload for set writes, or the params payload for action `invoke` rules. Increment operations are rejected when the write rule references `$value`; the delta is known before the write, but the resulting value is not.
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
