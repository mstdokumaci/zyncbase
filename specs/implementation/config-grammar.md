# Configuration Grammar

**Drivers**: [ADR-003](../architecture/adrs.md#adr-003-configuration-first-design-zero-zig), [Security](./security.md), [Memory Strategy](./memory-strategy.md)

This document defines the schema, properties, and constraints for the server runtime configuration (`zyncbase-config.json`).

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/config_loader.zig` | Loads JSON configurations, interpolates environment variables, and validates settings. |
| `src/config_loader_test.zig` | Verifies default values, validation ranges, and environment replacements. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `Config` | `ServerConfig`, `AuthConfig`, `SecurityConfig`, `LoggingConfig`, `PerformanceConfig` | Root configuration structure representing the complete JSON layout. |
| `ServerConfig` | none | Host, port, and interface binding parameters. |
| `AuthConfig` | `jwt` config keys | JWT signature algorithms, issuer, audience, and grace periods. |
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
| `environment` | `string` | `"development"` | Server environment mode (`development`, `production`). |

### `server` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `port` | `number` | `3000` | Port to bind (1-65535). |
| `host` | `string` | `"0.0.0.0"` | Bind address host interface. |

### `authentication` Settings

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `jwt.secret` | `string` | `null` | Key for HMAC tokens (`HS256`, `HS384`, `HS512`). Supports env variables. |
| `jwt.algorithm` | `string` | `"HS256"` | Supported signature checking: `HS256`, `HS384`, `HS512`, `RS256`. |
| `jwt.issuer` | `string` | `null` | Validates `iss` claim on incoming JWTs if specified. |
| `jwt.audience` | `string` | `null` | Validates `aud` claim on incoming JWTs if specified. |
| `session.tokenGracePeriodSeconds`| `number` | `30` | Grace period (in seconds) allowed after token expiry before WS close. |

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
- **Strictness**: Unknown keys at the top level or within section objects will be ignored with a logged warning.
- **Unit Defaults**: All duration/timeout parameters are parsed in milliseconds unless explicitly noted.
- **Variable Substitution**: String values support environment variable injection via `${VAR_NAME}` syntax.

---

## Validation & Failure Behavior

Validation checks occur during server bootstrap in `validateConfig`:
- Port range checks (1-65535).
- Capacity, buffer size, and batch boundary checks (must be > 0).
- Directory write capability checks on `dataDir`.
- Missing or unreadable configuration files fail bootstrap immediately.
- Specific config error codes are detailed in [Error Taxonomy](./error-taxonomy.md).

---

## See Also

- [Security](./security.md)
- [Error Taxonomy](./error-taxonomy.md)
- [Auth System](./auth-system.md)
