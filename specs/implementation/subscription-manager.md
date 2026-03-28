# Subscription Manager Implementation Spec

**Status**: v1 — Implementation Specification

---

## Overview

The `SubscriptionManager` acts as the beating heart of ZyncBase's real-time filtering engine. It provides the mechanism by which the application memory matches active queries against SQLite `RowChange` events. Rather than polling the database, `StoreDelta` messages are synthesized logically inside Zig.

This document formally specifies how it routes subscriptions and evaluates edge transitions (entering, leaving, and updating inside query bounds).

## Internal Data Structures

The `SubscriptionManager` requires high-performance structures capable of handling 100,000+ concurrent listeners without blocking writes. It relies heavily on memory isolation and pointer iteration rather than map lookups in the hot path.

### 1. Subscription Registry
An `AutoHashMap` of `SubscriptionId` -> `Subscription`. It tracks all active list and query bindings.
```zig
pub const Subscription = struct {
    id: SubscriptionId,
    namespace: []const u8,
    collection: []const u8,
    filter: QueryFilter, // Contains AST logic
    sort: ?SortSpec,     // Important for pagination bounds
    connection_id: u64,
};
```

### 2. Namespace Indexing
A `StringHashMap` mapping the strict key `"{namespace}:{collection}"` to an `ArrayList(SubscriptionId)`.
This serves as the primary router. When a `RowChange` fires, it only evaluates subscriptions inside that exact namespace bucket.

## Live Condition Evaluation

Every time `StorageEngine.insertOrReplace()`, `.updateField()`, or `.deleteDocument()` successfully commits a transaction, it fires a `RowChange` struct representing the mutation. 

```zig
pub const RowChange = struct {
    namespace: []const u8,
    collection: []const u8,
    operation: Operation, // .insert | .update | .delete
    old_row: ?Row,
    new_row: ?Row,
};
```

During a `RowChange`, the `findMatchingSubscriptions` routine executes against all candidates inside the `"{namespace}:{collection}"` index. 

### Resolving Edge Transitions 
A `RowChange` can dictate four possible scenarios against an active `QueryFilter` AST. The `SubscriptionManager` algorithm must deterministically isolate these outcomes.

#### Scenario 1: Inside to Inside
- State: Previous row matched -> New row matches.
- Response: Fire a `StoreDelta` mapped to `op: set`. The client applies the patch over the existing item.

#### Scenario 2: Outside to Inside (Entering)
- State: Previous row did not match -> New row matches. (Or `operation == .insert` and new row matches).
- Response: Fire a `StoreDelta` mapped to `op: set`. The client inserts the item into their active array.

#### Scenario 3: Inside to Outside (Leaving)
> [!WARNING]
> This is a crucial edge case. When a document's status changes such that it no longer fulfills the active filter parameters, ZyncBase MUST dispatch an eviction signal. 
- State: Previous row matched -> New row DOES NOT match.
- Response: Synthesize a `StoreDelta` mapped to `op: remove`. The physical SQLite document still exists, but to properly sync the client's internal query state window, they must strike it from the cache.

#### Scenario 4: Outside to Outside
- State: Previous row did not match -> New row DOES NOT match.
- Response: Omit `StoreDelta` entirely for this connection.

### Sort Evaluation Rules

If a `Subscription` contains a `SortSpec`, the evaluation engine carries one more task. 

Should a document transition in *Scenario 1: Inside to Inside*, it may have updated its primary sorting value (e.g. `priority` column changed from 1 to 5). 

If `!std.meta.eql(old_row.sort_field, new_row.sort_field)`, the engine explicitly fires a `StoreDelta` `op: set` forcing the client-side UI to re-sort visually real-time. If it did not change, the data patch is purely cosmetic mapping, reducing overhead.

---

## Memory Locking Context

The evaluation loop (`findMatchingSubscriptions()`) is bound inside the `lockShared()` path of the subscription mutex. No writes can block reads, scaling effectively across concurrent event streams.
