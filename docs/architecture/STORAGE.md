# Storage Layer

**Last Updated**: 2026-03-09

---

## Overview

ZyncBase uses SQLite in Write-Ahead Logging (WAL) mode as its storage layer. This provides zero-config deployment, ACID transactions, and parallel reads—all critical for vertical scaling.

**Key Innovation**: SQLite WAL mode + connection pool = parallel reads across all CPU cores

---

## Why SQLite?

### Advantages

✅ **Zero-config** - Embedded database, no separate server  
✅ **ACID transactions** - Data integrity guarantees  
✅ **Full-text search** - Built-in FTS5 extension  
✅ **Proven reliability** - 20+ years, billions of devices  
✅ **WAL mode** - Parallel reads (critical for scaling)  
✅ **Single file** - Easy backup and deployment  

### Performance

- **70,000+ reads/second** (with WAL mode)
- **3,600+ writes/second** (with batching)
- **Sub-millisecond latency** (in-memory cache)
- **Scales with CPU cores** (parallel reads)

---

## WAL Mode

Write-Ahead Logging (WAL) transforms SQLite's concurrency model:

### Without WAL (Rollback Journal)

```
┌─────────────────────────────────────┐
│  Single Writer                      │
│  ┌──────────────────────────────┐   │
│  │ Blocks ALL Readers           │   │
│  └──────────────────────────────┘   │
│                                     │
│  Random I/O patterns                │
│  Slower write performance           │
│  Limited concurrency                │
└─────────────────────────────────────┘
```

### With WAL

```
┌─────────────────────────────────────┐
│  Multiple Readers (Parallel)        │
│  ┌──────┐  ┌──────┐  ┌──────┐      │
│  │ R1   │  │ R2   │  │ RN   │      │
│  └──────┘  └──────┘  └──────┘      │
│                                     │
│  Single Writer (No blocking)        │
│  ┌──────────────────────────────┐   │
│  │ Writes to WAL file           │   │
│  └──────────────────────────────┘   │
│                                     │
│  Sequential I/O patterns            │
│  Faster write performance           │
│  True parallel reads                │
└─────────────────────────────────────┘
```

### How WAL Works

1. **Writes go to WAL file** - Not the main database
2. **Readers access both** - Main DB + WAL file
3. **Checkpoint merges** - WAL → main DB periodically
4. **No blocking** - Readers and writer operate independently

### Performance Impact

```
16-core machine with WAL mode:
- Reads: 16 threads × 10k = 160k reads/sec
- Writes: 1 thread × 10k = 10k writes/sec
- Total: 170k ops/sec (90% read workload)
```

---

## SQLite Configuration

### Recommended Settings

```sql
-- Enable WAL mode (parallel reads + better concurrency)
PRAGMA journal_mode = WAL;

-- Increase cache size (better performance)
PRAGMA cache_size = -64000; -- 64MB

-- Synchronous = NORMAL (good balance)
PRAGMA synchronous = NORMAL;

-- Memory-mapped I/O (faster reads)
PRAGMA mmap_size = 268435456; -- 256MB

-- Multiple reader connections (parallel reads)
PRAGMA read_uncommitted = 1;

-- Proactive checkpoint management (prevent WAL growth)
PRAGMA wal_autocheckpoint = 1000; -- Checkpoint every 1000 pages
```

### Why These Settings?

**journal_mode = WAL:**
- Enables parallel reads
- Improves write performance
- Essential for vertical scaling

**cache_size = -64000:**
- Caches hot pages in RAM
- Reduces disk I/O
- Negative value = KB (64MB)

**synchronous = NORMAL:**
- Balances durability and performance
- Still safe against application crashes
- Only risk is power failure (rare)

**mmap_size = 256MB:**
- Maps DB file to memory
- Reduces syscall overhead
- Faster reads

**wal_autocheckpoint = 1000:**
- Prevents WAL file from growing too large
- Maintains read performance
- Automatic management

---

## Connection Pool

ZyncBase uses a connection pool to enable parallel reads:

