# Verso

A small Notion-like workspace on ZyncBase. Pages nest, bodies are rich text,
two people type into the same paragraph, and every page can be replayed from its
change log.

```sh
bun run demo:verso        # build ZyncBase + open http://localhost:8080
bun run demo:verso:dev    # same, without rebuilding ZyncBase
bun run demo:verso:dev --reset
bun run test:verso
```

To open the demo from another machine on your network:

```sh
LAN_IP=$(ipconfig getifaddr en0)   # your LAN address; `ip -4 addr` on Linux
VERSO_HOST=0.0.0.0 \
VERSO_ORIGINS="http://localhost:8080,http://$LAN_IP:8080" \
  bun run demo:verso:dev
```

`VERSO_HOST` is the interface the edge binds; it defaults to `127.0.0.1`, so
nothing is exposed unless you ask. `VERSO_ORIGINS` is an exact-match,
comma-separated allowlist; it feeds both the app server's `Origin` check and
ZyncBase's `allowedOrigins`. Only the edge listens on the network: the app
server and ZyncBase stay on loopback and are reached through its `/auth/ticket`
and `/ws` proxies. macOS asks for incoming-connection permission the first time.
Identity is claimed, so anyone who can reach the URL can edit every page.

The demo uses one workspace (`verso:main`) and one claimed identity per browser
tab: open a second window, enter a different email, and you are a second person
with your own caret. Same email in two tabs is the same person, and the two
carets collapse into one — that is the presence semantics, not a bug.

## What to try

1. Type in the welcome page from two windows at once. The text merges; the
   titles do not (last write wins, on purpose).
2. Select a word: a floating toolbar appears with bold, italic, underline,
   strikethrough, and inline code. `⌘/Ctrl+B` and `**bold**` do the same thing.
3. Put the caret at the start of a line and type `/` for headings, lists,
   to-dos, quotes, code, dividers, and a link to another page.
4. Use the `⋯` menu in the sidebar to nest, reorder, and delete pages.
5. Press **History** and drag the slider: each step is the document as it
   existed after one committed change, labelled with who wrote it.
6. Leave and re-enter with a different name in one window: the other window's
   creator/editor line under the title updates without a reload, because the
   profile lives in a users row.
7. Go offline (DevTools → Network → Offline), keep typing, come back. The body
   merges on reconnect.

## How it is put together

A page is one row. Its body is a Yjs document; its metadata is columns on the
same row:

```
users            id, external_id, name, color (global: one row per person)
pages            id, title, icon, parent_id → pages (cascade), position,
                 compaction_version, current_snapshot_id, compacted_through
page_changes     append-only Yjs updates, chunked, written by the provider
page_snapshots   compacted Yjs state, written by the compactor
```

Every row also carries system columns: `owner_id` (the writer's `users.id`,
stamped on creation and never rewritten), `created_at`, and `updated_at`. The
creator line under the title reads `owner_id`; the editor line reads the newest
`page_changes.owner_id`. Both are looked up in `users`, so no name is copied
onto a page.

Three consequences worth looking at:

- **Deleting a page is one write.** `pages.parent_id` references `pages` with
  `onDelete: "cascade"`, and the chunk rows reference `pages` the same way, so a
  single `remove` deletes the subtree, every update, and every snapshot.
- **The title is last-write-wins; the body is a CRDT.** Renaming a page is a
  plain store write (`store.set(['pages', id, 'title'], …)`), because a name
  does not need merging. The body goes through Yjs, because prose does. The
  example shows both halves of ZyncBase in one screen.
- **Presence carries the carets.** Tiptap writes `{user, cursor}` into a Yjs
  awareness instance; the provider mirrors it into `presence.user`, and the
  other client rebuilds the awareness state from presence. Cursors are plain
  relative-position JSON, not bytes — `type` and `item` are `{client, clock}`
  IDs, which is why the presence schema declares them as objects.

### Renamed collections

The SDK ships the Yjs collections as `yjs_documents`, `yjs_updates`, and
`yjs_snapshots`. This example names them `pages`, `page_changes`, and
`page_snapshots` through the `collections` option on both the provider and the
compactor, and copies the matching schema fragment into `schema.json`. The
defaults still work exactly as documented in `sdk/typescript/README.md`; this is
the same provider with better domain names. If the SDK's Yjs schema ever gains a
field, this copy has to gain it too.

### History

`page_changes` is an append-only log, so history is a replay: assemble the
chunks in order, apply them to an empty `Y.Doc`, and render that document
read-only. No extra tables. The panel loads at most the 200 newest changes, so
the replay starts at the oldest loaded change, not at page creation; updates
that depend on earlier, now-absent content render without it. The compactor
deletes updates after `updateRetentionMs` (set to 7 days here), so both the
window and compaction can truncate the past. The panel shows its notice when it
hit the 200-change limit, or when the oldest loaded change is more than five
seconds (5,000,000 microseconds of `created_at`) after the page's creation.

## Identity is claimed, not verified

`POST /session` mints a JWT for whatever email the form contains. That is fine
for a demo and useless for a product. To make it real, verify the subject before
minting (passwordless link, OAuth, whatever) and keep the rest: ZyncBase only
cares that `$session.workspace` matches the namespace, so `authorization.json`
does not change. Anyone who can reach this demo can also rewrite any page.

## Limits this example accepts

- Offline covers the document body. Page titles, page creation, and deletes are
  store writes, and store writes are never retried: they fail while offline.
- One awareness-enabled document per tab, because presence is scoped per
  connection. Switching pages switches the presence namespace and rebuilds the
  provider.
- Images and file uploads are out; there is no upload endpoint.
- The selection toolbar covers inline marks only. Adding or editing a link is
  not wired; pasted URLs autolink through StarterKit's Link extension.
- Delete is immediate and cascades. There is no trash.
- Tiptap is pinned to one caret extension and the free starter kit; no paid
  Tiptap features are used.
- The user directory holds a display name and color only; your email stays in
  the tab you typed it into. It is the global `users` table, so a database
  shared by several workspaces pools profiles across them.
- "Edited by" comes from the change log, so it tracks body edits. Renaming a
  page or changing its icon writes the row and does not create a change row.
  The seeded welcome page was written by the service account, which has no
  profile, so it shows a time with no name.

## Files

| File | Purpose |
|---|---|
| `server.ts` | ZyncBase process, compactor, `/session`, and the welcome seed |
| `dev.ts` | Static assets plus `/session`, `/auth/ticket`, and `/ws` proxying |
| `schema.json` | `users` profiles + `pages` tree + `page_changes`/`page_snapshots` + presence fields |
| `authorization.json` | Workspace namespace and collection rules |
| `workspace.tsx` | Sidebar tree, routing (`#/<pageId>`), empty states |
| `page.tsx` | Provider lifecycle per page, title editing, avatars, icons, creator/editor line |
| `editor/` | Tiptap setup, slash menu, sub-page node, cursor ↔ presence mapping |
| `history.tsx` | Replay panel and read-only preview |
| `seed.ts` | Deterministic welcome document, written server-side |
| `smoke.ts` | Two clients, cascade delete, caret round-trip, history replay |
