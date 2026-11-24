# Yjs Provider

**Source files**: `sdk/typescript/src/yjs/{provider,storage,awareness,index}.ts`

The Yjs provider persists a `Y.Doc` in ZyncBase. Yjs updates are stored as
append-only rows, and a separate compactor folds them into chunked snapshots.

## Data model

Documents are first-class store rows. Other collections can reference
`yjs_documents.id` with a foreign key.

| Collection | Owner | Purpose |
|---|---|---|
| `yjs_documents` | application | One header row per document: slug, app metadata, snapshot commit pointer, compaction watermark |
| `yjs_snapshots` | compactor | Chunked compacted `Y.Doc` state |
| `yjs_updates` | providers | Chunked append-only incremental updates |

`yjs_documents` fields:

- `slug` (optional, unique, ≤ 120 chars) — application-facing name.
- `current_snapshot_id` (optional) — commit pointer to the active snapshot generation.
- `compacted_through` (optional integer) — max `yjs_updates.created_at` included in that snapshot.
- `compaction_version` (required integer) — compare-and-swap counter owned by the compactor. Apps create headers with `0`; the provider ignores it.
- Apps may add fields such as `title` or `owner_id`.

System fields are structural:

- `yjs_documents.id` is the document identity and FK target.
- `yjs_documents.updated_at` changes when metadata or the snapshot pointer is written.
- `yjs_updates.created_at` orders paging and retention and drives `compacted_through`.
- Snapshot/update row `id` values are the per-chunk row identities.

`yjs_snapshots` and `yjs_updates` both reference `yjs_documents` with
`onDelete: "cascade"`. Deleting a document header deletes its content.

## Chunk protocol

A logical payload (one update or one snapshot) is stored as one or more rows.
`chunkSize` is the maximum `data` bytes per row.

- Single part: `parts = 1`, `part = 0`, `data` present. Complete immediately.
- Multi part: data rows `part = 0..parts-1`, plus a commit row
  `part = parts` with no `data` and a `committed` flag. Update writers create
  the commit row first with `committed = false`, write the parts, then commit
  it with a conditional write `committed = false → true`. Snapshot writers
  write the commit row with `committed = true` after the parts.
- A payload is complete only when every part exists and the commit row
  explicitly has `committed = true`. There is no default: an absent or `false`
  flag means uncommitted and never seals the payload.
- A failed write attempt requeues its bytes. The next attempt uses a fresh
  payload ID and row IDs; the abandoned rows are ignored until the compactor
  reclaims them.
- Readers accept any chunk size; payloads are self-describing.
- Incomplete payloads are ignored (in-flight or abandoned writers). The
  compactor removes an uncommitted marker before it reclaims the group; after
  that removal, the writer's conditional commit fails and the group cannot
  become visible.

## Snapshot commit protocol (compactor)

1. Load the current snapshot and updates; apply both to a temporary `Y.Doc`.
2. Encode with `Y.encodeStateAsUpdate`.
3. Write `yjs_snapshots` parts, then the commit row with `committed = true`.
4. Atomically set `current_snapshot_id` and `compacted_through` on the header.
   `compacted_through` is the max `created_at` of updates actually applied.
   **This header write is the commit.**
5. Delete old snapshot generations and covered updates older than the retention
   window.

Never delete before step 4. `created_at` is assigned by the server at commit, so
an update that commits after the scan has a timestamp greater than
`compacted_through` and is not incorrectly considered included.

## Provider sync

`connect()`:

1. Ensure the shared client is connected (only when `client.status === "disconnected"`).
2. Subscribe to `yjs_updates` for `document_id`, ordered `created_at desc`,
   `limit: 1`. Awaiting the subscription is the session-readiness barrier.
3. Read the `yjs_documents` header by id. Missing → `YjsDocumentNotFoundError`.
4. Run the sync loop. On success emit `sync(true)` and flush buffered local edits.

Sync loop (up to 3 passes):

