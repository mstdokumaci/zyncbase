# Yjs Compactor

**Source files**: `sdk/typescript/src/yjs/compactor.ts`, `sdk/typescript/src/yjs/compactor_impl.ts`

The compactor is a long-running worker that folds `yjs_updates` rows into the
chunked snapshot stored in `yjs_snapshots` and commits the snapshot pointer on
`yjs_documents`. It operates on `Y.Doc` state, so ProseMirror, Tiptap, and other
Yjs editors use the same worker. Apps start it in their server process or an
existing Bun worker and stop it on shutdown.

## Public API

```ts
const compactor = startYjsCompactor(client, options);
await compactor.stop();
```

The app owns the client connection and connects a dedicated service client
first. When `namespaces` is set, the worker calls `client.setStoreNamespace` for
each namespace, so give it a client dedicated to the worker.

## Schema addition

`yjs_documents` gains a required `compaction_version` integer (start at `0`).
It is the compare-and-swap guard for the header commit. The provider ignores it.

## Discovery

Per namespace, the worker keeps an in-memory update cursor.

1. Query `yjs_updates` with `created_at > cursor`, ordered `created_at ASC`,
   paged by `pageSize`.
2. Collect distinct `document_id` values.
3. Advance the cursor to the last scanned row.
4. Stop at `maxUpdatesPerPass`; schedule the next pass immediately while work
   remains.

On worker start the cursor is `0`, so the first pass scans all retained updates.
Retention bounds that scan. New rows always have a greater `created_at` and are
picked up next pass.

Documents that cannot compact yet (incomplete chunk groups, transient errors,
version conflicts) go into a bounded retry set with exponential backoff. Newly
discovered docs are processed even if a retry entry exists; overflow beyond
`maxDocumentsPerPass` is deferred to the retry set so no discovered document is
lost after the cursor advances.

## Per-document pass

1. Read the header and its `compaction_version`.
2. Load the current snapshot from `yjs_snapshots` and apply it to a temporary
   `Y.Doc`. A missing or incomplete pointed-to snapshot retries the document.
3. Page updates with `created_at > compacted_through` (or all updates for a
   document with no watermark), ordered ascending.
4. Assemble complete groups with `ChunkAssembler`; apply each complete update.
   Track each group's min/max `created_at`.
5. Groups with no commit:
   - older than `updateRetentionMs` → abandoned; delete their rows.
   - recent → keep, and clamp the new watermark below the earliest incomplete
     row.
6. Compute:
   ```text
   maxComplete = max(created_at) over complete groups
   minIncomplete = min(created_at) over active incomplete groups
   nextWatermark = min(maxComplete, minIncomplete - 1)   // if incomplete
   nextWatermark = maxComplete                          // otherwise
   ```
7. Encode `Y.encodeStateAsUpdate`, split with `chunkSize`, write snapshot parts,
   then the commit row.
8. Commit the header atomically:
   - `current_snapshot_id = new snapshot`
   - `compacted_through = nextWatermark`
   - `compaction_version = observed + 1`
   - every op guarded by `if: { compaction_version: { eq: observed } }`
9. On `PRECONDITION_FAILED`, another worker won. Leave the new snapshot chunks
   for cleanup and retry the document.
10. Delete update rows in complete groups where
    `created_at <= nextWatermark` and older than `updateRetentionMs`.

The watermark clamp is what makes reading `created_at > watermark` safe: an
incomplete group's parts are always above the committed watermark until the
group completes.

## Cleanup

A bounded header sweep runs every `cleanupIntervalMs`:

- Delete update rows with `created_at <= compacted_through` and older than
  `updateRetentionMs`.
- Delete snapshot generations other than `current_snapshot_id` once their
  newest row is older than `snapshotRetentionMs`.
- Batch removals at 400 ops per batch.

The per-document pass cleans what it just covered. The sweep covers crash gaps
and documents that no longer receive updates.

## Defaults

| Option | Default |
|---|---|
| `intervalMs` | 30 s |
| `updateRetentionMs` | 24 h |
| `snapshotRetentionMs` | 1 h |
| `cleanupIntervalMs` | 10 min |
| `chunkSize` | 32 KiB |
| `pageSize` | 64 |
| `maxUpdatesPerPass` | 5 000 |
| `maxDocumentsPerPass` | 100 |
| `maxCleanupDocumentsPerPass` | 50 |

`created_at` values are Unix microseconds. Retention cutoffs are computed as
`Date.now() * 1000 - retentionMs * 1000`.

## Tests

- `sdk/typescript/src/yjs/compactor.test.ts`: snapshot creation and header
  commit, no-op docs, incomplete chunk clamping, version conflict retry,
  namespace isolation, cursor resumption, start/stop.
- `tests/e2e/src/test-yjs.ts`: real-server compaction, update cleanup, fresh
  client recovery from the compacted snapshot, and post-compaction editing.
