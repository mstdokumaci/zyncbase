# Storage Implementation

**Drivers**: [Storage Layer Architecture](../architecture/storage-layer.md)

This document contains the implementation specifics for the ZyncBase storage layer, focusing on SQLite configuration, connection management, schema generation, and migration logic.

---

## SQLite Configuration

### Pragma Settings
ZyncBase uses a specifically tuned set of PRAGMAs to optimize for high-concurrency real-time workloads.

```sql
-- Enable WAL mode (parallel reads + better concurrency)
PRAGMA journal_mode = WAL;

-- Increase cache size to 64MB (hot pages in RAM)
PRAGMA cache_size = -64000;

-- Synchronous = NORMAL (balance between durability and performance)
PRAGMA synchronous = NORMAL;

-- Memory-mapped I/O (reduces syscall overhead for reads)
PRAGMA mmap_size = 268435456; -- 256MB

-- Multiple reader connections (parallel reads)
PRAGMA read_uncommitted = 1;

-- Proactive checkpoint management (prevent WAL growth)
PRAGMA wal_autocheckpoint = 1000;
```

### Rationale

## SQLite Configuration: WAL Mode

ZyncBase leverages SQLite's Write-Ahead Logging (WAL) for high-performance concurrency. For a detailed explanation of the WAL mechanism and its benefits, see the [Storage Layer Architecture](../architecture/storage-layer.md#wal-mode-the-concurrency-engine).

We enforce these settings on every connection:

**cache_size = -64000:**
Caches hot pages in RAM to reduce disk I/O. Negative value represents KB (64MB total).

**synchronous = NORMAL:**
Balances durability and performance. Safe against application crashes; only vulnerable to power failure.

**mmap_size = 256MB:**
Maps the database file to memory, reducing syscall overhead and speeding up reads.

---

## Connection Pool Implementation

ZyncBase maintains a thread-local connection pool to maximize read throughput across CPU cores.

```zig
const StorageLayer = struct {
    write_conn: *sqlite.Connection,      // Single writer
    read_pool: []sqlite.Connection,      // Multiple readers
    write_queue: RingBuffer(WriteOp),
    
    pub fn init(allocator: Allocator) !*StorageLayer {
        const num_readers = try std.Thread.getCpuCount();
        const reader_pool = try allocator.alloc(sqlite.Db, num_readers);
        
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
        
        // Initial setup for the writer connection
        try self.write_conn.exec("PRAGMA journal_mode = WAL");
        try self.write_conn.exec("PRAGMA synchronous = NORMAL");
        try self.write_conn.exec("PRAGMA cache_size = -64000");
        
        return self;
    }
    
    pub fn getReader(self: *StorageLayer) *sqlite.Connection {
        // Thread-local selection to avoid connection contention
        const thread_id = std.Thread.getCurrentId();
        const reader_idx = thread_id % self.read_pool.len;
        return &self.read_pool[reader_idx];
    }
};
```

---

## Schema-to-DDL Generation

ZyncBase automatically transforms a JSON-based store definition into optimized SQLite relational tables.

### Type Mapping Implementation

| JSON Schema Type | SQLite Type | Notes |
|------------------|-------------|-------|
| `string` | `TEXT` | Map to UTF-8 text |
| `integer` | `INTEGER` | 64-bit signed integer |
| `number` | `REAL` | 64-bit float |
| `boolean` | `INTEGER` | Stored as 0 or 1 |
| `object` (nested) | Flattened columns | `address.city` → `address_city TEXT` |
| `array` (primitives) | `TEXT` | Stored as JSON blob |

### Implementation Logic