```zig
const StorageLayer = struct {
    write_conn: *sqlite.Connection,      // Single writer
    read_pool: []sqlite.Connection,      // Multiple readers
    write_queue: RingBuffer(WriteOp),
    
    pub fn init(allocator: Allocator) !*StorageLayer {
        const num_readers = std.Thread.getCpuCount();
        
        const self = try allocator.create(StorageLayer);
        self.* = .{
            .write_conn = try sqlite.open("ZyncBase.db"),
            .read_pool = try allocator.alloc(sqlite.Connection, num_readers),
            .write_queue = RingBuffer(WriteOp).init(allocator),
        };
        
        // Open one reader connection per CPU core
        for (self.read_pool) |*conn| {
            conn.* = try sqlite.open("ZyncBase.db");
        }
        
        // Configure WAL mode
        try self.write_conn.exec("PRAGMA journal_mode = WAL");
        try self.write_conn.exec("PRAGMA synchronous = NORMAL");
        try self.write_conn.exec("PRAGMA cache_size = -64000");
        
        return self;
    }
};
```

### Pool Strategy

**One reader per CPU core:**
- Maximizes parallel read throughput
- No contention for connections
- Thread-local connection selection

**Single writer connection:**
- SQLite requirement (single writer)
- All writes go through write queue
- Batched for efficiency

**Thread-local selection:**
```zig
pub fn getReader(self: *StorageLayer) *sqlite.Connection {
    const thread_id = std.Thread.getCurrentId();
    const reader_idx = thread_id % self.read_pool.len;
    return &self.read_pool[reader_idx];
}
```

---

## Schema Design

ZyncBase generates SQLite tables from `schema.json` using a store-based format. Frontend developers work with the store; ZyncBase handles the relational mapping underneath.

### Schema Format

```json
{
  "version": "1.0.0",
  "store": {
    "tasks": {
      "fields": {
        "title": { "type": "string" },
        "status": { "type": "string" },
        "priority": { "type": "integer" },
        "projectId": {
          "type": "string",
          "references": "projects",
          "onDelete": "cascade"
        }
      }
    },
    "projects": {
      "fields": {
        "name": { "type": "string" }
      }
    }
  }
}
```

### Generated Tables

From the schema above, ZyncBase generates:

```sql
-- Projects table (from 'projects' in store)
CREATE TABLE projects (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL,
    name TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX idx_projects_namespace ON projects(namespace_id);

-- Tasks table (from 'tasks' in store) with foreign key
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL,
    title TEXT,
    status TEXT,
    priority INTEGER,
    projectId TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (projectId) REFERENCES projects(id) ON DELETE CASCADE
);

CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_projectId ON tasks(projectId);
```

### Nested Fields (Flattened)

Simple nested objects are automatically flattened to columns:

```json
{
  "store": {
    "users": {
      "fields": {
        "name": { "type": "string" },
        "address": {
          "type": "object",
          "properties": {
            "street": { "type": "string" },
            "city": { "type": "string" },
            "zipCode": { "type": "string" }
          }
        }
      }
    }
  }
}
```

**Generated DDL:**
```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL,
    name TEXT,
    address_street TEXT,      -- Flattened
    address_city TEXT,         -- Flattened
    address_zipCode TEXT,      -- Flattened
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX idx_users_namespace ON users(namespace_id);
CREATE INDEX idx_users_address_city ON users(address_city);
```

### Arrays

**Simple arrays (primitives) stored as JSON:**
```json
{
  "store": {
    "tasks": {
      "fields": {
        "tags": {
          "type": "array",
          "items": "string"
        }
      }
    }
  }
}
```

```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    tags TEXT,  -- JSON: ["urgent", "backend"]
    ...
);
```

**Arrays of objects forbidden - use separate store paths with references:**
```json
{
  "store": {
    "projects": {
      "fields": {
        "name": { "type": "string" }
      }
    },
    "project_members": {
      "fields": {
        "projectId": {
          "type": "string",
          "references": "projects",
          "onDelete": "cascade"
        },
        "userId": { "type": "string" },
        "role": { "type": "string" }
      }
    }
  }
}
```

### References (Foreign Keys)

References provide referential integrity and enable efficient queries:

**Schema:**
```json
{
  "store": {
    "tasks": {
      "fields": {
        "projectId": {
          "type": "string",
          "references": "projects",
          "onDelete": "cascade"
        }
      }
    }
  }
}
```

**Generated DDL:**
```sql
CREATE TABLE tasks (
    ...
    projectId TEXT,
    FOREIGN KEY (projectId) REFERENCES projects(id) ON DELETE CASCADE
);

CREATE INDEX idx_tasks_projectId ON tasks(projectId);
```

