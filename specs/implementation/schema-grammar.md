# Schema Grammar

**Drivers**: [ADR-003](../architecture/adrs.md#adr-003-configuration-first-design-zero-zig), [ADR-011](../architecture/adrs.md#adr-011-data-ownership-and-namespace-tenancy), [ADR-012](../architecture/adrs.md#adr-012-typed-array-fields-as-canonical-sorted-sets), [Storage](./storage.md), [Query Grammar](./query-grammar.md)

This document defines the schema configuration format (`schema.json`), system table behavior, accepted metadata keys, and serialization layout for storage and wire communication.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/schema/types.zig` | Defines table, field, array, index, and validation structure models. |
| `src/schema/parse.zig` | Deserializes `schema.json`, validates naming rules, and performs dependency validation. |
| `src/schema/format.zig` | Serializes schema definitions for JSON export or remote sync payloads. |
| `src/schema/system.zig` | Injects implicit system tables (e.g. `users`) and implicit presence models. |
| `src/schema/index.zig` | Builds dense table/field lookup maps used by storage and wire dictionaries. |
| `src/schema/field_path.zig` | Normalizes dotted paths and nested field names to flat column names. |
| `src/sql/ddl.zig` | Translates parsed schema state into relational SQLite `CREATE TABLE` and `CREATE INDEX` queries. |
| `src/sql/build.zig`, `src/sql/buf.zig` | SQL fragment builders and quoting helpers shared by storage. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `Schema` | `Table` map, `PresenceSchema` | Root runtime schema context. |
| `Table` | `Field` map, required field list | Metadata for a persistent collection (e.g. `namespaced` state). |
| `Field` | type enum, metadata | Metadata for a table column, foreign keys, array element type, and indices. |
| `PresenceSchema` | user field map, shared field map | Typed ephemeral presence layout definitions. |
| `SchemaIndex` | table and field maps | Dense lookup structure used by integer wire routing and query parsing. |

---

## Root Schema Properties

Schema configuration is rooted, not a bare table map:

| Key | Type | Required | Description |
|:---|:---:|:---:|:---|
| `version` | `string` | yes | Schema version string. |
| `store` | `object` | yes | Map of table names to table definitions. |
| `presence` | `object` | no | User/shared presence field definitions. If omitted, a minimal implicit presence schema is synthesized. |
| `metadata` | `object` | no | Preserved schema metadata for operators/tools. |

`Config.schema` may be either an inline object with this shape or a string path to a JSON file with this shape.

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
| `indexed` | `boolean` | `false` | Creates a database index for this column. Reference fields are indexed regardless of this setting. |
| `references` | `string` | `null` | Target table name for an immediately enforced foreign key to that table's `id`. Stored as `BLOB(16)` internally. |
| `onDelete` | `string` | `"restrict"` | Enforced delete rule: `set_null`, `cascade`, or `restrict`. `set_null` is invalid for required fields. |
| `items` | `string` | - | **Required for `array` type.** Primitive element type (e.g., `"string"`, `"integer"`). |
| `fields` | `object` | - | **Required for `object` type.** Map of sub-fields (arbitrary nesting allowed). |
| `metadata` | `object` | `null` | Preserved field metadata for tooling and generated clients. |
| `enum`, `pattern`, `format`, `minLength`, `maxLength`, `minimum`, `maximum` | mixed | `null` | Accepted as reserved validation keywords by the parser, but not represented in runtime `Field` state or enforced on writes. |

---

## Supported Field Types

| JSON Type | SQLite Storage Type | Flattening Behavior | Description |
|:---|:---:|:---|:---|
| `string` | `TEXT` | Flat column | UTF-8 string value. |
| `integer` | `INTEGER` | Flat column | 64-bit signed integer value. |
| `number` | `REAL` | Flat column | 64-bit floating point value. |
| `boolean` | `INTEGER` | Flat column | Boolean value (stored as 0 or 1). |
| `array` | `BLOB` | Flat column | Persistent canonical sorted-set representation. |
| `object` | (None) | Flat columns | Parser-only container. Nested leaves are flattened using `__` separator. |

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
  "version": "1.0.0",
  "store": {
    "users": {
      "namespaced": false,
      "fields": {}
    }
  }
}
```

---

## Naming & Storage Invariants

- **Table/Field Identifiers**: Must match `[A-Za-z][A-Za-z0-9_]*`.
- **Flat Mapping**: Nested objects are flattened into database columns using double-underscore `__` separators (e.g., `profile__userId`).
- **Reserved Prefixes**: Namespaces starting with `_zync_` are reserved for internal database systems. Identifier keys must not contain `__`.
- **Built-in Columns**: Every table implicitly includes `id` (`BLOB(16)`), `namespace_id` (`INTEGER`), `owner_id` (`BLOB(16)`), `created_at` (`INTEGER`), and `updated_at` (`INTEGER`).
- **Field Limit**: Each table supports a maximum of 1024 fields (including flattened nested fields, excluding system columns).

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

### Implicit Presence Schema Layout

If `presence` is omitted from `schema.json`, the server synthesizes the following layout:

```json
{
  "presence": {
    "user": {
      "status": { "type": "string" }
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

## Metadata and Reserved Validation Keywords

`metadata` objects are preserved at schema, table, and field boundaries for generated clients and operator tooling.

The parser accepts validation-key names (`enum`, `pattern`, `format`, `minLength`, `maxLength`, `minimum`, `maximum`) so schema files can reserve future constraints without tripping unknown-key rejection. The current runtime write path enforces structural type compatibility, required fields, references, arrays, and system-column rules; it does not enforce these validation keywords.

Reference values may be `null` when the field is optional. Non-null values must identify an existing row in the referenced table; failed writes and restricted deletes use the public `SCHEMA_VALIDATION_FAILED` error contract. References are ID-based and may cross namespaces because document IDs are table-wide primary keys. Foreign keys are immediate, so a batch must create a parent before a child that references it. `ON UPDATE` actions and deferred constraints are not supported.

---

## Related Specifications

- [Error Taxonomy](./error-taxonomy.md)
- [Storage](./storage.md)
- [Query Grammar](./query-grammar.md)
