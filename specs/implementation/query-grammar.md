# Query Language Grammar and SQL Translation

**Status**: v1 — Implementation Specification

---

## Overview

This document specifies the full query translation pipeline:

1. **SDK → Wire**: How the Prisma-inspired SDK syntax is pre-compiled into compact positional tuples (per ADR-019).
2. **Wire → AST**: How the Zig server deserializes wire tuples into the `QueryFilter` AST.
3. **AST → SQL**: How the AST is translated into SQLite `SELECT` queries.

Unlike the public-facing API design documentation, this specification acts as the definitive source of truth for the backend systems executing queries against the storage engine.

---

## Wire Encoding (SDK → Wire)

The SDK transforms the developer-friendly Prisma-style query into compact positional arrays before transmission. This follows the same principle as path encoding (ADR-019): SDK-friendly syntax on the developer side, compact arrays on the wire.

### Operator Codes

Each query operator maps to a fixed integer code matching the Zig `Operator` enum ordinal:

| Code | Operator | Code | Operator |
|------|----------|------|----------|
| 0 | `eq` | 7 | `startsWith` |
| 1 | `ne` | 8 | `endsWith` |
| 2 | `gt` | 9 | `in` |
| 3 | `lt` | 10 | `notIn` |
| 4 | `gte` | 11 | `isNull` |
| 5 | `lte` | 12 | `isNotNull` |
| 6 | `contains` | | |

### Condition Tuples

Each condition is encoded as a positional array:

```
[field_index: int, op: int, value: any]
```

- `field_index` — Integer schema dictionary index (resolved by SDK)
- `op` — Integer operator code from the table above
- `value` — The comparison value. Omitted (2-element tuple) for `isNull` and `isNotNull`

### Sort Tuples

Each sort descriptor is encoded as a positional array:

```
[field_index: int, desc: int]
```

- `field_index` — Integer schema dictionary index
- `desc` — `0` for ascending, `1` for descending

### Transformation Examples

**Simple query:**

```typescript
// SDK input
{ where: { age: { gte: 18 }, status: { eq: 'active' } } }

// Wire output (assuming age=3, status=4)
{ "conditions": [[3, 4, 18], [4, 0, "active"]] }
```

**Query with OR:**

```typescript
// SDK input
{
  where: {
    priority: { eq: 'high' },
    or: [
      { status: { eq: 'active' } },
      { status: { eq: 'pending' } }
    ]
  }
}

// Wire output (assuming priority=2, status=4)
{
  "conditions": [[2, 0, "high"]],
  "orConditions": [[4, 0, "active"], [4, 0, "pending"]]
}
```

**Null check (no value):**

```typescript
// SDK input
{ where: { deleted_at: { isNull: true } } }

// Wire output (assuming deleted_at=5)
{ "conditions": [[5, 11]] }
```

**Array operator:**

```typescript
// SDK input
{ where: { role: { in: ['admin', 'editor'] } } }

// Wire output (assuming role=6)
{ "conditions": [[6, 9, ["admin", "editor"]]] }
```

**Nested field (flattened):**

```typescript
// SDK input
{ where: { address: { city: { eq: 'NYC' } } } }

// Wire output (assuming address__city=7)
{ "conditions": [[7, 0, "NYC"]] }
```

**Sort + pagination:**

```typescript
// SDK input
{ orderBy: { created_at: 'desc' }, limit: 50, after: 'eyJpZCI6...' }

// Wire output (assuming created_at=8)
{ "orderBy": [8, 1], "limit": 50, "after": "eyJpZCI6..." }
```

### Full Wire Message

A complete `StoreQuery` message on the wire:

```
{
  "type":  "StoreQuery",
  "id":    6,
  "table_index": 0,
  "conditions": [
    [3, 4, 18],
    [4, 0, "active"]
  ],
  "orConditions": [
    [6, 0, "admin"],
    [6, 0, "editor"]
  ],
  "orderBy": [8, 1],
  "limit":   50,
  "after":   "eyJpZCI6..."
}
```

### Encoding Rules Summary

| SDK field | Wire key | Encoding |
|-----------|----------|----------|
| `where` (root conditions) | `conditions` | Array of `[field_index, op, value?]` tuples |
| `where.or` | `orConditions` | Array of `[field_index, op, value?]` tuples |
| `orderBy` | `orderBy` | `[field_index, desc]` tuple |
| `limit` | `limit` | Integer (unchanged) |
| `after` | `after` | String (unchanged) |

---

## Flattening Rules

Clients submit paths as nested JSON, but under the hood, ZyncBase stores deeply nested JSON objects as flat columns. 
When a query specifies a nested structure like `{"address": {"city": { "eq": "NYC" }}}`, the SDK flattens the field path by joining keys with `__`. 
The resulting condition tuple field must literally be: `"address__city"`.

**No SQLite JSON Extractors for Objects**: SQLite's `json_extract()` or `->>` operators MUST NOT be used for reading document properties. Property queries strictly run against the `__` delimited flat columns.

---

