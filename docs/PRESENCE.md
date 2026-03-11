# Presence System

**Last Updated**: 2026-03-09

Complete guide to zyncBase's real-time presence system for user awareness and collaboration.

---

## Table of Contents

1. [Overview](#overview)
2. [Use Cases](#use-cases)
3. [Schema Definition](#schema-definition)
4. [Client API](#client-api)
5. [Presence Namespaces](#presence-namespaces)
6. [Performance & Optimization](#performance--optimization)
7. [Architecture](#architecture)
8. [Best Practices](#best-practices)
9. [Examples](#examples)

---

## Overview

zyncBase's presence system tracks ephemeral user state in real-time:

- **Cursor positions** - Where users are pointing
- **Selections** - What users have selected
- **Typing indicators** - Who's typing where
- **User status** - Online/away/idle
- **Custom state** - Any transient per-user data

**Key characteristics:**
- ✅ **In-memory only** - No persistence, automatic cleanup on disconnect
- ✅ **Real-time** - Sub-100ms latency
- ✅ **Namespace-scoped** - Only see users in your presence namespace
- ✅ **Schema-validated** - Type-safe presence data
- ✅ **Optimized** - Throttling, batching, interpolation

---

## Use Cases

### 1. Collaborative Editor (Figma/Google Docs)

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme',
  presenceNamespace: 'tenant:acme:document:doc-123'
})

// Track cursor position
document.addEventListener('mousemove', (e) => {
  client.presence.set({
    cursor: { x: e.clientX, y: e.clientY },
    color: userColor,
    name: userName
  })
})

// Render other users' cursors
client.presence.subscribe((users) => {
  users.forEach(user => {
    renderCursor(user.userId, user.data.cursor, user.data.color)
  })
})
```

### 2. Chat Application (Typing Indicators)

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  presenceNamespace: 'workspace:acme:channel:general'
})

// Show typing indicator
input.addEventListener('input', () => {
  client.presence.set({ typing: true })
  
  clearTimeout(typingTimeout)
  typingTimeout = setTimeout(() => {
    client.presence.set({ typing: false })
  }, 3000)
})

// Display who's typing
client.presence.subscribe((users) => {
  const typing = users.filter(u => u.data.typing)
  showTypingIndicator(typing.map(u => u.data.name))
})
```

### 3. Multiplayer Game

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  presenceNamespace: 'game:chess:match:match-789'
})

// Track player position
client.presence.set({
  position: { x: player.x, y: player.y },
  health: player.health,
  action: 'running'
})

// Render other players
client.presence.subscribe((players) => {
  players.forEach(player => {
    renderPlayer(player.userId, player.data)
  })
})
```

### 4. User Status (Online/Away/Idle)

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  presenceNamespace: 'workspace:acme'
})

// Set initial status
client.presence.set({ status: 'active' })

// Detect idle
let idleTimeout
document.addEventListener('mousemove', () => {
  client.presence.set({ status: 'active' })
  
  clearTimeout(idleTimeout)
  idleTimeout = setTimeout(() => {
    client.presence.set({ status: 'idle' })
  }, 5 * 60 * 1000) // 5 minutes
})

// Show online users
client.presence.subscribe((users) => {
  const online = users.filter(u => u.data.status === 'active')
  renderOnlineUsers(online)
})
```

---

## Schema Definition

Define presence structure in `schema.json`:

```json
{
  "version": "1.0.0",
  "store": {
    "documents": {
      "fields": {
        "title": { "type": "string" }
      }
    }
  },
  "presence": {
    "fields": {
      "cursor": {
        "type": "object",
        "properties": {
          "x": { "type": "number" },
          "y": { "type": "number" }
        },
        "required": ["x", "y"]
      },
      "selection": {
        "type": "object",
        "properties": {
          "start": { "type": "integer" },
          "end": { "type": "integer" }
        }
      },
      "typing": { "type": "boolean" },
      "status": {
        "type": "string",
        "enum": ["active", "away", "idle"]
      },
      "color": {
        "type": "string",
        "pattern": "^#[0-9a-fA-F]{6}$"
      },
      "name": { "type": "string" }
    }
  }
}
```

**Benefits of schema:**
- ✅ Type safety (TypeScript types generated)
- ✅ Validation (client and server)
- ✅ Documentation (clear contract)
- ✅ Prevents bugs (catch errors early)

---

## Client API

### Set Presence

```typescript
// Set full presence
client.presence.set({
  cursor: { x: 100, y: 200 },
  color: '#ff0000',
  name: 'Alice'
})

// Partial update (merges with existing)
client.presence.set({
  cursor: { x: 101, y: 201 }
})
// Other fields (color, name) remain unchanged

// Clear specific field
client.presence.set({
  typing: null
})
```

### Get Presence

```typescript
// Get specific user
const alicePresence = client.presence.get('user-123')
// Returns: { cursor: { x: 100, y: 200 }, color: '#ff0000', name: 'Alice' }

// Get all users
const allUsers = client.presence.getAll()
// Returns: [
//   { userId: 'user-123', data: { ... }, joinedAt: 1234567890 },
//   { userId: 'user-456', data: { ... }, joinedAt: 1234567891 }
// ]
```

### Subscribe to Changes

```typescript
const unsubscribe = client.presence.subscribe((users) => {
  console.log(`${users.length} users online`)
  
  users.forEach(user => {
    console.log(user.userId, user.data)
  })
})

// Cleanup
unsubscribe()
```

### Clear Presence

```typescript
// Clear your presence (called automatically on disconnect)
client.presence.clear()
```

---

## Presence Namespaces

Presence is scoped to the `presenceNamespace` set when creating the client.

### Why Namespace Presence?

**Problem:** In a collaborative app with multiple documents, you don't want to see cursors from all documents.

**Solution:** Scope presence to the document you're viewing.

```typescript
// User editing document A
const clientA = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme',
  presenceNamespace: 'tenant:acme:document:doc-123'
})

// User editing document B
const clientB = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme',
  presenceNamespace: 'tenant:acme:document:doc-456'
})

// Users don't see each other's cursors
```

### Hierarchical Namespaces

```
tenant:acme                                    // All users in tenant
  └─ tenant:acme:workspace:ws-1                // Users in workspace
      └─ tenant:acme:workspace:ws-1:document:doc-123  // Users in document
```

**Use the most specific namespace for presence:**

```typescript
// Too broad - see everyone in tenant
presenceNamespace: 'tenant:acme'

// Better - see everyone in workspace
presenceNamespace: 'tenant:acme:workspace:ws-1'

// Best - see only users in this document
presenceNamespace: 'tenant:acme:workspace:ws-1:document:doc-123'
```

### Switching Presence Namespace

```typescript
// Switch to different document
await client.setPresenceNamespace('tenant:acme:document:doc-456')

// Your presence is cleared from old namespace
// You join the new namespace
// You receive presence from users in new namespace
```

### Store vs Presence Namespace

**Store namespace** - Controls data access (security boundary)
**Presence namespace** - Controls who you see (collaboration context)

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'tenant:acme',              // Can access all tenant data
  presenceNamespace: 'tenant:acme:document:doc-123'  // Only see users in this doc
})

// Store: Tenant-scoped
client.store.get('documents')  // All documents in tenant

// Presence: Document-scoped
client.presence.subscribe((users) => {
  // Only users in doc-123
})
```

---

## Performance & Optimization

### Client-Side Throttling

High-frequency updates (cursor moves) are automatically throttled to ~60fps:

```typescript
// You can send updates as fast as you want
document.addEventListener('mousemove', (e) => {
  client.presence.set({
    cursor: { x: e.clientX, y: e.clientY }
  })
})

// Client throttles to 16ms (~60fps)
// Only ~60 updates/sec sent to server
```

### Server-Side Batching

Server batches presence updates every 50ms:

```
Client A: cursor update (t=0ms)
Client B: cursor update (t=10ms)
Client C: cursor update (t=30ms)

Server batches all 3 updates
Broadcasts at t=50ms

Result: 1 message instead of 3
```

### Client-Side Interpolation

For smooth rendering, interpolate between updates:

```typescript
client.presence.subscribe((users) => {
  users.forEach(user => {
    // Server sends updates at ~20fps
    // Interpolate to 60fps for smooth cursors
    const interpolated = lerp(
      lastPosition[user.userId],
      user.data.cursor,
      alpha
    )
    
    renderCursor(user.userId, interpolated)
  })
})

function lerp(start, end, alpha) {
  return {
    x: start.x + (end.x - start.x) * alpha,
    y: start.y + (end.y - start.y) * alpha
  }
}
```

### Delta Compression

Only send what changed:

```typescript
// Initial state
client.presence.set({
  cursor: { x: 100, y: 200 },
  color: '#ff0000',
  name: 'Alice'
})

// Only cursor changed
client.presence.set({
  cursor: { x: 101, y: 201 }
})
// Server only broadcasts cursor delta
```

### Performance Summary

| Optimization | Impact |
|--------------|--------|
| Client throttling (60fps) | 16ms between updates |
| Server batching (50ms) | ~20 updates/sec to clients |
| Delta compression | 50-90% bandwidth reduction |
| Interpolation | Smooth 60fps rendering |

**Result:** Smooth real-time experience with minimal bandwidth.

---

## Architecture

### In-Memory Storage

Presence is stored in-memory only (not in SQLite):

```zig
const PresenceManager = struct {
    // namespace -> user_id -> presence_data
    presence: HashMap([]const u8, HashMap([]const u8, PresenceData)),
    
    // History buffer (last 5 seconds)
    history: HashMap([]const u8, RingBuffer(PresenceSnapshot)),
    
    pub fn set(self: *PresenceManager, namespace: []const u8, user_id: []const u8, data: json.Value) !void {
        // Store in memory
        const ns_presence = self.presence.getOrPut(namespace);
        ns_presence.put(user_id, data);
        
        // Add to history buffer
        const ns_history = self.history.getOrPut(namespace);
        ns_history.push(.{
            .user_id = user_id,
            .data = data,
            .timestamp = std.time.milliTimestamp(),
        });
        
        // Broadcast to subscribers
        try self.broadcast(namespace, user_id, data);
    }
    
    pub fn remove(self: *PresenceManager, namespace: []const u8, user_id: []const u8) !void {
        // Remove from memory
        if (self.presence.get(namespace)) |ns_presence| {
            ns_presence.remove(user_id);
        }
        
        // Broadcast removal
        try self.broadcastRemoval(namespace, user_id);
    }
};
```

### Automatic Cleanup

Presence is automatically cleaned up on disconnect:

```zig
fn onDisconnect(conn: *Connection) !void {
    const namespace = conn.presence_namespace;
    const user_id = conn.user_id;
    
    // Remove presence
    try presence_manager.remove(namespace, user_id);
    
    // Notify other users
    try presence_manager.broadcastRemoval(namespace, user_id);
}
```

### History Buffer

When joining a presence namespace, you receive the last 5 seconds of updates:

```zig
pub fn onJoin(self: *PresenceManager, namespace: []const u8) !PresenceSnapshot {
    // Current state
    const current = self.presence.get(namespace);
    
    // Last 5 seconds of history
    const history = self.history.get(namespace);
    const recent = history.getLastNSeconds(5);
    
    return .{
        .current = current,
        .history = recent,
    };
}
```

**Use case:** See cursor trails when joining a document.

### Broadcast Strategy

```zig
fn broadcast(self: *PresenceManager, namespace: []const u8, user_id: []const u8, data: json.Value) !void {
    // Get all connections in this namespace
    const connections = self.getConnectionsInNamespace(namespace);
    
    // Broadcast to all except sender
    for (connections) |conn| {
        if (!std.mem.eql(u8, conn.user_id, user_id)) {
            try conn.send(.{
                .type = .presence_update,
                .userId = user_id,
                .data = data,
            });
        }
    }
}
```

---

## Best Practices

### 1. Keep Presence Data Minimal

```typescript
// ❌ Bad - too much data
client.presence.set({
  cursor: { x, y },
  color,
  name,
  avatar,
  bio,
  preferences,
  settings,
  // ...
})

// ✅ Good - minimal data
client.presence.set({
  cursor: { x, y },
  color
})
```

**Why:** Presence updates are frequent. Keep payload small.

### 2. Use Appropriate Namespace Granularity

```typescript
// ❌ Too broad - see everyone in tenant
presenceNamespace: 'tenant:acme'

// ❌ Too narrow - can't see collaborators
presenceNamespace: 'tenant:acme:document:doc-123:paragraph:p-5'

// ✅ Just right - see document collaborators
presenceNamespace: 'tenant:acme:document:doc-123'
```

### 3. Throttle High-Frequency Updates

```typescript
// ❌ Bad - sends every mousemove
document.addEventListener('mousemove', (e) => {
  client.presence.set({ cursor: { x: e.clientX, y: e.clientY } })
})

// ✅ Good - client throttles automatically
// But you can also throttle manually for more control
const throttledUpdate = throttle((x, y) => {
  client.presence.set({ cursor: { x, y } })
}, 16) // 60fps

document.addEventListener('mousemove', (e) => {
  throttledUpdate(e.clientX, e.clientY)
})
```

### 4. Clear Presence When Appropriate

```typescript
// Clear typing indicator after timeout
let typingTimeout
input.addEventListener('input', () => {
  client.presence.set({ typing: true })
  
  clearTimeout(typingTimeout)
  typingTimeout = setTimeout(() => {
    client.presence.set({ typing: false })
  }, 3000)
})

// Clear cursor when leaving canvas
canvas.addEventListener('mouseleave', () => {
  client.presence.set({ cursor: null })
})
```

### 5. Handle Late Joiners

Use the history buffer to show context:

```typescript
client.presence.subscribe((users) => {
  users.forEach(user => {
    // Show current cursor
    renderCursor(user.userId, user.data.cursor)
    
    // Show cursor trail from history (last 5 seconds)
    if (user.history) {
      renderCursorTrail(user.userId, user.history)
    }
  })
})
```

### 6. Interpolate for Smooth Rendering

```typescript
// Store last known positions
const lastPositions = new Map()

client.presence.subscribe((users) => {
  users.forEach(user => {
    const last = lastPositions.get(user.userId)
    const current = user.data.cursor
    
    if (last) {
      // Interpolate between last and current
      animateCursor(user.userId, last, current, 50) // 50ms animation
    } else {
      // First time seeing this user
      renderCursor(user.userId, current)
    }
    
    lastPositions.set(user.userId, current)
  })
})
```

### 7. Show User Info

```typescript
// Include user info in presence
client.presence.set({
  cursor: { x, y },
  color: userColor,
  name: userName,
  avatar: userAvatar
})

// Render with user info
client.presence.subscribe((users) => {
  users.forEach(user => {
    renderCursor(user.userId, user.data.cursor, {
      color: user.data.color,
      name: user.data.name,
      avatar: user.data.avatar
    })
  })
})
```

---

## Examples

### Example 1: Collaborative Whiteboard

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'public',
  presenceNamespace: 'canvas:canvas-123'
})

// Track cursor and tool
let currentTool = 'pen'

canvas.addEventListener('mousemove', (e) => {
  client.presence.set({
    cursor: { x: e.clientX, y: e.clientY },
    tool: currentTool,
    color: userColor,
    name: userName
  })
})

// Render other users
client.presence.subscribe((users) => {
  users.forEach(user => {
    renderCursor(user.userId, {
      position: user.data.cursor,
      tool: user.data.tool,
      color: user.data.color,
      name: user.data.name
    })
  })
})
```

### Example 2: Code Editor with Selections

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'public',
  presenceNamespace: 'file:file-456'
})

// Track cursor and selection
editor.on('selectionChange', (selection) => {
  client.presence.set({
    cursor: selection.cursor,
    selection: {
      start: selection.start,
      end: selection.end
    },
    color: userColor,
    name: userName
  })
})

// Render other users' selections
client.presence.subscribe((users) => {
  users.forEach(user => {
    // Render selection highlight
    renderSelection(user.userId, user.data.selection, user.data.color)
    
    // Render cursor
    renderCursor(user.userId, user.data.cursor, user.data.color)
    
    // Show name tag
    renderNameTag(user.userId, user.data.name, user.data.cursor)
  })
})
```

### Example 3: Chat with Typing Indicators

```typescript
const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token },
  storeNamespace: 'public',
  presenceNamespace: 'channel:general'
})

// Typing indicator
let typingTimeout
messageInput.addEventListener('input', () => {
  client.presence.set({
    typing: true,
    name: userName
  })
  
  clearTimeout(typingTimeout)
  typingTimeout = setTimeout(() => {
    client.presence.set({ typing: false })
  }, 3000)
})

// Show who's typing
client.presence.subscribe((users) => {
  const typing = users.filter(u => u.data.typing)
  
  if (typing.length === 0) {
    hideTypingIndicator()
  } else if (typing.length === 1) {
    showTypingIndicator(`${typing[0].data.name} is typing...`)
  } else if (typing.length === 2) {
    showTypingIndicator(`${typing[0].data.name} and ${typing[1].data.name} are typing...`)
  } else {
    showTypingIndicator(`${typing.length} people are typing...`)
  }
})
```

---

## See Also

- [API Reference](./API_REFERENCE.md) - Complete API documentation
- [Configuration](./CONFIGURATION.md) - Schema and auth setup
- [Examples](https://github.com/zyncBase/examples) - Complete working examples
