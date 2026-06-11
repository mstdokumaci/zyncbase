# ZyncBase Schema Grammar

This document defines the formal grammar and property specification for `schema.json`.

## Root Structure

| Key | Type | Description |
|:---|:---:|:---|
| `version` | `string` | Semver version of the schema (`MAJOR.MINOR.PATCH`). |
| `store` | `object` | Map of table names to table definitions. |
| `presence` | `object` | Optional. Typed ephemeral presence field definitions. When absent, the server synthesizes an implicit minimal schema (see [Implicit Presence Schema](#implicit-presence-schema)). Contains `user` and/or `shared` keys. |

---

## Table Definition

| Key | Type | Description |
|:---|:---:|:---|
| `fields` | `object` | Map of field names to field definitions. |
| `required` | `array<string>` | List of required field names (supports dot notation for nested fields). |
| `namespaced` | `boolean` | If `true` (default), rows are scoped to the active namespace. If `false`, rows are stored under reserved global namespace ID `0` and are visible across namespaces. The `users` collection defaults to `false`. |

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

- **Implicitly Global:** It defaults to `"namespaced": false`, which stores rows under reserved global namespace ID `0`.
- **Special Columns:** It possesses an implicitly created `external_id` (`TEXT`) column. Its `id` column is a standard `BLOB(16)` UUIDv7, and its `owner_id` column is always equal to `id`.
- **Identity Key:** The identity mapping is unique by `(namespace_id, external_id)`. With the default global mode this is effectively global uniqueness; with `"namespaced": true`, the same external identity string may resolve to different internal users in different namespaces.
- **Auto-Upsert:** When a scoped session is established, Zig resolves the external identity string through `external_id`, generating a new UUIDv7 row if missing. Anonymous SDK client IDs and authenticated JWT subjects use the same resolver. This ensures `owner_id`, presence `userId`, and any relational foreign keys to `users.id` always reference persisted user rows.
- **Namespaced Users:** If `users` is configured with `"namespaced": true`, identity resolution uses the namespace ID of the scope being established. Store and presence scopes may resolve to different internal user IDs when their namespaces differ. Namespace switching requires re-resolving the affected scope before operations in that scope are accepted.
- **Session Gate:** Store and presence operations require a ready scoped session. Before namespace and user resolution complete, only lifecycle messages such as auth refresh, namespace selection, ping/pong, and close are valid.
- **Extensible:** You can define `users` in your `schema.json` to append optional custom fields (like `avatar` or `language`). Custom `users` fields cannot be listed in `required`, because identity rows are auto-created before profile data exists. If omitted entirely, the engine treats it as the implicit JSON above.

---

## Field Definition

A field definition MUST contain a `type` property.

### Field Name Constraints

- Must match the SQL-safe identifier pattern `[A-Za-z][A-Za-z0-9_]*`.
- Must not contain `__`; this separator is reserved for flattened nested object paths.
- Must not use reserved system field names: `id`, `namespace_id`, `owner_id`, `created_at`, `updated_at`.
- In the `users` collection, must not use `external_id`; it is reserved for identity-provider subject mapping.

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
- **Recursion**: Unlimited depth is supported for `object` types within `store` field definitions. For `presence` field definitions, **only one level of nesting is permitted** (e.g., `cursor: { x, y }` is valid; `cursor: { pos: { x, y } }` is rejected at startup).

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

> *System Columns*: Every storage table automatically includes five built-in system columns:
> - `id`: Stored internally as `BLOB(16)` and transmitted over the wire as MessagePack `bin(16)`. The SDK converts user-facing string IDs (UUIDv7) to this representation. It is the collection-wide document identity (`PRIMARY KEY(id)`); `namespace_id` is not part of the document key.
> - `namespace_id`: Stored as `INTEGER` (a logical foreign key to the internal `_zync_namespaces` table). Namespaced tables use the active namespace ID; global tables (`"namespaced": false`) use reserved global namespace ID `0`.
> - `owner_id`: Stored internally as `BLOB(16)`. Automatically populated by the server with `$session.userId` upon document creation. For `users`, `owner_id` is equal to `id`.
> - `created_at` & `updated_at`: Stored as `INTEGER` timestamps.

---

## Presence Grammar (`presence`)

The optional `presence` top-level key defines typed ephemeral presence fields. When present, it MUST contain at least a `user` key. The `shared` key is optional.

### Presence Root

| Key | Type | Description |
|:---|:---:|:---|
| `user` | `object` | Map of presence field names to presence field definitions. Fields owned per connected user. |
| `shared` | `object` | Optional. Map of shared field names to presence field definitions. Namespace-level state. |

### Presence Field Definition

Presence fields support a subset of the store field grammar:

| Property | Applicable Types | Description |
|:---|:---:|:---|
| `type` | all | **Required.** One of: `string`, `integer`, `number`, `boolean`, `object`. |
| `fields` | `object` | **Required for `object` type.** Map of sub-field names to scalar field definitions. Max one level of nesting. |
| `enum` | `string`, `integer` | List of allowed values. |
| `pattern` | `string` | Regex pattern validation. |
| `minLength` | `string` | Minimum character length. |
| `maxLength` | `string` | Maximum character length. |
| `minimum` | `integer`, `number` | Minimum numeric value. |
| `maximum` | `integer`, `number` | Maximum numeric value. |

Presence fields do NOT support: `indexed`, `references`, `onDelete`, `items` (no array fields), or `required` (presence is always a merge — no field is mandatory).

### Presence Definition

| Key | Type | Description |
|:---|:---:|:---|
| `user` | `object` | Required when `presence` is explicitly defined. Map of user-owned ephemeral field definitions. One record per connected user per namespace. |
| `shared` | `object` | Optional. Map of namespace-level ephemeral field definitions. One record for the entire namespace. |

#### Presence Field Name Constraints

- Must match the SQL-safe identifier pattern `[A-Za-z][A-Za-z0-9_]*`.
- Must not contain `__`; this separator is reserved for flattened nested object paths.
- Must not use reserved system field names: `id`, `namespace_id`, `created_at`, `updated_at`.

#### Presence Nesting

One level of `object` nesting is supported. Sub-fields within an `object` are flattened using the `__` separator for wire encoding (`cursor: { x, y }` → `cursor__x`, `cursor__y`). Deeper nesting (an `object` containing another `object`) is rejected at server startup.

### Implicit Presence Schema

When the `presence` key is absent from `schema.json`, the server synthesizes a minimal implicit schema:

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

This produces `presenceUserFields: ["status"]` and `presenceSharedFields: []` in the `SchemaSync` message. Presence is always usable — developers can call `presence.set({ status: "active" })` immediately without defining any schema. The implicit schema provides a useful default for the most common presence use case (online/offline status).

Defining an explicit `presence` section in `schema.json` replaces the implicit schema entirely. Explicit schemas are recommended for applications with custom presence fields (cursor positions, typing indicators, etc.).

### Wire Index Derivation

At server startup, the server flattens `presence.user` and `presence.shared` into index arrays:

1. Iterate `presence.user` keys in definition order.
2. For each `object` field, expand its sub-fields in definition order using `parentName__subFieldName`.
3. For each scalar field, emit its name directly.
4. The resulting flat array is `presenceUserFields[]`. Array position = wire integer index.
5. Repeat for `presence.shared` → `presenceSharedFields[]`.

These arrays are emitted in the `SchemaSync` message on every new connection.

### Presence Error Catalog

| Error | Condition |
|:---|:---|
| `InvalidPresence` | `presence` key is present but not an object. |
| `MissingPresenceUser` | `presence` is present but `user` key is missing. |
| `InvalidPresenceUser` | `presence.user` is not an object. |
| `InvalidPresenceShared` | `presence.shared` is present but not an object. |
| `InvalidPresenceFieldName` | Presence field name violates naming constraints. |
| `InvalidPresenceFieldType` | Presence field `type` is missing, not a string, or not one of the supported types. |
| `PresenceNestingTooDeep` | A presence `object` field contains another `object` field (max one level). |
| `InvalidPresenceObjectField` | A presence `object` field is missing `fields`, or `fields` is not an object. |

---

## Validation Constraints

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

The following errors are returned by `Schema.init`:

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
