# Authorization Grammar

**Drivers**: [ADR-003](../architecture/adrs.md#adr-003-configuration-first-design-zero-zig), [ADR-016](../architecture/adrs.md#adr-016-authentication-authorization-and-the-trust-boundary), [Auth System](./auth-system.md), [Query Grammar](./query-grammar.md)

This document specifies the formal JSON grammar structures, context variables, and evaluation matrix used to authorize client messages.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/authorization/types.zig` | Defines AST nodes, variable tokens, operators, and rule configurations. |
| `src/authorization/parse.zig` | Validates AST schema typing, operator validity, and path formats. |
| `src/authorization/evaluate.zig` | Evaluates RAM-scoped context fields (`$session`, `$namespace`, `$value`). |
| `src/authorization/doc_predicate.zig` | Lowers `$doc` comparisons into storage engine filters. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `Condition` | `Expression`, `LogicalGroup`, boolean | Abstract node representing an auth check. |
| `Expression` | left/right variable references, operator | Relational comparison (e.g. `LHS Operator RHS`). |
| `LogicalGroup` | conditions list, `LogicalOp` | Logical grouping (`and` or `or`). |
| `Context` | `Session`, `NamespaceState`, payload bytes | Evaluator context wrapper for variables. |

---

## Root Structure

The root of `authorization.json` consists of two decoupled arrays:

| Key | Type | Description |
|:---|:---|:---|
| `namespaces` | `array` | Rules for horizontal partitioning (namespace access) and presence operations. |
| `store` | `array` | Rules for vertical partitioning (table access) and document ownership. |

### Namespace Rule Fields

| Key | Type | Description / Validation |
|:---|:---:|:---|
| `pattern` | `string` | Pinned match template (e.g., `tenant:{tenant_id}`). Enclosed variables are extracted. |
| `storeFilter` | `Condition` | Checked on `StoreSetNamespace`. Denies store scope if false. |
| `presenceRead` | `Condition` | Checked on `PresenceSetNamespace`, `PresenceSubscribe`, and `PresenceSubscribeShared`. |
| `presenceWrite` | `Condition` | Checked on `PresenceSet` and `PresenceRemove`. `$data` contains the fields. |
| `presenceSharedWrite`| `Condition` | Checked on `PresenceSetShared`. Defaults to `presenceWrite` if omitted. |

### Store Rule Fields

| Key | Type | Description / Validation |
|:---|:---:|:---|
| `collection` | `string` | Table name, or `*` for a catch-all fallback. |
| `read` | `Condition` | Checked on `StoreQuery` and `StoreSubscribe`. |
| `write` | `Condition` | Checked on `StoreSet`, `StoreRemove`, and `StoreBatch`. |

---

## Condition Structure

A `Condition` maps to one of three JSON formats:

| Format Type | JSON Layout | Evaluation Logic |
|:---|:---|:---|
| **Boolean Literal** | `true` or `false` | Absolute grant or denial. |
| **Logical Group** | `{ "and": [...] }` or `{ "or": [...] }` | Evaluates nested array conditions recursively. |
| **Comparison Object** | `{ "LHS": { "Operator": "RHS" } }` | Relational check (e.g. `{ "$doc.owner_id": { "eq": "$session.userId" } }`). |

- **LHS**: Must be a context variable (`$session`, `$doc`, `$namespace`, `$path`, `$value`, `$data`).
- **Operator**: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `notIn`, `contains`.
- **RHS**: A raw literal value or context variable.

---

## Variable Scope & Evaluation Matrix

ZyncBase evaluates variables using two execution paths:
1. **RAM Evaluation**: Instant, stateless check performed in memory on incoming variables.
2. **Predicate Lowering**: Row-level `$doc` comparisons are converted into the flat `FilterPredicate` shape. The storage engine renders the resulting predicate into SQL query clauses.

| Command | `$session` | `$namespace` | `$path` (table) | `$value` (payload) | `$data` (presence) | `$doc` (existing row) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `StoreSetNamespace` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |
| `PresenceSetNamespace` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |
| `StoreQuery` / `StoreSubscribe` | ✅ RAM | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ Predicate Lowering |
| `StoreSet` (Create) | ✅ RAM | ✅ RAM | ✅ RAM | ✅ RAM | ❌ | ✅ Candidate RAM |
| `StoreSet` (Update) | ✅ RAM | ✅ RAM | ✅ RAM | ✅ RAM | ❌ | ✅ Predicate Lowering |
| `StoreRemove` | ✅ RAM | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ Predicate Lowering |
| `PresenceSet` | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ RAM | ❌ |
| `PresenceSetShared` | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ RAM | ❌ |
| `PresenceSubscribe` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |
| `PresenceSubscribeShared` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |

---

## Write Operations and `$doc` Interpretation

For mutations (`StoreSet`, `StoreRemove`), the `$doc` variable behaves differently based on write kinds:

| Write Kind | `$doc` Representation | Evaluation Method | Invariant / Failure Behavior |
|:---|:---|:---|:---|
| **Create** | Candidate document (normalized fields + owner + default values). | RAM check | Checked in-memory before database query. Denied if required fields are missing. |
| **Update** | Existing database row. | Predicate Lowering | Lowered to SQL filter. If match fails, 0 rows are affected (zero-read verify). |
| **Delete** | Existing database row. | Predicate Lowering | Lowered to SQL filter. If match fails, 0 rows are affected (zero-read verify). |

---

## Default Implicit Playground Rules

When `authorization.json` is omitted, the server synthesizes the following "public playground" rule set:

```json
{
  "namespaces": [
    {
      "pattern": "public",
      "storeFilter": true,
      "presenceRead": true,
      "presenceWrite": true,
      "presenceSharedWrite": true
    }
  ],
  "store": [
    {
      "collection": "*",
      "read": true,
      "write": { "$doc.owner_id": { "eq": "$session.userId" } }
    }
  ]
}
```

---

## See Also

- [Auth System](./auth-system.md)
- [Query Grammar](./query-grammar.md)
- [Storage](./storage.md)