**Reference Actions:**
- `cascade` - Delete tasks when project is deleted
- `restrict` - Prevent project deletion if tasks exist
- `set_null` - Set projectId to NULL when project is deleted

**Benefits:**
- SQLite enforces referential integrity
- Automatic cascading deletes
- Efficient JOINs for queries
- Indexes automatically created

### Namespaces Table

For namespace metadata:

```sql
CREATE TABLE namespaces (
    id TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    metadata TEXT  -- JSON blob for namespace-level data
);
```

### Full-Text Search

For paths that need full-text search:

```sql
-- Enable FTS5 for tasks
CREATE VIRTUAL TABLE tasks_fts USING fts5(
    title,
    description,
    content=tasks
);
```

---

## Schema-to-DDL Generation

ZyncBase automatically generates SQLite tables from `schema.json`, mapping paths to tables with proper types and indexes.

### Path-to-Table Mapping

**Rule**: First segment of path = table name

```
Path: 'tasks' → Table: tasks
Path: 'tasks.task-1' → Table: tasks, row with id='task-1'
Path: 'users' → Table: users
Path: 'rooms' → Table: rooms
```

### DDL Generation Process

**Input (schema.json):**
```json
{
  "version": "1.0.0",
  "store": {
    "tasks": {
      "fields": {
        "title": { "type": "string" },
        "status": { "type": "string" },
        "priority": { "type": "integer" },
        "assignee": { "type": "string" },
        "projectId": {
          "type": "string",
          "references": "projects",
          "onDelete": "cascade"
        }
      },
      "required": ["title", "status"]
    }
  }
}
```

**Output (Generated SQL):**
```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL,
    priority INTEGER,
    assignee TEXT,
    projectId TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (projectId) REFERENCES projects(id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_assignee ON tasks(assignee);
CREATE INDEX idx_tasks_projectId ON tasks(projectId);
```

### Type Mapping

| JSON Schema Type | SQLite Type | Notes |
|------------------|-------------|-------|
| `string` | `TEXT` | UTF-8 text |
| `integer` | `INTEGER` | 64-bit signed |
| `number` | `REAL` | 64-bit float |
| `boolean` | `INTEGER` | 0 or 1 |
| `object` (nested) | Flattened columns | `address.city` → `address_city TEXT` |
| `array` (primitives) | `TEXT` | JSON blob: `["tag1", "tag2"]` |
| `array` (objects) | ❌ Not supported | Use separate table with foreign key |

### Implementation

