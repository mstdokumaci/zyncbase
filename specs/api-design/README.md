# ZyncBase API Design Specifications

This directory contains the core API design specifications for the ZyncBase SDK and Server.

## API Categories

ZyncBase's API is strictly divided into two namespaces to separate persistent state from ephemeral state.

### 1. Store API ([store-api.md](./store-api.md))
For durable, synchronized data. Everything in the Store API is validated against your schema, persisted to SQLite, and syncs across clients.
- **CRUD Operations**: Get, Set, and Remove data by path.
- **Query API**: Filter, sort, and search through data.
- **Batch Operations**: Perform multiple write operations atomically.
- **Query Language**: See [Query Language Reference](./query-language.md) for the Prisma-inspired DSL syntax.

### 2. Presence API ([presence-api.md](./presence-api.md))
For ephemeral, transient user awareness (cursors, typing indicators). Data is kept only in memory and is automatically wiped when a user disconnects.
- **Methods**: Set, Get, and Subscribe to user presence.

## Lifecycle & Setup

### Configuration ([configuration.md](./configuration.md))
Complete guide to server configuration, including:
- Server settings (port, host, security)
- Schema definitions and migrations
- Authorization rules (`auth.json`)
- Namespaces and multi-tenancy

---

**Note**: These documents serve as the source of truth for SDK implementation and server behavior. For installation and getting started guides, refer to the main repository documentation.
