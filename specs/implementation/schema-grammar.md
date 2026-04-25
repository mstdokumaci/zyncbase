# ZyncBase Schema Grammar

This document defines the formal grammar and property specification for `schema.json`.

## Root Structure

| Key | Type | Description |
|:---|:---:|:---|
| `version` | `string` | Semver version of the schema (`MAJOR.MINOR.PATCH`). `[PLANNED]` migration logic. |
| `store` | `object` | Map of table names to table definitions. |

---

## Table Definition

| Key | Type | Description |
|:---|:---:|:---|
| `fields` | `object` | Map of field names to field definitions. |
| `required` | `array<string>` | List of required field names (supports dot notation for nested fields). |
| `namespaced` | `boolean` | If `true` (default), the table is partitioned by namespaces. If `false`, the table transcends namespaces (global master data). The `users` collection defaults to `false`. |

### Table Name Constraints

- Must be a valid JSON key.
- Must match the SQL-safe identifier pattern `[A-Za-z][A-Za-z0-9_]*`.
- Must not contain `__`.
- Must not start with `_zync_`; that prefix is reserved for internal system tables.
- The name `users` is reserved for the hybrid system collection.
- SQLite reserved keywords are allowed because ZyncBase quotes identifiers in generated SQL.

### Reserved System Collections

#### `users`
The `users` collection is a special hybrid system table. It is always present in the database to map external identity claims (e.g., Auth0 `sub`) to internal `BLOB(16)` UUIDv7s, ensuring `owner_id` on all tables remains a compact binary format.

**Implicit JSON:**
```json
{
  "users": {
    "namespaced": false,
    "fields": {}
  }
}
```

- **Implicitly Global:** It defaults to `"namespaced": false`.
- **Special Columns:** It possesses an implicitly created `external_id` (`TEXT UNIQUE`) column. Its `id` column is a standard `BLOB(16)` UUIDv7. It completely omits the `namespace_id` and `owner_id` columns.
- **Auto-Upsert:** When a WebSocket authenticates, Zig automatically looks up the JWT's `sub` in `external_id`, generating a new UUIDv7 row if missing. This ensures any relational Foreign Keys to `users.id` are always satisfied.
- **Extensible:** You can define `users` in your `schema.json` to append custom fields (like `avatar` or `language`). If omitted entirely, the engine treats it as the implicit JSON above.

---

## Field Definition

A field definition MUST contain a `type` property.

### Field Name Constraints

- Must match the SQL-safe identifier pattern `[A-Za-z][A-Za-z0-9_]*`.
- Must not contain `__`; this separator is reserved for flattened nested object paths.
- Must not use reserved system field names: `id`, `namespace_id`, `owner_id`, `created_at`, `updated_at`.

### Supported Types

| Type | SQLite Mapping | Description |
|:---|:---:|:---|
| `string` | `TEXT` | UTF-8 text string. |
| `integer` | `INTEGER` | 64-bit signed integer. |
| `number` | `REAL` | 64-bit floating point number. |
| `boolean` | `INTEGER` | Boolean (0 or 1). |
| `array` | `BLOB` | Stored as a canonical JSON array (sorted, unique, primitive-typed via `items`). |
| `object` | (Flattened) | Logical grouping of fields. |

### Shared Properties

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `type` | `string` | - | One of the types listed above. |
| `indexed` | `boolean` | `false` | Creates a SQLite index for this column. |
| `references` | `string` | `null` | Target table name for a foreign key relationship. Referenced fields are stored internally as packed `doc_id` values (`BLOB(16)`), while the SDK still exposes them as strings. |
| `onDelete` | `string` | `"restrict"` | `set_null`, `cascade`, `restrict`. Note: `set_null` requires the field to be optional (not in `required`). |

### Array Properties

A field with `type: "array"` MUST contain an `items` property.

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `items` | `string` | - | Type of items within the array (must be a primitive type). |

### Array Semantics (Canonical Sorted Set)

For any field with `type: "array"`, ZyncBase enforces canonical sorted-set behavior:

- Elements MUST match the primitive type declared by `items`.
- `null` array elements are rejected.
- Nested arrays and objects are rejected (`INVALID_ARRAY_ELEMENT`).
- On write, arrays are normalized to sorted unique form.
- Reads return this canonical sorted unique representation.

---

## Nested Objects & Flattening

ZyncBase uses a **flat relational storage engine**. Nested objects are logically grouped in the schema but flattened in the database.

- **Separator**: `__` (double underscore).
- **Naming Restriction**: Field names must match `[A-Za-z][A-Za-z0-9_]*`, cannot contain `__`, and cannot use reserved system field names.
- **Recursion**: Unlimited depth is supported for `object` types with their own `fields` property.

Example:
```json
"profile": {
    "type": "object",
    "fields": {
        "userId": { "type": "string" }
    }
}
```
Flattens to SQLite column: `profile__userId TEXT`.

> *Note: On the wire, these flattened string names are fully bypassed. The SDK maps them transparently into integer `field_index` routing payloads.*

> *System Columns*: Every table automatically includes five built-in system columns:
> - `id`: Stored internally as `BLOB(16)` and transmitted over the wire as MessagePack `bin(16)`. The SDK converts user-facing string IDs (UUIDv7) to this representation.
> - `namespace_id`: Stored as `INTEGER` (a logical foreign key to the internal `_zync_namespaces` table) to guarantee flat, isolated multi-tenancy.
> - `owner_id`: Stored as `TEXT`. Automatically populated by the server with `$session.userId` upon document creation.
> - `created_at` & `updated_at`: Stored as `INTEGER` timestamps.

---

## Validation Constraints (`[PLANNED]`)

The following properties are part of the north star spec but are currently **ignored** by the implementation:

| Key | Applicable Types | Description |
|:---|:---:|:---|
| `enum` | `string`, `integer` | List of allowed values. |
| `pattern` | `string` | Regex pattern validation. |
| `format` | `string` | Known formats (`email`, `uuid`, `ipv4`). |
| `minLength` | `string` | Minimum character length. |
| `maxLength` | `string` | Maximum character length. |
| `minimum` | `integer`, `number` | Minimum numeric value. |
| `maximum` | `integer`, `number` | Maximum numeric value. |

---

## Error Catalog

The following errors are returned by `SchemaParser`:

| Error | Condition |
|:---|:---|
| `InvalidSchema` | File is not a valid JSON object. |
| `MissingVersion` | `version` key is missing. |
| `InvalidVersion` | `version` is not a string. |
| `MissingStore` | `store` key is missing. |
| `InvalidStore` | `store` is not an object. |
| `InvalidTableName` | Table name is empty, starts with a non-letter, contains a non-alphanumeric/non-underscore character, or contains `__`. |
| `InvalidTableDefinition` | A table value in `store` is not an object. |
| `MissingFieldType` | A field definition lacks the `type` property. |
| `InvalidFieldDefinition` | A field value is not an object. |
| `InvalidFieldType` | `type` value is not a string. |
| `InvalidFieldName` | Field name is empty, starts with a non-letter, contains a non-alphanumeric/non-underscore character, or contains `__`. |
| `UnknownFieldType` | `type` string is not recognized. |
| `InvalidOnDelete` | `onDelete` value is not one of `cascade`, `restrict`, `set_null`; or `set_null` is used on a `required` field. |
| `MissingArrayItems` | `items` property is missing for an `array` field. |
| `InvalidArrayItems` | `items` value is not a string. |
| `UnsupportedArrayItemsType` | `items` type is not one of the allowed primitive types. |