```zig
const SchemaParser = struct {
    allocator: Allocator,
    
    pub fn parseSchema(self: *SchemaParser, schema_json: []const u8) ![]Table {
        const schema = try json.parse(schema_json);
        
        var tables = ArrayList(Table).init(self.allocator);
        
        // Parse each item from schema.store
        const store_obj = schema.get("store") orelse return error.InvalidSchema;
        
        for (store_obj.object.items) |entry| {
            const table = try self.parseTable(entry.key, entry.value);
            try tables.append(table);
        }
        
        return tables.toOwnedSlice();
    }
    
    fn parseTable(self: *SchemaParser, name: []const u8, store_item: json.Value) !Table {
        const fields_obj = store_item.get("fields") orelse return error.InvalidSchema;
        const required = store_item.get("required");
        
        var fields = ArrayList(Field).init(self.allocator);
        
        // Always include these fields
        try fields.append(.{ .name = "id", .type = .text, .required = true, .primary_key = true });
        try fields.append(.{ .name = "namespace_id", .type = .text, .required = true });
        
        // Parse schema fields
        for (fields_obj.object.items) |field_entry| {
            const field_name = field_entry.key;
            const field_def = field_entry.value;
            
            // Check if field is nested object (flatten it)
            if (self.isNestedObject(field_def)) {
                const nested_fields = try self.flattenNestedObject(field_name, field_def);
                try fields.appendSlice(nested_fields);
            } else {
                const field = try self.parseField(field_name, field_def, required);
                try fields.append(field);
            }
        }
        
        // Always include timestamps
        try fields.append(.{ .name = "created_at", .type = .integer, .required = true });
        try fields.append(.{ .name = "updated_at", .type = .integer, .required = true });
        
        return Table{
            .name = name,
            .fields = fields.toOwnedSlice(),
        };
    }
    
    fn isNestedObject(self: *SchemaParser, field_def: json.Value) bool {
        const field_type = field_def.get("type") orelse return false;
        if (!std.mem.eql(u8, field_type.string, "object")) return false;
        
        // Check if it has properties (nested object)
        return field_def.get("properties") != null;
    }
    
    fn flattenNestedObject(self: *SchemaParser, prefix: []const u8, field_def: json.Value) ![]Field {
        var fields = ArrayList(Field).init(self.allocator);
        
        const properties = field_def.get("properties") orelse return error.InvalidSchema;
        
        for (properties.object.items) |prop_entry| {
            const prop_name = prop_entry.key;
            const prop_def = prop_entry.value;
            
            // Create flattened field name: address.city → address_city
            const flattened_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}_{s}",
                .{ prefix, prop_name }
            );
            
            const field = try self.parseField(flattened_name, prop_def, null);
            try fields.append(field);
        }
        
        return fields.toOwnedSlice();
    }
    
    fn parseField(self: *SchemaParser, name: []const u8, field_def: json.Value, required: ?json.Value) !Field {
        const field_type = field_def.get("type") orelse return error.InvalidSchema;
        
        // Check for reference (foreign key)
        const foreign_key = if (field_def.get("references")) |ref_path| blk: {
            const on_delete_str = if (field_def.get("onDelete")) |od| od.string else "cascade";
            
            break :blk ForeignKey{
                .table = ref_path.string,
                .on_delete = try self.parseForeignKeyAction(on_delete_str),
            };
        } else null;
        
        return Field{
            .name = name,
            .type = try self.mapType(field_type.string, field_def),
            .required = self.isRequired(name, required),
            .indexed = self.shouldIndex(field_def) or foreign_key != null,
            .foreign_key = foreign_key,
        };
    }
    
    fn parseForeignKeyAction(self: *SchemaParser, action: []const u8) !ForeignKeyAction {
        return if (std.mem.eql(u8, action, "cascade"))
            .cascade
        else if (std.mem.eql(u8, action, "restrict"))
            .restrict
        else if (std.mem.eql(u8, action, "set_null"))
            .set_null
        else
            error.InvalidForeignKeyAction;
    }
    
    fn mapType(self: *SchemaParser, json_type: []const u8, field_def: json.Value) !SqlType {
        return if (std.mem.eql(u8, json_type, "string"))
            .text
        else if (std.mem.eql(u8, json_type, "integer"))
            .integer
        else if (std.mem.eql(u8, json_type, "number"))
            .real
        else if (std.mem.eql(u8, json_type, "boolean"))
            .integer
        else if (std.mem.eql(u8, json_type, "array"))
            .text  // Arrays stored as JSON
        else
            .text; // Objects stored as JSON
    }
    
    fn isRequired(self: *SchemaParser, name: []const u8, required: ?json.Value) bool {
        if (required == null) return false;
        
        for (required.?.array.items) |req_field| {
            if (std.mem.eql(u8, req_field.string, name)) return true;
        }
        
        return false;
    }
};

const ForeignKey = struct {
    table: []const u8,
    on_delete: ForeignKeyAction,
};

const ForeignKeyAction = enum {
    cascade,
    restrict,
    set_null,
};

const Field = struct {
    name: []const u8,
    type: SqlType,
    required: bool,
    indexed: bool,
    primary_key: bool = false,
    foreign_key: ?ForeignKey = null,
};
```

### DDL Generator

