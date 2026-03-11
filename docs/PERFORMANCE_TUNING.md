# Performance Tuning Guide

## Overview

This guide provides comprehensive optimization strategies for ZyncBase deployments. It covers SQLite configuration, operating system tuning, hardware recommendations, benchmarking methodology, and solutions to common performance issues. Following these guidelines will help you achieve optimal throughput, latency, and resource utilization.

## Table of Contents

1. [SQLite PRAGMA Settings](#sqlite-pragma-settings)
2. [Operating System Tuning](#operating-system-tuning)
3. [Hardware Recommendations](#hardware-recommendations)
4. [Benchmarking Methodology](#benchmarking-methodology)
5. [Common Performance Issues](#common-performance-issues)

---

## SQLite PRAGMA Settings

SQLite's behavior can be significantly optimized through PRAGMA statements. ZyncBase uses SQLite in WAL (Write-Ahead Logging) mode for concurrent read/write access.

### Essential WAL Mode Settings

```sql
-- Enable WAL mode (required for ZyncBase)
PRAGMA journal_mode = WAL;

-- Set synchronous mode for durability vs performance tradeoff
PRAGMA synchronous = NORMAL;  -- Recommended for most deployments
-- PRAGMA synchronous = FULL;  -- Use for maximum durability (slower)
-- PRAGMA synchronous = OFF;   -- Use only for non-critical data (fastest)

-- Configure WAL autocheckpoint threshold
PRAGMA wal_autocheckpoint = 1000;  -- Checkpoint every 1000 pages (~4MB)

-- Set page size (must be set before creating database)
PRAGMA page_size = 4096;  -- Default, good for most workloads
-- PRAGMA page_size = 8192;  -- Better for large rows or blobs
```

### Memory and Cache Settings

```sql
-- Set cache size (negative value = KB, positive = pages)
PRAGMA cache_size = -64000;  -- 64MB cache (recommended minimum)
-- PRAGMA cache_size = -256000;  -- 256MB for high-throughput systems
-- PRAGMA cache_size = -512000;  -- 512MB for memory-rich servers

-- Enable memory-mapped I/O for read performance
PRAGMA mmap_size = 268435456;  -- 256MB mmap (recommended)
-- PRAGMA mmap_size = 1073741824;  -- 1GB for large databases

-- Set temp store to memory for faster temporary operations
PRAGMA temp_store = MEMORY;
```

### Query Optimization Settings

```sql
-- Enable query planner optimization
PRAGMA optimize;  -- Run periodically (e.g., on startup, shutdown)

-- Analyze database statistics for better query plans
ANALYZE;  -- Run after significant data changes

-- Set busy timeout to handle lock contention
PRAGMA busy_timeout = 5000;  -- 5 seconds (adjust based on workload)
```

### Connection Pool Settings

For ZyncBase's read connection pool:

```sql
-- Read-only connections should use:
PRAGMA query_only = ON;  -- Prevent accidental writes

-- All connections should set:
PRAGMA foreign_keys = ON;  -- Enforce referential integrity
PRAGMA case_sensitive_like = ON;  -- Consistent LIKE behavior
```

### Performance vs Durability Tradeoffs

| Setting | Durability | Performance | Use Case |
|---------|-----------|-------------|----------|
| `synchronous = FULL` | Maximum | Slowest | Financial, critical data |
| `synchronous = NORMAL` | High | Balanced | **Recommended default** |
| `synchronous = OFF` | Minimal | Fastest | Caches, temporary data |

**Recommendation**: Use `NORMAL` for production. It provides good durability (survives OS crash) while maintaining performance. Only use `FULL` if you need to survive power loss without UPS.

---

## Operating System Tuning

### Linux Kernel Parameters (sysctl)

Create or edit `/etc/sysctl.conf` with the following settings:

```bash
# Increase file descriptor limits
fs.file-max = 2097152

# Increase network buffer sizes for WebSocket connections
net.core.rmem_max = 134217728  # 128MB
net.core.wmem_max = 134217728  # 128MB
net.core.rmem_default = 16777216  # 16MB
net.core.wmem_default = 16777216  # 16MB

# TCP tuning for many concurrent connections
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384

# Reduce TIME_WAIT sockets for connection recycling
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Increase ephemeral port range
net.ipv4.ip_local_port_range = 10000 65535

# Virtual memory tuning for database workloads
vm.swappiness = 10  # Prefer RAM over swap
vm.dirty_ratio = 15  # Start background writeback at 15%
vm.dirty_background_ratio = 5  # Background writeback threshold
```

Apply settings:
```bash
sudo sysctl -p
```

### File Descriptor Limits (ulimit)

Edit `/etc/security/limits.conf`:

```
# For ZyncBase user (replace 'zyncbase' with actual username)
zyncbase soft nofile 1048576
zyncbase hard nofile 1048576
zyncbase soft nproc 65536
zyncbase hard nproc 65536
```

Or set in systemd service file:

```ini
[Service]
LimitNOFILE=1048576
LimitNPROC=65536
```

Verify limits:
```bash
ulimit -n  # File descriptors
ulimit -u  # Processes
```

### Filesystem Recommendations

**Recommended**: ext4 or XFS with the following mount options:

```bash
# /etc/fstab entry for ZyncBase data partition
/dev/sda1 /var/lib/zyncbase ext4 noatime,nodiratime,data=ordered 0 2
```

Mount options explained:
- `noatime`: Don't update access time (reduces writes)
- `nodiratime`: Don't update directory access time
- `data=ordered`: Balance between performance and safety (default)

**For maximum performance** (with UPS backup):
```bash
/dev/sda1 /var/lib/zyncbase ext4 noatime,nodiratime,data=writeback 0 2
```

### I/O Scheduler

For SSD storage:
```bash
# Set to 'none' or 'noop' for NVMe SSDs
echo none > /sys/block/nvme0n1/queue/scheduler

# Or 'deadline' for SATA SSDs
echo deadline > /sys/block/sda/queue/scheduler
```

For HDD storage:
```bash
# Use 'cfq' (Completely Fair Queuing)
echo cfq > /sys/block/sda/queue/scheduler
```

### Transparent Huge Pages (THP)

Disable THP for database workloads (can cause latency spikes):

```bash
# Temporary
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Permanent (add to /etc/rc.local or systemd service)
```

---

## Hardware Recommendations

### CPU

**Minimum**: 4 cores (8 threads)
**Recommended**: 8-16 cores (16-32 threads)
**Optimal**: 16+ cores for 100k+ concurrent connections

**Key considerations**:
- ZyncBase's lock-free cache scales linearly with CPU cores
- Target: 176k reads/sec on 16-core machine (11k reads/sec per core)
- Prefer higher core count over higher clock speed
- Modern CPUs with good single-thread performance (Intel Xeon, AMD EPYC)

### Memory

**Minimum**: 8 GB RAM
**Recommended**: 32 GB RAM
**Optimal**: 64+ GB RAM for large datasets

**Memory allocation guidelines**:
```
Total RAM = SQLite Cache + Lock-Free Cache + Connection Buffers + OS Cache + Overhead

Example for 32GB system:
- SQLite cache: 8 GB (cache_size = -8000000)
- Lock-free cache: 4 GB (estimated for 1000 namespaces)
- Connection buffers: 8 GB (100k connections × ~80KB each)
- OS page cache: 8 GB
- System overhead: 4 GB
```

**Rule of thumb**: Allocate 25-30% of RAM to SQLite cache, keep 25% for OS cache.

### Storage

**Minimum**: SSD with 100 MB/s sequential write
**Recommended**: NVMe SSD with 500+ MB/s sequential write
**Optimal**: Enterprise NVMe with 2+ GB/s sequential write

**Storage sizing**:
- Database size: Depends on data volume (estimate 1-2 KB per row)
- WAL file: Up to 10 MB (checkpoint threshold)
- Overhead: 20% for indexes and metadata

**IOPS requirements**:
- Read IOPS: 10k+ for cache misses
- Write IOPS: 5k+ for sustained write workload
- Latency: < 1ms for p99 read latency

**Storage recommendations by deployment size**:

| Deployment Size | Storage Type | Capacity | IOPS |
|----------------|--------------|----------|------|
| Small (< 10k connections) | SATA SSD | 256 GB | 10k |
| Medium (10k-50k connections) | NVMe SSD | 512 GB | 50k |
| Large (50k-100k connections) | Enterprise NVMe | 1 TB | 100k+ |
| Extra Large (100k+ connections) | NVMe RAID 0 | 2+ TB | 200k+ |

### Network

**Minimum**: 1 Gbps NIC
**Recommended**: 10 Gbps NIC
**Optimal**: 25+ Gbps NIC for 100k+ connections

**Bandwidth estimation**:
```
Bandwidth = Connections × Message Rate × Message Size

Example:
100k connections × 10 msg/sec × 1 KB = 1 GB/sec = 8 Gbps
```

**Network card recommendations**:
- Use multi-queue NICs for better CPU distribution
- Enable RSS (Receive Side Scaling)
- Consider SR-IOV for virtualized environments

---

## Benchmarking Methodology

### Benchmark Tools

#### 1. Lock-Free Cache Benchmark

```bash
# Build benchmark
zig build benchmark-cache

# Run with different thread counts
./zig-out/bin/benchmark-cache --threads=1
./zig-out/bin/benchmark-cache --threads=4
./zig-out/bin/benchmark-cache --threads=8
./zig-out/bin/benchmark-cache --threads=16

# Expected results:
# 1 thread:  ~11k reads/sec
# 4 threads: ~44k reads/sec
# 8 threads: ~88k reads/sec
# 16 threads: ~176k reads/sec
```

#### 2. MessagePack Parser Benchmark

```bash
# Build benchmark
zig build benchmark-msgpack

# Run with different payload sizes
./zig-out/bin/benchmark-msgpack --size=1kb
./zig-out/bin/benchmark-msgpack --size=10kb
./zig-out/bin/benchmark-msgpack --size=100kb

# Expected throughput: > 1 GB/sec
```

#### 3. End-to-End Load Testing

Use the provided load testing tool:

```bash
# Install dependencies
npm install -g zyncbase-loadtest

# Run load test
zyncbase-loadtest \
  --url ws://localhost:8080 \
  --connections 10000 \
  --duration 60s \
  --message-rate 10 \
  --message-size 1024

# Metrics to monitor:
# - Connection establishment time (p50, p95, p99)
# - Message latency (p50, p95, p99)
# - Throughput (messages/sec, bytes/sec)
# - Error rate
```

### Key Performance Metrics

#### Latency Targets

| Operation | p50 | p95 | p99 |
|-----------|-----|-----|-----|
| Cache hit read | < 100 ns | < 200 ns | < 500 ns |
| Cache miss read | < 1 ms | < 5 ms | < 10 ms |
| Write operation | < 5 ms | < 20 ms | < 50 ms |
| Subscription notification | < 5 ms | < 10 ms | < 20 ms |
| Checkpoint (passive) | < 100 ms | < 200 ms | < 500 ms |

#### Throughput Targets

| Metric | Target |
|--------|--------|
| Cache reads/sec (16-core) | 176k+ |
| MessagePack parse throughput | 1+ GB/sec |
| Concurrent connections | 100k |
| Messages/sec (aggregate) | 1M+ |
| Subscription matches/sec | 100k+ |

### Monitoring During Benchmarks

Use Prometheus + Grafana to monitor:

```bash
# Start Prometheus
prometheus --config.file=prometheus.yml

# Access metrics endpoint
curl http://localhost:8080/metrics

# Key metrics to watch:
# - zyncbase_cache_hit_rate
# - zyncbase_cache_read_latency_seconds
# - zyncbase_active_connections
# - zyncbase_messages_per_second
# - zyncbase_checkpoint_duration_seconds
# - zyncbase_subscription_match_latency_seconds
```

### Baseline Performance Test

Run this test on a fresh deployment to establish baseline:

```bash
#!/bin/bash
# baseline-test.sh

echo "=== ZyncBase Baseline Performance Test ==="

# 1. Cache benchmark
echo "Testing lock-free cache..."
./zig-out/bin/benchmark-cache --threads=16 --duration=30s

# 2. Parser benchmark
echo "Testing MessagePack parser..."
./zig-out/bin/benchmark-msgpack --size=10kb --duration=30s

# 3. Connection capacity
echo "Testing connection capacity..."
zyncbase-loadtest --connections 100000 --duration 60s --message-rate 1

# 4. Write throughput
echo "Testing write throughput..."
zyncbase-loadtest --connections 1000 --duration 60s --message-rate 100 --write-ratio 1.0

# 5. Read throughput
echo "Testing read throughput..."
zyncbase-loadtest --connections 10000 --duration 60s --message-rate 100 --write-ratio 0.0

echo "=== Baseline test complete ==="
```

---

## Common Performance Issues

### Issue 1: High Cache Miss Rate

**Symptoms**:
- Slow read operations (> 10ms p99)
- High disk I/O
- Low `zyncbase_cache_hit_rate` metric

**Diagnosis**:
```bash
# Check cache metrics
curl http://localhost:8080/metrics | grep cache_hit_rate

# Check cache size
curl http://localhost:8080/metrics | grep cache_memory_usage
```

**Solutions**:

1. **Increase SQLite cache size**:
```sql
PRAGMA cache_size = -256000;  -- Increase to 256MB
```

2. **Increase lock-free cache capacity**:
```zig
// In config
.cache_max_entries = 10000,  // Increase from default
```

3. **Enable memory-mapped I/O**:
```sql
PRAGMA mmap_size = 1073741824;  -- 1GB
```

4. **Add more RAM** to the server

### Issue 2: WAL File Growing Unbounded

**Symptoms**:
- WAL file size > 100 MB
- Increasing disk usage
- Slow checkpoint operations

**Diagnosis**:
```bash
# Check WAL size
ls -lh /var/lib/zyncbase/*.db-wal

# Check checkpoint metrics
curl http://localhost:8080/metrics | grep checkpoint
```

**Solutions**:

1. **Reduce checkpoint threshold**:
```zig
// In CheckpointManager config
.wal_size_threshold = 5 * 1024 * 1024,  // 5MB instead of 10MB
.time_threshold_sec = 60,  // 1 minute instead of 5 minutes
```

2. **Use more aggressive checkpoint mode**:
```zig
.checkpoint_mode = .full,  // Instead of .passive
```

3. **Check for long-running read transactions**:
```sql
-- Find blocking readers
SELECT * FROM pragma_wal_checkpoint(FULL);
```

4. **Ensure checkpoint thread is running**:
```bash
# Check logs for checkpoint activity
journalctl -u zyncbase | grep checkpoint
```

### Issue 3: Connection Limit Reached

**Symptoms**:
- New connections rejected
- "Too many open files" errors
- `zyncbase_active_connections` at maximum

**Diagnosis**:
```bash
# Check current connections
curl http://localhost:8080/metrics | grep active_connections

# Check file descriptor usage
lsof -p $(pgrep zyncbase) | wc -l

# Check limits
cat /proc/$(pgrep zyncbase)/limits | grep "open files"
```

**Solutions**:

1. **Increase file descriptor limits** (see OS Tuning section)

2. **Increase connection pool size**:
```zig
// In config
.max_connections = 200000,  // Increase from 100k
```

3. **Enable connection recycling**:
```zig
.connection_idle_timeout_sec = 300,  // Close idle connections after 5 min
```

4. **Check for connection leaks**:
```bash
# Monitor connection growth over time
watch -n 1 'curl -s http://localhost:8080/metrics | grep active_connections'
```

### Issue 4: High Message Latency

**Symptoms**:
- Message latency > 50ms p99
- Slow subscription notifications
- Client timeouts

**Diagnosis**:
```bash
# Check latency metrics
curl http://localhost:8080/metrics | grep latency

# Check CPU usage
top -p $(pgrep zyncbase)

# Check for lock contention
perf record -p $(pgrep zyncbase) -g -- sleep 10
perf report
```

**Solutions**:

1. **Optimize subscription matching**:
```zig
// Ensure indexes are used
.subscription_index_enabled = true,
```

2. **Reduce message size**:
- Use MessagePack compression
- Remove unnecessary fields
- Batch updates when possible

3. **Increase worker threads**:
```zig
.worker_threads = 16,  // Match CPU core count
```

4. **Check for slow hooks**:
```bash
# Monitor Hook Server latency
curl http://localhost:8080/metrics | grep authorization_latency
```

### Issue 5: Memory Leaks

**Symptoms**:
- Increasing memory usage over time
- OOM (Out of Memory) crashes
- Slow garbage collection

**Diagnosis**:
```bash
# Monitor memory usage
watch -n 1 'ps aux | grep zyncbase'

# Check for leaks with Valgrind (development only)
valgrind --leak-check=full ./zig-out/bin/zyncbase

# Use built-in memory tracking
curl http://localhost:8080/metrics | grep memory
```

**Solutions**:

1. **Enable LeakSanitizer** in development:
```bash
zig build -Doptimize=Debug -Dsanitize=leak
```

2. **Check ref_count leaks**:
```bash
# Monitor cache entry ref_counts
curl http://localhost:8080/metrics | grep ref_count
```

3. **Ensure proper cleanup**:
- Verify `release()` called for every `get()`
- Check arena allocator resets
- Verify object pool returns

4. **Restart periodically** as a temporary workaround:
```bash
# Systemd service with restart
[Service]
Restart=always
RestartSec=86400  # Restart daily
```

### Issue 6: Checkpoint Blocking Reads

**Symptoms**:
- Read latency spikes during checkpoints
- `zyncbase_checkpoint_duration_seconds` > 1 second
- Increased p99 latency

**Diagnosis**:
```bash
# Correlate checkpoint timing with latency spikes
curl http://localhost:8080/metrics | grep -E '(checkpoint|latency)'

# Check checkpoint mode
journalctl -u zyncbase | grep "checkpoint mode"
```

**Solutions**:

1. **Use passive checkpoint mode**:
```zig
.checkpoint_mode = .passive,  // Non-blocking
```

2. **Increase checkpoint frequency** (smaller checkpoints):
```zig
.wal_size_threshold = 5 * 1024 * 1024,  // 5MB
```

3. **Schedule checkpoints during low traffic**:
```zig
// Disable automatic checkpoints
.auto_checkpoint_enabled = false,

// Trigger manually via cron
// 0 3 * * * curl -X POST http://localhost:8080/admin/checkpoint
```

4. **Increase I/O bandwidth** (faster storage)

### Issue 7: Hook Server Timeouts

**Symptoms**:
- Authorization failures
- `error.Timeout` in logs
- Circuit breaker opening frequently

**Diagnosis**:
```bash
# Check Hook Server metrics
curl http://localhost:8080/metrics | grep hook_server

# Check Hook Server logs
journalctl -u zyncbase-hooks | tail -100

# Test Hook Server directly
curl -X POST http://localhost:3000/authorize -d '{"user_id":"test"}'
```

**Solutions**:

1. **Increase timeout**:
```zig
.hook_server_timeout_ms = 10000,  // 10 seconds instead of 5
```

2. **Optimize hook code**:
- Avoid synchronous database queries
- Use caching for repeated checks
- Minimize external API calls

3. **Increase circuit breaker threshold**:
```zig
.circuit_breaker_threshold = 10,  // Allow more failures
```

4. **Enable authorization caching**:
```typescript
// In hook code
return {
  allowed: true,
  cache_ttl_sec: 300,  // Cache for 5 minutes
};
```

### Issue 8: Slow Subscription Matching

**Symptoms**:
- Notification latency > 10ms
- `zyncbase_subscription_match_latency_seconds` high
- CPU usage spikes on writes

**Diagnosis**:
```bash
# Check subscription count
curl http://localhost:8080/metrics | grep subscription_count

# Check matching latency
curl http://localhost:8080/metrics | grep subscription_match_latency

# Profile subscription matching
perf record -e cpu-clock -g -p $(pgrep zyncbase) -- sleep 10
perf report
```

**Solutions**:

1. **Optimize subscription filters**:
- Use indexed fields in filters
- Avoid complex OR conditions
- Simplify filter expressions

2. **Reduce subscription count**:
- Consolidate overlapping subscriptions
- Use broader filters with client-side filtering
- Implement subscription limits per connection

3. **Enable subscription indexing**:
```zig
.subscription_index_enabled = true,
.subscription_index_fields = &[_][]const u8{"namespace", "collection"},
```

4. **Batch notifications**:
```zig
.notification_batch_size = 100,  // Send up to 100 notifications at once
.notification_batch_delay_ms = 10,  // Wait 10ms to accumulate batch
```

---

## Performance Tuning Checklist

Use this checklist when deploying or optimizing ZyncBase:

### Pre-Deployment

- [ ] Hardware meets minimum requirements
- [ ] Storage is SSD or better (NVMe recommended)
- [ ] OS kernel parameters configured (sysctl)
- [ ] File descriptor limits increased (ulimit)
- [ ] Filesystem mounted with optimal options (noatime)
- [ ] I/O scheduler appropriate for storage type
- [ ] Transparent Huge Pages disabled

### SQLite Configuration

- [ ] WAL mode enabled
- [ ] Synchronous mode set appropriately (NORMAL recommended)
- [ ] Cache size configured (25-30% of RAM)
- [ ] Memory-mapped I/O enabled
- [ ] Temp store set to MEMORY
- [ ] Busy timeout configured

### ZyncBase Configuration

- [ ] Lock-free cache capacity set
- [ ] Checkpoint thresholds configured
- [ ] Connection limits set appropriately
- [ ] Worker thread count matches CPU cores
- [ ] Hook Server timeout configured
- [ ] Circuit breaker thresholds set

### Monitoring Setup

- [ ] Prometheus metrics endpoint accessible
- [ ] Grafana dashboards configured
- [ ] Alerting rules defined
- [ ] Log aggregation configured
- [ ] Health check endpoint monitored

### Post-Deployment

- [ ] Baseline performance test completed
- [ ] Load testing performed
- [ ] Metrics reviewed and validated
- [ ] Performance targets met
- [ ] Documentation updated with actual results

---

## Additional Resources

- [SQLite Performance Tuning](https://www.sqlite.org/pragma.html)
- [Linux Performance Tuning](https://www.kernel.org/doc/Documentation/sysctl/)
- [WebSocket Performance Best Practices](https://www.nginx.com/blog/websocket-nginx/)
- [ZyncBase Architecture Documentation](./ARCHITECTURE.md)
- [ZyncBase Troubleshooting Guide](./TROUBLESHOOTING.md)

---

## Support

For performance-related questions or issues:

- GitHub Issues: https://github.com/zyncbase/zyncbase/issues
- Community Forum: https://community.zyncbase.io
- Email: support@zyncbase.io

When reporting performance issues, please include:
- Hardware specifications
- OS and kernel version
- ZyncBase version
- Configuration files
- Metrics snapshot from `/metrics` endpoint
- Relevant log excerpts