1. Read the header; note `current_snapshot_id` and `compacted_through`.
2. If a snapshot pointer exists and has not been applied in this run, page
   `yjs_snapshots` by `{ document_id, snapshot_id }`, assemble, and apply.
   An incomplete snapshot re-reads the header: if the pointer moved, retry;
   otherwise fail as corrupt.
3. Page `yjs_updates` for the document, ordered `created_at asc`, and apply
   complete updates with the provider as the Yjs origin. Retained updates are
   read and applied idempotently, so a chunked write that straddles a
   compaction boundary still reaches a complete payload. Yjs makes
   already-compacted duplicates a no-op.
4. Re-read the header. If either pointer changed, repeat so a compaction that
   landed mid-sync cannot hide rows it deleted. Applying a newer snapshot is a
   Yjs no-op for content already present.

The subscription callback receives the SDK's full materialized view each
delivery. `seenRowIds` (bounded) prevents reprocessing, and `applied` update
IDs (bounded) prevent re-applying payloads. Evicting either is safe because
Yjs updates are idempotent.

On client reconnect, the SDK replays subscriptions with a fresh snapshot.
The provider then reruns the sync loop and re-reads the document snapshot,
because updates written while offline may already have been compacted away.

## Local writes

`doc.on("update")` buffers updates whose origin is not a provider instance.
After `writeDebounceMs`, pending updates are merged with `Y.mergeUpdates` and
written as one payload. Writes are serialized and one row per message is sent:
batching all chunks would recreate the oversized message that chunking avoids.

Retryable failures requeue the merged bytes and retry with exponential backoff.
Every attempt creates a fresh update ID and row IDs; no partial resume, because
an uncertain timeout may or may not have committed and the compactor may
already have reclaimed the failed attempt. A non-retryable failure also
requeues the bytes and sets a write-blocked state: later Yjs deltas queue
instead of being written past the failed predecessor. The application calls
`flush()` after fixing the cause to retry the retained payload; if it still
fails, the block stays. Partial rows from an interrupted attempt remain but are
ignored by readers until the compactor cleans them up.

Multi-part writes create the uncommitted commit marker first, then the parts,
then commit the marker with a conditional write. If the compactor removes an
abandoned marker first, that conditional commit fails. The provider requeues
the merged bytes and retries with a new update ID and marker, so the local
update is not lost.

`flush()` forces the debounce and returns the current drain promise. It rejects
when the provider is disconnected, a drain loses the connection with unwritten
bytes, or a write fails. Terminal write failures are retried by `flush()`;
transient failures are reported and continue on automatic backoff.

When a drain loses the connection mid-flight, it rejects rather than resolving
with bytes still queued. The bytes remain buffered and the reconnect path
resumes draining. The post-drain reschedule requires a connected client and no
active write block, so an offline drain cannot spin.

## Awareness

Awareness is opt-in through the provider's `awareness` option. It maps a
`Y.Doc`-scoped `Awareness` instance onto the connection's `presence.user`
record; awareness state is ephemeral and never touches SQLite.

```ts
const provider = new ZyncBaseYjsProvider(client, documentId, doc, {
  awareness: { namespace: "doc:123" },
});
const at = Y.createRelativePositionFromTypeIndex(doc.getXmlFragment("default"), 3);
provider.awareness?.setLocalStateField("cursor", { anchor: at, head: at });
```

`awareness.namespace` is required and must equal `client.presenceNamespace`.
Presence scope is per connection, so one client bridges one document; another
document needs another client (with another presence namespace). The provider
creates the `Awareness` instance unless `instance` is supplied, and destroys
only the instance it owns.

**Field mapping.** The provider writes `yjsClientId` (the awareness client id)
and, by default, copies every other local state key into `presence.user`. The
presence schema must therefore declare an integer `yjsClientId` field plus every
awareness key the app publishes (for example `cursor` and `user` object fields
with their own sub-fields). `toPresence` and `fromPresence` override the
mapping; `toPresence` returns the complete desired presence state, not a partial
patch. Removed keys are sent as leaf `null`s; the client id is cleared when
the local state becomes `null`. The SDK README carries a complete copy-paste
schema example.