```zig
const SchemaParser = struct {
    allocator: Allocator,
    
    pub fn parseTable(self: *SchemaParser, name: []const u8, store_item: json.Value) !Table {
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
        return field_def.get("properties") != null;
    }
    
    fn flattenNestedObject(self: *SchemaParser, prefix: []const u8, field_def: json.Value) ![]Field {
        var fields = ArrayList(Field).init(self.allocator);
        const properties = field_def.get("properties") orelse return error.InvalidSchema;
        for (properties.object.items) |prop_entry| {
            const flattened_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, prop_entry.key });
            const field = try self.parseField(flattened_name, prop_entry.value, null);
            try fields.append(field);
        }
        return fields.toOwnedSlice();
    }
    
    fn parseField(self: *SchemaParser, name: []const u8, field_def: json.Value, required: ?json.Value) !Field {
        const field_type = field_def.get("type") orelse return error.InvalidSchema;
        return Field{
            .name = name,
            .type = try self.mapType(field_type.string, field_def),
            .required = self.isRequired(name, required),
            .indexed = field_def.get("indexed") != null,
        };
    }
};

const DDLGenerator = struct {
    allocator: Allocator,
    
    pub fn generateDDL(self: *DDLGenerator, table: Table) ![]const u8 {
        var buf = ArrayList(u8).init(self.allocator);
        try buf.appendSlice("CREATE TABLE ");
        try buf.appendSlice(table.name);
        try buf.appendSlice(" (\n");
        
        for (table.fields, 0..) |field, i| {
            try buf.appendSlice(try std.fmt.allocPrint(self.allocator, "    {s} {s}", .{field.name, self.sqlType(field.type)}));
            if (field.required) try buf.appendSlice(" NOT NULL");
            if (field.primary_key) try buf.appendSlice(" PRIMARY KEY");
            if (i < table.fields.len - 1) try buf.appendSlice(",\n");
        }
        try buf.appendSlice("\n);\n");
        
        // Auto-generate indexes
        for (table.fields) |field| {
            if (field.indexed or std.mem.eql(u8, field.name, "namespace_id")) {
                try buf.appendSlice(try std.fmt.allocPrint(self.allocator, "CREATE INDEX idx_{s}_{s} ON {s}({s});\n", .{table.name, field.name, table.name, field.name}));
            }
        }
        return buf.toOwnedSlice();
    }
};
```

### Relational Features
- **Foreign Keys**: Generated from `references` property. Supports `cascade`, `restrict`, and `set_null`.
- **FTS5**: Virtual tables created for full-text search capability on designated paths.

---

## Auto-Migration Implementation

ZyncBase manages schema evolution by comparing the current state with the target schema.

### Execution Strategy

```zig
const MigrationDetector = struct {
    pub fn detectChanges(old_schema: Schema, new_schema: Schema) ![]Change {
        var changes = ArrayList(Change).init(allocator);
        for (new_schema.tables) |new_table| {
            if (!old_schema.hasTable(new_table.name)) {
                try changes.append(.{ .type = .create_table, .table = new_table });
                continue;
            }
            // Logic for add_column, remove_column, change_type...
        }
        return changes.toOwnedSlice();
    }
};

const MigrationExecutor = struct {
    db: *sqlite.Connection,
    
    pub fn execute(self: *MigrationExecutor, plan: MigrationPlan) !void {
        try self.db.exec("BEGIN TRANSACTION");
        errdefer self.db.exec("ROLLBACK") catch {};
        
        for (plan.changes) |change| {
            switch (change.type) {
                .create_table => try self.db.exec(change.ddl),
                .add_column => {
                    const sql = try std.fmt.allocPrint(allocator, "ALTER TABLE {s} ADD COLUMN {s} {s}", .{change.table, change.field.name, sqlType(change.field.type)});
                    try self.db.exec(sql);
                },
                .change_type, .remove_column => try self.recreateTable(change.table),
            }
        }
        try self.db.exec("COMMIT");
    }
    
    fn recreateTable(self: *MigrationExecutor, table: Table) !void {
        const backup_name = try std.fmt.allocPrint(self.db.allocator, "{s}_migration_backup", .{table.name});
        defer self.db.allocator.free(backup_name);

        // 1. Copy existing rows into a temporary backup table
        const create_backup = try std.fmt.allocPrint(self.db.allocator,
            "CREATE TABLE {s} AS SELECT * FROM {s}", .{ backup_name, table.name });
        defer self.db.allocator.free(create_backup);
        try self.db.exec(create_backup);

        // 2. Drop the original table
        const drop_original = try std.fmt.allocPrint(self.db.allocator,
            "DROP TABLE {s}", .{table.name});
        defer self.db.allocator.free(drop_original);
        try self.db.exec(drop_original);

        // 3. Recreate with the new schema (DDL already generated by DDLGenerator)
        try self.db.exec(table.ddl);

        // 4. Copy rows back, mapping only columns that exist in both schemas
        const common_cols = try self.commonColumns(backup_name, table);
        defer self.db.allocator.free(common_cols);
        const reinsert = try std.fmt.allocPrint(self.db.allocator,
            "INSERT INTO {s} ({s}) SELECT {s} FROM {s}",
            .{ table.name, common_cols, common_cols, backup_name });
        defer self.db.allocator.free(reinsert);
        try self.db.exec(reinsert);

        // 5. Drop the backup table
        const drop_backup = try std.fmt.allocPrint(self.db.allocator,
            "DROP TABLE {s}", .{backup_name});
        defer self.db.allocator.free(drop_backup);
        try self.db.exec(drop_backup);
    }};
```

