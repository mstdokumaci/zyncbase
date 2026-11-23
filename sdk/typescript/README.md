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

Generate types from the same `schema.json` the server boots with. Besides the types, the file exports `schemaVersion`, the schema version it was generated from; compare it with `client.schemaVersion` (or the `schemaChange` event's `{ previousVersion, version }`) to notice a server on a newer major version:

```bash
# in a project that has @zyncbase/client installed (bunx resolves its local bin)
bunx generate --schema path/to/schema.json --out src/zyncbase-schema.ts
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
| Schema changed | `bunx generate --schema ... --out ...`. Commit the generated file together with `schema.json` and any migration folder (`zyncbase migrate new`); the server applies the change at its next start |
| Local development | add `--watch` to regenerate on save |
| CI | add `--check` — exits non-zero when the checked-in file is stale |

Generated files are the single source of truth for client types; commit them and gate drift with `--check`.

## React

React 19 bindings ship in the same package under the `/react` subpath:

```tsx
import { createClient } from "@zyncbase/client";
import {
	ZyncBaseProvider,
	useQuery,
	useListen,
	useSyncStatus,
} from "@zyncbase/client/react";

const client = createClient({ url: "ws://localhost:3000" });

function Tasks() {
	const { data, isLoading, error } = useQuery("tasks", {
		where: { done: false },
	});
	const title = useListen("projects.p1.name");
	const sync = useSyncStatus();
	// ...
}

root.render(
	<ZyncBaseProvider client={client}>
		<Tasks />
	</ZyncBaseProvider>,
);
```

- Hooks: `useQuery`, `useListen`, `useAction`, `usePresence`, `useSyncStatus`,
  and `useClient` — writes go through `useClient()` directly.
- The provider never connects; call `await client.connect()` yourself.
- With a generated schema, bind types once for fully typed hooks:
  `const z = createZyncBaseReact<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>();`
- React 19 is an optional peer dependency; the core client works without it.

## Yjs

A Yjs persistence/sync provider ships under the `/yjs` subpath. `yjs` is an optional peer dependency, like React: the core client does not install it, and your app supplies the one shared copy. If your app does not already have it:

```sh
bun add yjs
```

Add the three collections to the server schema. Merge `yjsStoreSchema` from the
package, or copy this JSON:

```json
{
	"yjs_documents": {
		"unique": [["slug"]],
		"fields": {
			"slug": { "type": "string", "minLength": 1, "maxLength": 120 },
			"current_snapshot_id": { "type": "string", "minLength": 1, "maxLength": 64 },
			"compacted_through": { "type": "integer", "minimum": 0 }
		}
	},
	"yjs_snapshots": {
		"required": ["document_id", "snapshot_id", "part", "parts"],
		"unique": [["snapshot_id", "part"]],
		"fields": {
			"document_id": { "type": "string", "references": "yjs_documents", "onDelete": "cascade", "indexed": true },
			"snapshot_id": { "type": "string", "minLength": 1, "maxLength": 64 },
			"part": { "type": "integer", "minimum": 0 },
			"parts": { "type": "integer", "minimum": 1 },
			"data": { "type": "bytes" }
		}
	},
	"yjs_updates": {
		"required": ["document_id", "update_id", "part", "parts"],
		"unique": [["update_id", "part"]],
		"fields": {
			"document_id": { "type": "string", "references": "yjs_documents", "onDelete": "cascade", "indexed": true },
			"update_id": { "type": "string", "minLength": 1, "maxLength": 64 },
			"part": { "type": "integer", "minimum": 0 },
			"parts": { "type": "integer", "minimum": 1 },
			"data": { "type": "bytes" }
		}
	}
}
```

The document header is a normal store row. Create it first, then pass its id to
the provider:

```ts
import * as Y from "yjs";
import { createClient } from "@zyncbase/client";
import { ZyncBaseYjsProvider } from "@zyncbase/client/yjs";

const client = createClient<ZyncBaseSchema>({ url: "ws://localhost:3000" });
await client.connect();

const documentId = await client.store.create("yjs_documents", {
	slug: "notes-demo",
});

const doc = new Y.Doc();
const provider = new ZyncBaseYjsProvider(client, documentId, doc, {
	chunkSize: 32 * 1024,
});

provider.on("sync", (synced) => {
	if (synced) bindEditor(doc);
});
provider.on("error", (error) => console.error(error));

await provider.connect();
```

- The provider connects the shared client if needed, but never disconnects it.
  `disconnect()`/`destroy()` only stop this provider.
- The `yjs_documents` schema above only declares the provider fields. Add app
  fields such as `title` or `owner_id` to that table before writing them.
- `provider.on("status", ...)`, `"sync"`, `"connection-close"`,
  `"connection-error"`, `"error"`, and `"destroy"` mirror the usual Yjs
  provider surface. `provider.synced` and `provider.connected` are synchronous.
- The provider takes the document row id, not the slug. Resolve a slug with a
  normal query if your app routes by name.
- One provider per `Y.Doc`. Multiple documents can share one client.
- A non-retryable write failure (for example `PERMISSION_DENIED`) blocks later
  writes and keeps the failed payload queued. Fix the cause and call
  `flush()` to retry; transient failures retry automatically with backoff.

### First-class integration

The header row is the document entity:

- Link app data with a foreign key to `yjs_documents.id`, for example
  `projects.document_id → yjs_documents`, with `onDelete: "cascade"` or
  `"set_null"`.
- Add app fields (`title`, `owner_id`, …) to the `yjs_documents` table.
- List documents with `store.query("yjs_documents", { orderBy: [{ updated_at: "desc" }] })`.
  `updated_at` moves on metadata writes and snapshot commits; it lags text edits
  until the compactor runs. For a live "last edited" value, query the newest
  `yjs_updates` row for the document ordered by `created_at desc`.
- Delete the header to cascade-delete updates, snapshots, and linked app rows.
  Destroy active providers first.

### Sizing

| Option | Default | Keep below |
|---|---|---|
| `chunkSize` | 32 KiB | `security.maxMessageSize` (1 MiB default) |
| `pageSize` | 64 | `security.maxQueryResponseSize` (8 MiB default) |
| `writeDebounceMs` | 150 | — |

Chunking is independent per writer: readers accept snapshots and updates written
with any chunk size. Reads halve `pageSize` and retry on `RESPONSE_TOO_LARGE`.
Small chunks mean more messages and can touch `maxMessagesPerSecond`; large
chunks risk `MESSAGE_TOO_LARGE`.

### What ships later

This iteration is the provider only: no compactor, no awareness/cursors, no
ProseMirror example. Updates are never deleted until a compactor ships, so a
fresh client reads all retained history once. The SDK also keeps live update
rows in its materialized subscription view; without a compactor deleting them,
a long session grows that view. A future delta-only subscription or explicit
release API will bound it. Seed content after the first `sync`; content edited
before the provider is constructed is not persisted.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
