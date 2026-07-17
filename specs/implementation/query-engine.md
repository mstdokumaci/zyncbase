# Query Engine

**Drivers**: [ADR-013](../architecture/adrs.md#adr-013-query-language), [ADR-014](../architecture/adrs.md#adr-014-unified-subscription-engine), [Query Grammar](./query-grammar.md), [Cursor Pagination](./cursor-pagination.md), [Storage](./storage.md)

The query engine converts SDK query requests into a typed AST, validates them against the loaded schema, lowers storage-backed reads to SQLite SQL, and reuses the same predicate semantics for in-memory subscription filtering.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/query/ast.zig` | Canonical query AST: operators, conditions, sort descriptors, predicates, filters. |
| `src/query/parser.zig` | MessagePack query decoding, schema field resolution, cursor encode/decode helpers. |
| `src/storage_engine/filter_sql.zig` | AST-to-SQL predicate lowering and bound value ownership. |
| `src/storage_engine/sql.zig` | SELECT, namespace, cursor, and ordering SQL helpers. |
| `src/storage_engine/reader.zig` | Query execution and row decoding. |
| `src/query/eval.zig` | In-memory predicate evaluation for subscription matching. |
| `src/subscription/engine.zig` | Subscription grouping, query retention, and record-change matching. |
| `src/store_service.zig` | Store-facing query, subscribe, and load-more operations. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `QueryFilter` | `FilterPredicate`, `SortDescriptor`, schema field metadata | Full read/subscription query contract after parsing. |
| `FilterPredicate` | `PredicateState`, `Condition` | Logical predicate tree for SQL lowering and in-memory evaluation. |
| `Condition` | `Operator`, typed operands | One field/operator/value comparison. |
| `SortDescriptor` | schema field index, direction | Stable order definition used by SQL and cursor encoding. |
| `ParserError` | wire/schema validation | Internal parser failure set mapped through public error taxonomy. |
| `RenderedPredicate` | SQL fragment, bound values | Result of lowering AST predicates for SQLite. |
| `SubscriptionEngine` | `QueryFilter`, `RecordChange` | Keeps active queries and evaluates committed changes. |
| `CursorResult` | records, next cursor | Store-service result for paginated reads. |

## Responsibilities

- Decode wire query tuples into typed operators and operands.
- Validate table/field names, operator compatibility, sort fields, and cursor shape.
- Preserve one semantic model for storage reads and subscription filtering.
- Generate stable ordering and cursor predicates for paginated reads.
- Apply authorization predicates before storage execution.
- Retain subscription queries in a form that can be evaluated against committed changes.

## Query Flow

1. `MessageHandler` extracts the wire request and requires a ready store scope.
2. Authorization builds an optional read predicate for the current session.
3. `parser.zig` parses the requested filter/sort/limit/cursor into `QueryFilter`.
4. `store_service.zig` passes the filter and auth predicate to storage.
5. Storage lowers predicates through `filter_sql.zig` and executes the SELECT.
6. Results are encoded by `wire.encodeQuery`.
7. Subscriptions retain the parsed query and use `eval.zig` for committed changes.

## Invariants

- Query grammar is owned by [Query Grammar](./query-grammar.md); do not duplicate operator catalogs here.
- SQL lowering and in-memory filtering must agree for every supported operator.
- Cursor tokens must be tied to the active sort order and reject mismatched sort values.
- Namespace filters and authorization predicates must be applied before returning records.
- Subscription matching uses committed record changes only; speculative writes must not be broadcast.
- Parser/internal errors map through [Error Taxonomy](./error-taxonomy.md).

## Performance Contract

| Property | Value | Notes |
|----------|-------|-------|
| Batch write ops limit | 500 | Maximum operations in a single `StoreBatch` call. |
| Cursor overfetch | +1 row | `LIMIT` is overfetched by 1 for accurate `hasMore` detection. |
| Subscription condition matching | 64 max as sets | Maximum conditions matched as sets during filter equality comparison. |
| Default query limit | None (unbounded) | Client must supply `limit` for bounded queries. |

**Overflow policy**: Batch operations exceeding 500 ops return `BATCH_TOO_LARGE`. Queries without a `limit` are unbounded; clients should always supply a limit for predictable performance.

## See Also

- [Query Grammar](./query-grammar.md)
- [Cursor Pagination](./cursor-pagination.md)
- [Storage](./storage.md)
- [TypeScript SDK](./typescript-sdk.md)
