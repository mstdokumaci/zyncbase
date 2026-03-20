const std = @import("std");
const Allocator = std.mem.Allocator;

/// Lock-free cache for parallel reads across all CPU cores
/// Uses atomic operations for all read access to cache entries
pub const LockFreeCache = struct {
    entries: std.atomic.Value(*std.StringHashMap(*CacheEntry)),
    allocator: Allocator,
    defer_stack: std.atomic.Value(?*DeferNode),
    pool: NodePool,
    epoch_manager: EpochManager,
    config: Config,
    reclaim_handle: ?std.Thread = null,
    reclaim_active: std.atomic.Value(bool),

    pub const Config = struct {
        max_deferred_nodes: usize = 4096,
        reclamation_interval_ms: u64 = 100,
    };

    const DeferNode = struct {
        next: ?*DeferNode,
        next_index: u32,
        epoch: u64,
        resource: union(enum) {
            map: *std.StringHashMap(*CacheEntry),
            entry: *CacheEntry,
            key: []const u8,
        },
    };

    const NodePool = struct {
        nodes: []DeferNode,
        free_stack: std.atomic.Value(u64),
        active_count: std.atomic.Value(usize),
        allocator: Allocator,

        const null_index = std.math.maxInt(u32);

        const TaggedIndex = packed struct {
            index: u32,
            tag: u32,
        };

        fn init(allocator: Allocator, size: usize) !NodePool {
            const nodes = try allocator.alloc(DeferNode, size);
            const initial_head = TaggedIndex{ .index = 0, .tag = 0 };
            const self = NodePool{
                .nodes = nodes,
                .free_stack = std.atomic.Value(u64).init(@bitCast(initial_head)),
                .active_count = std.atomic.Value(usize).init(0),
                .allocator = allocator,
            };

            // Link all nodes into the free stack
            for (nodes, 0..) |*node, i| {
                node.* = .{
                    .resource = undefined,
                    .epoch = 0,
                    .next_index = if (i + 1 < size) @intCast(i + 1) else null_index,
                    .next = null,
                };
            }
            return self;
        }

        fn deinit(self: *NodePool) void {
            self.allocator.free(self.nodes);
        }

        fn push(self: *NodePool, node: *DeferNode) void {
            const node_index = @as(u32, @intCast((@intFromPtr(node) - @intFromPtr(self.nodes.ptr)) / @sizeOf(DeferNode)));
            var current = self.free_stack.load(.acquire);
            while (true) {
                const current_head: TaggedIndex = @bitCast(current);
                node.next_index = current_head.index;
                const next_head = TaggedIndex{ .index = node_index, .tag = current_head.tag +% 1 };
                if (self.free_stack.cmpxchgWeak(current, @bitCast(next_head), .acq_rel, .acquire)) |actual| {
                    current = actual;
                } else {
                    _ = self.active_count.fetchSub(1, .release);
                    break;
                }
            }
        }

        fn pop(self: *NodePool) ?*DeferNode {
            var current = self.free_stack.load(.acquire);
            while (true) {
                const current_head: TaggedIndex = @bitCast(current);
                if (current_head.index == null_index) return null;
                const head_node = &self.nodes[current_head.index];
                const next_index = head_node.next_index;

                const next_head = TaggedIndex{ .index = next_index, .tag = current_head.tag +% 1 };
                if (self.free_stack.cmpxchgWeak(current, @bitCast(next_head), .acq_rel, .acquire)) |actual| {
                    current = actual;
                } else {
                    _ = self.active_count.fetchAdd(1, .release);
                    return head_node;
                }
            }
        }

        pub fn activeCount(self: *NodePool) usize {
            return self.active_count.load(.acquire);
        }
    };

    const EpochManager = struct {
        current_epoch: std.atomic.Value(u64),
        thread_epochs: [128]std.atomic.Value(u64),

        fn init() EpochManager {
            var self = EpochManager{
                .current_epoch = std.atomic.Value(u64).init(1),
                .thread_epochs = undefined,
            };
            for (&self.thread_epochs) |*slot| {
                slot.* = std.atomic.Value(u64).init(std.math.maxInt(u64));
            }
            return self;
        }

        fn enter(self: *EpochManager) usize {
            const epoch = self.current_epoch.load(.acquire);
            for (&self.thread_epochs, 0..) |*slot, i| {
                if (slot.cmpxchgStrong(std.math.maxInt(u64), epoch, .acq_rel, .acquire)) |_| {
                    continue;
                }
                return i;
            }
            // If we run out of slots, we spin until one is free
            while (true) {
                for (&self.thread_epochs, 0..) |*slot, i| {
                    if (slot.cmpxchgStrong(std.math.maxInt(u64), epoch, .acq_rel, .acquire)) |_| {
                        continue;
                    }
                    return i;
                }
                std.Thread.yield() catch {}; // zwanzig-disable-line: swallowed-error
            }
        }

        fn exit(self: *EpochManager, slot_idx: usize) void {
            self.thread_epochs[slot_idx].store(std.math.maxInt(u64), .release);
        }

        fn minActiveEpoch(self: *EpochManager) u64 {
            var min = self.current_epoch.load(.acquire);
            for (&self.thread_epochs) |*slot| {
                const e = slot.load(.acquire);
                if (e != std.math.maxInt(u64) and e < min) {
                    min = e;
                }
            }
            return min;
        }

        fn bump(self: *EpochManager) u64 {
            return self.current_epoch.fetchAdd(1, .acq_rel) + 1;
        }
    };

    /// Individual cache entry with atomic fields for concurrent access
    pub const CacheEntry = struct {
        state: StateTree,
        version: std.atomic.Value(u64),
        ref_count: std.atomic.Value(u32),
        timestamp: std.atomic.Value(i64),

        pub fn init(allocator: Allocator) !*CacheEntry {
            const entry = try allocator.create(CacheEntry);
            entry.* = .{
                .state = undefined,
                .version = std.atomic.Value(u64).init(0),
                .ref_count = std.atomic.Value(u32).init(0),
                .timestamp = std.atomic.Value(i64).init(std.time.timestamp()),
            };
            return entry;
        }

        pub fn deinit(self: *CacheEntry, allocator: Allocator) void {
            self.state.deinit();
            _ = allocator;
        }
    };

    /// Hierarchical JSON structure representing application state
    pub const StateTree = struct {
        root: *Node,
        allocator: Allocator,

        pub const Node = struct {
            key: []const u8,
            value: std.json.Value,
            children: std.StringHashMap(*Node),

            pub fn init(allocator: Allocator, key: []const u8, value: std.json.Value) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .key = try allocator.dupe(u8, key),
                    .value = value,
                    .children = std.StringHashMap(*Node).init(allocator),
                };
                return node;
            }

            pub fn deinit(self: *Node, allocator: Allocator) void {
                var it = self.children.valueIterator();
                while (it.next()) |child| {
                    child.*.deinit(allocator);
                }
                self.children.deinit();
                allocator.free(self.key);
                allocator.destroy(self);
            }
        };

        pub fn init(allocator: Allocator) !StateTree {
            const root = try Node.init(allocator, "root", .null);
            return StateTree{
                .root = root,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *StateTree) void {
            self.root.deinit(self.allocator);
        }
    };

    pub fn init(allocator: Allocator, config: Config) !*LockFreeCache {
        const cache = try allocator.create(LockFreeCache);
        const entries = try allocator.create(std.StringHashMap(*CacheEntry));
        entries.* = std.StringHashMap(*CacheEntry).init(allocator);

        cache.* = .{
            .entries = std.atomic.Value(*std.StringHashMap(*CacheEntry)).init(entries),
            .allocator = allocator,
            .defer_stack = std.atomic.Value(?*DeferNode).init(null),
            .pool = try NodePool.init(allocator, config.max_deferred_nodes),
            .epoch_manager = EpochManager.init(),
            .config = config,
            .reclaim_active = std.atomic.Value(bool).init(true),
        };

        cache.reclaim_handle = try std.Thread.spawn(.{}, reclaimLoop, .{cache});
        return cache;
    }

    pub fn deinit(self: *LockFreeCache) void {
        // Stop reclamation thread
        self.reclaim_active.store(false, .release);
        if (self.reclaim_handle) |h| h.join();

        // Perform final reclamation of all deferred nodes
        self.reclaim(true);

        // Final cleanup of the current map and its contents
        const entries = self.entries.load(.acquire);
        var it = entries.iterator();
        while (it.next()) |entry| {
            // Free the namespace key (we own all keys in the map)
            self.allocator.free(entry.key_ptr.*);
            // Free the cache entry shell and its state
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        entries.deinit();
        self.allocator.destroy(entries);

        // Free the pool (contains the actual DeferNode storage)
        self.pool.deinit();
        self.allocator.destroy(self);
    }

    pub const Error = error{
        NotFound,
        RefCountOverflow,
        OutOfMemory,
    };

    /// Handle for a cached state tree, ensures proper ref counting
    pub const Handle = struct {
        cache: *LockFreeCache,
        namespace: []const u8,
        entry: *CacheEntry,
        epoch_slot: usize,

        pub fn state(self: Handle) *StateTree {
            return &self.entry.state;
        }

        pub fn release(self: Handle) void {
            self.cache.releaseHandle(self);
        }
    };

    /// Lock-free read operation with atomic ref_count increment
    pub fn get(self: *LockFreeCache, namespace: []const u8) Error!Handle {
        const slot = self.epoch_manager.enter();
        errdefer self.epoch_manager.exit(slot);

        // Load entries map atomically (Acquire ordering)
        const entries = self.entries.load(.acquire);

        // Lookup cache entry
        const entry = entries.get(namespace) orelse return error.NotFound;

        // Atomically increment reference count (AcqRel ordering)
        const old_count = entry.ref_count.fetchAdd(1, .acq_rel);

        // Verify we didn't overflow (safety check)
        if (old_count >= std.math.maxInt(u32) - 1) {
            _ = entry.ref_count.fetchSub(1, .acq_rel);
            return error.RefCountOverflow;
        }

        return Handle{
            .cache = self,
            .namespace = namespace,
            .entry = entry,
            .epoch_slot = slot,
        };
    }

    /// Release operation using a handle
    pub fn releaseHandle(self: *LockFreeCache, handle: Handle) void {
        // Atomically decrement reference count
        const old_count = handle.entry.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(old_count > 0);
        self.epoch_manager.exit(handle.epoch_slot);
    }

    /// Helper to clone the current entries map
    fn cloneEntries(self: *LockFreeCache, old_entries: *std.StringHashMap(*CacheEntry)) Error!*std.StringHashMap(*CacheEntry) {
        const new_entries = try self.allocator.create(std.StringHashMap(*CacheEntry));
        new_entries.* = std.StringHashMap(*CacheEntry).init(self.allocator);
        errdefer {
            new_entries.deinit();
            self.allocator.destroy(new_entries);
        }

        var it = old_entries.iterator();
        while (it.next()) |entry| {
            try new_entries.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_entries;
    }
    fn reserveNode(self: *LockFreeCache) ?*DeferNode {
        if (self.pool.pop()) |node| return node;
        // Emergency reclaim
        self.reclaim(false);
        return self.pool.pop();
    }

    fn internalDefer(self: *LockFreeCache, node: *DeferNode, resource: anytype) void {
        const T = @TypeOf(resource);
        node.epoch = self.epoch_manager.current_epoch.load(.acquire);

        if (T == *std.StringHashMap(*CacheEntry)) {
            node.resource = .{ .map = resource };
        } else if (T == *CacheEntry) {
            node.resource = .{ .entry = resource };
        } else if (T == []const u8) {
            node.resource = .{ .key = resource };
        } else {
            // Assume it's already the union type
            node.resource = resource;
        }

        var current_head = self.defer_stack.load(.acquire);
        while (true) {
            node.next = current_head;
            if (self.defer_stack.cmpxchgWeak(current_head, node, .acq_rel, .acquire)) |actual| {
                current_head = actual;
            } else break;
        }
    }

    fn reclaimLoop(self: *LockFreeCache) void {
        while (self.reclaim_active.load(.acquire)) {
            self.reclaim(false);
            std.Thread.sleep(self.config.reclamation_interval_ms * std.time.ns_per_ms);
        }
    }

    pub fn reclaim(self: *LockFreeCache, force: bool) void {
        const min_epoch = if (force) std.math.maxInt(u64) else self.epoch_manager.minActiveEpoch();

        // Atomically detach the entire defer stack
        const head = self.defer_stack.swap(null, .acq_rel);

        var still_deferred_head: ?*DeferNode = null;
        var node_ptr = head;

        while (node_ptr) |node| {
            const next = node.next;
            if (force or node.epoch < min_epoch) {
                // Safe to reclaim
                switch (node.resource) {
                    .map => |m| {
                        m.deinit();
                        self.allocator.destroy(m);
                    },
                    .entry => |e| {
                        e.deinit(self.allocator);
                        self.allocator.destroy(e);
                    },
                    .key => |k| {
                        self.allocator.free(k);
                    },
                }
                self.pool.push(node);
            } else {
                // Still in use, put back in the new defer stack
                node.next = still_deferred_head;
                still_deferred_head = node;
            }
            node_ptr = next;
        }

        // Re-attach still deferred nodes to the global stack
        if (still_deferred_head) |s_head| {
            var current_stack_head = self.defer_stack.load(.acquire);
            var tail = s_head;
            while (tail.next) |n| tail = n;

            while (true) {
                tail.next = current_stack_head;
                if (self.defer_stack.cmpxchgWeak(current_stack_head, s_head, .acq_rel, .acquire)) |actual| {
                    current_stack_head = actual;
                } else break;
            }
        }
    }

    /// Update operation for single-writer cache updates
    /// PRECONDITION: namespace exists in cache
    /// POSTCONDITION: Cache entry updated with new state via COW
    pub fn update(self: *LockFreeCache, namespace: []const u8, new_state: StateTree) Error!void {
        const slot = self.epoch_manager.enter();
        defer self.epoch_manager.exit(slot);

        // Pre-allocate new entry outside the loop
        const new_entry = try CacheEntry.init(self.allocator);
        // ownership has not been transferred yet, just destroy the entry shell on error
        errdefer self.allocator.destroy(new_entry);
        new_entry.state = new_state;

        // Pre-reserve nodes (2 needed: map, entry)
        const node_map = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_map);
        const node_entry = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_entry);

        while (true) {
            const old_entries = self.entries.load(.acquire);
            const old_entry = old_entries.get(namespace) orelse return error.NotFound;

            // COW: Clone map
            const new_entries = try self.cloneEntries(old_entries);
            errdefer {
                new_entries.deinit();
                self.allocator.destroy(new_entries);
            }

            // Prepare new entry state from current old_entry
            new_entry.version.store(old_entry.version.load(.acquire) + 1, .release);
            new_entry.timestamp.store(std.time.timestamp(), .release);

            // Find the actual key string owned by the map to reuse it (avoiding dangling pointers/extra dupes)
            // The key is guaranteed to exist because we just confirmed it with old_entries.get() above.
            const map_key = (old_entries.getEntry(namespace) orelse unreachable).key_ptr.*;

            // Replace in new map (it's a pointer to our pre-allocated entry)
            try new_entries.put(map_key, new_entry);

            // Atomically swap the map
            if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |_| {
                // Failure, cleanup loop-local map copy and retry
                new_entries.deinit();
                self.allocator.destroy(new_entries);
                continue;
            }

            // SUCCESS
            self.internalDefer(node_map, old_entries);
            self.internalDefer(node_entry, old_entry);
            _ = self.epoch_manager.bump();
            return;
        }
    }

    /// Evict operation for cache entry removal
    /// PRECONDITION: ref_count is zero
    /// POSTCONDITION: Entry removed from cache via COW
    pub fn evict(self: *LockFreeCache, namespace: []const u8) Error!void {
        const slot = self.epoch_manager.enter();
        defer self.epoch_manager.exit(slot);

        // Pre-reserve nodes (3 needed: map, key, entry)
        const node_map = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_map);
        const node_key = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_key);
        const node_entry = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_entry);

        while (true) {
            const old_entries = self.entries.load(.acquire);
            const entry = old_entries.get(namespace) orelse return error.NotFound;

            if (entry.ref_count.load(.acquire) != 0) {
                return error.RefCountOverflow;
            }

            const new_entries = try self.cloneEntries(old_entries);
            errdefer {
                new_entries.deinit();
                self.allocator.destroy(new_entries);
            }

            // Key exists in old_entries, so must exist in the clone
            const kv = new_entries.fetchRemove(namespace) orelse unreachable;

            if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |_| {
                // Failure, cleanup loop-local map copy and retry
                new_entries.deinit();
                self.allocator.destroy(new_entries);
                continue;
            }

            // Defer free map, key, and entry
            self.internalDefer(node_map, old_entries);
            self.internalDefer(node_key, kv.key);
            self.internalDefer(node_entry, kv.value);
            _ = self.epoch_manager.bump();
            return;
        }
    }

    /// Create a new cache entry for a namespace
    pub fn create(self: *LockFreeCache, namespace: []const u8) Error!void {
        const slot = self.epoch_manager.enter();
        defer self.epoch_manager.exit(slot);

        // Pre-allocate resources outside the loop
        const new_entry = try CacheEntry.init(self.allocator);
        errdefer self.allocator.destroy(new_entry); // Don't deinit state, it hasn't been set yet
        new_entry.state = try StateTree.init(self.allocator);
        errdefer new_entry.state.deinit();

        const namespace_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(namespace_copy);

        // Pre-reserve nodes (up to 3 needed: map, [old_key], [old_entry])
        const node_map = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_map);
        const node_key = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_key);
        const node_entry = self.reserveNode() orelse return error.OutOfMemory;
        errdefer self.pool.push(node_entry);

        while (true) {
            const old_entries = self.entries.load(.acquire);

            const new_entries = try self.cloneEntries(old_entries);
            errdefer {
                new_entries.deinit();
                self.allocator.destroy(new_entries);
            }

            var old_entry_item: ?*CacheEntry = null;
            var old_key_item: ?[]const u8 = null;
            if (new_entries.fetchRemove(namespace)) |kv| {
                old_key_item = kv.key;
                old_entry_item = kv.value;
            }

            try new_entries.put(namespace_copy, new_entry);

            if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |_| {
                // Failure, cleanup loop-local map copy and retry
                new_entries.deinit();
                self.allocator.destroy(new_entries);
                continue;
            }

            // SUCCESS
            self.internalDefer(node_map, old_entries);
            if (old_key_item) |k| {
                self.internalDefer(node_key, k);
            } else {
                self.pool.push(node_key);
            }
            if (old_entry_item) |e| {
                self.internalDefer(node_entry, e);
            } else {
                self.pool.push(node_entry);
            }
            _ = self.epoch_manager.bump();
            return;
        }
    }
};
