const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

/// Lock-free cache for parallel reads across all CPU cores.
/// Generic over type T, allowing specialized storage for AuthResponses, MsgPack payloads, etc.
pub fn lockFreeCache(comptime t: type) type { // zwanzig-disable-line: unused-parameter
    return struct {
        const Self = @This();

        /// Individual cache entry with atomic fields for concurrent access
        pub const CacheEntry = struct {
            data: t,
            version: std.atomic.Value(u64),
            ref_count: std.atomic.Value(u32),
            timestamp: std.atomic.Value(i64),

            pub fn init(allocator: Allocator, data: t) !*CacheEntry {
                const entry = try allocator.create(CacheEntry);
                entry.* = .{
                    .data = data,
                    .version = std.atomic.Value(u64).init(0),
                    .ref_count = std.atomic.Value(u32).init(0),
                    .timestamp = std.atomic.Value(i64).init(std.time.timestamp()),
                };
                return entry;
            }

            pub fn deinit(self: *CacheEntry, allocator: Allocator, deinit_payload: ?*const fn (Allocator, *t) void) void {
                if (deinit_payload) |hook| {
                    hook(allocator, &self.data);
                }
                allocator.destroy(self);
            }
        };

        const DeferNode = struct {
            resource: Resource,
            next: ?*DeferNode = null,
            epoch: u64 = 0,
        };

        const Resource = union(enum) {
            map: *std.StringHashMap(*CacheEntry),
            entry: *CacheEntry,
            key: []const u8,
        };

        entries: std.atomic.Value(*std.StringHashMap(*CacheEntry)),
        allocator: Allocator,
        defer_stack: std.atomic.Value(?*DeferNode),
        pool: MemoryStrategy.IndexPool(DeferNode),
        epoch_manager: EpochManager,
        config: Config,
        reclaim_handle: ?std.Thread = null,
        reclaim_active: std.atomic.Value(bool),
        /// Optional hook for deep-freeing complex types
        deinit_payload: ?*const fn (Allocator, *t) void,

        pub const Config = struct {
            max_deferred_nodes: usize = 100_000,
            reclamation_interval_ms: u64 = 100,
        };

        pub const UpdateOptions = struct {
            max_capacity: ?usize = null,
            evict_batch_size: usize = 0,
        };

        const EpochManager = struct {
            current_epoch: std.atomic.Value(u64),
            thread_epochs: [128]std.atomic.Value(u64),

            fn init() EpochManager {
                var self = EpochManager{
                    .current_epoch = std.atomic.Value(u64).init(1),
                    // SAFETY: thread_epochs is initialized in the loop below
                    .thread_epochs = undefined,
                };
                for (&self.thread_epochs) |*s| {
                    s.* = std.atomic.Value(u64).init(std.math.maxInt(u64));
                }
                return self;
            }

            fn enter(self: *EpochManager) usize {
                const epoch = self.current_epoch.load(.acquire);
                for (&self.thread_epochs, 0..) |*s, i| {
                    if (s.cmpxchgStrong(std.math.maxInt(u64), epoch, .acq_rel, .acquire)) |_| {
                        continue;
                    }
                    return i;
                }
                while (true) {
                    for (&self.thread_epochs, 0..) |*s, i| {
                        if (s.cmpxchgStrong(std.math.maxInt(u64), epoch, .acq_rel, .acquire)) |_| {
                            continue;
                        }
                        return i;
                    }
                    std.Thread.yield() catch |err| {
                        // yielded or not, we continue the wait loop
                        std.log.debug("yield failed: {}", .{err});
                    };
                }
            }

            fn exit(self: *EpochManager, slot_idx: usize) void {
                self.thread_epochs[slot_idx].store(std.math.maxInt(u64), .release);
            }

            fn minActiveEpoch(self: *EpochManager) u64 {
                var min = self.current_epoch.load(.acquire);
                for (&self.thread_epochs) |*s| {
                    const e = s.load(.acquire);
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

        pub fn init(allocator: Allocator, config: Config, deinit_payload: ?*const fn (Allocator, *t) void) !*Self {
            const cache = try allocator.create(Self);
            const entries = try allocator.create(std.StringHashMap(*CacheEntry));
            entries.* = std.StringHashMap(*CacheEntry).init(allocator);

            cache.* = .{
                .entries = std.atomic.Value(*std.StringHashMap(*CacheEntry)).init(entries),
                .allocator = allocator,
                .defer_stack = std.atomic.Value(?*DeferNode).init(null),
                // SAFETY: pool is initialized via cache.pool.init below
                .pool = undefined,
                .epoch_manager = EpochManager.init(),
                .config = config,
                .reclaim_active = std.atomic.Value(bool).init(true),
                .deinit_payload = deinit_payload,
            };

            try cache.pool.init(allocator, @intCast(@as(u32, @intCast(config.max_deferred_nodes))), null, null);

            cache.reclaim_handle = try std.Thread.spawn(.{}, reclaimLoop, .{cache});
            return cache;
        }

        pub fn deinit(self: *Self) void {
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
                // Free the cache entry shell and its data
                entry.value_ptr.*.deinit(self.allocator, self.deinit_payload);
            }
            entries.deinit();
            self.allocator.destroy(entries);

            // Free the pool (contains the actual DeferNode storage)
            self.pool.deinit();
            self.allocator.destroy(self);
        }

        pub const Error = error{
            RefCountOverflow,
            OutOfMemory,
            NotFound,
        };

        pub const Snapshot = struct {
            cache: *Self,
            map: *std.StringHashMap(*CacheEntry),
            slot: usize,

            pub fn deinit(self: Snapshot) void {
                self.cache.epoch_manager.exit(self.slot);
            }
        };

        pub fn getSnapshot(self: *Self) Snapshot {
            const slot = self.epoch_manager.enter();
            return Snapshot{
                .cache = self,
                .map = self.entries.load(.acquire),
                .slot = slot,
            };
        }

        /// Handle for a cached item, ensures proper ref counting
        pub const Handle = struct {
            cache: *Self,
            namespace: []const u8,
            entry: *CacheEntry,
            epoch_slot: usize,

            pub fn data(self: Handle) *t {
                return &self.entry.data;
            }

            pub fn release(self: Handle) void {
                self.cache.releaseHandle(self);
            }
        };

        /// Lock-free read operation with atomic ref_count increment
        pub fn get(self: *Self, namespace: []const u8) !Handle {
            const slot = self.epoch_manager.enter();
            errdefer self.epoch_manager.exit(slot);

            const entries = self.entries.load(.acquire);
            const entry = entries.get(namespace) orelse return Error.NotFound;

            // Increment ref count while we hold the epoch barrier
            _ = entry.ref_count.fetchAdd(1, .acq_rel);

            return Handle{
                .cache = self,
                .namespace = namespace,
                .entry = entry,
                .epoch_slot = slot,
            };
        }

        /// Signal release of a handle and potentially defer reclamation
        pub fn releaseHandle(self: *Self, handle: Handle) void {
            _ = handle.entry.ref_count.fetchSub(1, .acq_rel);
            self.epoch_manager.exit(handle.epoch_slot);
        }

        /// Create a new version of the namespace entry (COW)
        pub fn update(self: *Self, namespace: []const u8, new_data: t) Error!void {
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);

                // 1. Create a full copy of the hash map
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

                // 2. Prepare new entry
                const old_entry = old_entries.get(namespace);
                const new_version = if (old_entry) |oe| oe.version.load(.acquire) + 1 else 0;

                const entry = try CacheEntry.init(self.allocator, new_data);
                errdefer self.allocator.destroy(entry);
                entry.version.store(new_version, .release);

                // 3. Update the new map
                const ns_copy = try self.allocator.dupe(u8, namespace);
                errdefer self.allocator.free(ns_copy);

                const gop = try new_entries.getOrPut(ns_copy);

                var deferred_old_value: ?*CacheEntry = null;
                var deferred_old_key: ?[]const u8 = null;
                if (gop.found_existing) {
                    deferred_old_key = gop.key_ptr.*;
                    deferred_old_value = gop.value_ptr.*;
                    gop.key_ptr.* = ns_copy;
                    gop.value_ptr.* = entry;
                } else {
                    gop.value_ptr.* = entry;
                }

                // 4. Atomic swap the map
                if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                    // Someone beat us to it, retry
                    self.allocator.destroy(entry);
                    self.allocator.free(ns_copy);
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    _ = actual;
                    continue;
                }

                // 5. Success! Now we can safely defer the old resources
                if (deferred_old_value) |ov| self.internalDefer(.{ .entry = ov });
                if (deferred_old_key) |ok| self.internalDefer(.{ .key = ok });

                // 6. Defer reclamation of the old map itself
                self.internalDefer(.{ .map = old_entries });

                // 7. Bump epoch to ensure new readers see the new map
                _ = self.epoch_manager.bump();
                return;
            }
        }

        /// Update an entry in the cache with extended options (e.g., size limit)
        pub fn updateExt(self: *Self, namespace: []const u8, new_data: t, options: UpdateOptions) !void {
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);

                // 1. Create a full copy of the hash map
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

                // 2. Handle capacity limit if set
                var evicted_batch = std.ArrayListUnmanaged(struct { key: []const u8, value: *CacheEntry }).empty;
                defer evicted_batch.deinit(self.allocator);

                if (options.max_capacity) |max| {
                    // Check if we need to evict BEFORE adding the new one
                    // We check if it's already there to decide if count will increase
                    const exists = new_entries.contains(namespace);
                    if (!exists and new_entries.count() >= max) {
                        const to_evict = @min(options.evict_batch_size, new_entries.count());
                        var evicted_count: usize = 0;
                        var nit = new_entries.iterator();
                        while (nit.next()) |entry| {
                            if (evicted_count >= to_evict) break;
                            // Don't evict the one we are about to update (though it's not and-added yet)
                            if (std.mem.eql(u8, entry.key_ptr.*, namespace)) continue;

                            try evicted_batch.append(self.allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
                            evicted_count += 1;
                        }

                        for (evicted_batch.items) |eb| {
                            _ = new_entries.remove(eb.key);
                        }
                    }
                }

                // 3. Prepare new entry
                const old_entry = old_entries.get(namespace);
                const new_version = if (old_entry) |oe| oe.version.load(.acquire) + 1 else 0;

                const entry = try CacheEntry.init(self.allocator, new_data);
                errdefer self.allocator.destroy(entry);
                entry.version.store(new_version, .release);

                // 4. Update the new map
                const ns_copy = try self.allocator.dupe(u8, namespace);
                errdefer self.allocator.free(ns_copy);

                const gop = try new_entries.getOrPut(ns_copy);

                var deferred_old_value: ?*CacheEntry = null;
                var deferred_old_key: ?[]const u8 = null;
                if (gop.found_existing) {
                    deferred_old_key = gop.key_ptr.*;
                    deferred_old_value = gop.value_ptr.*;
                    gop.key_ptr.* = ns_copy;
                    gop.value_ptr.* = entry;
                } else {
                    gop.value_ptr.* = entry;
                }

                // 5. Atomic swap the map
                if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                    // Someone beat us to it, retry
                    self.allocator.destroy(entry);
                    self.allocator.free(ns_copy);
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    _ = actual;
                    continue;
                }

                // 6. Success! Now we can safely defer the old resources
                if (deferred_old_value) |ov| self.internalDefer(.{ .entry = ov });
                if (deferred_old_key) |ok| self.internalDefer(.{ .key = ok });

                // Defer batch evicted entries
                for (evicted_batch.items) |eb| {
                    self.internalDefer(.{ .entry = eb.value });
                    self.internalDefer(.{ .key = eb.key });
                }

                // 7. Defer reclamation of the old map itself
                self.internalDefer(.{ .map = old_entries });

                // 8. Bump epoch
                _ = self.epoch_manager.bump();
                return;
            }
        }

        /// Evict an entry from the cache
        pub fn evict(self: *Self, namespace: []const u8) bool {
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);
                if (!old_entries.contains(namespace)) return false;

                const new_entries = self.allocator.create(std.StringHashMap(*CacheEntry)) catch return false;
                new_entries.* = std.StringHashMap(*CacheEntry).init(self.allocator);

                var it = old_entries.iterator();
                var old: ?struct { key: []const u8, value: *CacheEntry } = null;
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, namespace)) {
                        old = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
                        continue;
                    }
                    new_entries.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                        new_entries.deinit();
                        self.allocator.destroy(new_entries);
                        return false;
                    };
                }

                if (old) |o| {
                    if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                        _ = actual;
                        new_entries.deinit();
                        self.allocator.destroy(new_entries);
                        continue;
                    } else {
                        self.internalDefer(.{ .entry = o.value });
                        self.internalDefer(.{ .key = o.key });
                        self.internalDefer(.{ .map = old_entries });
                        _ = self.epoch_manager.bump();
                        return true;
                    }
                } else {
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    return false;
                }
            }
        }

        /// Evict multiple entries from the cache in a single COW operation
        pub fn bulkEvict(self: *Self, namespaces: []const []const u8) void {
            if (namespaces.len == 0) return;
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);

                // Check if any of the namespaces exist
                var any_exists = false;
                for (namespaces) |ns| {
                    if (old_entries.contains(ns)) {
                        any_exists = true;
                        break;
                    }
                }
                if (!any_exists) return;

                const new_entries = self.allocator.create(std.StringHashMap(*CacheEntry)) catch return;
                new_entries.* = std.StringHashMap(*CacheEntry).init(self.allocator);
                errdefer {
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                }

                var it = old_entries.iterator();
                var evicted_entries = std.ArrayListUnmanaged(struct { key: []const u8, value: *CacheEntry }).empty;
                defer evicted_entries.deinit(self.allocator);

                while (it.next()) |entry| {
                    var should_evict = false;
                    for (namespaces) |ns| {
                        if (std.mem.eql(u8, entry.key_ptr.*, ns)) {
                            should_evict = true;
                            break;
                        }
                    }

                    if (should_evict) {
                        evicted_entries.append(self.allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* }) catch {
                            new_entries.deinit();
                            self.allocator.destroy(new_entries);
                            return;
                        };
                        continue;
                    }
                    new_entries.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                        new_entries.deinit();
                        self.allocator.destroy(new_entries);
                        return;
                    };
                }

                if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                    _ = actual;
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    continue;
                } else {
                    for (evicted_entries.items) |o| {
                        self.internalDefer(.{ .entry = o.value });
                        self.internalDefer(.{ .key = o.key });
                    }
                    self.internalDefer(.{ .map = old_entries });
                    _ = self.epoch_manager.bump();
                    return;
                }
            }
        }

        fn internalDefer(self: *Self, resource: Resource) void {
            const node = self.pool.pop() orelse blk: {
                // Pool exhausted, try a regular reclamation cycle
                self.reclaim(false);
                break :blk self.pool.acquire() catch return;
            };

            node.* = .{
                .next = null,
                .epoch = self.epoch_manager.current_epoch.load(.acquire),
                .resource = resource,
            };
            self.pushToDeferStack(node);
        }

        fn pushToDeferStack(self: *Self, node: *DeferNode) void {
            var current = self.defer_stack.load(.acquire);
            while (true) {
                node.next = current;
                if (self.defer_stack.cmpxchgWeak(current, node, .acq_rel, .acquire)) |actual| {
                    current = actual;
                } else break;
            }
        }

        fn reclaimLoop(self: *Self) void {
            while (self.reclaim_active.load(.acquire)) {
                self.reclaim(false);
                std.Thread.sleep(self.config.reclamation_interval_ms * std.time.ns_per_ms);
            }
        }

        pub fn size(self: *Self) usize {
            const map = self.entries.load(.acquire);
            return map.count();
        }

        pub fn reclaim(self: *Self, force: bool) void {
            const min_epoch = if (force) std.math.maxInt(u64) else self.epoch_manager.minActiveEpoch();

            // Atomically detach the entire defer stack
            const head = self.defer_stack.swap(null, .acq_rel);

            var node_it = head;
            while (node_it) |node| {
                const next = node.next;
                if (force or node.epoch < min_epoch) {
                    // Safe to reclaim
                    switch (node.resource) {
                        .map => |m| {
                            m.deinit();
                            self.allocator.destroy(m);
                        },
                        .entry => |e| {
                            e.deinit(self.allocator, self.deinit_payload);
                        },
                        .key => |k| self.allocator.free(k),
                    }
                    self.pool.release(node);
                } else {
                    // Still in use, re-push to stack
                    self.pushToDeferStack(node);
                }
                node_it = next;
            }
        }
    };
}
