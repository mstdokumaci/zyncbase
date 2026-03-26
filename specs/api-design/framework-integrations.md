# Framework Integrations

> [!NOTE]
> These are **design specifications** for planned framework bindings. The SDK does not exist yet — these patterns define the target developer experience.

---

## Table of Contents

1. [React](#react)
2. [Vue](#vue)
3. [Common Patterns](#common-patterns)

---

## React

Package: `@zyncbase/react`

### Hooks

#### `useStore(path)`

Subscribe to a store path with automatic cleanup on unmount.

```typescript
const { data, loading, error } = useStore('elements')
```

**Returns:** `{ data: T | undefined, loading: boolean, error: ZyncBaseError | null }`

#### `useQuery(path, options)`

Subscribe to filtered query results with pagination support.

```typescript
const { data, loading, error, hasMore, loadMore, loadingMore } = useQuery('tasks', {
  where: { status: { eq: 'active' } },
  orderBy: { created_at: 'desc' },
  limit: 20
})
```

**Returns:** `{ data: T[], loading: boolean, error: ZyncBaseError | null, hasMore: boolean, loadMore: () => Promise<void>, loadingMore: boolean }`

#### `usePresence()`

Subscribe to presence updates in the current namespace.

```typescript
const others = usePresence()
// Array<{ userId, data, joinedAt }>
```

#### `useConnectionStatus()`

Reactive connection state for UI feedback.

```typescript
const { status, error, retryCount, retryIn } = useConnectionStatus()
```

**Returns:** `{ status: 'connecting' | 'connected' | 'reconnecting' | 'disconnected', error: Error | null, retryCount: number, retryIn: number | null }`

### Example: Connection Status Banner

```tsx
function ConnectionBanner() {
  const { status, retryCount, retryIn } = useConnectionStatus()

  if (status === 'connected') return null
  if (status === 'connecting') return <Banner>Connecting...</Banner>

  if (status === 'reconnecting') {
    return (
      <Banner>
        Reconnecting (attempt {retryCount})...
        {retryIn && ` Retrying in ${Math.ceil(retryIn / 1000)}s`}
      </Banner>
    )
  }

  return <Banner variant="error">Disconnected</Banner>
}
```

### Example: Infinite Scroll

```tsx
function ActivityFeed() {
  const { data, hasMore, loadMore, loadingMore } = useQuery('activities', {
    orderBy: { created_at: 'desc' },
    limit: 20
  })

  return (
    <ScrollArea onBottomReached={() => hasMore && loadMore()}>
      {data.map(item => <ActivityItem key={item.id} {...item} />)}
      {loadingMore && <LoadingSpinner />}
    </ScrollArea>
  )
}
```

---

## Vue

Package: `@zyncbase/vue`

### Composables

#### `useStore(path)`

```typescript
const { data, loading, error } = useStore('elements')
// All return values are Vue refs
```

#### `useQuery(path, options)`

```typescript
const { data, loading, error, hasMore, loadMore } = useQuery('tasks', {
  where: { status: { eq: 'active' } }
})
```

#### `usePresence()`

```typescript
const others = usePresence()
```

All composables return reactive refs and automatically clean up subscriptions when the component is unmounted.

---

## Common Patterns

### Loading / Error / Data

All hooks follow a consistent `{ data, loading, error }` pattern:

```typescript
// React
const { data, loading, error } = useStore('tasks')
if (loading) return <Spinner />
if (error) return <ErrorView error={error} />
return <TaskList tasks={data} />
```

### Auto-cleanup

All hooks automatically unsubscribe from store, query, and presence subscriptions when the component unmounts. No manual cleanup required.

### Client Provider

The client instance should be provided at the app root:

```tsx
// React
import { ZyncBaseProvider } from '@zyncbase/react'

function App() {
  return (
    <ZyncBaseProvider client={client}>
      <MyApp />
    </ZyncBaseProvider>
  )
}
```

---

## See Also

- [Store API](./store-api.md) — Underlying store methods
- [Presence API](./presence-api.md) — Underlying presence methods
- [Connection Management](./connection-management.md) — Connection events and status
- [Error Handling](./error-handling.md) — `ZyncBaseError` interface used in hook error states