```zig
const DDLGenerator = struct {
    allocator: Allocator,
    
    pub fn generateDDL(self: *DDLGenerator, table: Table) ![]const u8 {
        var buf = ArrayList(u8).init(self.allocator);
        
        // CREATE TABLE
        try buf.appendSlice("CREATE TABLE ");
        try buf.appendSlice(table.name);
        try buf.appendSlice(" (\n");
        
        // Fields
        for (table.fields, 0..) |field, i| {
            try buf.appendSlice("    ");
            try buf.appendSlice(field.name);
            try buf.appendSlice(" ");
            try buf.appendSlice(self.sqlType(field.type));
            
            if (field.required) {
                try buf.appendSlice(" NOT NULL");
            }
            
            if (std.mem.eql(u8, field.name, "id")) {
                try buf.appendSlice(" PRIMARY KEY");
            }
            
            if (i < table.fields.len - 1) {
                try buf.appendSlice(",\n");
            }
        }
        
        try buf.appendSlice("\n);\n\n");
        
        // Indexes
        for (table.fields) |field| {
            if (field.indexed or std.mem.eql(u8, field.name, "namespace_id")) {
                try buf.appendSlice("CREATE INDEX idx_");
                try buf.appendSlice(table.name);
                try buf.appendSlice("_");
                try buf.appendSlice(field.name);
                try buf.appendSlice(" ON ");
                try buf.appendSlice(table.name);
                try buf.appendSlice("(");
                try buf.appendSlice(field.name);
                try buf.appendSlice(");\n");
            }
        }
        
        return buf.toOwnedSlice();
    }
    
    fn sqlType(self: *DDLGenerator, sql_type: SqlType) []const u8 {
        return switch (sql_type) {
            .text => "TEXT",
            .integer => "INTEGER",
            .real => "REAL",
        };
    }
};
```

---

## Auto-Migration Implementation

ZyncBase detects schema changes and auto-migrates when safe.

### Migration Detection

```zig
const MigrationDetector = struct {
    pub fn detectChanges(old_schema: Schema, new_schema: Schema) ![]Change {
        var changes = ArrayList(Change).init(allocator);
        
        // Check for new tables
        for (new_schema.tables) |new_table| {
            if (!old_schema.hasTable(new_table.name)) {
                try changes.append(.{ .type = .create_table, .table = new_table });
                continue;
            }
            
            const old_table = old_schema.getTable(new_table.name);
            
            // Check for new fields
            for (new_table.fields) |new_field| {
                if (!old_table.hasField(new_field.name)) {
                    try changes.append(.{
                        .type = .add_column,
                        .table = new_table.name,
                        .field = new_field,
                    });
                } else {
                    const old_field = old_table.getField(new_field.name);
                    
                    // Check for type changes
                    if (old_field.type != new_field.type) {
                        try changes.append(.{
                            .type = .change_type,
                            .table = new_table.name,
                            .field = new_field,
                            .old_type = old_field.type,
                        });
                    }
                }
            }
            
            // Check for removed fields
            for (old_table.fields) |old_field| {
                if (!new_table.hasField(old_field.name)) {
                    try changes.append(.{
                        .type = .remove_column,
                        .table = new_table.name,
                        .field = old_field,
                    });
                }
            }
        }
        
        return changes.toOwnedSlice();
    }
};
```

### Migration Safety Checks

```zig
const MigrationValidator = struct {
    pub fn validate(changes: []Change, config: Config) !MigrationPlan {
        var plan = MigrationPlan.init();
        
        for (changes) |change| {
            switch (change.type) {
                .create_table, .add_column => {
                    // Always safe - additive changes
                    try plan.addSafe(change);
                },
                
                .change_type, .remove_column => {
                    // Destructive changes
                    if (config.environment == .production and !config.allowDestructive) {
                        return error.DestructiveMigrationNotAllowed;
                    }
                    
                    if (config.environment == .development and config.confirmDestructive) {
                        try plan.addWithConfirmation(change);
                    } else {
                        try plan.addDestructive(change);
                    }
                },
            }
        }
        
        return plan;
    }
};
```

### Migration Execution

