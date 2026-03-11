# ZyncBase Query Language Reference

**Last Updated**: 2026-03-09

Complete reference for ZyncBase's Prisma-inspired query language used in `client.query()` and `client.subscribe()`.

---

## Table of Contents

1. [Design Philosophy](#design-philosophy)
2. [Query Operators](#query-operators)
3. [Combining Conditions](#combining-conditions)
4. [Sorting](#sorting)
5. [Pagination](#pagination)
6. [Examples](#examples)

---

## Design Philosophy

ZyncBase's query language is inspired by Prisma with improvements:

- **Prisma-inspired syntax** - TypeScript-first, clean, no prefixes
- **Implicit AND** - All root-level conditions combined with AND (most common case)
- **Explicit `or`** - Use `or` key for OR conditions
- **Short operator names** - `eq`, `gte` (not `equals`, `greaterThanOrEqual`)
- **Consistent lowercase** - All operators and keywords in lowercase
- **Standard SQL terms** - `limit`/`offset` (not `take`/`skip`)

---

## Query Operators

### Equality Operators

```typescript
{
  where: {
    status: { eq: 'active' },      // Equal
    status: { ne: 'deleted' }      // Not equal
  }
}
```

**Operators:**
- `eq` - Equal to
- `ne` - Not equal to

---

### Comparison Operators

```typescript
{
  where: {
    age: { gt: 18 },               // Greater than
    age: { gte: 18 },              // Greater than or equal
    age: { lt: 65 },               // Less than
    age: { lte: 65 }               // Less than or equal
  }
}
```

**Operators:**
- `gt` - Greater than
- `gte` - Greater than or equal to
- `lt` - Less than
- `lte` - Less than or equal to

---

### String Operators

```typescript
{
  where: {
    name: { contains: 'john' },    // Contains substring
    name: { startsWith: 'J' },     // Starts with
    name: { endsWith: 'son' },     // Ends with
    email: { contains: '@example.com' }
  }
}
```

**Operators:**
- `contains` - Contains substring (case-sensitive)
- `startsWith` - Starts with prefix
- `endsWith` - Ends with suffix

**Note:** String matching is case-sensitive. For case-insensitive matching, normalize data on write or use computed fields.

---

### Array Operators

```typescript
{
  where: {
    role: { in: ['admin', 'editor'] },      // In array
    role: { notIn: ['guest', 'banned'] }    // Not in array
  }
}
```

**Operators:**
- `in` - Value is in the provided array
- `notIn` - Value is not in the provided array

---

### Null Operators

```typescript
{
  where: {
    deleted_at: { isNull: true },           // Is null
    verified_at: { isNotNull: true }        // Is not null
  }
}
```

**Operators:**
- `isNull` - Field is null or undefined
- `isNotNull` - Field has a value (not null/undefined)

---

## Combining Conditions

### Implicit AND

All conditions at the root level are automatically combined with AND:

```typescript
// age >= 18 AND status = 'active' AND role IN ['admin', 'editor']
{
  where: {
    age: { gte: 18 },
    status: { eq: 'active' },
    role: { in: ['admin', 'editor'] }
  }
}
```

This is the most common case, so we make it the default to keep queries clean.

---

### Explicit OR

Use the `or` key for OR conditions:

```typescript
// status = 'active' OR status = 'pending'
{
  where: {
    or: [
      { status: { eq: 'active' } },
      { status: { eq: 'pending' } }
    ]
  }
}
```

The `or` key takes an array of condition objects.

---

### Complex Nested (AND + OR)

Combine implicit AND with explicit OR for complex queries:

```typescript
// age >= 18 AND (role = 'admin' OR role = 'editor')
{
  where: {
    age: { gte: 18 },
    or: [
      { role: { eq: 'admin' } },
      { role: { eq: 'editor' } }
    ]
  }
}
```

```typescript
// (status = 'active' OR status = 'pending') AND priority = 'high'
{
  where: {
    priority: { eq: 'high' },
    or: [
      { status: { eq: 'active' } },
      { status: { eq: 'pending' } }
    ]
  }
}
```

---

### Multiple OR Groups

You can have multiple conditions with OR groups:

```typescript
// age >= 18 AND (role = 'admin' OR role = 'editor') AND status = 'active'
{
  where: {
    age: { gte: 18 },
    status: { eq: 'active' },
    or: [
      { role: { eq: 'admin' } },
      { role: { eq: 'editor' } }
    ]
  }
}
```

**Note:** Currently, only one `or` key is supported at the root level. For more complex boolean logic, consider restructuring your query or using multiple queries.

---

## Sorting

### Single Field Sort

```typescript
{
  orderBy: { created_at: 'desc' }
}
```

**Sort directions:**
- `'asc'` - Ascending (A-Z, 0-9, oldest first)
- `'desc'` - Descending (Z-A, 9-0, newest first)

---

### Multiple Field Sort (Future)

```typescript
{
  orderBy: [
    { priority: 'desc' },    // Sort by priority first
    { created_at: 'asc' }    // Then by creation date
  ]
}
```

**Note:** Multi-field sorting is planned for a future release. Currently, only single-field sorting is supported.

---

## Pagination

### Basic Pagination

```typescript
{
  limit: 50,      // Max results to return
  offset: 0       // Skip first N results
}
```

---

### Page-based Pagination

```typescript
// Page 1 (first 20 items)
{
  limit: 20,
  offset: 0
}

// Page 2 (items 21-40)
{
  limit: 20,
  offset: 20
}

// Page 3 (items 41-60)
{
  limit: 20,
  offset: 40
}
```

**Formula:** `offset = (page - 1) * limit`

---

### Infinite Scroll

```typescript
// Load first batch
const items = await client.query('items', {
  orderBy: { created_at: 'desc' },
  limit: 20,
  offset: 0
})

// Load next batch
const moreItems = await client.query('items', {
  orderBy: { created_at: 'desc' },
  limit: 20,
  offset: 20
})
```

---

## Examples

### Form Validation

Check if a username is already taken:

```typescript
const existing = await client.query('users', {
  where: { username: { eq: 'alice' } }
})

const isAvailable = existing.length === 0
```

---

### Date Range Query

Get events within a date range:

```typescript
const events = await client.query('events', {
  where: {
    created_at: { gte: startDate, lte: endDate },
    status: { eq: 'active' }
  },
  orderBy: { created_at: 'desc' },
  limit: 50
})
```

---

### Multi-Status Filter

Get tasks that are either active or pending:

```typescript
const tasks = await client.query('tasks', {
  where: {
    or: [
      { status: { eq: 'active' } },
      { status: { eq: 'pending' } }
    ]
  },
  orderBy: { priority: 'desc' }
})
```

---

### Role-Based Query

Get users with admin or editor roles who are active:

```typescript
const users = await client.query('users', {
  where: {
    status: { eq: 'active' },
    or: [
      { role: { eq: 'admin' } },
      { role: { eq: 'editor' } }
    ]
  }
})
```

---

### Search by Substring

Find users whose email contains a domain:

```typescript
const users = await client.query('users', {
  where: {
    email: { contains: '@example.com' }
  }
})
```

---

### Exclude Deleted Items

Get all items that haven't been soft-deleted:

```typescript
const items = await client.query('items', {
  where: {
    deleted_at: { isNull: true }
  }
})
```

---

### Complex Business Logic

Get high-priority tasks assigned to admins or editors that are not completed:

```typescript
const tasks = await client.query('tasks', {
  where: {
    priority: { eq: 'high' },
    status: { ne: 'completed' },
    or: [
      { assigned_role: { eq: 'admin' } },
      { assigned_role: { eq: 'editor' } }
    ]
  },
  orderBy: { created_at: 'desc' },
  limit: 100
})
```

---

## Operator Reference Table

| Operator | Type | Description | Example |
|----------|------|-------------|---------|
| `eq` | Any | Equal to | `{ status: { eq: 'active' } }` |
| `ne` | Any | Not equal to | `{ status: { ne: 'deleted' } }` |
| `gt` | Number/Date | Greater than | `{ age: { gt: 18 } }` |
| `gte` | Number/Date | Greater than or equal | `{ age: { gte: 18 } }` |
| `lt` | Number/Date | Less than | `{ age: { lt: 65 } }` |
| `lte` | Number/Date | Less than or equal | `{ age: { lte: 65 } }` |
| `contains` | String | Contains substring | `{ name: { contains: 'john' } }` |
| `startsWith` | String | Starts with prefix | `{ name: { startsWith: 'J' } }` |
| `endsWith` | String | Ends with suffix | `{ name: { endsWith: 'son' } }` |
| `in` | Any | Value in array | `{ role: { in: ['admin', 'editor'] } }` |
| `notIn` | Any | Value not in array | `{ role: { notIn: ['guest'] } }` |
| `isNull` | Any | Is null/undefined | `{ deleted_at: { isNull: true } }` |
| `isNotNull` | Any | Has a value | `{ verified_at: { isNotNull: true } }` |

---

## Best Practices

### 1. Use implicit AND for simplicity

```typescript
// Good - clean and readable
{
  where: {
    age: { gte: 18 },
    status: { eq: 'active' }
  }
}

// Avoid - unnecessary complexity
{
  where: {
    and: [
      { age: { gte: 18 } },
      { status: { eq: 'active' } }
    ]
  }
}
```

---

### 2. Prefer `in` over multiple OR conditions

```typescript
// Good - concise
{
  where: {
    status: { in: ['active', 'pending', 'review'] }
  }
}

// Avoid - verbose
{
  where: {
    or: [
      { status: { eq: 'active' } },
      { status: { eq: 'pending' } },
      { status: { eq: 'review' } }
    ]
  }
}
```

---

### 3. Always paginate large result sets

```typescript
// Good - prevents memory issues
{
  where: { status: { eq: 'active' } },
  limit: 100
}

// Risky - could return thousands of items
{
  where: { status: { eq: 'active' } }
}
```

---

### 4. Use specific queries over broad ones

```typescript
// Good - targeted query
{
  where: {
    project_id: { eq: currentProject },
    status: { eq: 'active' }
  }
}

// Avoid - fetches too much data
{
  where: {
    status: { eq: 'active' }
  }
}
```

---

## Performance Considerations

### Indexed Fields

Queries perform best on indexed fields. Common fields to index:

- Primary keys (automatically indexed)
- Foreign keys (e.g., `user_id`, `project_id`)
- Status fields (e.g., `status`, `type`)
- Timestamp fields (e.g., `created_at`, `updated_at`)

Configure indexes in your `schema.json` file.

---

### Query Complexity

Simple queries are faster than complex ones:

- **Fast**: Single field equality (`{ status: { eq: 'active' } }`)
- **Medium**: Multiple AND conditions, range queries
- **Slower**: OR conditions, string operations (`contains`, `startsWith`)

---

### Real-time Subscriptions

For real-time subscriptions, keep queries focused:

```typescript
// Good - specific subscription
client.subscribe('tasks', {
  where: {
    project_id: { eq: currentProject },
    status: { eq: 'active' }
  }
}, callback)

// Avoid - too broad, updates frequently
client.subscribe('tasks', {
  where: {
    status: { ne: 'archived' }
  }
}, callback)
```

---

## Limitations

### Current Limitations

1. **Single OR group** - Only one `or` key at root level
2. **No nested OR** - Cannot nest OR within OR
3. **Single field sort** - Multi-field sorting coming in future release
4. **No aggregations** - No `count`, `sum`, `avg` (use client-side or separate endpoint)
5. **No joins** - Query one path at a time (denormalize data if needed)

### Workarounds

For complex queries beyond these limitations:

1. **Denormalize data** - Duplicate data to avoid joins
2. **Multiple queries** - Fetch related data separately
3. **Client-side filtering** - For very complex logic
4. **Computed fields** - Pre-compute values on write

---

## See Also

- [API Reference](./API_REFERENCE.md) - Complete client SDK documentation
- [Configuration](./CONFIGURATION.md) - Schema and index configuration
- [Design Decisions](./DESIGN_DECISIONS.md) - Why we chose this query language
