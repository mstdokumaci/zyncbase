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
   existed after one committed change.
6. Go offline (DevTools → Network → Offline), keep typing, come back. The body
   merges on reconnect.

## How it is put together

A page is one row. Its body is a Yjs document; its metadata is columns on the
same row:

```
pages            id, title, icon, parent_id → pages (cascade), position,
                 compaction_version, current_snapshot_id, compacted_through
page_changes     append-only Yjs updates, chunked, written by the provider
page_snapshots   compacted Yjs state, written by the compactor
```

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

## Files

| File | Purpose |
|---|---|
| `server.ts` | ZyncBase process, compactor, `/session`, and the welcome seed |
| `dev.ts` | Static assets plus `/session`, `/auth/ticket`, and `/ws` proxying |
| `schema.json` | `pages` tree + `page_changes`/`page_snapshots` + presence fields |
| `authorization.json` | Workspace namespace and collection rules |
| `workspace.tsx` | Sidebar tree, routing (`#/<pageId>`), empty states |
| `page.tsx` | Provider lifecycle per page, title editing, avatars, icons |
| `editor/` | Tiptap setup, slash menu, sub-page node, cursor ↔ presence mapping |
| `history.tsx` | Replay panel and read-only preview |
| `seed.ts` | Deterministic welcome document, written server-side |
| `smoke.ts` | Two clients, cascade delete, caret round-trip, history replay |
