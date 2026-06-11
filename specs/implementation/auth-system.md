# ZyncBase Authorization Format (`authorization.json`)

**Drivers**:
- [Configuration API Design](../api-design/configuration.md) - Server configuration and authorization rules.
- [Auth Exchange](./auth-exchange.md) - Ticket handshake and `$session` construction.
- [ADR-032](../architecture/adrs.md#adr-032-config-driven-authentication-and-external-permission-claims) - Config-driven authentication and external permission claims.

---

## 1. Core Principles

1. **Deny by Default**: All access is denied unless explicitly allowed by a rule.
2. **Native-Only Evaluation**: Rules are evaluated by Zig using a strictly limited context:
   - `$session`: The resolved session context projected from a validated JWT or anonymous identity.
   - `$namespace`: The current namespace string parts.
   - `$doc`: Columns on the target row, lowered to the same flat `FilterPredicate` used by `StoreQuery` and `StoreSubscribe`.
   - `$value`: The incoming mutation payload, evaluated in RAM.
   - `$path`: The table name.
3. **External Permission Truth**: ZyncBase does not compute memberships, billing state, group inheritance, or permission graphs. Those facts must be present in trusted token claims, namespace parts, same-row data, or the incoming value.
4. **Same-Row Limit**: `$doc` can only constrain the same row being selected, updated, or deleted. Rules requiring relationship traversal, joins, external calls, or lookups of another table are invalid in JSON.
5. **Query Predicate Parity**: Auth JSON keeps its rule syntax (`and` / `or` groups and comparison objects), but any residual `$doc` predicate must lower to the same flat query predicate used by StoreQuery: zero or more AND conditions plus at most one OR group. Auth never supports a more expressive `$doc` filter than the store query language.
6. **Decoupled Configuration**: Namespace rules handle horizontal isolation and presence. Store rules handle collection-level access and same-row ownership.

The `users` table is not read for authorization. It maps an external subject to the internal `users.id` used by `$session.userId`, `owner_id`, presence identity, and foreign keys. Optional profile fields such as display name or avatar remain application data.

## 2. Rule Format Structure

The file is organized into two decoupled arrays: **`namespaces`** and **`store`**. For the full formal grammar, see [Auth Grammar](./auth-grammar.md).

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

## 3. Evaluation Order & Conflict Resolution

- **Top-Down Evaluation**: Rules within the `namespaces` and `store` arrays are evaluated top-down independently. The first matching pattern wins.
- **Early Exit**: As soon as a rule explicitly grants access (`true` or matching condition), evaluation stops and access is permitted.
- **Namespace-First**: A frame's namespace is always evaluated via `StoreSetNamespace` or `PresenceSetNamespace` first. If no namespace rule matches, the corresponding scope is not marked ready, and subsequent path evaluations are irrelevant.
- **Ready-Scope Gate**: Store rules are evaluated only after the store scope has a resolved namespace and internal `$session.userId`. Presence rules are evaluated only after the presence scope has a resolved namespace and internal `$session.userId`.

## 4. Namespace Wildcard Behavior & Session Expectations

Namespaces use a colon-separated segment model. Wildcards (`*`) can be used to match segments and extract variables into the `$namespace` context.

**Crucial understanding: ZyncBase is stateless for authorization.**
Any hierarchical namespace authorization requires that data to be present in `$session`.

`$session.userId` is not the raw external identity. It is the persisted internal `users.id` resolved for the scope being authorized. If `users.namespaced = false`, this ID is resolved in global namespace `0`. If `users.namespaced = true`, the ID is resolved in the namespace of the store or presence scope.

### Example 1: Tenant Isolation

- Session contains: `{ "tenant_id": "acme" }`
- Namespace: `tenant:{tenant_id}`
- Rule: `{ "$namespace.tenant_id": { "eq": "$session.tenant_id" } }`
- How it works: User connects to namespace `tenant:acme`. ZyncBase extracts `acme` as `$namespace.tenant_id` and compares it to `$session.tenant_id`.

### Example 2: Project Isolation With Session Arrays

A Jira- or Confluence-style app may have one organization token that carries multiple project grants:

```json
{
  "sub": "user_123",
  "org_id": "acme",
  "read_projects": ["docs", "wiki", "planning"],
  "write_projects": ["docs"]
}
```

Namespace authorization can use those arrays directly:

```json
{
  "namespaces": [
    {
      "pattern": "org:{org_id}:project:{project_id}",
      "storeFilter": {
        "and": [
          { "$namespace.org_id": { "eq": "$session.org_id" } },
          { "$namespace.project_id": { "in": "$session.read_projects" } }
        ]
      },
      "presenceRead": { "$namespace.project_id": { "in": "$session.read_projects" } },
      "presenceWrite": { "$namespace.project_id": { "in": "$session.write_projects" } }
    }
  ]
}
```

Store rules can also check project grants against same-row data:

```json
{
  "store": [
    {
      "collection": "pages",
      "read": { "$doc.project_id": { "in": "$session.read_projects" } },
      "write": { "$doc.project_id": { "in": "$session.write_projects" } }
    }
  ]
}
```

By using arrays and roles in the JWT/session, ZyncBase performs scope validation statelessly in RAM or as same-row SQL predicates. Permission lists should remain human-manageable; applications should use roles, groups, or active-context tokens rather than unbounded grant arrays.

## 5. Presence API Authorization

Unlike the Store API, the Presence API is a flat, namespace-wide concept. Users join a presence namespace, broadcast their own state, and listen to others.

Presence authorization is defined directly at the namespace level:

- **`presenceRead`**: Permission to subscribe to the presence channel (`PresenceSubscribe`, `PresenceSubscribeShared`) and see who is online and what the shared state is.
- **`presenceWrite`**: Permission to broadcast user presence (`PresenceSet`, `PresenceRemove`). The `$data` variable exposes incoming field values, enabling content-gated rules.
- **`presenceSharedWrite`**: Permission to write namespace-level shared state (`PresenceSetShared`). The `$data` variable exposes incoming field values. Defaults to the same value as `presenceWrite` when omitted — if you can write user presence, you can write shared state, unless explicitly restricted.

Because presence is ephemeral, there is no `$doc` equivalent and no path-level routing. Presence still requires a ready presence scope so presence entries are keyed by the resolved internal user ID.

Example:

```json
{
  "namespaces": [
    {
      "pattern": "org:{org_id}:project:{project_id}",
      "storeFilter": {
        "and": [
          { "$namespace.org_id": { "eq": "$session.org_id" } },
          { "$namespace.project_id": { "in": "$session.read_projects" } }
        ]
      },
      "presenceRead":        { "$namespace.project_id": { "in": "$session.read_projects" } },
      "presenceWrite":       { "$namespace.project_id": { "in": "$session.write_projects" } },
      "presenceSharedWrite": { "$namespace.project_id": { "in": "$session.write_projects" } }
    }
  ],
  "store": []
}
```

## 6. Composition Model

Conditions mirror the store query predicate model where they apply to `$doc`, and use RAM evaluation for `$session`, `$namespace`, `$path`, and `$value`.

- **Boolean Values**: `true` (allow) or `false` (deny).
- **Operators**: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `notIn`, `contains`.
- **Logic**: `and`, `or`.

At server boot, `AuthConfig.init(allocator, json, schema)` validates every store rule against the schema. A rule that cannot be evaluated in RAM or lowered into a valid same-row `FilterPredicate` fails startup. Unknown `$doc` fields, invalid operators, and `$doc` expressions requiring nested groups beyond the flat store-query predicate shape are invalid.

Example:

```json
{
  "write": {
    "or": [
      { "$session.role": { "eq": "admin" } },
      {
        "and": [
          { "$session.role": { "eq": "editor" } },
          { "$path": { "eq": "tasks" } },
          { "$doc.owner_id": { "eq": "$session.userId" } }
        ]
      }
    ]
  }
}
```

## 7. Authorization Boundary

ZyncBase does not provide an application-code authorization runtime. If a permission check requires facts outside the token, namespace, target row, or incoming value, the application must compute that permission before issuing or refreshing the token.

Examples that belong outside ZyncBase:

- looking up `project_members` before allowing access
- resolving inherited permissions across spaces, folders, and pages
- checking billing status in Stripe
- evaluating a custom approval workflow
- calling an external policy engine

Examples that belong inside ZyncBase:

- matching `$namespace.tenant_id` to `$session.tenant_id`
- checking `$namespace.project_id` against `$session.read_projects`
- checking `$doc.owner_id == $session.userId`
- allowing writes for `$session.role in ["admin", "editor"]`
- checking `$doc.project_id` against `$session.write_projects`
