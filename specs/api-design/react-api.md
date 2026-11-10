# React API Reference (`@zyncbase/client/react`)

The React layer is thin bindings over the existing client namespaces — Store, Presence, Actions, and connection lifecycle — for React 19 frontend applications. It adds no state manager, no second copy of the data, and no new wire messages. Every hook is a wrapper around a client primitive that already exists: `store.subscribe`, `store.listen`, `presence.subscribe`, `actions.call`, and `client.on`.

This document is the design contract for the React layer. The implementation spec is deliberately narrow: React 19 only, one package, six hooks, nothing speculative. Related specs: [Store API](./store-api.md), [Presence API](./presence-api.md), [Actions API](./actions-api.md), [Connection Management](./connection-management.md), [Error Handling](./error-handling.md).

## Table of Contents

1. [Design Principles](#design-principles)
2. [Decision Log](#decision-log)
3. [Package & Exports](#package-exports)
4. [Provider](#provider)
5. [Hooks](#hooks)
6. [Loading & Error States](#loading-error-states)
7. [Lifecycle Contract](#lifecycle-contract)
8. [Deliberately Not Included](#deliberately-not-included)
9. [Testing Requirements](#testing-requirements)

---

## Design Principles

1. **The client is the engine; React is a view adapter.** Reconnection, subscription restore, retry, and ack handling live in `@zyncbase/client`. Hooks never duplicate that logic.
2. **Every hook maps to one client primitive.** If a hook cannot be described as "the client primitive, made reactive", it does not belong in this layer.
3. **No manual effect subscriptions.** A frontend developer should never write `useEffect` + `subscribe` + cleanup for any of the three namespaces. (This is the failure mode of raw WebSocket-based SDKs — channels plus manual `removeChannel()` — which competitors solved at the hooks layer.)
4. **Writes are not hooks.** Unlike Convex, ZyncBase writes are typed client operations (`store.set`, `store.create`, `store.remove`, `store.batch`, `actions.call`). Components obtain the client via `useClient()` and call writes directly, in the InstantDB style (`db.transact`). There is no `useMutation` wrapper.
5. **Suspense comes later, binary-compatible with these names.** Hooks here never suspend; a future `/react/suspense` dual export will follow the Liveblocks pattern. Nothing in this spec may later conflict with that addition.

## Decision Log

Locked during competitive research (session 2026-11-10), with receipts. Cite these instead of re-arguing.

| Decision | Choice | Receipt |
| :--- | :--- | :--- |
| Package layout | Same package, `/react` subpath (not a second package) | Convex (`convex/react`), Zero (`@rocicorp/zero/react`). At 0.x protocol churn, a second package doubles version choreography; splitting later is easy, merging is not. |
| React target | `^19.0.0` peer dependency, **optional** so non-React consumers are unaffected | React 19 covers the audience; `peerDependenciesMeta.optional` keeps Node/bun CLI users of the core package clean. |
| Query hook return | `{ data, isLoading, error }` triad (not a tuple, not `undefined`-punning) | InstantDB, PowerSync (`+isFetching`), Liveblocks all use the triad. Majority of the cohort; friendlier than Convex's `undefined`-while-loading. |
| Conditional queries | `"skip"` sentinel argument (not `enabled: false`) | Convex's documented pattern; one-line semantics, no config object growth. |
| Presence hook shape | `{ mine, peers, publish }` with merge-on-publish | InstantDB `db.rooms.usePresence`. Almost identical to our `Presence` client primitive (`localUserId`, unordered `PresenceEntry[]`, `set`). |
| Status hook shape | `{ status, synced }` over `ConnectionStatus` + lifecycle events | Liveblocks' richer `lost/restored/failed` vocabulary requires client-side lost-detection the client does not expose yet; keep the hook mapped to existing primitives. |
| Optimistic writes | Out of scope; subscription-first propagation stays (ADR-018) | Local echo is a client-store product decision, not a hooks concern. Mentioned here so it is not rediscovered. |
| Suspense variant | Deferred to a future dual export | Liveblocks ships root + `/suspense`; Zero builds suspense-first. Both validate that this can be added without renaming anything. |

## Package & Exports

The package stays `@zyncbase/client`. One new entry point:

```json
{
  "exports": {
    ".": { "types": "./dist/index.d.ts", "import": "./dist/index.js" },
    "./react": { "types": "./dist/react/index.d.ts", "import": "./dist/react/index.js" }
  },
  "peerDependencies": { "react": "^19.0.0" },
  "peerDependenciesMeta": { "react": { "optional": true } }
}
```

- The root export depends on nothing React. Bundlers tree-shake it clean.
- Importing `@zyncbase/client/react` without React installed fails at import time with a bundler-resolution error — acceptable and expected; documented.
- Module format follows the package convention (ESM only).

## Provider

```tsx
import { ZyncBaseProvider } from "@zyncbase/client/react";

<ZyncBaseProvider client={client}>
  <App />
</ZyncBaseProvider>
```

- The provider stores **only the client reference** in context — no derived state, no subscriptions. It never calls `client.connect()`; connecting stays explicit (`await client.connect()`), so server-side rendering and route loaders control when the session starts.
- The module is marked `"use client"` for React Server Components boundaries.
- All hooks throw a descriptive development error (with a link to this spec) when rendered outside a `ZyncBaseProvider`.
- The client instance is treated as a stable singleton. Swapping it during a component's life is supported (subscriptions re-bind), but is not an optimization to rely on.

## Hooks

Six hooks, in dependency-free order. All return-triad members are stable between deliveries.

### `useQuery(collection, options | "skip")`

Reactive collection query over `store.subscribe`.

```typescript
const { data, isLoading, error } = useQuery("tasks", {
  where: { done: false },
  orderBy: [{ createdAt: "desc" }],
});
const nothing = useQuery("tasks", "skip");
```

- `data: RowsOf<S, C>` — current rows, synchronously available from the first server delivery; `[]` before it and while skipped.
- `isLoading` — `true` until **any** snapshot has been delivered since the hook's subscription began; `false` thereafter, also when skipped.
- `error: ZyncBaseError | null` — subscription-registration failures land here; render never throws.
- Subscribes on mount, `unsubscribe()` on unmount. Re-subscription happens only when the canonical query changes: options are key-serialized (sorted-key canonical form), so callers may pass inline object literals safely.
- `"skip"` registers nothing and resets the triad — the Convex conditional-query idiom for hooks under early returns.
- Pagination (`handle.loadMore`, `hasMore`) is **not** exposed by this hook yet; see [Deliberately Not Included](#deliberately-not-included).

### `useListen(path)`

Reactive single-path value over `store.listen`.

```typescript
const { value, isLoading, error } = useListen("users.alice.status");
```

- `value: GetValue<S, P>` — last value, or `undefined` before the first delivery (matches `ListenHandle.getSnapshot` semantics exactly).
- Same triad, subscribe/unmount, and canonical-keying rules as `useQuery`.
- Changing `path` between renders unlistens the old path and listens the new one; the hook must tolerate the async `unlisten` rejection race by ignoring late deliveries from a detached handle.

### `useAction(name, options?)`

Bound, typed action caller over `actions.call`.

```typescript
const join = useAction("player_join");
// ... onClick={() => join({ name: "Alice", country_id: 1 })}
```

- Returns a stable `useCallback`-memoized function — safe in dependency arrays.
- Does **not** track loading or error state internally (Convex convention): the caller owns await/catch. Errors reject with `ActionTimeoutError`/`ActionError` per [Error Handling](./error-handling.md).
- Type safety comes from the generated `ZyncBaseActions` type, identical to `client.actions.call` contract.

### `usePresence()`

Ephemeral peer awareness over `presence.subscribe`, InstantDB shape.

```typescript
const { mine, peers, publish } = usePresence();
publish({ status: "typing" });
```

- `mine` — own `PresenceEntry`, resolved by `presence.localUserId`; `undefined` before scope setup.
- `peers: PresenceEntry[]` — everyone but self. Snapshot-derived; referentially stable between wire deliveries.
- `publish(data)` — memoized wrapper of `presence.set` (merge semantics unchanged, throttled to ~60fps by the client).
- **Shared wire subscription requirement:** multiple components using `usePresence()` concurrently must share one underlying `presence.subscribe()` (refcounted in a per-client registry), not fan out N wire subscriptions. The whole-namespace snapshot shape makes this both possible and necessary. `presence.setShared`/`subscribeShared` are exposed only via `useClient()` in this iteration.
- Unsubscribes when the last consumer unmounts.

### `useSyncStatus()`

Connection surface over `client.status`, `statusChange`, `connected`, `reconnected`, `synced`.

```typescript
const { status, synced } = useSyncStatus();
// status: "connecting" | "connected" | "reconnecting" | "disconnected"
```

- `synced: boolean` — `true` only after a `synced`/`reconnected` event and until the next disconnect; the "my reads are current" banner state.
- Server-side snapshot: `{ status: "disconnected", synced: false }`.
- Rich detail (`DisconnectDetail`) remains available on `client.on("disconnected", ...)` — escape hatch on purpose.

### `useClient()`

```typescript
const client = useClient();
await client.store.set("users.u1.name", "Alice"); // typed write
await client.store.create("tasks", { title: "New" });
```

- The write path. Typed by the generated schema; identical to the plain client API.
- Also the escape hatch for everything this iteration deliberately does not wrap (`presence.setShared`, `presence.subscribeShared`, raw `store.get`, `batch`, `client.on`).

The module-level hooks are loosely typed (`SchemaLike`). Applications with a
generated schema bind their types once through the factory — same six bindings,
fully typed rows and action signatures:

```tsx
const z = createZyncBaseReact<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>();

<z.ZyncBaseProvider client={client}>
	<App />
</z.ZyncBaseProvider>

const { data } = z.useQuery("tasks", { where: { done: false } }); // typed rows
const join = z.useAction("player_join"); // typed params and returns
```

## Loading & Error States

Uniform rule across every data hook:

| State | Meaning |
| :--- | :--- |
| `isLoading === true` | Hook registered a real subscription; no server snapshot has arrived for this registration yet. Never true while skipped. |
| `error !== null` | The registration failed (validation, namespace, auth here — not network resumption; reconnection retries live in the client). Stale last-known data stays in `data`. |
| Both false | Steady state: fresh data, `data` referentially stable between deliveries. |

Hooks never throw during render and never suspend. Errors thrown by the client's async plumbing outside registration use the client's fire-and-forget `error` event — via `useClient().on(...)` when an app needs it.

## Lifecycle Contract

This section binds what the React layer must and must not do:

- **Reconnection:** the client restores all active subscriptions and emits `synced`/`reconnected`. Hooks must not unsubscribe/resubscribe on connection events. If a hook re-subscribes on anything, it is wrong.
- **Schema change:** the client invalidates active subscriptions and re-registers them itself; hooks again do nothing. Any new data arrives through the same callback.
- **Strict Mode:** double mount/unmount must leak neither wires subscriptions nor callbacks. Handles are disposable; late async acks after unmount are ignored, not unawaited garbage.
- **Never read-and-throw:** registration methods whose promise rejects mid-render windows resolve in effect scope, not render scope. The triad fields are the only render-visible effect.

## Deliberately Not Included

Named so absence is a decision, not an omission. Each is a cheap follow-up in version order:

- **`/react/suspense` dual export** — Liveblocks-style; hooks get suspense twins sharing semantics with these names.
- **Infinite query hook** — `SubscriptionHandle.loadMore`/`hasMore` exist client-side; a hook will come with cursor UX rather than wrapping them ad hoc.
- **Selector + shallow rerender control** (`useOthers(selector, shallow)`, `rowComparator`) — mirror Liveblocks/PowerSync if real apps show over-render pain our snapshot diffing does not already cure.
- **`useMutation`-style write hooks and optimistic local echo** — blocked on an ADR-level product decision in the store, not React.
- **TanStack Query adapter** — InstantDB ships one after their React SDK hardened (`start-tanstack` guide), a good precedent for when to add one.
- **React Native** — the client library is runtime-agnostic, but hooks stay browser/worker-targeted until someone asks.
- **Devtools** — not a spec artifact until the API stabilizes.

## Testing Requirements

Creation of `@zyncbase/client/react` is the following iteration; these are its acceptance criteria. Hook tests run under `@testing-library/react` with happy-dom via Bun; per repo convention, no production code is added to accommodate tests:

1. Provider missing → every hook throws a descriptive dev error.
2. `useQuery` triad transitions: `isLoading` true → false on first delivery; skip sentinel registers nothing; inline option literals do not re-subscribe.
3. `useListen` path change re-binds; late detached deliveries ignored.
4. `useAction` returns a stable identity; rejects propagate.
5. `usePresence`: `publish` reaches `presence.set`; peers exclude self; two consumers share one wire subscription (registry asserted); last unmount unsubscribes.
6. `useSyncStatus`: maps `statusChange` and `synced`/`reconnected` exactly; correct SSR defaults.
7. Unmount/Strict-Mode double-invoke leaks nothing (mock handles count calls).
8. **One live e2e** against a running server: provider + `useQuery` + `useListen` + real `store.set` round-trip, verifying the hook's `data` matches the plain client's `getSnapshot()` for the same query (existing e2e harness). Protocol changes (if any) re-run `bun run test:e2e` per repo convention.
