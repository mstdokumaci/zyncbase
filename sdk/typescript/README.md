# @zyncbase/client

TypeScript client for ZyncBase: realtime store access, subscriptions, presence, and actions over WebSocket.

```bash
bun add @zyncbase/client
```

## Quick start

```ts
import { createClient } from "@zyncbase/client";

const client = createClient({
	url: "ws://localhost:3000",
	auth: { anonymous: true },
});

await client.connect();
await client.store.set("users.alice.name", "Alice");
const name = await client.store.get("users.alice.name");
```

## Typed schema

Generate types from the same `schema.json` the server boots with:

```bash
bunx @zyncbase/client generate --schema path/to/schema.json --out src/zyncbase-schema.ts
```

Then bind the client to it:

```ts
import { createClient } from "@zyncbase/client";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./zyncbase-schema";

// The action and presence type arguments are optional.
const client = createClient<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>({
	url: "ws://localhost:3000",
});

await client.store.set("users.alice.age", 30); // value type checked
await client.store.get("users.alice.age");      // Promise<number | undefined>
await client.store.query("countries", {
	where: { count: { gte: 10 } },
	orderBy: [{ count: "desc" }],
});                                              // rows include id: string

const joined = await client.actions.call("player_join", {
	name: "Alice",
	country_id: 1,
	session_id: "...",
});                                              // joined.user_id is string
await client.presence.set({ status: "active" }); // enum checked (when declared)
```

What is checked: collection names, dot-path and tuple-path fields, `get`/`set`/`create`/`listen` value types, `query`/`subscribe` rows and `getSnapshot()`, `where` fields and operators, single-field `orderBy` clauses, action names/params/enums/returns, and presence payloads. Reads include the server-issued `id`; writes use the schema fields only.

Not yet typed: `batch` operation values and the wire-internal message types — they accept their dynamic shapes.

Generic helpers should be parameterized (`Store<S>`, `ZyncBaseClient<S>`) rather than annotated with the bare fallback types: the typed and permissive surfaces are not mutually assignable, so a `ZyncBaseClient<ZyncBaseSchema>` does not flow into a slot typed `ZyncBaseClient`.

### Regeneration lifecycle

| When | Command |
|---|---|
| Schema changed | `bunx @zyncbase/client generate --schema ... --out ...` (same moment you restart the server to apply the migration) |
| Local development | add `--watch` to regenerate on save |
| CI | add `--check` — exits non-zero when the checked-in file is stale |

Generated files are the single source of truth for client types; commit them and gate drift with `--check`.

## License

See the repository root.
