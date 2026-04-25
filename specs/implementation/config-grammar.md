# ZyncBase Configuration Grammar

This document defines the formal grammar and property specification for `zyncbase-config.json`.

## General Rules

1. **Format**: Valid JSON.
2. **Units**: All duration/timeout values are expressed in **milliseconds** unless otherwise specified.
3. **Environment Variables**: Values of type `string` support environment variable substitution using the `${VAR_NAME}` syntax.
4. **Strictness**: Unknown keys at the top level or within section objects will be ignored (with a warning in logs).

---

## Properties Reference

### Root Level

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `server` | `object` | `{}` | Network and connection settings. |
| `authentication` | `object` | `{}` | Identity and access tokens. |
| `security` | `object` | `{}` | Access control and rate limiting. |
| `logging` | `object` | `{}` | Log verbosity and formatting. |
| `performance` | `object` | `{}` | Tuning for throughput and latency. |
| `dataDir` | `string` | `"./data"` | Directory for persistence (SQLite, WAL). |
| `schema` | `string \| object` | `"./schema.json"` | Path to schema file or schema config object. |
| `authorization` | `string` | `null` | `[PLANNED]` Path to `authorization.json`. If omitted or the file is missing, the server boots with the safe implicit public playground rules defined in `auth-grammar.md`. |
| `environment` | `string` | `"development"` | `[PLANNED]` Engine mode (`development`, `production`). |

---

### `server`

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `port` | `number` | `3000` | Port to listen on (1-65535). |
| `host` | `string` | `"0.0.0.0"` | Bind address. |

---

### `authentication`

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `jwt.secret` | `string` | `null` | Secret key for HS256/HS384/HS512. |
| `jwt.algorithm` | `string` | `"HS256"` | Supported: `HS256`, `HS384`, `HS512`, `RS256`. |
| `jwt.issuer` | `string` | `null` | Validates `iss` claim if present. |
| `jwt.audience` | `string` | `null` | Validates `aud` claim if present. |

---

### `security`

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `allowedOrigins` | `array<string>` | `[]` | CORS `Access-Control-Allow-Origin` list. |
| `allowLocalhost` | `boolean` | `true` | Always allow connections from local loopback. |
| `maxMessagesPerSecond` | `number` | `100` | Max messages per connection per second. |
| `maxConnectionsPerIP` | `number` | `10` | Max simultaneous connections per IP. |
| `maxMessageSize` | `number` | `1048576` | Max size of a single WebSocket message (bytes). |
| `violationThreshold` | `number` | `10` | Number of security violations before IP ban. |

---

### `logging`

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `level` | `string` | `"info"` | `debug`, `info`, `warn`, `error`. |
| `format` | `string` | `"json"` | `json`, `text`. |

---

### `performance`

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `messageBufferSize` | `number` | `1000` | Size of internal ring buffer for routing. |
| `batchWrites` | `boolean` | `true` | Group multiple writes into single transactions. |
| `batchTimeout` | `number` | `10` | Wait time for batching (ms). |
| `statementCacheSize` | `number` | `100` | Max number of prepared statements to keep in cache per connection. |

---

## Validation & Errors

The following checks are performed during `validateConfig`:

| Error | Condition |
|:---|:---|
| `InvalidPort` | Port is 0 or > 65535. |
| `InvalidDataDir` | Parent directory relative to `dataDir` does not exist or is not writable. |
| `InvalidSchemaFile` | `schema` path is empty. |
| `SchemaFileNotFound` | Specified schema file does not exist. |
| `InvalidAuthorizationFile` | Specified `authorization` file exists but cannot be parsed or fails authorization grammar validation. |
| `InvalidBufferSize` | `messageBufferSize` is 0. |
| `InvalidMaxMessageSize` | `maxMessageSize` is 0. |