```zig
const MigrationExecutor = struct {
    db: *sqlite.Connection,
    
    pub fn execute(self: *MigrationExecutor, plan: MigrationPlan) !void {
        try self.db.exec("BEGIN TRANSACTION");
        errdefer self.db.exec("ROLLBACK") catch {};
        
        for (plan.changes) |change| {
            switch (change.type) {
                .create_table => {
                    const ddl = try DDLGenerator.generateDDL(change.table);
                    try self.db.exec(ddl);
                },
                
                .add_column => {
                    const sql = try std.fmt.allocPrint(
                        allocator,
                        "ALTER TABLE {s} ADD COLUMN {s} {s}",
                        .{
                            change.table,
                            change.field.name,
                            sqlType(change.field.type),
                        }
                    );
                    try self.db.exec(sql);
                    
                    // Create index if needed
                    if (change.field.indexed) {
                        const index_sql = try std.fmt.allocPrint(
                            allocator,
                            "CREATE INDEX idx_{s}_{s} ON {s}({s})",
                            .{
                                change.table,
                                change.field.name,
                                change.table,
                                change.field.name,
                            }
                        );
                        try self.db.exec(index_sql);
                    }
                },
                
                .change_type, .remove_column => {
                    // Requires table recreation (SQLite limitation)
                    try self.recreateTable(change.table);
                },
            }
        }
        
        try self.db.exec("COMMIT");
    }
    
    fn recreateTable(self: *MigrationExecutor, table: Table) !void {
        // Create backup
        try self.db.exec(
            try std.fmt.allocPrint(
                allocator,
                "CREATE TABLE {s}_backup AS SELECT * FROM {s}",
                .{table.name, table.name}
            )
        );
        
        // Drop old table
        try self.db.exec(
            try std.fmt.allocPrint(allocator, "DROP TABLE {s}", .{table.name})
        );
        
        // Create new table
        const ddl = try DDLGenerator.generateDDL(table);
        try self.db.exec(ddl);
        
        // Copy data (with transformations if needed)
        try self.copyData(table);
        
        // Drop backup
        try self.db.exec(
            try std.fmt.allocPrint(allocator, "DROP TABLE {s}_backup", .{table.name})
        );
    }
};
```

---

## Write Strategy

### Async Writes with Batching

```zig
const StorageLayer = struct {
    write_queue: RingBuffer(WriteOp),
    batch_size: usize = 100,
    batch_timeout_ms: u64 = 10,
    
    pub fn queueWrite(self: *StorageLayer, op: WriteOp) !void {
        try self.write_queue.push(op);
        
        // Trigger batch if full
        if (self.write_queue.len() >= self.batch_size) {
            try self.flushBatch();
        }
    }
    
    fn flushBatch(self: *StorageLayer) !void {
        const batch = self.write_queue.drain();
        
        // Single transaction for entire batch
        try self.write_conn.exec("BEGIN TRANSACTION");
        
        for (batch) |op| {
            try self.executeWrite(op);
        }
        
        try self.write_conn.exec("COMMIT");
    }
};
```

### Why Batching?

**Without batching:**
- Each write = separate transaction
- Each transaction = fsync() call
- ~100 writes/sec (limited by disk)

**With batching:**
- 100 writes = one transaction
- One transaction = one fsync() call
- ~10,000 writes/sec (100x improvement)

### Batching Strategy

**Trigger batch when:**
1. Queue reaches batch_size (e.g., 100 operations)
2. Timeout expires (e.g., 10ms since first operation)
3. Manual flush requested

**Benefits:**
- Reduces fsync() overhead
- Improves write throughput
- Still maintains low latency

---

## Read Strategy

### Read-through Cache

```zig
const StateManager = struct {
    cache: HashMap([]const u8, *Namespace),
    storage: *StorageLayer,
    
    pub fn getNamespace(self: *StateManager, id: []const u8) !*Namespace {
        // Check cache first
        if (self.cache.get(id)) |ns| {
            return ns;
        }
        
        // Load from storage
        const ns = try self.storage.loadNamespace(id);
        try self.cache.put(id, ns);
        return ns;
    }
};
```

### Cache Strategy

**1. Check in-memory cache first**
- Nanosecond latency
- No disk I/O
- Most common case

**2. Load from SQLite if not cached**
- Use reader from pool
- Parallel with other reads
- Cache result for future

**3. Invalidate on write**
- Update cache immediately
- Queue async write to disk
- Notify subscribers

---

## Checkpoint Management

### The Checkpoint Problem

WAL files must be periodically checkpointed (merged back to main DB). Without proper management:

- WAL file grows indefinitely
- Read performance degrades
- "Checkpoint starvation" under heavy read load

### ZyncBase's Solution

**1. Passive checkpoints** during low-traffic periods
```zig
fn backgroundCheckpoint(self: *StorageLayer) !void {
    // Run during low traffic
    try self.write_conn.exec("PRAGMA wal_checkpoint(PASSIVE)");
}
```

**2. Automatic checkpointing** when WAL reaches threshold
```sql
PRAGMA wal_autocheckpoint = 1000; -- Every 1000 pages
```

