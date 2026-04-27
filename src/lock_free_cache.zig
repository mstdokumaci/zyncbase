const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

/// Lock-free cache for parallel reads across all CPU cores.
/// Generic over type T, allowing specialized storage for AuthResponses, MsgPack payloads, etc.
pub fn lockFreeCache(comptime t: type, comptime KeyType: type) type { // zwanzig-disable-line: unused-parameter
    comptime {
        if (!@hasDecl(t, "deinit")) {
            @compileError("lockFreeCache(T) requires `pub fn deinit(self: T, allocator: std.mem.Allocator) void` on T");
        }

        const fn_info = switch (@typeInfo(@TypeOf(t.deinit))) {
            .@"fn" => |f| f,
            else => @compileError("lockFreeCache(T): T.deinit must be a function"),
        };

        if (fn_info.params.len != 2) {
            @compileError("lockFreeCache(T): T.deinit must have signature `fn (T, std.mem.Allocator) void`");
        }

        const param0 = fn_info.params[0].type orelse
            @compileError("lockFreeCache(T): first deinit parameter type must be concrete");
        const param1 = fn_info.params[1].type orelse
            @compileError("lockFreeCache(T): second deinit parameter type must be concrete");

        if (param0 != t or param1 != Allocator or fn_info.return_type != void) {
            @compileError("lockFreeCache(T): T.deinit must be `fn (T, std.mem.Allocator) void`");
        }
    }
    return struct {
        const Self = @This();
        const MapType = std.AutoHashMap(KeyType, *CacheEntry);

        /// Individual cache entry with atomic fields for concurrent access
        pub const CacheEntry = struct {
            data: t,
            ref_count: std.atomic.Value(usize),
            version: std.atomic.Value(u64),

            fn init(allocator: Allocator, data: t) !*CacheEntry {
                const entry = try allocator.create(CacheEntry);
                entry.* = .{
                    .data = data,
                    .ref_count = std.atomic.Value(usize).init(0),
                    .version = std.atomic.Value(u64).init(0),
                };
                return entry;
            }

            fn deinit(self: *CacheEntry, allocator: Allocator) void {
                if (@hasDecl(t, "deinit")) {
                    self.data.deinit(allocator);
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
            map: *MapType,
            entry: *CacheEntry,
        };

        entries: std.atomic.Value(*MapType),
        allocator: Allocator,
        defer_stack: std.atomic.Value(?*DeferNode),
        pool: MemoryStrategy.IndexPool(DeferNode),
        epoch_manager: EpochManager,
        config: Config,
        reclaim_handle: ?std.Thread = null,
        reclaim_active: std.atomic.Value(bool),

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
                    .current_epoch = std.atomic.Value(u64).init(0),
                    // SAFETY: Initialized immediately below in the thread array loop
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

        pub fn init(self: *Self, allocator: Allocator, config: Config) !void {
            const entries = try allocator.create(MapType);
            entries.* = MapType.init(allocator);

            self.* = .{
                .entries = std.atomic.Value(*MapType).init(entries),
                .allocator = allocator,
                .defer_stack = std.atomic.Value(?*DeferNode).init(null),
                // SAFETY: Pool is populated before any threads use the EpochManager
                .pool = undefined,
                .epoch_manager = EpochManager.init(),
                .config = config,
                .reclaim_active = std.atomic.Value(bool).init(true),
                .reclaim_handle = null,
            };

            try self.pool.init(allocator, @intCast(@as(u32, @intCast(config.max_deferred_nodes))), null, null);

            self.reclaim_handle = try std.Thread.spawn(.{}, reclaimLoop, .{self});
        }

        pub fn deinit(self: *Self) void {
            self.reclaim_active.store(false, .release);
            if (self.reclaim_handle) |h| h.join();

            self.reclaim(true);

            const entries = self.entries.load(.acquire);
            var it = entries.valueIterator();
            while (it.next()) |entry| {
                entry.*.deinit(self.allocator);
            }
            entries.deinit();
            self.allocator.destroy(entries);

            self.pool.deinit();
        }

        pub const Error = error{
            RefCountOverflow,
            OutOfMemory,
            NotFound,
        };

        pub const Snapshot = struct {
            cache: *Self,
            map: *MapType,
            epoch_slot: usize,

            pub fn deinit(self: Snapshot) void {
                self.cache.epoch_manager.exit(self.epoch_slot);
            }
        };

        pub fn getSnapshot(self: *Self) Snapshot {
            const slot = self.epoch_manager.enter();
            return Snapshot{
                .cache = self,
                .map = self.entries.load(.acquire),
                .epoch_slot = slot,
            };
        }

        /// Handle for a cached item, ensures proper ref counting
        pub const Handle = struct {
            cache: *Self,
            key: KeyType,
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
        pub fn get(self: *Self, key: KeyType) !Handle {
            const slot = self.epoch_manager.enter();
            errdefer self.epoch_manager.exit(slot);

            const entries = self.entries.load(.acquire);
            const entry = entries.get(key) orelse return Error.NotFound;

            _ = entry.ref_count.fetchAdd(1, .acq_rel);

            return Handle{
                .cache = self,
                .key = key,
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
        pub fn update(self: *Self, key: KeyType, new_data: t) Error!void {
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);

                const new_entries = try self.allocator.create(MapType);
                new_entries.* = try old_entries.clone();
                errdefer {
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                }

                const old_entry = old_entries.get(key);
                const new_version = if (old_entry) |oe| oe.version.load(.acquire) + 1 else 0;

                const entry = try CacheEntry.init(self.allocator, new_data);
                errdefer self.allocator.destroy(entry);
                entry.version.store(new_version, .release);

                const gop = try new_entries.getOrPut(key);

                var deferred_old_value: ?*CacheEntry = null;
                if (gop.found_existing) {
                    deferred_old_value = gop.value_ptr.*;
                    gop.value_ptr.* = entry;
                } else {
                    gop.value_ptr.* = entry;
                }

                if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                    self.allocator.destroy(entry);
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    _ = actual;
                    continue;
                }

                if (deferred_old_value) |ov| self.internalDefer(.{ .entry = ov });
                self.internalDefer(.{ .map = old_entries });

                _ = self.epoch_manager.bump();
                return;
            }
        }

        /// Update an entry in the cache with extended options (e.g., size limit)
        pub fn updateExt(self: *Self, key: KeyType, new_data: t, options: UpdateOptions) !void {
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);

                const new_entries = try self.allocator.create(MapType);
                new_entries.* = try old_entries.clone();
                errdefer {
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                }

                var evicted_batch = std.ArrayListUnmanaged(struct { key: KeyType, value: *CacheEntry }).empty;
                defer evicted_batch.deinit(self.allocator);

                if (options.max_capacity) |max| {
                    const exists = new_entries.contains(key);
                    if (!exists and new_entries.count() >= max) {
                        const to_evict = @min(options.evict_batch_size, new_entries.count());
                        var evicted_count: usize = 0;
                        var nit = new_entries.iterator();
                        while (nit.next()) |entry| {
                            if (evicted_count >= to_evict) break;
                            if (std.meta.eql(entry.key_ptr.*, key)) continue;

                            try evicted_batch.append(self.allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
                            evicted_count += 1;
                        }

                        for (evicted_batch.items) |eb| {
                            _ = new_entries.remove(eb.key);
                        }
                    }
                }

                const old_entry = old_entries.get(key);
                const new_version = if (old_entry) |oe| oe.version.load(.acquire) + 1 else 0;

                const entry = try CacheEntry.init(self.allocator, new_data);
                errdefer self.allocator.destroy(entry);
                entry.version.store(new_version, .release);

                const gop = try new_entries.getOrPut(key);

                var deferred_old_value: ?*CacheEntry = null;
                if (gop.found_existing) {
                    deferred_old_value = gop.value_ptr.*;
                    gop.value_ptr.* = entry;
                } else {
                    gop.value_ptr.* = entry;
                }

                if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                    self.allocator.destroy(entry);
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    _ = actual;
                    continue;
                }

                if (deferred_old_value) |ov| self.internalDefer(.{ .entry = ov });
                for (evicted_batch.items) |eb| {
                    self.internalDefer(.{ .entry = eb.value });
                }

                self.internalDefer(.{ .map = old_entries });

                _ = self.epoch_manager.bump();
                return;
            }
        }

        /// Evict an entry from the cache
        pub fn evict(self: *Self, key: KeyType) bool {
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);
                if (!old_entries.contains(key)) return false;

                const new_entries = self.allocator.create(MapType) catch return false;
                new_entries.* = old_entries.clone() catch {
                    self.allocator.destroy(new_entries);
                    return false;
                };

                const old_val = new_entries.fetchRemove(key) orelse unreachable;

                if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                    _ = actual;
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    continue;
                } else {
                    self.internalDefer(.{ .entry = old_val.value });
                    self.internalDefer(.{ .map = old_entries });
                    _ = self.epoch_manager.bump();
                    return true;
                }
            }
        }

        /// Evict multiple entries from the cache in a single COW operation
        pub fn bulkEvict(self: *Self, keys: []const KeyType) void {
            if (keys.len == 0) return;
            while (true) {
                const epoch_slot = self.epoch_manager.enter();
                defer self.epoch_manager.exit(epoch_slot);

                const old_entries = self.entries.load(.acquire);

                var any_exists = false;
                for (keys) |key| {
                    if (old_entries.contains(key)) {
                        any_exists = true;
                        break;
                    }
                }
                if (!any_exists) return;

                const new_entries = self.allocator.create(MapType) catch return;
                new_entries.* = old_entries.clone() catch {
                    self.allocator.destroy(new_entries);
                    return;
                };

                var evicted_entries = std.ArrayListUnmanaged(*CacheEntry).initCapacity(self.allocator, keys.len) catch {
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    return;
                };
                defer evicted_entries.deinit(self.allocator);

                for (keys) |key| {
                    if (new_entries.fetchRemove(key)) |kv| {
                        evicted_entries.appendAssumeCapacity(kv.value);
                    }
                }

                if (self.entries.cmpxchgStrong(old_entries, new_entries, .acq_rel, .acquire)) |actual| {
                    _ = actual;
                    new_entries.deinit();
                    self.allocator.destroy(new_entries);
                    continue;
                } else {
                    for (evicted_entries.items) |e| {
                        self.internalDefer(.{ .entry = e });
                    }
                    self.internalDefer(.{ .map = old_entries });
                    _ = self.epoch_manager.bump();
                    return;
                }
            }
        }

        fn internalDefer(self: *Self, resource: Resource) void {
            const node = self.pool.pop() orelse blk: {
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

            const head = self.defer_stack.swap(null, .acq_rel);

            var node_it = head;
            while (node_it) |node| {
                const next = node.next;
                if (force or node.epoch < min_epoch) {
                    switch (node.resource) {
                        .map => |m| {
                            m.deinit();
                            self.allocator.destroy(m);
                        },
                        .entry => |e| {
                            e.deinit(self.allocator);
                        },
                    }
                    self.pool.release(node);
                } else {
                    self.pushToDeferStack(node);
                }
                node_it = next;
            }
        }
    };
}