## Abstract Syntax Tree (AST)

The wire tuples map directly to the Zig AST. The parser validates wire integer indices against the schema field array bounds.

```zig
pub const PredicateState = enum(u8) {
    conditional,
    match_all,
    match_none,
};

pub const FilterPredicate = struct {
    state: PredicateState = .conditional,
    conditions: ?[]Condition = null,
    or_conditions: ?[]Condition = null,
};

pub const QueryFilter = struct {
    predicate: FilterPredicate,
    order_by: SortDescriptor,
};

pub const SortDescriptor = struct {
    field_index: usize,
    desc: bool,
};

pub const Condition = struct {
    field_index: usize,
    op: Operator,
    value: ?TypedValue,
};

pub const Operator = enum {
    eq, ne, gt, lt, gte, lte, contains, startsWith, endsWith, in, notIn, isNull, isNotNull
};
```

### Wire → AST Mapping

The server deserializes each condition tuple into a `Condition` struct directly without string lookup:

| Tuple position | AST field | Notes |
|----------------|-----------|-------|
| `[0]` | `Condition.field_index` | Integer index direct assignment |
| `[1]` | `Condition.op` | Integer cast to `Operator` enum |
| `[2]` | `Condition.value` | Any MessagePack value. Absent for `isNull`/`isNotNull` |

Sort tuples map to `SortDescriptor`:

| Tuple position | AST field | Notes |
|----------------|-----------|-------|
| `[0]` | `SortDescriptor.field_index` | Integer index direct assignment |
| `[1]` | `SortDescriptor.desc` | `1` → `true`, `0` → `false` |

### Predicate Normalization

After parsing and after authorization `$doc` predicate lowering, ZyncBase normalizes predicates once before execution. Normalization is semantic-preserving and uses explicit `PredicateState` values instead of fake SQL fragments or fake conditions.

Rules:

- `field IN []` is `match_none`.
- `field NOT IN []` is `match_all`.
- In the AND group, any `match_none` condition makes the whole predicate `match_none`; `match_all` conditions are removed.
- In the OR group, any `match_all` condition removes the entire OR group while preserving the AND group; `match_none` OR terms are removed.
- If an OR group existed and every OR term is removed as `match_none`, the whole predicate becomes `match_none`.
- If no conditions remain, the predicate becomes `match_all`.

`conditions` and `or_conditions` retain their existing meaning:

```text
conditions AND (or_conditions[0] OR or_conditions[1] ...)
```

`match_none` must remain distinguishable from an empty predicate. Empty predicates are `match_all`; impossible predicates are `match_none`.

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
ORDER BY [sorts...], id DESC
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

### JSONB Array Fields (Canonical Sorted Sets)

Array fields are persisted in canonical sorted unique form. Query operands for array equality (`eq`, `ne`) are canonicalized before SQL binding, so equality semantics are deterministic and order-insensitive for valid typed arrays.

Because arrays are stored as JSONB values, array properties cannot be queried natively with scalar operators like `>` or `LIKE`. ZyncBase therefore restricts array fields to a tight subset:

| Operator | Action on Array Field | SQLite Subquery Mapping |
|----------|-----------------------|--------------------------|
| `contains`| Array contains element (membership) | `EXISTS (SELECT 1 FROM json_each(column_name) WHERE value = ?)` |
| `eq`     | Canonical array equality | `column_name = ?` (comparison against canonicalized value) |
| `isNull` | Undefined/Missing     | `column_name IS NULL` |
| `isNotNull`| Exists              | `column_name IS NOT NULL` |

Attempting to run `startsWith` or `gt` on an array field results in a `SCHEMA_VALIDATION_FAILED` error.

For scalar-field `in` / `notIn`, the operand array is canonicalized (sorted + deduped) during parsing. Result semantics are order-insensitive and duplicate-insensitive.

---

## Combining Conditions

A standard filter contains both `conditions` and an optional `orConditions` array.

#### Example Wire Payload

```json
{
  "conditions": [[2, 0, "high"]],
  "orConditions": [[4, 0, "active"], [4, 0, "pending"]]
}
```

#### SQL Form Generation

The translation engine builds the statement by appending an implicit `AND` for all root-level conditions, and isolating the `orConditions` group into a parenthetical block.

```sql
SELECT value_msgpack FROM "tasks"
WHERE _namespace = ?
  AND priority = ?
  AND (status = ? OR status = ?)
```

---

## Sorting Rules

ZyncBase supports sorting by multiple fields. The `orderBy` field on the wire is either a single `[field, desc]` tuple or an array of such tuples for multi-field sorting (future).

### Tie-breaking
To ensure deterministic pagination (Cursor Stability), ZyncBase ALWAYS appends `id DESC` (or `id ASC` if the last sort field was ASC) as a final tie-breaker if `id` was not already the primary sort field.

### Mapping to SQL
Each `SortDescriptor` translates to a comma-separated fragment in the `ORDER BY` clause:
```sql
ORDER BY priority DESC, created_at ASC, id DESC
```
