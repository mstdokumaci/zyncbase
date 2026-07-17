# Query Grammar and SQL Translation

**Drivers**: [ADR-009](../architecture/adrs.md#adr-009-integer-routing-architecture), [ADR-013](../architecture/adrs.md#adr-013-query-language), [Cursor Pagination](./cursor-pagination.md), [Storage](./storage.md)

This document specifies the pipeline that parses wire-encoded query tuples, normalizes them into an Abstract Syntax Tree (AST), and lowers them to parameterized SQLite statements.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/query/ast.zig` | Defines Zig AST representation for query filters, sort descriptors, and operators. |
| `src/query/parser.zig` | Deserializes MessagePack tuples into query ASTs, validating fields against schemas. |
| `src/query/eval.zig` | Evaluates AST predicates in-memory (used by authorization and sub engines). |
| `src/storage_engine/filter_sql.zig` | Lowers query predicates to SQLite parameterized `WHERE` clauses. |
| `src/storage_engine/reader.zig` | Prepares and binds SQLite query statements, executing pagination and queries. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `QueryFilter` | `FilterPredicate`, `SortDescriptor` | Complete query descriptor mapping filter bounds and order options. |
| `FilterPredicate` | `Condition` arrays, `PredicateState` | Combines AND groups and at most one OR group, tracking simplified match states. |
| `Condition` | field schema index, `Operator`, value | Individual condition tuple (field index, operator, typed operand). |
| `SortDescriptor` | field schema index, direction | Field sorting instruction. |
| `Operator` | enum | Supported relational operators (e.g. `eq`, `contains`, `in`, `isNull`). |

---

## Wire Encoding Protocol

Queries use compact integer tuples on the wire to minimize message size.

### Operator Codes

| Code | Operator | Code | Operator | Code | Operator |
|:---:|:---|:---:|:---|:---:|:---|
| **0** | `eq` | **5** | `lte` | **10** | `notIn` |
| **1** | `ne` | **6** | `contains` | **11** | `isNull` |
| **2** | `gt` | **7** | `startsWith` | **12** | `isNotNull` |
| **3** | `lt` | **8** | `endsWith` | | |
| **4** | `gte` | **9** | `in` | | |

### Positional Tuple Forms

- **Condition Tuple**: `[field_index: int, op: int, value: any]`. Value is omitted (size 2 array) for `isNull` / `isNotNull`.
- **Sort Tuple**: `[field_index: int, desc: int]` where `desc` is `0` (ascending) or `1` (descending).

---

## SDK-to-Wire Transformation Examples

| SDK Input Example | Wire Output Representation | Mapped Indexes & Operators |
|:---|:---|:---|
| `{ age: { gte: 18 }, status: { eq: 'active' } }` | `[[3, 4, 18], [4, 0, "active"]]` | `age = index 3`, `status = index 4` |
| `{ priority: { eq: 'high' }, or: [ { status: { eq: 'active' } }, { status: { eq: 'pending' } } ] }` | `{"conditions": [[2, 0, "high"]], "orConditions": [[4, 0, "active"], [4, 0, "pending"]]}` | `priority = index 2`, `status = index 4` |
| `{ deleted_at: { isNull: true } }` | `[[5, 11]]` | `deleted_at = index 5` |
| `{ role: { in: ['admin', 'editor'] } }` | `[[6, 9, ["admin", "editor"]]]` | `role = index 6` |
| `{ address: { city: { eq: 'NYC' } } }` | `[[7, 0, "NYC"]]` | Flat column: `address__city = index 7` |
| `{ orderBy: { created_at: 'desc' }, limit: 50, after: '...' }` | `{"orderBy": [8, 1], "limit": 50, "after": "..."}` | `created_at = index 8` |

### Full Wire Message Layout (`StoreQuery`)

```json
{
  "type": "StoreQuery",
  "id": 6,
  "table_index": 0,
  "conditions": [[3, 4, 18], [4, 0, "active"]],
  "orConditions": [[6, 0, "admin"], [6, 0, "editor"]],
  "orderBy": [8, 1],
  "limit": 50,
  "after": "eyJpZCI6..."
}
```

---

## Flattening & Storage Invariants

- **Nested Objects**: Client-facing nested JSON keys are flattened using `__` delimiters. SQLite query logic runs against flat column representations (e.g., `address__city`), avoiding SQLite dynamic JSON extractors (`json_extract`) on the query path.
- **Prepared Statements**: All inputs must be bound to parameterized queries (`?`). User inputs are never concatenated directly into SQL strings.

---

## SQLite Operator Translation

The AST conditions map directly to SQLite query clauses and parameters during translation in `src/storage_engine/filter_sql.zig`:

### Scalar Fields

| AST Operator | SQLite WHERE Clause Fragment |
|--------------|------------------------------|
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
| `isNull`     | `column_name IS NULL` |
| `isNotNull`  | `column_name IS NOT NULL` |

### Array Fields (Canonical Sorted Sets)

Because array fields are persisted in JSONB representation, they use subqueries or specialized canonical lookups:

| AST Operator | Action on Array Field | SQLite Subquery / Clause Mapping |
|----------|-----------------------|----------------------------------|
| `contains`| Array contains element | `EXISTS (SELECT 1 FROM json_each(column_name) WHERE value = ?)` |
| `eq`     | Canonical array equality | `column_name = ?` (exact comparison against canonicalized value) |
| `isNull` | Undefined/Missing array | `column_name IS NULL` |
| `isNotNull`| Exists | `column_name IS NOT NULL` |

---

## Predicate Normalization Rules

Filters are simplified prior to execution based on logical invariants:

| Condition Pattern | Normalized Form |
|:---|:---|
| `field IN []` | `match_none` |
| `field NOT IN []` | `match_all` |
| `match_none` in AND group | Entire filter simplified to `match_none` |
| `match_all` in AND group | Discarded from evaluation |
| `match_all` in OR group | OR group simplified to `match_all` |
| `match_none` in OR group | Discarded from evaluation |

- **Logical Order**: AND group and OR group are joined as `AND`: `conditions AND (or_conditions[0] OR or_conditions[1]...)`.

---

## See Also

- [Cursor Pagination](./cursor-pagination.md)
- [Storage](./storage.md)
- [Schema Grammar](./schema-grammar.md)