**Cursor state belongs to the binding.** The bridge transports awareness values
as JSON and never interprets them: only the editor binding that produced a
cursor can resolve it. Publish positions the binding produced, never a character
offset. A relative position carrying none of `type`, `tname`, or `item` cannot be
resolved, and ProseMirror-backed bindings (Tiptap included) throw
`Unexpected case` from their cursor plugin when they read one; a caret on an
empty node is the common source of such a position. Because presence merges
object leaves, every cursor write carries the complete position and clears the
absent leaves (`type.*`, `item.*`, `tname`) with `null`, or a previous position
survives the merge and renders stale.

**Synchronization.**

- A local awareness update (`origin === "local"`) sends the full mapped
  top-level fields. Presence broadcasts are sparse and the SDK merges them
  shallowly, so nested objects are always sent whole.
- A presence subscription snapshot is the remote source of truth. Each entry
  with a valid client id is applied as an awareness state with a fabricated
  clock (the receiver's clock + 1); entries missing from the snapshot and
  entries without a client id are removed. Unchanged states only refresh the
  awareness `lastUpdated` timestamp so the 30 s timeout does not drop them.
- The awareness heartbeat (local renewal every 15 s) is the presence heartbeat;
  no additional timer exists.
- `stop()` clears the fields this bridge published, removes remote states and
  unsubscribes. Transport loss pauses the bridge; reconnect republishes the
  local state and reconciles the fresh snapshot.
- Presence failures are reported through the client's `error` event and do not
  fail document sync.
- Only one awareness-enabled provider may be active per client.

**Limits.** Presence is keyed by user: two tabs of the same user collapse to one
awareness state and the last writer wins. Awareness state must be
JSON-representable and map to declared presence fields; arrays and bytes are not
presence field types. Store the plain object from
`Y.createRelativePositionFromTypeIndex`, not the `Uint8Array` from
`Y.encodeRelativePosition`: `type` and `item` are `{client, clock}` IDs, and the
presence schema has to mirror that shape or the bridge drops the reference.

## Sizing

| Option | Default | Server limit |
|---|---|---|
| `chunkSize` | 32 KiB | `security.maxMessageSize` (1 MiB default) per write message |
| `pageSize` | 64 | `security.maxQueryResponseSize` (8 MiB default) per read |
| `writeDebounceMs` | 150 | — |

Reads halve `pageSize` and retry on `RESPONSE_TOO_LARGE`. If `pageSize` reaches
1 and the read still fails, `chunkSize` is too large for the configured limit.

Small chunks increase message count and can touch `maxMessagesPerSecond`;
large chunks risk `MESSAGE_TOO_LARGE` and reduce headroom for row overhead.

## Operational requirements

- The application creates the document header before constructing the provider.
- The provider uses the shared client; applications own the client lifecycle.
- Keep the store namespace stable while a provider is active.
- Destroy active providers before deleting the document header. Cascade delete
  removes snapshots, updates, and app rows referencing the document.
- The compactor's `updateRetentionMs` controls how long update rows remain in
  the SDK's materialized subscription view.

## Tests

- `sdk/typescript/src/yjs/storage.test.ts`: chunk split/assembly edge cases.
- `sdk/typescript/src/yjs/provider.test.ts`: lifecycle, snapshot and history
  paging, snapshot plus retained updates, a chunked update straddling the
  compaction watermark, multi-part commit gating, write retry/chunking, header
  re-read race, reconnect snapshot reload, connection isolation, and the
  opt-in awareness lifecycle.
- `sdk/typescript/src/yjs/awareness.test.ts`: local mapping and leaf clearing,
  remote state application and removal, timeout refresh, namespace guard, and
  one-bridge-per-client.
- `tests/e2e/src/test-yjs.ts`: real-server cross-client sync, forced chunking,
  seeded snapshot recovery, slug lookup, system fields, and cascade delete.
  It also imports the emitted package and checks shared `ZyncBaseError`
  identity, retryable/oversized-error recognition across entry points, and
  `yjs` remaining external. Awareness sync, update, clear, and rejoin run
  against the real server.
