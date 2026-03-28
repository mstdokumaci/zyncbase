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

### Table Name Constraints

- Must be a valid JSON key.
- Should avoid SQLite reserved keywords.
- Recommended: lowercase snake_case.

---

## Field Definition

A field definition MUST contain a `type` property.

### Supported Types

| Type | SQLite Mapping | Description |
|:---|:---:|:---|
| `string` | `TEXT` | UTF-8 text string. |
| `integer` | `INTEGER` | 64-bit signed integer. |
| `number` | `REAL` | 64-bit floating point number. |
| `boolean` | `INTEGER` | Boolean (0 or 1). |
| `array` | `BLOB` | Stored as a JSON blob. |
| `object` | (Flattened) | Logical grouping of fields. |

### Shared Properties

| Key | Type | Default | Description |
|:---|:---:|:---|:---|
| `type` | `string` | - | One of the types listed above. |
| `indexed` | `boolean` | `false` | Creates a SQLite index for this column. |
| `references` | `string` | `null` | Target table name for a foreign key relationship. |
| `onDelete` | `string` | `"restrict"` | `set_null`, `cascade`, `restrict`. Note: `set_null` requires the field to be optional (not in `required`). |

---

## Nested Objects & Flattening

ZyncBase uses a **flat relational storage engine**. Nested objects are logically grouped in the schema but flattened in the database.

- **Separator**: `__` (double underscore).
- **Naming Restriction**: Field names cannot contain `__`.
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
| `items` | `string` | `[PLANNED]` / `[UNENFORCED]` Type of items within the array (currently stored as opaque BLOB). |

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
| `InvalidTableDefinition` | A table value in `store` is not an object. |
| `MissingFieldType` | A field definition lacks the `type` property. |
| `InvalidFieldDefinition` | A field value is not an object. |
| `InvalidFieldType` | `type` value is not a string. |
| `InvalidFieldName` | Field name is empty or contains `__`. |
| `UnknownFieldType` | `type` string is not recognized. |
| `InvalidOnDelete` | `onDelete` value is not one of `cascade`, `restrict`, `set_null`; or `set_null` is used on a `required` field. |
