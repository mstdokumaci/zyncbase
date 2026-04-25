# ZyncBase Authorization Format (`authorization.json`)

**Status**: v1 — Stable  
**Context**: Replaces complex row-level security (RLS) with a high-performance, JSON-declarative model executed natively by the ZyncBase Zig core. Evaluated on every incoming MessagePack frame.

**Drivers**:
- [Configuration API Design](../api-design/configuration.md) - Authorization rules and hook management requirements.

---

## 1. Core Principles

1. **Deny by Default**: All access is denied unless explicitly allowed by a rule.
2. **Variables Context**: Rules are evaluated against a strictly limited context containing:
   - `$session`: The resolved session context (enriched from JWT and/or Hook Server).
   - `$namespace`: The current namespace string parts.
   - `$doc`: Columns on the existing target row (compiled via AST Injection into SQL `WHERE` clauses).
   - `$value`: The incoming mutation payload (evaluated in RAM).
   - `$path`: The table name.
   
   **Hard Limit**: `$doc` can only constrain the same row being selected, updated, or deleted. Any rule requiring relationship traversal, a relational join, or a lookup of another table (e.g., checking a separate `project_members` table) is explicitly forbidden in JSON and MUST be delegated to the Hook Server via a `"hook"` rule.
3. **Query Language Syntax**: Conditions use the exact same JSON structure as the ZyncBase Query Language (implicit ANDs, explicit `or`, e.g., `{ "$session.role": { "eq": "admin" } }`), ensuring easy parsing and AST injection.
4. **Decoupled Configuration**: Namespaces handle horizontal isolation and presence, while store handles vertical collection-level access.

## 2. Rule Format Structure

The file is organized into two decoupled arrays: **`namespaces`** and **`store`**. For the full formal grammar, see [Auth Grammar](./auth-grammar.md).

