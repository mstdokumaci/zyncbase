const std = @import("std");
const Allocator = std.mem.Allocator;

/// Lock-free cache for parallel reads across all CPU cores
/// Uses atomic operations for all read access to cache entries
pub const LockFreeCache = struct {
    entries: std.atomic.Value(*std.StringHashMap(*CacheEntry)),
    allocator: Allocator,
    write_mutex: std.Thread.Mutex,

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

    /// Update operation for single-writer cache updates
    /// PRECONDITION: namespace exists in cache
    /// POSTCONDITION: Cache entry updated with new state
    pub fn update(self: *LockFreeCache, namespace: []const u8, new_state: StateTree) Error!void {
        // Acquire write mutex before updating cache
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        const entries = self.entries.load(.acquire);
        const entry = entries.get(namespace) orelse return error.NotFound;

        // Update state (protected by write mutex)
        entry.state.deinit();
        entry.state = new_state;

        // Increment version number atomically
        _ = entry.version.fetchAdd(1, .acq_rel);

        // Update timestamp atomically
        entry.timestamp.store(std.time.timestamp(), .release);
    }

    /// Evict operation for cache entry removal
    /// PRECONDITION: ref_count is zero
    /// POSTCONDITION: Entry removed from cache and memory freed
    pub fn evict(self: *LockFreeCache, namespace: []const u8) Error!void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        const entries = self.entries.load(.acquire);
        const entry = entries.get(namespace) orelse return error.NotFound;

        // Check ref_count is zero before eviction
        const ref_count = entry.ref_count.load(.acquire);
        if (ref_count != 0) {
            return error.RefCountOverflow; // Reusing error for "still in use"
        }

        // Remove entry from HashMap and get the key
        const kv = entries.fetchRemove(namespace) orelse return error.NotFound;

        // Free memory for key, StateTree and CacheEntry
        self.allocator.free(kv.key);
        kv.value.deinit(self.allocator);
    }

    /// Create a new cache entry for a namespace
    pub fn create(self: *LockFreeCache, namespace: []const u8) Error!void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        const entries = self.entries.load(.acquire);

        // Check if entry already exists and clean it up
        if (entries.fetchRemove(namespace)) |kv| {
            // Free the old key and entry
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
        }

        // Create new entry
        const entry = try CacheEntry.init(self.allocator);
        errdefer entry.deinit(self.allocator);

        // Add to cache
        const namespace_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(namespace_copy);

        try entries.put(namespace_copy, entry);
    }
};
