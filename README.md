# ZyncBase

Realtime database with filtered subscriptions, presence, actions, and Yjs — on
infrastructure you control. Built in Zig on uWebSockets, SQLite WAL, and a
compact MessagePack protocol.

**Status:** early development. Single-node by design. No automatic failover or
multi-node replication. APIs may change; validate against your workload before
production.

## Why ZyncBase

- **Predictable self-hosted cost.** One SQLite database on a server you control;
  no per-read/per-write billing and no managed-service lock-in.
- **Filtered fanout, not raw broadcast.** Live queries run on the server, so a
  write only reaches matching subscribers.
- **One stack for realtime primitives.** Store, presence, actions, atomic
  batches, Yjs collaboration, and React bindings in one client SDK.
- **Density.** The reference run handled 50,000 concurrent clients on about 2
  cores and 1.5 GB RSS.
- **Documented single-node operations.** Online snapshots, restore drills,
  Litestream replication, migrations, and durability modes are covered.

Managed realtime services are the better default when you need zero-ops, global
edge, or automatic failover. ZyncBase targets the other case: you want the
realtime layer to be a file on a server you control, with predictable cost.

## Features

| | |
|---|---|
| **Store** | Path-based documents, filtered live subscriptions, atomic batches |
| **Presence** | User and shared presence, awareness for collaborative editors |
| **Actions** | Server-side actions with schema-typed parameters and results |
| **Yjs** | CRDT provider, snapshots, compaction, awareness mirroring |
| **Auth** | JWT sessions, scoped namespaces, authorization rules |
| **Schema** | Strict validation, generated TypeScript types, migrations |
| **Transport** | MessagePack over uWebSockets; SQLite WAL persistence |
| **SDK** | TypeScript client, React 19 bindings, Yjs provider |

## Quick start

Prerequisites: Zig 0.16, Bun, and OpenSSL. See [BUILD.md](BUILD.md).

```sh
bun install
bun run demo:game        # builds the SDK and server, then opens localhost:8080
```

Other demos:

```sh
bun run demo:quorum
bun run demo:verso
```

Use the TypeScript SDK directly against your own server (default port 3000).
The server needs `authentication.ticket` and `authentication.anonymous.enabled`;
the demos issue their own scoped tokens and apply their own authorization.

```sh
bun add @zyncbase/client
```

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

See [sdk/typescript/README.md](sdk/typescript/README.md) for typed schemas,
React bindings, and Yjs.

## Examples

- [Cordon Off](examples/cordon-off/README.md) — a multiplayer territory game:
  browser actions, a Bun simulation, and two independently sized chunk-table
  subscriptions.
- [Quorum](examples/quorum/README.md) — a live decision room with presence,
  private vote budgets, and an atomic reveal, built with the React bindings.
- [Verso](examples/verso/README.md) — a Notion-like workspace with Yjs editing,
  page history, and presence carets.

## Performance

Reference run on a 12-logical-CPU host:

- **50k clients, 5 namespaces:** ~2 cores, ~1.5 GB RSS, 10.5M store fanout
  messages at ~2.6–3.9M messages/s, ~0.8–1.0M presence messages, client-observed
  store p99 1.0–1.5 s during the burst.
- **100k clients, 10 namespaces:** completes, but the event loops saturate;
  store create p99 rises to 3.4–3.9 s and the update maximum reaches 4.7–5.2 s
  (update p99 is censored at the 5 s histogram cap). This is a stress result,
  not the recommended operating point.
- **Caveat:** these are synchronized-burst numbers, not sustained throughput or
  steady-state p99. 100k here is ten namespaces of 10k clients, not one
  100k-subscriber namespace.

Methodology, isolation checks, and caveats: [benchmark/README.md](benchmark/README.md).

## Production

Single-node operation is documented in [OPERATIONS.md](OPERATIONS.md):

- Consistent online snapshots, `verify`, and restore with a safety copy.
- Cron/systemd scheduling, retention, offsite copies, and Litestream for
  second-level RPO.
- Startup migrations with dry-run, pre-migration snapshots, and rollback.
- `storage.synchronous` durability modes and WAL/checkpoint monitoring.

**Boundary:** backups and restores are covered; automatic failover and
multi-node replication are not. Plan for manual recovery or add external
automation.

## Fit

**Good fit**

- Self-hosted SaaS, internal tools, community apps, and on-prem deployments.
- Multiplayer games, live decision rooms, collaborative editors, and presence-heavy
  apps.
- Teams that value data ownership, predictable cost, and SQLite operations.
- Workloads up to roughly 50k concurrent clients per node.

**Not yet**

- Global multi-region or automatic failover requirements.
- Zero-ops managed-service expectations.
- Large single-namespace fanout: the measured 100k is ten namespaces of 10k
  clients, not one namespace with 100k subscribers.

## Documentation

| I want to… | Read |
|---|---|
| Build from source | [BUILD.md](BUILD.md) |
| Deploy, back up, restore, migrate | [OPERATIONS.md](OPERATIONS.md) |
| See benchmark results and caveats | [benchmark/README.md](benchmark/README.md) |
| Use the TypeScript SDK | [sdk/typescript/README.md](sdk/typescript/README.md) |
| Try a complete app | [examples/](examples/) |
| Understand the internals | [specs/README.md](specs/README.md) |
| Contribute | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Cut a release | [RELEASING.md](RELEASING.md) |

## License

ZyncBase is licensed under the **Business Source License 1.1**.

- **Source code is available** for everyone to view, modify, and use for
  non-production purposes.
- **Production use is permitted** as long as you are not offering ZyncBase as a
  managed cloud service.
- **Automatic Open Source:** on **January 1, 2032**, the project transitions to
  the **Apache License 2.0**.
- **TypeScript SDK** (`sdk/typescript/`): **Apache License 2.0** — see
  [sdk/typescript/LICENSE](sdk/typescript/LICENSE).

For full terms, see [LICENSE](LICENSE).