```json
{
  "namespaces": [
    {
      "pattern": "tenant:{tenant_id}",
      "storeFilter": { "$session.tenantId": { "eq": "$namespace.tenant_id" } },
      "presenceRead": { "$session.tenantId": { "eq": "$namespace.tenant_id" } },
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
- **Namespace-First**: A frame's namespace is always evaluated via `StoreSetNamespace` or `PresenceSetNamespace` first. If no namespace rule matches, the connection context is not set, and subsequent path evaluations are irrelevant.

## 4. Namespace Wildcard Behavior & Session Expectations

Namespaces use a colon-separated segment model. Wildcards (`*`) can be used to match segments and extract variables into the `$namespace` context.

**Crucial understanding: ZyncBase is stateless for authorization.**
Any hierarchical namespace authorization requires that data to be present in the `$session`.

**Example 1: Tenant Isolation (Common)**
- Session contains: `{ "tenant_id": "acme" }`
- Namespace: `tenant:${tenant_id}`
- Rule: `{ "$namespace.tenant_id": { "eq": "$session.tenant_id" } }`
- *How it works*: User connects to namespace `tenant:acme`. ZyncBase extracts `acme` as `$namespace.tenant_id`. It compares it to `$session.tenant_id`. If they match, access is granted.

**Example 2: Workspace Isolation (Stateless Arrays)**
- If you use a namespace like `tenant:acme:workspace:123`, how does ZyncBase know the user is allowed in `workspace:123`?
- The `$session` (via `onConnect`) contains an array of allowed workspaces: `{ "workspaces": ["123", "456"] }`. 
  - Rule: `{ "$namespace.workspace": { "in": "$session.workspaces" } }`

By using arrays in the JWT/Session, ZyncBase can perform complex scope validation statelessly without hitting the Hook Server.

## 5. Presence API Authorization

Unlike the Store API which has fine-grained nested data paths, the Presence API is a flat, namespace-wide concept. Users join a presence namespace, broadcast their own state, and listen to others.

Therefore, presence authorization is defined directly at the `namespace` level alongside `paths`:
- **`read`**: Permission to subscribe to the presence channel and see who is online.
- **`write`**: Permission to broadcast your own presence object to the channel (schema validation still applies).

Because presence is ephemeral, there is no `$doc` equivalent and no path-level routing. 

**Hook Server Support:**
Presence rules fully support Hook Server Delegation. If you need relational lookups before letting a user join a presence channel (e.g., "is this user a paid subscriber?"), you can delegate it:

```json
{
  "namespaces": [
    {
      "pattern": "premium:*",
      "presenceRead": { "hook": "checkPresenceAccess" },
      "presenceWrite": { "$session.role": { "in": ["admin", "paid"] } }
    }
  ]
}
```

## 6. Composition Model (Conditions)

Conditions mirror the `QUERY_LANGUAGE.md` operators to reuse the same evaluation engine in Zig.

- **Boolean Values**: `true` (allow) or `false` (deny).
- **Operators**: `eq`, `ne`, `in`, `notIn`, `contains`.
- **Logic**: `and`, `or`.

**Example:**
```json
"write": {
  "or": [
    { "$session.role": { "eq": "admin" } },
    { 
      "$session.role": { "eq": "editor" },
      "$path": { "eq": "tasks" },
      "$doc.owner_id": { "eq": "$session.userId" }
    }
  ]
}
```



## 7. The Bun Hook Server (Managing Complexity)

The core tension in authorization is between **stateless performance** and **complex relational permissions** (e.g., "does this user belong to the workspace that owns the folder containing this document?").

To solve this, ZyncBase draws a hard line:
1. **`authorization.json` is strictly for RAM checks and same-row SQL predicates.** (e.g., `$namespace.tenant == $session.tenant_id`, `$doc.owner_id == $session.userId`). It is exceptionally fast and evaluated natively in Zig.
2. **Any rule requiring a relationship traversal, join, or lookup outside the target row is delegated to the Bun Hook Server.**

We do *not* attempt to build a Turing-complete database lookup engine into `authorization.json`. Instead, ZyncBase provides an out-of-the-box Bun WebSocket server. Developers simply write a TypeScript function to handle complex auth logic.

**Example `authorization.json` delegation:**
```json
{
  "store": [
    {
      "collection": "documents",
      "write": { "hook": "checkDocumentAccess" } 
    }
  ]
}
```

**How it works (The MessagePack Contract):**
1. ZyncBase maintains a persistent, high-speed `ws://` connection to the local Bun Hook Server.
2. When a write matches the `"hook"` rule, ZyncBase streams a MessagePack payload containing the `$session`, `$namespace`, `$path`, the incoming `value`, and the requested function name (`"checkDocumentAccess"`).
3. The Bun Hook Server executes the developer's TypeScript function, which has full access to the database (via Prisma, Drizzle, raw SQL, or fetch calls).
4. The Hook Server responds immediately with a `true` (allow) or `false` (deny) MessagePack payload.

**The Developer Experience:**
The developer writes authorization logic in a designated file (e.g., `zyncbase.auth.ts`). The CLI spins up the Bun Hook Server automatically. 

Crucially, **the Hook Server is provided a privileged ZyncBase client**. The developer queries ZyncBase using the exact same `client.store` API they use in the frontend, but running as an admin that bypasses `authorization.json`. This eliminates the need to configure Prisma, Drizzle, or raw SQL just for authorization.

```typescript
// zyncbase.auth.ts
import { createAdminClient } from '@zyncbase/server';

// Automatically configured to talk to the local Zig core over IPC/WebSocket
const client = createAdminClient();

// The function name matches the `"hook"` rule in authorization.json
export async function checkDocumentAccess({ session, namespace, path, value }) {
  const workspaceId = namespace.split(':')[1];
  
  // Use the exact same Query API you use on the frontend
  const memberships = await client.store.query('workspace_members', {
    where: { 
      userId: { eq: session.userId },
      workspaceId: { eq: workspaceId }
    }
  });

  if (memberships.length === 0) return false;
  
  const role = memberships[0].role;
  return role === 'admin' || role === 'editor';
}
```

This architecture ensures the ZyncBase core remains incredibly fast and completely decoupled from business logic, while giving developers an incredibly smooth, unified API experience.
