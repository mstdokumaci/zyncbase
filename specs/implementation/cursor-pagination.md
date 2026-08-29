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
| `typed.Cursor` | ordered value list in canonical sort order | Represents the token state pointing directly after the last seen row; the final value belongs to a unique required system field. |
| `QueryFilter.after` | `typed.Cursor` | Optional cursor boundary parsed from the request and tied to the active canonical `orderBy`. |

---

## Opaque Cursor Layout

The `nextCursor` token returned in `StoreQuery` responses is an opaque Base64 literal containing a MessagePack-encoded triple bound to the collection and canonical order:

```typescript
const cursorTuple = [tableIndex, sortTuples, values];
// sortTuples = [[field_index, desc_flag], ...]  — canonical descriptors ending in created_at or explicit id
// values     = [sort_value_0, ..., uniqueValue] — one value per descriptor, count must match
const nextCursor = base64(msgpackEncode(cursorTuple));
```

- `tableIndex`: binds the token to one collection; reuse against another table is rejected.
- `sortTuples`: the server's canonical order including hidden/final `created_at`, or an explicit final `id`. A token whose embedded order differs from the active query fails deterministically instead of returning a plausible but incorrect page.
- Sort values may be `nil` for optional fields only. Required/system fields reject null. The token remains opaque and unsigned: tampering can shift a page boundary but cannot alter authorization predicates, namespace scoping, selected table, or active order.

### Cursor Validation

Decoding uses wire MessagePack limits (not trusted/internal limits) because the token is client supplied:

1. Base64-decode; decode with wire limits; require full byte consumption (reject trailing data).
2. Require the exact three-element outer shape.
3. Validate the table index against the active table.
4. Validate the embedded descriptor list exactly against the active canonical order.
5. Validate value count equals descriptor count.
6. Decode each value against its field's schema storage type; permit `nil` only for optional fields; reject arrays.

Failures map to `InvalidCursorSortValue` or `InvalidMessageFormat`.

---

## SQL Compilation & Parameter Binding

Every canonical clause appears in `ORDER BY`; non-required fields get explicit `NULLS LAST` so nulls sort last in both directions:

```sql
ORDER BY
  "priority" DESC NULLS LAST,
  "created_at" ASC
```

SQLite row-value comparison cannot express independent per-key directions, so the cursor predicate compiles to a **lexicographic disjunction**: branch `i` requires equality on `k0..k(i-1)` and an after-comparison on `ki`. SQL fragment generation and bind-list generation live in the same loop to prevent positional drift.

### Example: `priority DESC, created_at ASC`

```sql
AND (
  "priority" < ?
  OR ("priority" = ? AND "created_at" > ?)
)
```

### Null-Safe Forms for Optional Fields

For an optional key with `NULLS LAST`, prefix equality becomes `"col" IS ?` and the comparison branch gains a null guard:

```sql
(? IS NOT NULL AND ("col" IS NULL OR "col" > ?))   -- ASC
(? IS NOT NULL AND ("col" IS NULL OR "col" < ?))   -- DESC
```

The `? IS NOT NULL` guard makes the current-key branch false when the cursor value is null; a later branch still advances within the equal-null group via subsequent keys, ultimately reaching the unique non-null `created_at` tie-breaker.

### Parameter Bind Array Order

Binds are positional and mirror the generated fragments exactly: namespace id first, then each branch's prefix equalities and comparisons in generation order (an optional comparison contributes two binds — guard then compare), then the page limit. The disjunction and repeated prefix binds are O(n²) in clause count, bounded by at most nine canonical keys.

### Statement Cache Stability

Generated SQL depends only on table schema, canonical descriptors, field requiredness, and the presence of predicates/cursor/limit — never on whether a particular cursor value is null. Cursor values remain bind parameters, preserving structural-hash statement reuse across pages with mixed null/non-null boundaries.

---

## Live Windowing (`loadMore`)

- Active query subscriptions (`StoreSubscribe`) materialise real-time updates at the top of the collection view.
- To paginate backward or fetch historically older elements, the SDK synthesises a query cursor based on the last row currently present in the client-side array.
- A `StoreLoadMore` request uses this cursor to fetch the next batch from the database without disrupting the active subscription's push listener.
- The SDK may include `table_index` with `StoreLoadMore` for response context, but the server resolves the retained query by `subId`.

---

## Related Specifications

- [Query Engine](./query-engine.md)
- [Storage](./storage.md)
- [TypeScript SDK](./typescript-sdk.md)
