# Schema Grammar

**Drivers**: [ADR-003](../architecture/adrs.md#adr-003-configuration-first-design-zero-zig), [ADR-011](../architecture/adrs.md#adr-011-data-ownership-and-namespace-tenancy), [ADR-012](../architecture/adrs.md#adr-012-typed-array-fields-as-canonical-sorted-sets), [Storage](./storage.md), [Query Grammar](./query-grammar.md)

This document defines the schema configuration format (`schema.json`), system table behavior, validation constraints, and serialization layout for storage and wire communication.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/schema/types.zig` | Defines table, field, array, index, and validation structure models. |
| `src/schema/parse.zig` | Deserializes `schema.json`, validates naming rules, and performs dependency validation. |
| `src/schema/format.zig` | Serializes schema definitions for JSON export or remote sync payloads. |
| `src/schema/system.zig` | Injects implicit system tables (e.g. `users`) and implicit presence models. |
| `src/ddl_generator.zig` | Translates the parsed schema state into relational SQLite `CREATE TABLE` and `CREATE INDEX` queries. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `Schema` | `Table` map, `PresenceSchema` | Root runtime schema context. |
| `Table` | `Field` map, required field list | Metadata for a persistent collection (e.g. `namespaced` state). |
| `Field` | type enum, constraints | Metadata for a table column, foreign keys, and indices. |
| `PresenceSchema` | user field map, shared field map | Typed ephemeral presence layout definitions. |

---

## Table & Field Properties Reference

### Table Properties

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `fields` | `object` | - | Map of field names to field definitions. |
| `required` | `array<string>` | `[]` | List of required field names (supports dot notation for nested fields). |
| `namespaced` | `boolean` | `true` | If `true`, rows are scoped to the active namespace. If `false`, rows are stored globally under namespace ID `0`. |

### Field Properties

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `type` | `string` | - | **Required.** One of: `string`, `integer`, `number`, `boolean`, `array`, `object`. |
| `indexed` | `boolean` | `false` | Creates a database index for this column. |
| `references` | `string` | `null` | Target table name for foreign key reference. Stored as `BLOB(16)` internally. |
| `onDelete` | `string` | `"restrict"` | Foreign key delete rule: `set_null`, `cascade`, `restrict`. |
| `items` | `string` | - | **Required for `array` type.** Primitive element type (e.g., `"string"`, `"integer"`). |
| `fields` | `object` | - | **Required for `object` type.** Map of sub-fields (arbitrary nesting allowed). |

---

## Supported Field Types

| JSON Type | SQLite Storage Type | Flattening Behavior | Description |
|:---|:---:|:---|:---|
| `string` | `TEXT` | Flat column | UTF-8 string value. |
| `integer` | `INTEGER` | Flat column | 64-bit signed integer value. |
| `number` | `REAL` | Flat column | 64-bit floating point value. |
| `boolean` | `INTEGER` | Flat column | Boolean value (stored as 0 or 1). |
| `array` | `BLOB` | Flat column | Persistent canonical sorted-set representation. |
| `object` | (None) | Flat columns | Nested variables are flattened using `__` separator. |

---

## System Table: `users`

The `users` collection is a special, hybrid system table:
- **Scope**: Defaults to `"namespaced": false` (stored globally under namespace ID `0`).
- **Implicit Columns**:
  - `id`: `BLOB(16)` UUIDv7 (Primary Key).
  - `external_id`: `TEXT` (maps external subjects/anonymous subjects).
  - `owner_id`: Always equal to `id`.
- **Single-Namespace Constraint**: If `users` is configured with `"namespaced": true`, the first `SetNamespace` binds the connection to a single namespace. Changing namespaces is rejected with `NAMESPACE_SWITCH_REJECTED`.
- **Identity Resolver**: Creating a scoped session auto-upserts the identity mapping, generating a UUIDv7 user row if missing.

```json
{
  "users": {
    "namespaced": false,
    "fields": {}
  }
}
```

---

## Naming & Storage Invariants

- **Table/Field Identifiers**: Must match `[A-Za-z][A-Za-z0-9_]*`.
- **Flat Mapping**: Nested objects are flattened into database columns using double-underscore `__` separator bounds (e.g., `profile__userId`).
- **Reserved Prefixes**: Namespaces starting with `_zync_` are reserved for internal database systems. Identifier keys must not contain `__`.
- **Built-in Columns**: Every table implicitly includes `id` (`BLOB(16)`), `namespace_id` (`INTEGER`), `owner_id` (`BLOB(16)`), `created_at` (`INTEGER`), and `updated_at` (`INTEGER`).

---

## Typed Arrays (Canonical Sorted Sets)

- Fields of type `array` require a primitive type declaration via `items`.
- Nested arrays or nested objects within arrays are prohibited.
- Arrays are serialized and stored as unique, sorted arrays. Reads return this canonical representation.

---

## Presence Schema

### Presence Root

| Key | Type | Description |
|:---|:---:|:---|
| `user` | `object` | Map of presence fields owned per connected user. |
| `shared` | `object` | Map of namespace-level shared presence fields. |

### Presence Field Validation Keywords

Presence fields support validation keywords:

| Keyword | Applicable Types | Description |
|:---|:---:|:---|
| `enum` | `string`, `integer` | Restricts values to allowed list. |
| `pattern` | `string` | Regex validation. |
| `minLength` / `maxLength` | `string` | Character bounds. |
| `minimum` / `maximum` | `integer`, `number` | Numeric bounds. |

### Implicit Presence Schema Layout

If `presence` is omitted from `schema.json`, the server synthesizes the following layout:

```json
{
  "presence": {
    "user": {
      "status": { "type": "string", "enum": ["active", "idle", "away"] }
    },
    "shared": {}
  }
}
```

### Wire Index Derivation

At boot, the server flattens presence definitions to index arrays sent to clients via `SchemaSync`:

| Phase | Target | Iteration / Rule | Output |
|:---|:---|:---|:---|
| **Phase 1** | `presence.user` | Recursively iterates keys in definition order. Object sub-fields are joined with `__`. | Array `presenceUserFields[]`. (Position = Wire Index). |
| **Phase 2** | `presence.shared` | Recursively iterates keys in definition order. Object sub-fields are joined with `__`. | Array `presenceSharedFields[]`. (Position = Wire Index). |

---

## Supported Validation Constraints

ZyncBase parses and enforces the following JSON schema validation properties on the write path:

| Constraint Key | Applicable Field Types | Description / Validation Behaviour |
|:---|:---:|:---|
| `enum` | `string`, `integer` | Restricts values to a fixed list of allowed options. |
| `pattern` | `string` | Regex pattern matching check. |
| `format` | `string` | Predefined validation formats (e.g. `email`, `uuid`, `ipv4`). |
| `minLength` | `string` | Minimum character length constraints. |
| `maxLength` | `string` | Maximum character length constraints. |
| `minimum` | `integer`, `number` | Minimum numeric value bounds (inclusive). |
| `maximum` | `integer`, `number` | Maximum numeric value bounds (inclusive). |

---

## See Also

- [Error Taxonomy](./error-taxonomy.md)
- [Storage](./storage.md)
- [Query Grammar](./query-grammar.md)
