# Configuration Grammar

**Drivers**: [ADR-003](../architecture/adrs.md#adr-003-configuration-first-design-zero-zig), [Security](./security.md), [Memory Strategy](./memory-strategy.md)

This document defines the schema, properties, and constraints for the server runtime configuration (`zyncbase-config.json`).

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/config_loader.zig` | Loads JSON configuration files, expands environment variables in strings, applies defaults, and validates settings. |
| `src/config_loader_test.zig` | Verifies default values, validation ranges, and environment replacements. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `Config` | `ServerConfig`, `AuthConfig`, `SecurityConfig`, `LoggingConfig`, `PerformanceConfig` | Root configuration structure representing the complete JSON layout. |
| `ServerConfig` | none | Host, port, and interface binding parameters. |
| `AuthConfig` | `jwt`, `ticket`, `anonymous`, `session` config keys | JWT validation, ticket exchange, anonymous-auth, projected claims, and token grace periods. |
| `SecurityConfig` | none | Allowed origins, rate limiting bounds, message caps, and violation thresholds. |
| `LoggingConfig` | none | Output format (JSON/text) and minimum log level threshold. |
| `PerformanceConfig` | none | Ring buffer sizes, SQL statement cache capacities, and write-batching parameters. |

---

## Configuration Property Reference

### Root Level Settings

| Key | Type | Default | Description / Validation |
|:---|:---:|:---|:---|
| `server` | `object` | `{}` | Network and port settings object. |
| `authentication` | `object` | `{}` | Token settings object. |
| `security` | `object` | `{}` | Access control and rate limits object. |
| `logging` | `object` | `{}` | Log verbosity and format settings object. |
| `performance` | `object` | `{}` | Internal tuning configurations object. |
| `dataDir` | `string` | `"./data"` | Directory path for persistence (SQLite, WAL). Supports env expansion. |
| `schema` | `string \| object` | `"./schema.json"` | Path to schema JSON or inline schema object. If missing, runs with users-only schema. |
| `authorization` | `string` | `null` | Path to `authorization.json` file. If missing, runs with playground default. |

### `server` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `port` | `number` | `3000` | Port to bind (1-65535). |
| `host` | `string` | `"0.0.0.0"` | Bind address host interface. |

### `authentication.jwt` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `secret` | `string` | `null` | Key for HMAC tokens (`HS256`, `HS384`, `HS512`). Supports env variables. |
| `algorithm` | `string` | `"HS256"` | Supported signature checking: `HS256`, `HS384`, `HS512`, `RS256`. |
| `issuer` | `string` | `null` | Validates `iss` claim on incoming JWTs if specified. |
| `audience` | `string` | `null` | Validates `aud` claim on incoming JWTs if specified. |
| `jwksUrl` | `string` | `null` | JWKS endpoint used by RSA validation and periodic refresh. |
| `subjectClaim` | `string` | `"sub"` | Claim used as the external subject. |

### `authentication.ticket` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `secret` | `string` | `null` | 32-byte ticket signing secret. If omitted, a runtime secret is generated. |
| `ttlSeconds` | `number` | `60` | Short-lived WebSocket ticket lifetime. |

### `authentication.anonymous` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `enabled` | `boolean` | `false` | Allows anonymous subjects through the HTTP ticket exchange. |
| `subjectPrefix` | `string` | `"anon:"` | Required prefix for anonymous subjects. |

### `authentication.session` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `claims` | `object<string,string>` | `{}` | Maps JWT claim names to `$session` variable names. |
| `tokenGracePeriodSeconds` | `number` | `30` | Grace period allowed after token expiry before WebSocket close. |

### `security` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `allowedOrigins` | `array<string>` | `[]` | CORS `Access-Control-Allow-Origin` permitted patterns. |
| `allowLocalhost` | `boolean` | `true` | Explicitly permits client connections from `localhost` / `127.0.0.1`. |
| `maxMessagesPerSecond` | `number` | `100` | Hard cap on messages allowed per connection per second. |
| `maxConnections` | `number` | `100000` | Hard cap on global simultaneous active connections. |
| `maxMessageSize` | `number` | `1048576` | Hard cap on single WebSocket message payload size (in bytes). |
| `violationThreshold` | `number` | `10` | Number of security violations before triggering temporary IP ban. |

### `logging` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `level` | `string` | `"info"` | Log level output cutoff: `debug`, `info`, `warn`, `error`. |
| `format` | `string` | `"json"` | Console output serialization: `json` or `text`. |

### `performance` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `messageBufferSize` | `number` | `1000` | Capacity size of message-routing ring buffers. |
| `batchWrites` | `boolean` | `true` | Enables grouping multiple writes into single database transactions. |
| `batchSize` | `number` | `200` | Max number of writes processed in a single transaction. |
| `batchTimeout` | `number` | `10` | Write batch window collection delay timeout (in ms). |
| `statementCacheSize` | `number` | `100` | Max number of prepared statements cached per SQLite connection. |

---

## Configuration Invariants

- **Format**: Valid JSON.
- **Strictness**: Config loading is permissive; unknown top-level and section keys are ignored by the loader helpers rather than rejected.
- **Unit Defaults**: All duration/timeout parameters are parsed in milliseconds unless explicitly noted.
- **Variable Substitution**: String values support environment variable injection via `${VAR_NAME}` syntax.

---

## Validation & Failure Behavior

Validation checks occur during server bootstrap in `validateConfig`:
- Port range checks (1-65535).
- Capacity, buffer size, and batch boundary checks (must be > 0).
- Directory write capability checks on `dataDir`.
- Missing config file path loads defaults. Missing schema file falls back to the implicit users-only schema. A configured authorization file must be readable; if omitted, the implicit playground rules are used.
- Specific config error codes are detailed in [Error Taxonomy](./error-taxonomy.md).

---

## See Also

- [Security](./security.md)
- [Error Taxonomy](./error-taxonomy.md)
- [Auth System](./auth-system.md)
