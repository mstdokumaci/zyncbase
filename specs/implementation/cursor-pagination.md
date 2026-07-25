# Cursor Pagination

**Drivers**: [ADR-013](../architecture/adrs.md#adr-013-query-language), [ADR-014](../architecture/adrs.md#adr-014-unified-subscription-engine), [Query Engine](./query-engine.md), [Storage](./storage.md)

ZyncBase exposes a purely cursor-driven pagination topology over offset-based equivalents (`offset/limit`). Cursor pagination scales securely and provides deterministic sequence navigation regardless of new inserts mutating sequence positions beneath the pointer.

---

## Source Files

| File | Responsibility |
|------|----------------|
| `src/query/parser.zig` | Decodes Base64 cursor strings and validates sorted page requirements. |
| `src/typed/types.zig`, `src/typed/doc_id.zig` | Cursor sort-value representation and 16-byte document id packing. |
| `src/sql/build.zig` | Builds cursor predicates and deterministic order clauses. |
| `src/storage_engine/reader.zig` | Builds compound SQL selection predicates and executes tie-breaking pagination queries. |
| `src/store_service.zig` | Marshals cursor bounds between client requests and storage queries. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `typed.Cursor` | sorting value, document ID | Represents the token state pointing directly after the last seen row. |
| `QueryFilter.after` | `typed.Cursor` | Optional cursor boundary parsed from the request and tied to the active `orderBy`. |

---

## Opaque Cursor Layout

The `nextCursor` token returned in `StoreQuery` responses is an opaque Base64 literal containing a MessagePack-encoded tuple:

```typescript
const cursorTuple = [sort_value, docIdBin16];
const nextCursor = base64(msgpackEncode(cursorTuple));
```

- `sort_value`: The value of the sorting column for the last element on the page. Cursor sort values cannot be null.
- `docIdBin16`: The 16-byte binary UUIDv7 of the last element on the page.

---

## SQL Compilation & Parameter Binding

When querying with a cursor, ZyncBase compiles the compound sorting criteria using an `OR` logic gate to handle colliding values (tie-breaking) while preserving database index usage:

### Ascending Sort Query

```sql
SELECT ...
FROM "collection"
WHERE "namespace_id" = ?
  AND (
    sort_column > ? 
    OR (sort_column = ? AND id > ?)
  )
ORDER BY sort_column ASC, id ASC
LIMIT ?
```

### Descending Sort Query

```sql
SELECT ...
FROM "collection"
WHERE "namespace_id" = ?
  AND (
    sort_column < ? 
    OR (sort_column = ? AND id < ?)
  )
ORDER BY sort_column DESC, id DESC
LIMIT ?
```

### Parameter Bind Array Order

The SQL queries require positional arguments. Parameters must be bound in the exact following order:

| Query Type | Parameters Array | Bind Types |
|:---|:---|:---|
| **Ascending** | `[namespace_id, sort_value, sort_value, last_doc_uuid, page_limit]` | `[Int, Any, Any, Blob(16), Int]` |
| **Descending** | `[namespace_id, sort_value, sort_value, last_doc_uuid, page_limit]` | `[Int, Any, Any, Blob(16), Int]` |

When the active sort field is the system `id` field, the cursor predicate is simplified to `id > ?` or `id < ?`; only `[namespace_id, last_doc_uuid, page_limit]` is bound.

---

## Live Windowing (`loadMore`)

- Active query subscriptions (`StoreSubscribe`) materialise real-time updates at the top of the collection view.
- To paginate backward or fetch historically older elements, the SDK synthesises a query cursor based on the last row currently present in the client-side array.
- A `StoreLoadMore` request uses this cursor to fetch the next batch from the database without disrupting the active subscription's push listener.
- The SDK may include `table_index` with `StoreLoadMore` for response context, but the server resolves the retained query by `subId`.

---

## See Also

- [Query Engine](./query-engine.md)
- [Storage](./storage.md)
- [TypeScript SDK](./typescript-sdk.md)
