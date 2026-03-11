# STX v2.0 - Real-Time Collaborative State Manager

**Status**: Draft  
**Last Updated**: 2026-03-09

---

## 🎯 What is STX?

**STX is a self-hosted, real-time collaborative state manager with built-in network sync, presence awareness, and multi-tenant isolation.**

**The Problem**: Firebase costs explode with success and locks you in. Supabase is slow at scale. Building real-time features from scratch is complex.

**The Solution**: STX gives you Firebase's real-time features with predictable costs, no vendor lock-in, and full control over your infrastructure.

---

## The "Better Than" Strategy

STX isn't trying to be everything to everyone. It's laser-focused on being the **best choice for real-time collaborative applications**.

| What You Need | Best Choice | Why |
|---------------|-------------|-----|
| **Real-time collaboration** | **STX** | Built for this, 200k+ req/sec, presence included |
| **Complex SQL queries** | Supabase | PostgreSQL is better for complex joins |
| **Serverless functions** | Firebase | Managed cloud, auto-scaling |
| **Simple CRUD API** | PocketBase | Simpler if you don't need real-time |
| **Mobile offline-first** | **STX** | Optimistic updates, conflict resolution |
| **Multi-tenant SaaS** | **STX** | Namespace isolation built-in |

**STX's Unfair Advantages:**

1. **Performance** - 20x faster than Supabase real-time, 2x faster than PocketBase
2. **Presence** - Built-in, not an afterthought or extra cost
3. **Zero-config** - Download binary, edit JSON, done
4. **Real-time first** - Not bolted on, designed from the ground up
5. **Predictable costs** - Your server, your costs, no surprises
6. **Developer experience** - TypeScript SDK that feels like Firebase but better

---

## Quick Start

### 1. Download & Run Server

```bash
# Download binary
curl -L https://stx.dev/download/latest -o stx-server
chmod +x stx-server

# Run with default config
./stx-server
```

### 2. Define Your Schema

Create `schema.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "elements": {
      "type": "object",
      "patternProperties": {
        ".*": {
          "type": "object",
          "properties": {
            "x": { "type": "number" },
            "y": { "type": "number" },
            "width": { "type": "number" },
            "height": { "type": "number" }
          }
        }
      }
    }
  }
}
```

### 3. Connect from Client

```typescript
import { createClient } from '@stx/client'

const client = createClient({
  url: 'ws://localhost:3000',
  auth: { token: userJWT },
  namespace: 'room:abc-123'
})

await client.connect()

// Subscribe to real-time updates
client.store.subscribe('elements', (elements) => {
  renderCanvas(elements)
})

// Update state (syncs to all clients)
client.store.set('elements.rect-1', {
  x: 100, y: 100, width: 200, height: 150
})

// Show presence
client.presence.set({ cursor: { x, y }, color: '#ff0000' })
const others = client.presence.getAll()
```

That's it! You now have real-time collaboration with presence awareness.

---

## Documentation

### User Documentation
- **[API Reference](./API_REFERENCE.md)** - Complete client SDK documentation
- **[Query Language](./QUERY_LANGUAGE.md)** - Filtering, sorting, and pagination syntax
- **[Configuration](./CONFIGURATION.md)** - Server setup and config files
- **[Migrations](./MIGRATIONS.md)** - Schema changes and data migrations
- **[Deployment](./DEPLOYMENT.md)** - Docker, production, security
- **[Comparison](./COMPARISON.md)** - vs Firebase/Supabase/PocketBase
- **[Design Decisions](./DESIGN_DECISIONS.md)** - High-level architecture decisions

### Technical Documentation
- **[Architecture](./architecture/README.md)** - Deep dive into STX internals
  - [Core Principles](./architecture/CORE_PRINCIPLES.md) - Design philosophy and technology choices
  - [Threading Model](./architecture/THREADING.md) - Multi-threaded architecture
  - [Storage Layer](./architecture/STORAGE.md) - SQLite optimization
  - [Network Layer](./architecture/NETWORKING.md) - uWebSockets integration
  - [Query Engine](./architecture/QUERY_ENGINE.md) - Query execution and subscriptions
  - [Research](./architecture/RESEARCH.md) - Technical validation with citations

---

## Why Developers Choose STX

### Not Another State Manager

STX is **NOT** a replacement for Zustand, Redux, or Jotai. Those are great for local state.

STX is for when you need:
- **Real-time collaboration** - Multiple users editing the same data simultaneously
- **Presence awareness** - See who's online, where their cursor is, what they're selecting
- **Multi-tenant SaaS** - Isolated state per customer with efficient resource sharing
- **Offline-first apps** - Automatic conflict resolution when reconnecting

### When to Use STX

**Use STX when you need:**
- ✅ Real-time collaboration (multiple users editing same data)
- ✅ Presence awareness (see who's online, where they are)
- ✅ Multi-tenant isolation (SaaS with per-customer state)
- ✅ Offline-first with sync (mobile apps, unreliable networks)
- ✅ Conflict resolution (automatic merging of concurrent edits)

**Don't use STX when:**
- ❌ You just need local state management → Use Zustand
- ❌ You need server state caching → Use TanStack Query
- ❌ You need complex state machines → Use XState
- ❌ You're building a static site → Use nothing, just React state

---

## Zero-Zig Philosophy

**You don't need to know Zig to use STX.** The server is a single binary that you configure with JSON files. Think of it like:
- **Nginx** - You don't write C, you edit nginx.conf
- **PostgreSQL** - You don't write C, you write SQL and config files
- **Redis** - You don't write C, you use redis.conf

**STX is the same**: Download the binary, edit config files, connect from your JavaScript/TypeScript app.

**No Zig compilation. No build steps. Just configuration.**

---

## Community & Support

- **GitHub**: [github.com/stx/stx](https://github.com/stx/stx)
- **Discord**: [discord.gg/stx](https://discord.gg/stx)
- **Documentation**: [stx.dev/docs](https://stx.dev/docs)
- **Examples**: [github.com/stx/examples](https://github.com/stx/examples)

---

## License

MIT License - See [LICENSE](../LICENSE) for details