---

## Write Strategy: Async Batching

To avoid disk I/O bottlenecks, ZyncBase groups operations into single transactions.

```zig
const StorageLayer = struct {
    write_queue: RingBuffer(WriteOp),
    batch_size: usize = 100,
    
    pub fn queueWrite(self: *StorageLayer, op: WriteOp) !void {
        try self.write_queue.push(op);
        if (self.write_queue.len() >= self.batch_size) {
            try self.flushBatch();
        }
    }

    fn flushBatch(self: *StorageLayer) !void {
        const batch = self.write_queue.drain();
        try self.write_conn.exec("BEGIN TRANSACTION");
        for (batch) |op| {
            try self.executeWrite(op);
        }
        try self.write_conn.exec("COMMIT");
    }
};
```

---

## Read Strategy: Cache Integration

A lock-free in-memory cache acts as a read-through layer.

```zig
const StateManager = struct {
    cache: HashMap([]const u8, *Namespace),
    storage: *StorageLayer,
    
    pub fn getNamespace(self: *StateManager, id: []const u8) !*Namespace {
        if (self.cache.get(id)) |ns| return ns;
        
        const ns = try self.storage.loadNamespace(id);
        try self.cache.put(id, ns);
        return ns;
    }
};
```

---

## Checkpoint Management

Prevents WAL file starvation and minimizes read degradation.

| Mode | Behavior | Use Case |
|------|----------|----------|
| PASSIVE | Non-blocking, best effort | Background maintenance |
| FULL | Waits for readers, completes | Scheduled maintenance |
| TRUNCATE | Resets and shrinks WAL | Reclaim disk space |

---

## Performance Optimization

### Authorization Snapshots
Saves overhead by caching permission queries on connection. In-memory lookup (nanoseconds) prevents authorization from bottlenecking the read-path.

---

## Backup

### Online Backup Contract
`backup` is safe to call while the server is running. It checkpoints the WAL so the main database file is fully up-to-date, then copies it atomically using SQLite's online backup API.

```zig
pub fn backup(self: *StorageLayer, dest_path: []const u8) !void {
    // Checkpoint WAL into the main database file
    try self.write_conn.exec("PRAGMA wal_checkpoint(FULL)");

    // Use SQLite's online backup API for an atomic, consistent copy
    const dest = try sqlite.open(dest_path);
    defer dest.close();
    const bk = try sqlite.backupInit(dest, "main", self.write_conn, "main");
    defer bk.finish();
    while (try bk.step(100) == .more) {} // copy 100 pages at a time
}
```

### Invariants
- The destination file is a valid, readable SQLite database on success.
- The source database remains fully operational during the backup.
- If `backup` returns an error, the destination file is incomplete and must be discarded.

### Verification
```bash
zig test src/storage_backup_test.zig
```

---

## See Also

- [Storage Layer Architecture](../architecture/storage-layer.md) - Deep dive into WAL and pooling design
- [Threading Model](../architecture/threading-model.md) - Multi-threaded core integration
- [Research](../architecture/research.md) - Benchmarks and performance validation
