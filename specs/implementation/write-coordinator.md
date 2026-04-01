# Write Coordinator

## Overview
The `WriteCoordinator` is a central orchestration component that handles all write operations (StoreSet, StoreRemove) in ZyncBase. it sits between the protocol layer (`MessageHandler`) and the storage layer (`StoreEngine`).

The primary purpose of the `WriteCoordinator` is to ensure that subscriber notifications are accurate and performant by capturing the full row context (before and after) during an optimistic write.

## Responsibility
1. **Context Fetching**: Fetch the current state of a document (optimistically from the metadata cache) before a write is performed.
2. **Change Merging**: Construct a full `new_row` by merging partial updates into the `old_row`.
3. **Full-Row Persistence**: Submit the **complete** merged row to the `StorageEngine.insertOrReplace`. This ensures that partial SDK updates (e.g., `user.u1.name`) do not wipe out other fields in the database row during the destructive SQLite `REPLACE` operation.
4. **Optimistic Notification**: Compute matches and broadcast changes to subscribers immediately, using the full `new_row`.

## Component Architecture

### Data Flow
1. `MessageHandler` receives `StoreSet` or `StoreRemove`.
2. `MessageHandler` delegates to `WriteCoordinator.coordinateSet` or `WriteCoordinator.coordinateRemove`.
3. `WriteCoordinator` selects the current document from `StorageEngine` (hits the O(1) in-memory metadata cache).
4. `WriteCoordinator` creates a `RowChange` object and a merged `new_row` (Full Document).
5. `WriteCoordinator` submits the **full** set of columns to `StorageEngine.insertOrReplace`.
6. `WriteCoordinator` calls `SubscriptionEngine.handleRowChange` for notification.
6. `WriteCoordinator` iterates through matches and sends `StoreDelta` messages via `ConnectionManager`.

### Memory Management
The `WriteCoordinator` uses the provided `Arena` (usually the request-scoped arena) for temporary allocations like the `RowChange` and the merged `new_row`.

## Error Handling
In ZyncBase's optimistic model:
- If the `selectDocument` fails (e.g., corrupted cache), the coordinator proceeds with the write, treating it as a blind insert or using a best-effort merge.
- Subscriber notifications are best-effort "Fire and Forget". If a write is later NACKed by the storage engine, the `MessageHandler` handles the NACK response, but the optimistic subscriber update is not retracted (consistent with other real-time sync systems).

## Related Components
- [Storage Engine](storage.md)
- [Subscription Engine](subscription_engine.md)
- [Message Handler](message-handler.zig)
