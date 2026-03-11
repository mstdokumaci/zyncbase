const std = @import("std");
const Allocator = std.mem.Allocator;

/// Lock-free cache for parallel reads across all CPU cores
/// Uses atomic operations for all read access to cache entries
pub const LockFreeCache = struct {
    entries: std.atomic.Value(*std.StringHashMap(*CacheEntry)),
    allocator: Allocator,
    defer_stack: std.atomic.Value(?*DeferNode),

    const DeferNode = struct {
        next: ?*DeferNode,
        resource: union(enum) {
            map: *std.StringHashMap(*CacheEntry),
            entry: *CacheEntry,
            key: []const u8,
        },
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
            allocator.destroy(self);
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

    pub fn init(allocator: Allocator) !*LockFreeCache {
        const cache = try allocator.create(LockFreeCache);
        const entries = try allocator.create(std.StringHashMap(*CacheEntry));
        entries.* = std.StringHashMap(*CacheEntry).init(allocator);

        cache.* = .{
            .entries = std.atomic.Value(*std.StringHashMap(*CacheEntry)).init(entries),
            .allocator = allocator,
            .defer_stack = std.atomic.Value(?*DeferNode).init(null),
        };
        return cache;
    }

    pub fn deinit(self: *LockFreeCache) void {
        const entries = self.entries.load(.acquire);
        var it = entries.iterator();
        while (it.next()) |entry| {
            // Free the namespace key
            self.allocator.free(entry.key_ptr.*);
            // Free the cache entry
            entry.value_ptr.*.deinit(self.allocator);
        }
        entries.deinit();
        self.allocator.destroy(entries);

        // Free all deferred resources
        var node_ptr = self.defer_stack.load(.acquire);
        while (node_ptr) |node| {
            switch (node.resource) {
                .map => |m| {
                    m.deinit();
                    self.allocator.destroy(m);
                },
                .entry => |e| {
                    e.deinit(self.allocator);
                },
                .key => |k| {
                    self.allocator.free(k);
                },
            }
            const next = node.next;
            self.allocator.destroy(node);
            node_ptr = next;
        }

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

        pub fn state(self: Handle) *StateTree {
            return &self.entry.state;
        }

        pub fn release(self: Handle) void {
            self.cache.releaseHandle(self);
        }
    };

    /// Lock-free read operation with atomic ref_count increment
    pub fn get(self: *LockFreeCache, namespace: []const u8) Error!Handle {
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
        };
    }

    /// Release operation using a handle
    pub fn releaseHandle(self: *LockFreeCache, handle: Handle) void {
        _ = self;
        // Atomically decrement reference count
        const old_count = handle.entry.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(old_count > 0);
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
    fn deferFree(self: *LockFreeCache, resource: anytype) void {
        const T = @TypeOf(resource);
        const node = self.allocator.create(DeferNode) catch return;

        if (T == *std.StringHashMap(*CacheEntry)) {
            node.resource = .{ .map = resource };
        } else if (T == *CacheEntry) {
            node.resource = .{ .entry = resource };
        } else if (T == []const u8) {
            node.resource = .{ .key = resource };
        } else unreachable;

        var current_head = self.defer_stack.load(.acquire);
        while (true) {
            node.next = current_head;
            if (self.defer_stack.cmpxchgWeak(current_head, node, .acq_rel, .acquire)) |actual| {
                current_head = actual;
            } else break;
        }
    }

    /// Update operation for single-writer cache updates
    /// PRECONDITION: namespace exists in cache
    /// POSTCONDITION: Cache entry updated with new state via COW
    pub fn update(self: *LockFreeCache, namespace: []const u8, new_state: StateTree) Error!void {
        // Pre-allocate new entry outside the loop
        const new_entry = try CacheEntry.init(self.allocator);
        // ownership has not been transferred yet, just destroy the entry shell on error
        errdefer self.allocator.destroy(new_entry);
        new_entry.state = new_state;

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

            // Replace in new map (it's a pointer to our pre-allocated entry)
            try new_entries.put(namespace, new_entry);

            // Atomically swap the map
            if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |_| {
                // FAIL
                new_entries.deinit();
                self.allocator.destroy(new_entries);
                continue;
            }

            // SUCCESS
            self.deferFree(old_entries);
            self.deferFree(old_entry);
            return;
        }
    }

    /// Evict operation for cache entry removal
    /// PRECONDITION: ref_count is zero
    /// POSTCONDITION: Entry removed from cache via COW
    pub fn evict(self: *LockFreeCache, namespace: []const u8) Error!void {
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

            const kv = new_entries.fetchRemove(namespace).?;

            if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |_| {
                new_entries.deinit();
                self.allocator.destroy(new_entries);
                continue;
            }

            // Defer free map, key, and entry
            self.deferFree(old_entries);
            self.deferFree(kv.key);
            self.deferFree(kv.value);
            return;
        }
    }

    /// Create a new cache entry for a namespace
    pub fn create(self: *LockFreeCache, namespace: []const u8) Error!void {
        // Pre-allocate resources outside the loop
        const new_entry = try CacheEntry.init(self.allocator);
        errdefer self.allocator.destroy(new_entry); // Don't deinit state, it hasn't been set yet
        new_entry.state = try StateTree.init(self.allocator);
        errdefer new_entry.state.deinit();

        const namespace_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(namespace_copy);

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
                // FAIL
                new_entries.deinit();
                self.allocator.destroy(new_entries);
                continue;
            }

            // SUCCESS
            self.deferFree(old_entries);
            if (old_key_item) |k| self.deferFree(k);
            if (old_entry_item) |e| self.deferFree(e);
            return;
        }
    }
};
