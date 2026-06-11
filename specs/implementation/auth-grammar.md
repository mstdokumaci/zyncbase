# ZyncBase Authorization Grammar

This document defines the formal JSON grammar for `authorization.json`.

## Root Structure

The root of `authorization.json` consists of two decoupled arrays:

| Key | Type | Description |
|:---|:---|:---|
| `namespaces` | `array` | Rules for horizontal partitioning (namespace access) and presence operations. |
| `store` | `array` | Rules for vertical partitioning (table access) and document ownership. |

### 1. Namespace Definition

A namespace definition governs access to a namespace and its presence channels.

| Key | Type | Description |
|:---|:---|:---|
| `pattern` | `string` | The namespace pattern (e.g., `tenant:{tenant_id}`). Segments enclosed in `{}` are extracted into the `$namespace` context. |
| `storeFilter` | `Condition` | Evaluated on `StoreSetNamespace`. If `false`, the client is rejected from the store namespace. |
| `presenceRead` | `Condition` | Evaluated on `PresenceSetNamespace`, `PresenceSubscribe`, and `PresenceSubscribeShared`. |
| `presenceWrite` | `Condition` | Evaluated on `PresenceSet` and `PresenceRemove`. `$data` contains the incoming field values. |
| `presenceSharedWrite` | `Condition` | Evaluated on `PresenceSetShared`. `$data` contains the incoming field values. Defaults to the same value as `presenceWrite` when omitted. |

### 2. Store Definition

A store definition governs read and write access to a specific table.

| Key | Type | Description |
|:---|:---|:---|
| `collection` | `string` | The table name to which these rules apply (e.g., `tasks`), or `*` for a catch-all rule that applies to any collection not matched by an earlier rule. |
| `read` | `Condition` | Evaluated on `StoreQuery` and `StoreSubscribe`. |
| `write` | `Condition` | Evaluated on `StoreSet`, `StoreRemove`, and `StoreBatch`. |

## The Condition Grammar

A `Condition` can be:
1. **Boolean literal**: `true` or `false`
2. **Logical grouping**: `{ "and": [Condition, Condition] }` or `{ "or": [Condition, Condition] }`
3. **Comparison object**: `{ "LHS": { "Operator": "RHS" } }`

### Comparison Object
- **LHS (Left-Hand Side)**: MUST be a context variable (e.g., `$session.userId`, `$doc.owner_id`).
- **Operator**: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `notIn`, `contains`.
- **RHS (Right-Hand Side)**: A raw literal (string, number, boolean, array) or another context variable.

## Variable Scope & Evaluation Matrix

To guarantee strict predictability and sub-microsecond performance, ZyncBase heavily restricts which variables are available during which wire command. 

Variables are evaluated using two execution paths:
1. **RAM Evaluation**: Instant, stateless check performed in memory.
2. **Predicate Lowering**: Existing-row `$doc` comparisons are lowered into the same flat `FilterPredicate` shape used by `StoreQuery` and `StoreSubscribe`. The storage layer owns SQL rendering.

`$session` is built during the authentication exchange from a validated JWT or SDK-generated anonymous subject. It does not load fields from the `users` row for authorization.

| Wire Command | `$session` | `$namespace` | `$path` (table) | `$value` (payload) | `$data` (presence) | `$doc` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `StoreSetNamespace` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |
| `PresenceSetNamespace` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |
| `StoreQuery` / `StoreSubscribe` | ✅ RAM | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ Predicate Lowering |
| `StoreSet` | ✅ RAM | ✅ RAM | ✅ RAM | ✅ RAM | ❌ | ✅ Create: RAM candidate / Update: Predicate Lowering |
| `StoreRemove` | ✅ RAM | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ Predicate Lowering |
| `PresenceSet` | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ RAM | ❌ |
| `PresenceSetShared` | ✅ RAM | ✅ RAM | ❌ | ❌ | ✅ RAM | ❌ |
| `PresenceSubscribe` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |
| `PresenceSubscribeShared` | ✅ RAM | ✅ RAM | ❌ | ❌ | ❌ | ❌ |

*(Note: If a rule references a forbidden variable for a specific command, evaluation fails safely, and access is denied. `StoreLoadMore` and `StoreUnsubscribe` inherit authorization established during `StoreSubscribe`. `PresenceUnsubscribe` and `PresenceUnsubscribeShared` require no authorization check.)*

`$data` is the decoded presence field map from the incoming `PresenceSet` or `PresenceSetShared` message. Fields are identified by their schema name (e.g., `$data.status`, `$data.slide`). `$data` is only available on presence write commands.

For `StoreSet`, `$doc` in write rules is interpreted by write kind:

- **Create**: `$doc` is the candidate document being created. It is evaluated in RAM without a storage read.
- **Update**: `$doc` is the existing stored document. It is enforced by predicate lowering.
- **Delete**: `$doc` is the existing stored document. It is enforced by predicate lowering.

The create candidate includes the document id, injected `owner_id = $session.userId`, normalized incoming fields, and server-managed fields/defaults when applicable. If a create rule references a `$doc` field that is absent from the candidate document and is not server-injected or defaulted, the create is denied. This preserves the invariant that a client cannot create a document the same session could not later update under the same write rules.

## Predicate Lowering Strategy

For existing-row checks, the `$doc` variable does NOT fetch the document into RAM before authorization. Instead, the authorization layer lowers the condition into a storage-neutral `FilterPredicate`. The storage layer then renders that predicate into a SQL `WHERE` fragment with bound values.

At server boot, `AuthConfig.init(allocator, json, schema)` validates every store rule against the active schema. Unknown `$doc` fields, invalid operators for field types, and `$doc` predicate shapes that cannot fit the flat store-query predicate model fail startup.

The supported `$doc` shape is intentionally no more expressive than StoreQuery: zero or more AND conditions plus at most one OR group. Nested `$doc` groups that would require multiple OR groups or an AND group inside an OR branch are invalid.

**Example**:
```json
"write": { "$doc.owner_id": { "eq": "$session.userId" } }
```
When creating a document, the server injects `owner_id` from `$session.userId`, treats the candidate document as `$doc`, and evaluates the ownership rule in RAM.

When updating a document (`StoreSet`) or deleting a document (`StoreRemove`), Zig evaluates `$session.userId` in RAM as the internal `BLOB(16)` user ID resolved through the `users` table. It recognizes `$doc.owner_id` as a column reference, lowers it to a filter condition, and the storage layer renders it with a bound binary parameter:
`UPDATE tasks SET ... WHERE id = ? AND owner_id = ?`

If the user does not own the existing document, 0 rows are affected without an extra `SELECT` overhead. Default accepted writes do not perform extra reads solely to classify that zero-row outcome. Confirmed writes may classify it and report `PERMISSION_DENIED`.

## Zero-Config Default (Implicit Rules)

If `authorization.json` is missing or not provided in the server configuration, ZyncBase boots with an implicit "public playground" rule set. This guarantees a frictionless developer experience for immediate prototyping while preventing users from destroying each other's data.

**Implicit JSON:**
```json
{
  "namespaces": [
    {
      "pattern": "public",
      "storeFilter":        true,
      "presenceRead":       true,
      "presenceWrite":      true,
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

**What this default means:**
1. The only accessible namespace is `public`.
2. Anyone (including anonymous users via the SDK's client-generated anonymous subject) can read all data and broadcast presence in the `public` namespace.
3. Users can create records owned by their own `$session.userId`, and can strictly only modify or delete records they created. Creates satisfy `$doc.owner_id == $session.userId` through server-side owner injection; updates and deletes enforce the same rule on existing rows through predicate lowering.
