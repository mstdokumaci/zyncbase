const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const values = @import("values.zig");

pub const CheckpointMode = enum {
    /// Passive mode: checkpoint without blocking readers/writers
    passive,
    /// Full mode: wait for readers to finish, then checkpoint
    full,
    /// Restart mode: checkpoint and reset WAL
    restart,
    /// Truncate mode: checkpoint and truncate WAL to zero bytes
    truncate,
};

pub const CheckpointStats = struct {
    mode: CheckpointMode,
    duration_ms: u64,
    frames_checkpointed: usize,
    frames_in_wal: usize,
    wal_size_before: usize,
    wal_size_after: usize,
};

/// Configuration for reconnection logic.
pub const ReconnectionConfig = struct {
    /// Maximum number of reconnection attempts
    max_attempts: u32 = 5,
    /// Initial backoff delay in milliseconds
    initial_backoff_ms: u64 = 100,
    /// Maximum backoff delay in milliseconds
    max_backoff_ms: u64 = 5000,
    /// Multiplier for exponential backoff
    backoff_multiplier: f64 = 2.0,
};

pub const BatchEntry = struct {
    kind: enum { upsert, delete },
    table_index: usize,
    id: values.DocId,
    namespace_id: i64,
    owner_doc_id: values.DocId,
    sql: []const u8,
    values: ?[]values.TypedValue,
    timestamp: i64,
};

pub const WriteOp = union(enum) {
    checkpoint: struct { mode: CheckpointMode, completion_signal: *CompletionSignal },
    upsert: struct {
        table_index: usize,
        id: values.DocId,
        namespace_id: i64,
        owner_doc_id: values.DocId,
        sql: []const u8,
        values: []values.TypedValue,
        timestamp: i64,
        completion_signal: ?*CompletionSignal = null,
    },
    delete: struct {
        table_index: usize,
        id: values.DocId,
        namespace_id: i64,
        sql: []const u8,
        completion_signal: ?*CompletionSignal = null,
    },
    upsert_namespace: struct {
        namespace: []const u8,
        result: *i64,
        completion_signal: *CompletionSignal,
    },
    batch: struct {
        entries: []BatchEntry,
        completion_signal: ?*CompletionSignal = null,
    },

    pub const CompletionSignal = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
        err: ?anyerror = null,
        result: ?CheckpointStats = null,

        pub fn wait(self: *CompletionSignal) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.done) {
                self.cond.wait(&self.mutex);
            }
            if (self.err) |e| return e;
        }

        pub fn signal(self: *CompletionSignal, err: ?anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.err = err;
            self.done = true;
            self.cond.signal();
        }

        pub fn signalWithResult(self: *CompletionSignal, result: CheckpointStats) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.result = result;
            self.done = true;
            self.cond.signal();
        }
    };

    pub fn getCompletionSignal(self: WriteOp) ?*CompletionSignal {
        return switch (self) {
            .checkpoint => |op| op.completion_signal,
            .upsert => |op| op.completion_signal,
            .delete => |op| op.completion_signal,
            .upsert_namespace => |op| op.completion_signal,
            .batch => |op| op.completion_signal,
        };
    }

    pub fn deinit(self: WriteOp, allocator: Allocator) void {
        switch (self) {
            .upsert => |op| {
                allocator.free(op.sql);
                for (op.values) |value| value.deinit(allocator);
                allocator.free(op.values);
            },
            .delete => |op| {
                allocator.free(op.sql);
            },
            .upsert_namespace => |op| {
                allocator.free(op.namespace);
            },
            .batch => |op| {
                for (op.entries) |entry| {
                    allocator.free(entry.sql);
                    if (entry.values) |vals| {
                        for (vals) |v| v.deinit(allocator);
                        allocator.free(vals);
                    }
                }
                allocator.free(op.entries);
            },
            else => {},
        }
    }
};

pub const WriteQueue = struct {
    pub const Node = struct {
        op: WriteOp,
        next: std.atomic.Value(?*Node),
    };

    head: *Node,
    tail: std.atomic.Value(*Node),
    allocator: Allocator,
    pool: *MemoryStrategy.IndexPool(Node),

    pub fn init(self: *WriteQueue, allocator: Allocator, node_pool: *MemoryStrategy.IndexPool(Node)) !void {
        const stub = try node_pool.acquire();
        stub.next = std.atomic.Value(?*Node).init(null);
        self.* = WriteQueue{
            .head = stub,
            .tail = std.atomic.Value(*Node).init(stub),
            .allocator = allocator,
            .pool = node_pool,
        };
    }

    pub fn deinit(self: *WriteQueue) void {
        while (self.pop()) |op| {
            op.deinit(self.allocator);
        }
        self.pool.release(self.head);
    }

    pub fn push(self: *WriteQueue, op: WriteOp) !void {
        const node = try self.pool.acquire();
        node.op = op;
        node.next = std.atomic.Value(?*Node).init(null);
        const prev = self.tail.swap(node, .acq_rel);
        prev.next.store(node, .release);
    }

    pub fn pop(self: *WriteQueue) ?WriteOp {
        const head = self.head;
        const next = head.next.load(.acquire) orelse return null;

        self.head = next;
        const op = next.op;
        self.pool.release(head);
        return op;
    }

    pub fn hasItems(self: *WriteQueue) bool {
        return self.head.next.load(.acquire) != null;
    }
};
