# Cursor Pagination Implementation Spec

**Status**: v1 — Implementation Specification

---

## Overview

ZyncBase exposes a purely cursor-driven pagination topology over offset-based equivalents (`offset/limit`). Cursor pagination scales securely and provides deterministic sequence navigation regardless of new inserts mutating sequence positions beneath the pointer.

This document serves as the implementation specification defining the `nextCursor` token encoding layout, SQLite execution logic, and real-time cursor windowing.

---

## Defining Determinism: Tie-Breaking Cursors

In a high-throughput environment, queries ordered exclusively by a singular column (e.g., `ORDER BY created_at DESC`) are structurally unsafe. Millions of rows can share the exact precise timestamp. Standard cursors inherently risk "infinite loops" and skipped pages via collision overlap.

Following established industry patterns found in strictly enforced schemas (Firebase / PostgREST), ZyncBase utilizes **Compound Cursors**. A compound cursor encodes the primary sorting column and an implicit, globally unique identifier (the packed 16-byte document ID). 

The generated `nextCursor` string provided inside `StoreQuery` responses is an opaque Base64 literal representing a MessagePack tuple constraint:

```typescript
const cursorTuple = [sort_value, docIdBin16];
const opaqueToken = base64(msgpackEncode(cursorTuple));
```

---

## SQLite Execution

When the `StorageEngine` interprets a `StoreQuery` containing an `after` string token:

### Step 1: Cursor Decoding
Base64 extraction decodes the token back into the isolated sort variable and distinct ID constraints.

### Step 2: Compound Translation
Because the cursor is a compounded combination, it requires an `OR` logic boundary inside the parameter generator to support tie-break skipping.

When traversing an **`ascending`** sort sequence, the translation reads:
```sql
SELECT * FROM collection
WHERE ...
  AND (
    sort_column > ? 
    OR (sort_column = ? AND id > ?)
  )
ORDER BY sort_column ASC, id ASC
LIMIT x
```
_(Parameter binding matches `[sort_value, sort_value, document_id_blob]`)_

When navigating a **`descending`** sequence, the translation is inverted:
```sql
SELECT * FROM collection
WHERE ...
  AND (
    sort_column < ? 
    OR (sort_column = ? AND id < ?)
  )
ORDER BY sort_column DESC, id DESC
LIMIT x
```

> [!NOTE]
> ZyncBase's internal SQLite queries implicitly force `ORDER BY id DESC/ASC` across all calls. 
> Without appending `id` as the final instruction, SQLite cannot consistently organize colliding timestamps, undermining the effectiveness of the OR tiebreaker.

---

## Real-time Live Windowing (`loadMore`)

The `StoreSubscribe` model allows a query stream to actively watch a chunk of results, whilst optionally loading historic items deep into the cache via `loadMore()`.

When the `MessageHandler` accepts a `StoreLoadMore` request, it must fetch historical boundary elements without destroying the sequence integrity of `StoreDelta` events previously recorded. 
The internal logic relies entirely on the same sequence bounds outlined above. 

The primary difference lies in the UI representation. The client-side wrapper isolates the initial `limit` bounds and applies identical deterministic sorting. While new items slide into the array top by way of real-time server Pushes (`StoreDelta`), executing `loadMore()` cleanly fetches elements using a cursor synthesized directly from the final active element resting at the bottom of the client array chunk.
