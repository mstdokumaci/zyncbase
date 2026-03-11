const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");

pub const StorageEngine = struct {
    allocator: Allocator,
    db_path: [:0]const u8,
    writer_conn: sqlite.Db,
    reader_pool: []sqlite.Db,
    write_queue: WriteQueue,
    write_thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool),
    next_reader_idx: std.atomic.Value(usize),

    pub fn init(allocator: Allocator, data_dir: []const u8) !*StorageEngine {
        const self = try allocator.create(StorageEngine);
        errdefer allocator.destroy(self);

        // Ensure data directory exists
        std.fs.cwd().makePath(data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Build database path (null-terminated for SQLite)
        const db_path_buf = try std.fmt.allocPrint(allocator, "{s}/zyncbase.db", .{data_dir});
        errdefer allocator.free(db_path_buf);
        const db_path = try allocator.dupeZ(u8, db_path_buf);
        allocator.free(db_path_buf); // Free the non-null-terminated version
        errdefer allocator.free(db_path);

        // Open writer connection
        var writer_conn = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = db_path },
            .open_flags = .{
                .write = true,
                .create = true,
            },
        });
        errdefer writer_conn.deinit();

        // Configure WAL mode and pragmas
        try configureDatabase(&writer_conn);

        // Create schema
        try createSchema(&writer_conn);

        // Create reader pool (one per CPU core)
        const num_readers = try std.Thread.getCpuCount();
        const reader_pool = try allocator.alloc(sqlite.Db, num_readers);
        errdefer allocator.free(reader_pool);

        var initialized_readers: usize = 0;
        errdefer {
            for (reader_pool[0..initialized_readers]) |*reader| {
                reader.deinit();
            }
        }

        for (reader_pool) |*reader| {
            reader.* = try sqlite.Db.init(.{
                .mode = sqlite.Db.Mode{ .File = db_path },
                .open_flags = .{
                    .write = false,
                },
            });
            initialized_readers += 1;
        }

        self.* = .{
            .allocator = allocator,
            .db_path = db_path,
            .writer_conn = writer_conn,
            .reader_pool = reader_pool,
            .write_queue = try WriteQueue.init(allocator, 1000),
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .next_reader_idx = std.atomic.Value(usize).init(0),
        };

        // Start write thread
        self.write_thread = try std.Thread.spawn(.{}, writeThreadLoop, .{self});

        // Give the write thread a moment to initialize
        std.Thread.sleep(1 * std.time.ns_per_ms);

        return self;
    }

    pub fn deinit(self: *StorageEngine) void {
        // Signal shutdown
        self.shutdown_requested.store(true, .release);

        // Give write thread time to see shutdown signal
        std.Thread.sleep(50 * std.time.ns_per_ms);

        // Wait for write thread
        if (self.write_thread) |thread| {
            thread.join();
        }

        // Close connections
        self.writer_conn.deinit();
        for (self.reader_pool) |*reader| {
            reader.deinit();
        }

        // Free resources
        self.allocator.free(self.reader_pool);
        self.allocator.free(self.db_path);
        self.write_queue.deinit();
        self.allocator.destroy(self);
    }

    pub fn set(self: *StorageEngine, namespace: []const u8, path: []const u8, value: []const u8) !void {
        // Queue write operation
        const op = WriteOp{
            .type = .set,
            .namespace = try self.allocator.dupe(u8, namespace),
            .path = try self.allocator.dupe(u8, path),
            .value = try self.allocator.dupe(u8, value),
        };

        try self.write_queue.push(op);
    }

    pub fn get(self: *StorageEngine, namespace: []const u8, path: []const u8) !?[]const u8 {
        // Get reader connection (round-robin)
        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const reader = &self.reader_pool[reader_idx];

        // Execute query with inline parameters
        const row = (try reader.oneAlloc(
            struct { value_json: []const u8 },
            self.allocator,
            "SELECT value_json FROM kv_store WHERE namespace = $namespace{[]const u8} AND path = $path{[]const u8}",
            .{},
            .{ .namespace = namespace, .path = path },
        )) orelse return null;

        // The string is already allocated by oneAlloc, so we just return it
        return row.value_json;
    }

    pub fn delete(self: *StorageEngine, namespace: []const u8, path: []const u8) !void {
        // Queue delete operation
        const op = WriteOp{
            .type = .delete,
            .namespace = try self.allocator.dupe(u8, namespace),
            .path = try self.allocator.dupe(u8, path),
            .value = null,
        };

        try self.write_queue.push(op);
    }

    pub fn query(
        self: *StorageEngine,
        namespace: []const u8,
        path_prefix: []const u8,
    ) ![]QueryResult {
        // Get reader connection
        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const reader = &self.reader_pool[reader_idx];

        // Build LIKE pattern
        const pattern_buf = try std.fmt.allocPrint(self.allocator, "{s}%", .{path_prefix});
        defer self.allocator.free(pattern_buf);
        const pattern: []const u8 = pattern_buf;

        // Prepare statement
        var stmt = try reader.prepare("SELECT path, value_json FROM kv_store WHERE namespace = $namespace{[]const u8} AND path LIKE $pattern{[]const u8}");
        defer stmt.deinit();

        // Collect results
        var results = std.ArrayList(QueryResult).initCapacity(self.allocator, 10) catch |err| {
            std.log.err("Failed to initialize results: {}", .{err});
            return err;
        };
        errdefer {
            for (results.items) |result| {
                self.allocator.free(result.path);
                self.allocator.free(result.value);
            }
            results.deinit(self.allocator);
        }

        var iter = try stmt.iterator(struct {
            path: []const u8,
            value_json: []const u8,
        }, .{ .namespace = namespace, .pattern = pattern });

        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            defer self.allocator.free(row.path);
            defer self.allocator.free(row.value_json);

            try results.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, row.path),
                .value = try self.allocator.dupe(u8, row.value_json),
            });
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn beginTransaction(self: *StorageEngine) !void {
        try self.writer_conn.exec("BEGIN TRANSACTION", .{}, .{});
    }

    pub fn commitTransaction(self: *StorageEngine) !void {
        try self.writer_conn.exec("COMMIT", .{}, .{});
    }

    pub fn rollbackTransaction(self: *StorageEngine) !void {
        try self.writer_conn.exec("ROLLBACK", .{}, .{});
    }

    pub fn flushPendingWrites(self: *StorageEngine) !void {
        // Wait for write queue to drain
        while (self.write_queue.len() > 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn writeThreadLoop(self: *StorageEngine) void {
        self.writeThreadLoopImpl() catch |err| {
            std.log.err("Write thread error: {}", .{err});
        };
    }

    fn writeThreadLoopImpl(self: *StorageEngine) !void {
        const batch_size = 100;
        const batch_timeout_ms = 10;

        var batch = std.ArrayListUnmanaged(WriteOp){};
        try batch.ensureTotalCapacity(self.allocator, batch_size);
        defer {
            for (batch.items) |op| {
                op.deinit(self.allocator);
            }
            batch.deinit(self.allocator);
        }

        var last_batch_time = std.time.milliTimestamp();

        while (!self.shutdown_requested.load(.acquire)) {
            // Collect operations for batch
            while (batch.items.len < batch_size) {
                if (self.write_queue.pop()) |op| {
                    batch.append(self.allocator, op) catch |err| {
                        std.log.err("Failed to append to batch: {}", .{err});
                        op.deinit(self.allocator);
                        continue;
                    };
                } else {
                    break;
                }
            }

            // Check if we should flush batch
            const now = std.time.milliTimestamp();
            const time_since_last = now - last_batch_time;

            const should_flush = batch.items.len >= batch_size or
                (batch.items.len > 0 and time_since_last >= batch_timeout_ms);

            if (should_flush) {
                try self.executeBatch(batch.items);
                for (batch.items) |op| {
                    op.deinit(self.allocator);
                }
                batch.clearRetainingCapacity();
                last_batch_time = now;
            } else {
                // Sleep briefly to avoid busy-waiting
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        // Flush remaining operations on shutdown
        if (batch.items.len > 0) {
            try self.executeBatch(batch.items);
        }
    }

    fn executeBatch(self: *StorageEngine, ops: []const WriteOp) !void {
        // Begin transaction
        try self.writer_conn.exec("BEGIN TRANSACTION", .{}, .{});
        errdefer self.writer_conn.exec("ROLLBACK", .{}, .{}) catch {};

        // Execute all operations
        for (ops) |op| {
            switch (op.type) {
                .set => try self.executeSet(op.namespace, op.path, op.value.?),
                .delete => try self.executeDelete(op.namespace, op.path),
            }
        }

        // Commit transaction
        try self.writer_conn.exec("COMMIT", .{}, .{});
    }

    fn executeSet(self: *StorageEngine, namespace: []const u8, path: []const u8, value: []const u8) !void {
        try self.writer_conn.exec(
            \\INSERT INTO kv_store (namespace, path, value_json, updated_at)
            \\VALUES ($namespace{[]const u8}, $path{[]const u8}, $value{[]const u8}, $timestamp{i64})
            \\ON CONFLICT(namespace, path) DO UPDATE SET
            \\  value_json = excluded.value_json,
            \\  updated_at = excluded.updated_at
        , .{}, .{
            .namespace = namespace,
            .path = path,
            .value = value,
            .timestamp = std.time.timestamp(),
        });
    }

    fn executeDelete(self: *StorageEngine, namespace: []const u8, path: []const u8) !void {
        try self.writer_conn.exec(
            \\DELETE FROM kv_store
            \\WHERE namespace = $namespace{[]const u8} AND path = $path{[]const u8}
        , .{}, .{
            .namespace = namespace,
            .path = path,
        });
    }

    fn configureDatabase(db: *sqlite.Db) !void {
        // journal_mode = WAL returns "wal", so we use void to consume the result row.
        _ = try db.pragma(void, .{}, "journal_mode", "wal");

        // The following usually return nothing or a single row with the new value.
        // Using `void` with `pragma` ensures that the result row (if any) is consumed.
        _ = try db.pragma(void, .{}, "synchronous", "normal");
        _ = try db.pragma(void, .{}, "cache_size", "-64000");
        _ = try db.pragma(void, .{}, "mmap_size", "268435456");
        _ = try db.pragma(void, .{}, "wal_autocheckpoint", "1000");
    }

    fn createSchema(db: *sqlite.Db) !void {
        // Create generic key-value table
        const create_table =
            \\CREATE TABLE IF NOT EXISTS kv_store (
            \\  namespace TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  value_json TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            \\  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            \\  PRIMARY KEY (namespace, path)
            \\)
        ;

        try db.exec(create_table, .{}, .{});

        // Create indexes
        try db.exec("CREATE INDEX IF NOT EXISTS idx_kv_namespace ON kv_store(namespace)", .{}, .{});
        try db.exec("CREATE INDEX IF NOT EXISTS idx_kv_path ON kv_store(path)", .{}, .{});
    }
};

pub const WriteOp = struct {
    type: enum { set, delete },
    namespace: []const u8,
    path: []const u8,
    value: ?[]const u8,

    pub fn deinit(self: WriteOp, allocator: Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.path);
        if (self.value) |v| {
            allocator.free(v);
        }
    }
};

pub const QueryResult = struct {
    path: []const u8,
    value: []const u8,
};

pub const WriteQueue = struct {
    items: std.ArrayListUnmanaged(WriteOp),
    mutex: std.Thread.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !WriteQueue {
        var items = std.ArrayListUnmanaged(WriteOp){};
        try items.ensureTotalCapacity(allocator, capacity);
        return WriteQueue{
            .items = items,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WriteQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |op| {
            op.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *WriteQueue, op: WriteOp) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.items.append(self.allocator, op);
    }

    pub fn pop(self: *WriteQueue) ?WriteOp {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    pub fn len(self: *WriteQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.items.items.len;
    }
};
