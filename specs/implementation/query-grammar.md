# Query Language Grammar and SQL Translation

**Status**: v1 — Implementation Specification

---

## Overview

This document specifies how the ZyncBase JSON query language maps to the internal Zig `QueryFilter` Abstract Syntax Tree (AST), and strictly how that AST is translated into SQLite `SELECT` queries. 

Unlike the public-facing API design documentation, this specification acts as the definitive source of truth for the backend systems executing queries against the `StorageEngine`.

## Abstract Syntax Tree (AST)

The query language is structurally parsed down to an array of conditions via an implicit `AND`, with an optional `OR` group.

```zig
pub const QueryFilter = struct {
    conditions: []const Condition,
    or_conditions: ?[]const Condition = null,
};

pub const Condition = struct {
    field: []const u8,
    op: Operator,
    value: Condition.Value,
};

pub const Operator = enum {
    eq, ne, gt, lt, gte, lte, contains, startsWith, endsWith, in, notIn, isNull, isNotNull
};
```

### Flattening Rules
Clients submit paths as nested JSON, but under the hood, ZyncBase stores deeply nested JSON objects as flat columns. 
When a query specifies a nested structure like `{"address": {"city": { "eq": "NYC" }}}`, the message payload is flattened by joining keys with `__`. 
The resulting `Condition.field` injected into the AST must literally be: `"address__city"`.

**No SQLite JSON Extractors for Objects**: SQLite's `json_extract()` or `->>` operators MUST NOT be used for reading document properties. Property queries strictly run against the `__` delimited flat columns.

---

## SQLite Translation Rules

### The Core Selection
By default, standard collection queries operate strictly on the `namespace` boundaries:

```sql
SELECT value_msgpack 
FROM "collection_name" 
WHERE _namespace = ? 
  [AND ...conditions] 
  [AND (...or_conditions)]
ORDER BY sort_col DESC
LIMIT ?
```

### Parameter Binding

ZyncBase MUST strictly separate the query layout and data injection via parameterized queries (`?`). Under no circumstances is user-input values formatted directly into SQL strings.

| AST Operator | SQLite WHERE fragment |
|--------------|-----------------------|
| `eq`         | `column_name = ?` |
| `ne`         | `column_name != ?` |
| `gt`         | `column_name > ?` |
| `lt`         | `column_name < ?` |
| `gte`        | `column_name >= ?` |
| `lte`        | `column_name <= ?` |
| `startsWith` | `column_name LIKE ? || '%'` |
| `endsWith`   | `column_name LIKE '%' || ?` |
| `in`         | `column_name IN (?, ?, ...)` |
| `notIn`      | `column_name NOT IN (?, ?, ...)` |
| `isNull`     | `column_name IS NULL` (Or `column_name = NULL` safely translated) |
| `isNotNull`  | `column_name IS NOT NULL` |

### JSONB Array Fields

Due to SQLite storing arrays as serialized MessagePack/JSON bytes, array properties cannot be queried natively using operators like `>` or `LIKE`. To avoid inventing new operators, ZyncBase restricts array fields to a tight subset:

| Operator | Action on Array Field | SQLite Subquery Mapping |
|----------|-----------------------|--------------------------|
| `contains`| Array contains element| `EXISTS (SELECT 1 FROM json_each(column_name) WHERE value = ?)` |
| `eq`     | Exact array equality  | `column_name = ?` (Binary match on MessagePack bytes) |
| `isNull` | Undefined/Missing     | `column_name IS NULL` |
| `isNotNull`| Exists              | `column_name IS NOT NULL` |

Attempting to run `startsWith` or `gt` on an array field results in a `SCHEMA_VALIDATION_FAILED` error.

---

## Combining Conditions

A standard filter contains both `conditions` and an optional `or_conditions` array.

#### Example Payload

```json
{
  "where": {
    "priority": { "eq": "high" },
    "or": [
      { "status": { "eq": "active" } },
      { "status": { "eq": "pending" } }
    ]
  }
}
```

#### SQL Form Generation

The translation engine builds the statement by appending an implicit `AND` for all root-level items, and isolating the `OR` group into a parenthetical block.

```sql
SELECT value_msgpack FROM "tasks"
WHERE _namespace = ?
  AND priority = ?
  AND (status = ? OR status = ?)
```

_Note_: The SQLite parameter binding array must push the namespace bound parameter first, followed by the variables defined in standard `conditions`, followed finally by variables declared in the `or_conditions`.
