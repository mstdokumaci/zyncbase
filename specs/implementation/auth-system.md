# ZyncBase Authorization Format (`authorization.json`) - Draft Spec

**Status**:  Done
**Context**: Replaces complex row-level security (RLS) with a high-performance, JSON-declarative model executed natively by the ZyncBase Zig core. Evaluated on every incoming MessagePack frame.

**Drivers**:
- [Configuration API Design](../api-design/configuration.md) - Authorization rules and hook management requirements.

---

## 1. Core Principles

1. **Deny by Default**: All access is denied unless explicitly allowed by a rule.
2. **Variables Context**: Rules are evaluated against a context containing:
   - `$session`: The resolved session context (enriched from JWT and/or Hook Server).
   - `$namespace`: The current namespace string.
   - `$path`: Array or string of the specific data path being accessed (for `store`).
   - `$doc`: (Future) The existing document in the database, enabling attribute-based access control (ABAC).
3. **Query Language Syntax**: Conditions use the exact same JSON structure as the ZyncBase Query Language (implicit ANDs, explicit `or`, e.g., `{ "$session.role": { "eq": "admin" } }`), ensuring easy parsing and safe evaluation without `eval()`.
4. **Separation of Concerns**: Namespaces handle coarse-grained isolation (e.g., tenant separation), while path rules handle fine-grained access (e.g., table/document level).

## 2. Rule Format Structure

The file is organized by **Namespaces**, followed by **Paths** within those namespaces.

```json
{
  "rules": [
    {
      "namespace": "public",
      "read": true,
      "write": false
    },
    {
      "namespace": "tenant:${tenant_id}:*",
      "condition": { "$session.tenantId": { "eq": "$namespace.tenant_id" } },
      
      "presence": {
        "read": true,
        "write": true
      },

      "paths": [
        {
          "path": "*",
          "read": true,
          "write": { "$session.role": { "in": ["admin", "editor"] } }
        },
        {
          "path": "users.${user_id}",
          "read": true,
          "write": { "$session.sub": { "eq": "$path.user_id" } }
        }
      ]
    }
  ]
}
```

## 3. Evaluation Order & Conflict Resolution

- **Top-Down Evaluation**: Rules within the `rules` array, and `paths` arrays, are evaluated top-down. 
  - *Alternative to consider*: Most-specific-match first (avoids ordering bugs, but harder to implement and reason about).
- **Early Exit**: As soon as a rule explicitly grants access (`true` or matching condition), evaluation stops and access is permitted. 
- **Namespace-First**: The frame's namespace is checked first. If no namespace rule matches or the namespace `condition` fails, the frame is rejected immediately, bypassing path evaluation.

## 4. Namespace Wildcard Behavior & Session Expectations

Namespaces use a colon-separated segment model. Wildcards (`*`) can be used to match segments and extract variables into the `$namespace` context.

**Crucial understanding: ZyncBase is stateless for authorization.**
Any hierarchical namespace authorization requires that data to be present in the `$session`.

**Example 1: Tenant Isolation (Common)**
- Session contains: `{ "tenant_id": "acme" }`
- Namespace: `tenant:${tenant_id}`
- Rule: `{ "$namespace.tenant_id": { "eq": "$session.tenant_id" } }`
- *How it works*: User connects to namespace `tenant:acme`. ZyncBase extracts `acme` as `$namespace.tenant_id`. It compares it to `$session.tenant_id`. If they match, access is granted.

**Example 2: Workspace Isolation (Complex)**
- If you use a namespace like `tenant:acme:workspace:123`, how does ZyncBase know the user is allowed in `workspace:123`?
- **Option A (Injected arrays)**: The `$session` (via `onConnect`) contains an array of allowed workspaces: `{ "workspaces": ["123", "456"] }`. 
  - Rule: `{ "$namespace.workspace": { "in": "$session.workspaces" } }`
- **Option B (Document-level check)**: If the `$session` only has the user me ID, ZyncBase would need to check the database (`$doc`) to see if the user is a member of the workspace. (See Open Questions).

To keep the initial implementation focused and performant, we should prioritize **Namespace matching against the resolved `$session`**, keeping the hierarchy shallow until we decide on the necessity of `$doc` evaluation.

## 5. Presence API Authorization

Unlike the Store API which has fine-grained nested data paths, the Presence API is a flat, namespace-wide concept. Users join a presence namespace, broadcast their own state, and listen to others.

Therefore, presence authorization is defined directly at the `namespace` level alongside `paths`:
- **`read`**: Permission to subscribe to the presence channel and see who is online.
- **`write`**: Permission to broadcast your own presence object to the channel (schema validation still applies).

Because presence is ephemeral, there is no `$doc` equivalent and no path-level routing. 

**Hook Server Support:**
Presence rules fully support Hook Server Delegation (see **Section 7: The Bun Hook Server** for details). If you need relational lookups before letting a user join a presence channel (e.g., "is this user a paid subscriber?"), you can delegate it exactly like a path rule:

```json
"presence": {
  "read": { "hook": "checkPresenceAccess" },
  "write": { "$session.role": { "in": ["admin", "paid"] } }
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
      "$session.sub": { "eq": "$path.user_id" }
    }
  ]
}
```



## 7. The Bun Hook Server (Managing Complexity)

The core tension in authorization is between **stateless performance** and **complex relational permissions** (e.g., "does this user belong to the workspace that owns the folder containing this document?").

To solve this, ZyncBase draws a hard line:
1. **`authorization.json` is strictly for stateless checks.** (e.g., `$namespace.tenant == $session.tenant_id`). It is exceptionally fast and evaluated natively in Zig.
2. **Any rule requiring a database lookup (`$doc` or external tables) is delegated to the Bun Hook Server.**

We do *not* attempt to build a Turing-complete database lookup engine into `authorization.json`. Instead, ZyncBase provides an out-of-the-box Bun WebSocket server. Developers simply write a TypeScript function to handle complex auth logic.

**Example `authorization.json` delegation:**
```json
{
  "namespace": "tenant:*",
  "paths": [
    {
      "path": "documents.*",
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
      userId: { eq: session.sub },
      workspaceId: { eq: workspaceId }
    }
  });

  if (memberships.length === 0) return false;
  
  const role = memberships[0].role;
  return role === 'admin' || role === 'editor';
}
```

This architecture ensures the ZyncBase core remains incredibly fast and completely decoupled from business logic, while giving developers an incredibly smooth, unified API experience.