**3. Manual checkpoints** via admin API if needed
```zig
pub fn forceCheckpoint(self: *StorageLayer) !void {
    try self.write_conn.exec("PRAGMA wal_checkpoint(TRUNCATE)");
}
```

### Checkpoint Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| PASSIVE | Non-blocking, best effort | Background maintenance |
| FULL | Waits for readers, completes | Scheduled maintenance |
| RESTART | Resets WAL file | After backup |
| TRUNCATE | Resets and shrinks WAL | Reclaim disk space |

---

## Performance Optimization

### Authorization Performance

**Problem**: Running SQL queries for authorization on every WebSocket message creates a bottleneck.

**Solution**: Permission snapshots

1. **On connection**: Execute SQL queries to determine permissions
2. **Cache in memory**: Store permission snapshot for the connection
3. **Fast path**: Check permissions via memory lookup (nanoseconds)
4. **Invalidation**: Only re-query when underlying data changes

**Result**: Authorization doesn't bottleneck real-time operations like cursor movements.

### Query Optimization

**Use indexes for common queries:**
```sql
-- Index on namespace_id (always created)
CREATE INDEX idx_tasks_namespace ON tasks(namespace_id);

-- Index on frequently queried fields
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_assignee ON tasks(assignee);

-- Composite index for common patterns
CREATE INDEX idx_tasks_status_priority ON tasks(status, priority);
```

**Use EXPLAIN QUERY PLAN:**
```sql
EXPLAIN QUERY PLAN
SELECT * FROM tasks 
WHERE namespace_id = ? AND status = 'active';
```

---

## Backup Strategy

### Simple Backup (Single File)

```bash
# Stop writes (or use PRAGMA wal_checkpoint)
sqlite3 ZyncBase.db ".backup ZyncBase-backup.db"

# Or just copy the file
cp ZyncBase.db ZyncBase-backup.db
```

### Online Backup (No Downtime)

```zig
pub fn backup(self: *StorageLayer, dest_path: []const u8) !void {
    // Checkpoint WAL first
    try self.write_conn.exec("PRAGMA wal_checkpoint(FULL)");
    
    // Copy database file
    try std.fs.copyFileAbsolute(
        "ZyncBase.db",
        dest_path,
        .{}
    );
}
```

### Continuous Backup (LiteFS)

For production, consider LiteFS for continuous replication:
- Real-time replication
- Point-in-time recovery
- Geographic distribution
- Automatic failover

---

## Comparison with Alternatives

| Database | Type | Concurrency | Setup | Performance | Use Case |
|----------|------|-------------|-------|-------------|----------|
| **SQLite (WAL)** | Embedded | Parallel reads | Zero-config | 70k reads/s | Vertical scaling |
| **PostgreSQL** | Server | Full parallel | Complex | 100k+ ops/s | Horizontal scaling |
| **Redis** | In-memory | Single-threaded | Simple | 100k+ ops/s | Caching only |
| **MongoDB** | Server | Full parallel | Medium | 50k+ ops/s | Document store |

**Key Insight**: For vertical scaling with zero-config deployment, SQLite WAL mode is optimal. It provides parallel reads without the complexity of a separate database server.

---

## Limitations and Trade-offs

### Single Writer

**Limitation**: SQLite allows only one writer at a time

**Impact**: Writes are serialized, limited to ~10k writes/sec

**Mitigation**:
- Most workloads are read-heavy (90%+)
- 10k writes/sec is sufficient for most apps
- Batch writes for higher throughput

### Checkpoint Starvation

**Limitation**: Heavy read load can prevent checkpoints

**Impact**: WAL file grows, read performance degrades

**Mitigation**:
- Proactive checkpoint management
- Automatic checkpointing thresholds
- Manual checkpoints during low traffic

### No Horizontal Scaling (v1.0)

**Limitation**: Single-node only in v1.0

**Impact**: Cannot scale beyond one server

**Mitigation**:
- Vertical scaling is sufficient for most apps
- Can add LiteFS/Marmot in v2.5+ if needed

---

## See Also

- [Core Principles](./CORE_PRINCIPLES.md) - Why we chose SQLite
- [Threading Model](./THREADING.md) - How connection pool enables parallel reads
- [Network Layer](./NETWORKING.md) - WebSocket integration
- [Research](./RESEARCH.md) - SQLite performance validation
