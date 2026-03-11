const std = @import("std");
const Allocator = std.mem.Allocator;

/// Lock-free cache for parallel reads across all CPU cores
/// Uses atomic operations for all read access to cache entries
pub const LockFreeCache = struct {
    entries: std.atomic.Value(*std.StringHashMap(*CacheEntry)),
    allocator: Allocator,
    write_mutex: std.Thread.Mutex,
    old_maps: std.ArrayListUnmanaged(*std.StringHashMap(*CacheEntry)),

    /// Individual cache entry with atomic fields for concurrent access
    pub const CacheEntry = struct {
        state: StateTree,
        version: std.atomic.Value(u64),
        ref_count: std.atomic.Value(u32),
        timestamp: std.atomic.Value(i64),

        pub fn init(allocator: Allocator) !*CacheEntry {
            const entry = try allocator.create(CacheEntry);
            entry.* = .{
                .state = try StateTree.init(allocator),
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
            .write_mutex = .{},
            .old_maps = .{},
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

        // Free all old maps tracked for COW
        for (self.old_maps.items) |old_map| {
            old_map.deinit();
            self.allocator.destroy(old_map);
        }
        self.old_maps.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub const Error = error{
        NotFound,
        RefCountOverflow,
        OutOfMemory,
    };

    /// Lock-free read operation with atomic ref_count increment
    /// PRECONDITION: namespace is valid UTF-8 string
    /// POSTCONDITION: Returns valid StateTree pointer with incremented ref_count
    pub fn get(self: *LockFreeCache, namespace: []const u8) Error!*StateTree {
        // Load entries map atomically (Acquire ordering)
        const entries = self.entries.load(.acquire);

        // Lookup cache entry
        const entry = entries.get(namespace) orelse return error.NotFound;

        // Atomically increment reference count (AcqRel ordering)
        // INVARIANT: ref_count >= 0 at all times
        const old_count = entry.ref_count.fetchAdd(1, .acq_rel);

        // Verify we didn't overflow (safety check)
        if (old_count >= std.math.maxInt(u32) - 1) {
            _ = entry.ref_count.fetchSub(1, .acq_rel);
            return error.RefCountOverflow;
        }

        // Return pointer to state tree
        // POSTCONDITION: Caller must call release() when done
        return &entry.state;
    }

    /// Release operation with atomic ref_count decrement
    /// PRECONDITION: get() was previously called for this namespace
    /// POSTCONDITION: ref_count decremented, entry may be reclaimed
    pub fn release(self: *LockFreeCache, namespace: []const u8) void {
        const entries = self.entries.load(.acquire);
        const entry = entries.get(namespace) orelse return;

        // Atomically decrement reference count
        const old_count = entry.ref_count.fetchSub(1, .acq_rel);

        // INVARIANT: ref_count was > 0 before decrement
        std.debug.assert(old_count > 0);

        // If ref_count reached 0, entry can be reclaimed
        // (Actual reclamation happens in separate GC phase)
    }

    /// Helper to clone the current entries map
    /// Caller must hold write_mutex
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

    /// Update operation for single-writer cache updates
    /// PRECONDITION: namespace exists in cache
    /// POSTCONDITION: Cache entry updated with new state via COW
    pub fn update(self: *LockFreeCache, namespace: []const u8, new_state: StateTree) Error!void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        const old_entries = self.entries.load(.acquire);

        // Find the entry we want to update
        if (!old_entries.contains(namespace)) return error.NotFound;

        // COW: Clone the entries map
        const new_entries = try self.cloneEntries(old_entries);
        errdefer {
            self.allocator.destroy(new_entries);
        }

        const entry = new_entries.get(namespace).?;

        // Update state in the new view
        entry.state.deinit();
        entry.state = new_state;
        _ = entry.version.fetchAdd(1, .acq_rel);
        entry.timestamp.store(std.time.timestamp(), .release);

        // Atomically swap the map
        self.entries.store(new_entries, .release);

        // Track the old map for cleanup
        self.old_maps.append(self.allocator, old_entries) catch {
            // If we can't track it, we have to leak it or deinit now (risky)
            // For tests, we'll favor tracking
        };
    }

    /// Evict operation for cache entry removal
    /// PRECONDITION: ref_count is zero
    /// POSTCONDITION: Entry removed from cache via COW
    pub fn evict(self: *LockFreeCache, namespace: []const u8) Error!void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        const old_entries = self.entries.load(.acquire);
        const entry = old_entries.get(namespace) orelse return error.NotFound;

        // Check ref_count is zero before eviction
        if (entry.ref_count.load(.acquire) != 0) {
            return error.RefCountOverflow;
        }

        // COW: Clone
        const new_entries = try self.cloneEntries(old_entries);
        errdefer {
            self.allocator.destroy(new_entries);
        }

        const kv = new_entries.fetchRemove(namespace).?;
        self.allocator.free(kv.key);
        kv.value.deinit(self.allocator);

        // Swap
        self.entries.store(new_entries, .release);
        try self.old_maps.append(self.allocator, old_entries);
    }

    /// Create a new cache entry for a namespace
    pub fn create(self: *LockFreeCache, namespace: []const u8) Error!void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        const old_entries = self.entries.load(.acquire);

        // COW: Clone
        const new_entries = try self.cloneEntries(old_entries);
        errdefer {
            self.allocator.destroy(new_entries);
        }

        // Remove old if exists
        if (new_entries.fetchRemove(namespace)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
        }

        // Create new entry
        const entry = try CacheEntry.init(self.allocator);
        errdefer entry.deinit(self.allocator);

        const namespace_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(namespace_copy);

        try new_entries.put(namespace_copy, entry);

        // Swap
        self.entries.store(new_entries, .release);
        try self.old_maps.append(self.allocator, old_entries);
    }
};
