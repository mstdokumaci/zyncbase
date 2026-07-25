# Authorization System

**Drivers**: [ADR-003](../architecture/adrs.md#adr-003-configuration-first-design-zero-zig), [ADR-016](../architecture/adrs.md#adr-016-authentication-authorization-and-the-trust-boundary), [Auth Exchange](./auth-exchange.md), [Query Grammar](./query-grammar.md)

ZyncBase employs a declarative, stateless authorization model configured via `authorization.json`. Evaluation is fail-closed, executing entirely in Zig using metadata loaded at boot and state resolved during session handshake.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/authorization/types.zig` | Internal representation of declarative rule arrays and conditions. |
| `src/authorization/parse.zig` | JSON deserialization, validation, and schema consistency checking. |
| `src/authorization/pattern.zig` | Colon-separated namespace segment parsing, matching, and wildcard binding. |
| `src/authorization/evaluate.zig` | Evaluation context, variable resolution, literals, and comparison execution. |
| `src/authorization/store.zig` | Store read/write authorization entry points and predicate construction. |
| `src/authorization/presence.zig` | Presence read/write/shared-write authorization entry points. |
| `src/authorization/defaults.zig` | Implicit playground authorization rules used when no file is configured. |
| `src/authorization/session_resolver.zig` | Event-loop consumer for background namespace/user scope resolution results. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `AuthConfig` | allocator | Root container for `namespaces` and `store` rule lists. |
| `NamespaceRule` | pattern, conditions | Matches client-requested namespaces and dictates read/write/shared access. |
| `StoreRule` | collection name, conditions | Gates CRUD operations on SQLite tables via path and row-level checks. |
| `MatchPattern` | segment buffers | Parses namespace templates (e.g. `tenant:{tenant_id}`) and extracts route variables. |
| `EvalContext` | session, namespace, payload/doc data | Resolves `$session`, `$namespace`, `$path`, `$value`, `$data`, and `$doc` operands. |

---

## Invariants

- **Fail-Closed**: Any operation not matching an explicit allow rule is rejected.
- **Stateless Evaluation**: Access must be resolved from `$session` claims, `$namespace` variables, `$path` metadata, `$value` (mutation payload), or `$doc` (current database row).
- **Same-Row Boundaries**: `$doc` predicates can only constrain columns on the single row being written, read, or modified. Cross-table joins or relational traversal in auth rules are prohibited.
- **Lowering Consistency**: Any auth condition targeting database rows (`$doc`) must lower to the same flat `FilterPredicate` shape supported by the query parser.
- **Namespace Guard**: All store and presence operations require a ready, resolved namespace scope. If a namespace fails to authorize during `SetNamespace` setup, all subsequent operations on that scope block.

---

## JSON Structure Overview

`authorization.json` organizes authorization rules into two primary arrays:

```json
{
  "namespaces": [
    {
      "pattern": "tenant:{tenant_id}",
      "storeFilter": { "$session.tenant_id": { "eq": "$namespace.tenant_id" } },
      "presenceRead": { "$session.tenant_id": { "eq": "$namespace.tenant_id" } },
      "presenceWrite": true
    }
  ],
  "store": [
    {
      "collection": "tasks",
      "read": true,
      "write": { "$doc.owner_id": { "eq": "$session.userId" } }
    }
  ]
}
```

---

## Namespace Scoping & Wildcard Rules

Namespaces use a colon-separated segment structure. SEGMENTS matching `{variable}` are extracted into the `$namespace` context:

| Template Pattern | Request Namespace | Resolved `$namespace` Context |
|:---|:---|:---|
| `tenant:{tenant_id}` | `tenant:acme` | `$namespace.tenant_id = "acme"` |
| `org:{org_id}:proj:{p_id}` | `org:google:proj:db` | `$namespace.org_id = "google"`, `$namespace.p_id = "db"` |

### Multi-Tenancy Scoping Examples

#### Tenant Isolation:
- **Session Context**: `{ "tenant_id": "acme" }`
- **Rule filter**: `{ "$namespace.tenant_id": { "eq": "$session.tenant_id" } }`
- **Result**: User upgrade to `tenant:acme` succeeds; `tenant:other` is rejected.

#### Array Member Checking (Project Isolation):
- **Session Context**: `{ "read_projects": ["docs", "wiki"], "write_projects": ["docs"] }`
- **Namespace config**:
  ```json
  {
    "pattern": "org:{org_id}:project:{project_id}",
    "storeFilter": { "$namespace.project_id": { "in": "$session.read_projects" } },
    "presenceRead": { "$namespace.project_id": { "in": "$session.read_projects" } },
    "presenceWrite": { "$namespace.project_id": { "in": "$session.write_projects" } }
  }
  ```

---

## Presence Authorization

Unlike the Store API, the Presence API is a namespace-wide boundary:

| Presence Operation | Scoped JSON Key | Variables Available | Default Behavior |
|:---|:---|:---|:---|
| Subscribing to user events | `presenceRead` | `$session`, `$namespace` | Denied |
| Broadcasting own state | `presenceWrite` | `$session`, `$namespace`, `$data` | Denied |
| Updating shared states | `presenceSharedWrite` | `$session`, `$namespace`, `$data` | Inherits `presenceWrite` value if omitted |

---

## Composition Model & Operators

Rules utilize a subset of the store query predicate model:
- **Literals**: `true` (allow) or `false` (deny).
- **Operators**:

| Operator | Usage | Evaluated In |
|:---|:---|:---|
| `eq`, `ne` | Equality / Inequality checks | RAM or SQL |
| `gt`, `gte`, `lt`, `lte` | Range bounds comparison | RAM or SQL |
| `in`, `notIn` | Value membership in array claims | RAM or SQL |
| `contains` | Check if array field contains value | RAM or SQL |
| `startsWith`, `endsWith` | String prefix/suffix comparison | RAM or SQL |
| `isNull`, `isNotNull` | Field/null existence comparison | RAM or SQL |
| `and`, `or` | Condition groupings | RAM or SQL |

---

## Authorization Boundaries (Inside vs. Outside)

To ensure sub-microsecond performance, ZyncBase separates database concerns from application policies:

| Allowed Inside ZyncBase (Stateless RAM / Same-Row SQL) | Must Be Handled Outside (JWT Claims / App Logic) |
|:---|:---|
| Matching `$namespace.tenant_id` to `$session.tenant_id`. | Looking up user members in a `project_members` join table. |
| Checking `$namespace.project_id` in `$session.read_projects`. | Resolving hierarchical organization tree permissions. |
| Restricting mutations to `$doc.owner_id == $session.userId`. | Verifying Stripe billing status or credit balances. |
| Restricting writes to `$session.role` in `["admin", "editor"]`. | Multi-step approval workflows or external policy lookups. |

---

## See Also

- [Auth Exchange](./auth-exchange.md)
- [Auth Grammar](./auth-grammar.md)
- [Query Grammar](./query-grammar.md)
- [Security](./security.md)
