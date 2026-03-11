# ZyncBase Troubleshooting Guide

**Last Updated**: 2026-03-09

Comprehensive guide to diagnosing and resolving common ZyncBase issues. This guide covers connection problems, performance issues, database errors, Hook Server failures, and debugging techniques.

---

## Table of Contents

1. [Quick Diagnostic Commands](#quick-diagnostic-commands)
2. [Connection Issues](#connection-issues)
3. [Performance Problems](#performance-problems)
4. [Database Errors](#database-errors)
5. [Hook Server Issues](#hook-server-issues)
6. [Memory Issues](#memory-issues)
7. [Debug Mode and Logging](#debug-mode-and-logging)
8. [Log Analysis](#log-analysis)
9. [Performance Debugging](#performance-debugging)
10. [Common Error Messages](#common-error-messages)

---

## Quick Diagnostic Commands

Run these commands first to get an overview of system health:

```bash
# Check if ZyncBase is running
systemctl status zyncbase
# or
docker ps | grep zyncbase

# Check health endpoint
curl http://localhost:3000/health

# Check metrics
curl http://localhost:3000/metrics | grep -E '(connections|errors|latency)'

# Check recent logs
journalctl -u zyncbase -n 100 --no-pager
# or
docker logs zyncbase --tail 100

# Check resource usage
top -p $(pgrep zyncbase)
# or
docker stats zyncbase

# Check disk space
df -h /var/lib/zyncbase
# or
docker exec zyncbase df -h /data
```


---

## Connection Issues

### Issue 1: Clients Cannot Connect

**Symptoms**:
- WebSocket connection fails immediately
- "Connection refused" error
- Timeout when connecting

**Diagnosis**:

```bash
# 1. Verify server is running
systemctl status zyncbase
docker ps | grep zyncbase

# 2. Check if port is listening
netstat -tlnp | grep 3000
# or
ss -tlnp | grep 3000

# 3. Test local connection
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: test" \
  http://localhost:3000/

# 4. Check firewall rules
sudo ufw status
sudo iptables -L -n | grep 3000

# 5. Check server logs for errors
journalctl -u zyncbase -f
```

**Solutions**:

1. **Server not running**:
```bash
# Start the server
systemctl start zyncbase
# or
docker-compose up -d zyncbase
```

2. **Wrong port or host**:
```bash
# Check configuration
cat /opt/zyncbase/zyncbase-config.json | grep -E '(port|host)'

# Verify environment variables
docker exec zyncbase env | grep ZYNCBASE_PORT
```

3. **Firewall blocking**:
```bash
# Allow port through firewall
sudo ufw allow 3000/tcp

# Or for Docker
docker run -p 3000:3000 ...
```

4. **TLS/SSL misconfiguration**:
```bash
# Check TLS settings
cat /opt/zyncbase/zyncbase-config.json | grep -A 5 tls

# Verify certificate files exist
ls -l /opt/zyncbase/ssl/

# Test TLS connection
openssl s_client -connect localhost:3000 -servername localhost
```


### Issue 2: Connection Drops Frequently

**Symptoms**:
- Clients disconnect randomly
- "Connection closed" errors
- Frequent reconnection attempts

**Diagnosis**:

```bash
# 1. Check connection metrics
curl http://localhost:3000/metrics | grep -E '(connections|disconnections)'

# 2. Monitor connection stability
watch -n 1 'curl -s http://localhost:3000/metrics | grep active_connections'

# 3. Check for rate limiting
curl http://localhost:3000/metrics | grep rate_limit

# 4. Look for errors in logs
journalctl -u zyncbase | grep -E '(disconnect|close|error)'

# 5. Check network stability
ping -c 100 your-server-ip
mtr your-server-ip
```

**Solutions**:

1. **Rate limiting triggered**:
```json
// Increase rate limits in config
{
  "security": {
    "rateLimit": {
      "messagesPerSecond": 200,
      "connectionsPerIP": 20
    }
  }
}
```

2. **Idle timeout too aggressive**:
```json
{
  "connection": {
    "idleTimeoutSec": 600,
    "pingIntervalSec": 30
  }
}
```

3. **MessagePack limit violations**:
```bash
# Check for parsing errors
journalctl -u zyncbase | grep -E '(MaxDepthExceeded|MaxSizeExceeded)'

# Increase limits if legitimate
export MSGPACK_MAX_DEPTH=64
export MSGPACK_MAX_SIZE=20971520  # 20MB
```

4. **Network issues**:
```bash
# Check for packet loss
netstat -s | grep -E '(retransmit|loss)'

# Increase TCP buffer sizes (see PERFORMANCE_TUNING.md)
sudo sysctl -w net.core.rmem_max=134217728
```


### Issue 3: Authentication Failures

**Symptoms**:
- "AUTH_FAILED" errors
- "TOKEN_EXPIRED" errors
- Clients rejected immediately after connection

**Diagnosis**:

```bash
# 1. Check JWT secret configuration
echo $JWT_SECRET
docker exec zyncbase env | grep JWT_SECRET

# 2. Verify token format
# Decode JWT token (use jwt.io or jwt-cli)
jwt decode your-token-here

# 3. Check auth logs
journalctl -u zyncbase | grep -E '(auth|AUTH_FAILED|TOKEN_EXPIRED)'

# 4. Test authentication endpoint
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:3000/health
```

**Solutions**:

1. **JWT secret mismatch**:
```bash
# Ensure JWT_SECRET matches between auth service and ZyncBase
# Update environment variable
export JWT_SECRET="your-secret-key"

# Restart service
systemctl restart zyncbase
```

2. **Token expired**:
```typescript
// Client-side: Implement token refresh
client.on('tokenExpired', async () => {
  const newToken = await refreshAuthToken()
  await client.reconnect({ token: newToken })
})
```

3. **Invalid token format**:
```typescript
// Ensure token includes required claims
{
  "sub": "user-123",
  "exp": 1234567890,
  "iat": 1234567800
}
```

4. **Clock skew**:
```bash
# Synchronize server time
sudo ntpdate -s time.nist.gov
# or
sudo timedatectl set-ntp true
```


### Issue 4: Maximum Connections Reached

**Symptoms**:
- New connections rejected
- "Too many connections" error
- "Too many open files" error

**Diagnosis**:

```bash
# 1. Check current connection count
curl http://localhost:3000/metrics | grep active_connections

# 2. Check file descriptor usage
lsof -p $(pgrep zyncbase) | wc -l
# or
cat /proc/$(pgrep zyncbase)/limits | grep "open files"

# 3. Check configured limits
cat /opt/zyncbase/zyncbase-config.json | grep maxConnections

# 4. Monitor connection growth
watch -n 5 'curl -s http://localhost:3000/metrics | grep active_connections'
```

**Solutions**:

1. **Increase file descriptor limits**:
```bash
# Edit /etc/security/limits.conf
zyncbase soft nofile 1048576
zyncbase hard nofile 1048576

# Or in systemd service
[Service]
LimitNOFILE=1048576

# Restart service
systemctl daemon-reload
systemctl restart zyncbase
```

2. **Increase connection limit**:
```bash
# Set environment variable
export MAX_CONNECTIONS=200000

# Or in config
{
  "server": {
    "maxConnections": 200000
  }
}
```

3. **Enable connection recycling**:
```json
{
  "connection": {
    "idleTimeoutSec": 300,
    "maxIdleConnections": 10000
  }
}
```

4. **Check for connection leaks**:
```bash
# Monitor connections over time
while true; do
  echo "$(date): $(curl -s http://localhost:3000/metrics | grep active_connections)"
  sleep 60
done > connection-log.txt

# Analyze for leaks
grep active_connections connection-log.txt
```

---

## Performance Problems

### Issue 5: High Latency

**Symptoms**:
- Message latency > 100ms
- Slow query responses
- Client timeouts

**Diagnosis**:

```bash
# 1. Check latency metrics
curl http://localhost:3000/metrics | grep latency

# 2. Check CPU usage
top -p $(pgrep zyncbase)
mpstat -P ALL 1 10

# 3. Check disk I/O
iostat -x 1 10

# 4. Check memory usage
free -h
vmstat 1 10

# 5. Profile the application
perf record -p $(pgrep zyncbase) -g -- sleep 10
perf report
```

**Solutions**:

1. **CPU bottleneck**:
```bash
# Increase worker threads
export WORKER_THREADS=16

# Check CPU affinity
taskset -cp $(pgrep zyncbase)

# Consider vertical scaling (more CPU cores)
```

2. **Disk I/O bottleneck**:
```bash
# Check WAL size
ls -lh /var/lib/zyncbase/*.db-wal

# Force checkpoint
curl -X POST http://localhost:3000/admin/checkpoint

# Increase SQLite cache
export SQLITE_CACHE_SIZE=-256000  # 256MB

# Use faster storage (NVMe SSD)
```

3. **Memory pressure**:
```bash
# Check for swapping
vmstat 1 10 | grep -E '(si|so)'

# Increase cache size
export CACHE_SIZE=8589934592  # 8GB

# Add more RAM
```

4. **Network congestion**:
```bash
# Check network stats
netstat -s | grep -E '(retransmit|loss)'

# Increase buffer sizes
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
```


### Issue 6: Low Throughput

**Symptoms**:
- Messages/sec below expected
- Cache hit rate low
- Slow subscription notifications

**Diagnosis**:

```bash
# 1. Check throughput metrics
curl http://localhost:3000/metrics | grep -E '(messages_per_second|throughput)'

# 2. Check cache performance
curl http://localhost:3000/metrics | grep -E '(cache_hit_rate|cache_entries)'

# 3. Check subscription performance
curl http://localhost:3000/metrics | grep subscription

# 4. Profile lock contention
perf record -e lock:contention_begin -p $(pgrep zyncbase) -- sleep 10
perf report
```

**Solutions**:

1. **Low cache hit rate**:
```bash
# Increase cache capacity
export CACHE_MAX_ENTRIES=10000

# Increase SQLite cache
export SQLITE_CACHE_SIZE=-512000  # 512MB

# Enable memory-mapped I/O
# Add to SQLite config: PRAGMA mmap_size = 1073741824;
```

2. **Subscription bottleneck**:
```bash
# Check subscription count
curl http://localhost:3000/metrics | grep subscriptions_active

# Optimize filters (use indexed fields)
# Reduce subscription count per connection
# Enable subscription batching
```

3. **Lock contention**:
```bash
# Verify lock-free cache is enabled
curl http://localhost:3000/metrics | grep cache_ref_count

# Check for write mutex contention
perf record -e lock:contention_begin -p $(pgrep zyncbase)
```

4. **MessagePack parsing overhead**:
```bash
# Check parsing metrics
curl http://localhost:3000/metrics | grep msgpack

# Reduce message size
# Use compression
# Batch operations
```

### Issue 7: Memory Usage Growing

**Symptoms**:
- Memory usage increasing over time
- OOM (Out of Memory) errors
- Slow garbage collection

**Diagnosis**:

```bash
# 1. Monitor memory over time
watch -n 10 'ps aux | grep zyncbase | grep -v grep'

# 2. Check memory metrics
curl http://localhost:3000/metrics | grep memory

# 3. Check for leaks
valgrind --leak-check=full --log-file=valgrind.log ./zyncbase-server

# 4. Check cache size
curl http://localhost:3000/metrics | grep cache_memory_bytes

# 5. Check connection buffers
curl http://localhost:3000/metrics | grep -E '(connections|buffers)'
```

**Solutions**:

1. **Cache growing unbounded**:
```bash
# Set cache size limit
export CACHE_MAX_ENTRIES=5000
export CACHE_MAX_MEMORY_BYTES=4294967296  # 4GB

# Enable cache eviction
export CACHE_EVICTION_ENABLED=true
```

2. **Connection buffer accumulation**:
```bash
# Reduce buffer size per connection
export CONNECTION_BUFFER_SIZE=8192

# Enable idle connection cleanup
export CONNECTION_IDLE_TIMEOUT_SEC=300
```

3. **Subscription memory leak**:
```bash
# Check subscription count
curl http://localhost:3000/metrics | grep subscriptions_active

# Enable subscription cleanup
# Ensure unsubscribe is called when connections close
```

4. **Ref count leak**:
```bash
# Check ref counts
curl http://localhost:3000/metrics | grep ref_count

# Enable debug logging
export LOG_LEVEL=debug

# Look for "ref_count not zero" warnings
journalctl -u zyncbase | grep ref_count
```


---

## Database Errors

### Issue 8: Database Corruption

**Symptoms**:
- "DATABASE_CORRUPT" errors
- SQLite integrity check failures
- Crashes on startup

**Diagnosis**:

```bash
# 1. Check database integrity
sqlite3 /var/lib/zyncbase/zyncbase.db "PRAGMA integrity_check;"

# 2. Check for disk errors
dmesg | grep -E '(error|fail)'
smartctl -a /dev/sda

# 3. Check logs for corruption indicators
journalctl -u zyncbase | grep -E '(corrupt|integrity|malformed)'

# 4. Check WAL file
sqlite3 /var/lib/zyncbase/zyncbase.db "PRAGMA wal_checkpoint(FULL);"
```

**Solutions**:

1. **Restore from backup**:
```bash
# Stop server
systemctl stop zyncbase

# Restore database
cp /backups/zyncbase-latest.db /var/lib/zyncbase/zyncbase.db

# Remove WAL files
rm -f /var/lib/zyncbase/zyncbase.db-wal
rm -f /var/lib/zyncbase/zyncbase.db-shm

# Verify integrity
sqlite3 /var/lib/zyncbase/zyncbase.db "PRAGMA integrity_check;"

# Start server
systemctl start zyncbase
```

2. **Attempt recovery** (if no backup):
```bash
# Dump recoverable data
sqlite3 /var/lib/zyncbase/zyncbase.db ".recover" > recovered.sql

# Create new database
mv /var/lib/zyncbase/zyncbase.db /var/lib/zyncbase/zyncbase.db.corrupt
sqlite3 /var/lib/zyncbase/zyncbase.db < recovered.sql

# Verify
sqlite3 /var/lib/zyncbase/zyncbase.db "PRAGMA integrity_check;"
```

3. **Prevent future corruption**:
```bash
# Use synchronous=FULL for critical data
export SQLITE_SYNCHRONOUS=FULL

# Enable checksums
export SQLITE_CHECKSUM_ENABLED=true

# Use UPS for power protection
# Use ECC RAM
# Use enterprise-grade storage
```

### Issue 9: Database Locked

**Symptoms**:
- "DATABASE_LOCKED" errors
- "DATABASE_BUSY" errors
- Write operations timing out

**Diagnosis**:

```bash
# 1. Check for long-running transactions
sqlite3 /var/lib/zyncbase/zyncbase.db "SELECT * FROM pragma_wal_checkpoint(PASSIVE);"

# 2. Check for blocking processes
lsof /var/lib/zyncbase/zyncbase.db

# 3. Check busy timeout setting
sqlite3 /var/lib/zyncbase/zyncbase.db "PRAGMA busy_timeout;"

# 4. Monitor lock contention
curl http://localhost:3000/metrics | grep -E '(lock|busy)'
```

**Solutions**:

1. **Increase busy timeout**:
```bash
# Set longer timeout
export SQLITE_BUSY_TIMEOUT=10000  # 10 seconds

# Or in SQLite
# PRAGMA busy_timeout = 10000;
```

2. **Force checkpoint**:
```bash
# Checkpoint to release locks
curl -X POST http://localhost:3000/admin/checkpoint

# Or manually
sqlite3 /var/lib/zyncbase/zyncbase.db "PRAGMA wal_checkpoint(TRUNCATE);"
```

3. **Kill blocking process**:
```bash
# Find process holding lock
lsof /var/lib/zyncbase/zyncbase.db

# Kill if necessary (last resort)
kill -9 <PID>
```

4. **Optimize write patterns**:
```bash
# Enable write batching
export WRITE_BATCH_SIZE=100
export WRITE_BATCH_DELAY_MS=10

# Use transactions for multiple writes
# Reduce write frequency
```


### Issue 10: WAL File Growing Unbounded

**Symptoms**:
- WAL file > 100 MB
- Disk space running out
- Slow checkpoint operations

**Diagnosis**:

```bash
# 1. Check WAL size
ls -lh /var/lib/zyncbase/*.db-wal

# 2. Check checkpoint metrics
curl http://localhost:3000/metrics | grep checkpoint

# 3. Check for checkpoint failures
journalctl -u zyncbase | grep -E '(checkpoint|failed)'

# 4. Check for long-running readers
sqlite3 /var/lib/zyncbase/zyncbase.db "SELECT * FROM pragma_wal_checkpoint(FULL);"
```

**Solutions**:

1. **Reduce checkpoint threshold**:
```bash
# Checkpoint more frequently
export WAL_SIZE_THRESHOLD=5242880  # 5MB
export CHECKPOINT_INTERVAL_SEC=60  # 1 minute

# Restart service
systemctl restart zyncbase
```

2. **Use aggressive checkpoint mode**:
```bash
# Switch to TRUNCATE mode
export CHECKPOINT_MODE=truncate

# Or manually trigger
curl -X POST http://localhost:3000/admin/checkpoint?mode=truncate
```

3. **Check for blocking readers**:
```bash
# Find long-running connections
curl http://localhost:3000/metrics | grep connection_duration

# Enable connection timeout
export CONNECTION_MAX_DURATION_SEC=3600  # 1 hour
```

4. **Verify checkpoint thread is running**:
```bash
# Check logs for checkpoint activity
journalctl -u zyncbase | grep checkpoint | tail -20

# Verify background thread
ps aux | grep zyncbase | grep checkpoint
```

---

## Hook Server Issues

### Issue 11: Hook Server Unavailable

**Symptoms**:
- "HOOK_SERVER_UNAVAILABLE" errors
- Authorization failures
- Circuit breaker open

**Diagnosis**:

```bash
# 1. Check Hook Server status
systemctl status zyncbase-hooks
docker ps | grep hook-server

# 2. Check Hook Server metrics
curl http://localhost:3000/metrics | grep hook_server

# 3. Test Hook Server directly
curl http://localhost:3001/health

# 4. Check Hook Server logs
journalctl -u zyncbase-hooks -n 100
docker logs zyncbase-hook-server --tail 100

# 5. Check network connectivity
telnet localhost 3001
nc -zv localhost 3001
```

**Solutions**:

1. **Start Hook Server**:
```bash
# Start service
systemctl start zyncbase-hooks
# or
docker-compose up -d hook-server
```

2. **Verify Hook Server is running**:
```bash
# The Hook Server is automatically managed by ZyncBase CLI
# Check if it's running by looking at the health endpoint
curl http://localhost:3000/health | jq '.hook_server'

# Check ZyncBase logs for Hook Server connection status
journalctl -u zyncbase | grep "hook.*server"
docker logs zyncbase | grep "hook.*server"
```

3. **Restart ZyncBase** (which will restart the Hook Server):
```bash
# The Hook Server is bundled with ZyncBase
systemctl restart zyncbase
# or
docker-compose restart zyncbase
```

4. **Reset circuit breaker**:
```bash
# Wait for automatic recovery (60s default)
# Or restart ZyncBase to reset
systemctl restart zyncbase
```


### Issue 12: Hook Server Timeouts

**Symptoms**:
- Authorization requests timing out
- "Timeout" errors in logs
- Circuit breaker opening frequently

**Diagnosis**:

```bash
# 1. Check authorization latency
curl http://localhost:3000/metrics | grep authorization_latency

# 2. Check Hook Server performance
curl http://localhost:3001/metrics

# 3. Profile Hook Server
# Add profiling to hook code
console.time('authorization')
// ... hook logic ...
console.timeEnd('authorization')

# 4. Check for slow database queries in hooks
# Enable query logging in hook code
```

**Solutions**:

1. **Optimize hook code**:
```typescript
// Cache expensive operations
const cache = new Map()

export async function authorize(req: AuthRequest) {
  const cacheKey = `${req.userId}:${req.namespace}:${req.operation}`
  
  if (cache.has(cacheKey)) {
    return cache.get(cacheKey)
  }
  
  const result = await checkPermission(req)
  
  // Cache for 5 minutes
  cache.set(cacheKey, result)
  setTimeout(() => cache.delete(cacheKey), 300000)
  
  return result
}
```

2. **Optimize database queries in hooks**:
```typescript
// Use indexes, avoid N+1 queries, batch operations
// The Hook Server has access to the same ZyncBase client as your frontend
// but with admin privileges - use it efficiently
```

3. **Enable authorization caching**:
```typescript
// Return cache TTL in response
return {
  allowed: true,
  cache_ttl_sec: 300  // Cache for 5 minutes
}
```

4. **Reduce external API calls**:
```typescript
// Batch API calls
// Use local caching
// Avoid synchronous HTTP requests
```

### Issue 13: Hook Server Circuit Breaker Open

**Symptoms**:
- "CIRCUIT_BREAKER_OPEN" errors
- All authorization requests failing
- Hook Server appears healthy

**Diagnosis**:

```bash
# 1. Check circuit breaker state
curl http://localhost:3000/metrics | grep circuit_breaker_state

# 2. Check failure count
curl http://localhost:3000/metrics | grep hook_server_failures

# 3. Check recent errors
journalctl -u zyncbase | grep -E '(HOOK|circuit)' | tail -50

# 4. Verify Hook Server is actually healthy
curl http://localhost:3001/health
```

**Solutions**:

1. **Wait for automatic recovery**:
```bash
# Circuit breaker will transition to half-open after timeout (60s default)
# Monitor state
watch -n 5 'curl -s http://localhost:3000/metrics | grep circuit_breaker_state'
```

2. **Circuit breaker settings are managed internally**: The Hook Server circuit breaker is automatically configured by ZyncBase. If you're experiencing frequent circuit breaker openings, focus on fixing the underlying Hook Server issues (slow queries, errors in hook code, etc.).

4. **Fix underlying Hook Server issues**:
```bash
# Check Hook Server logs for errors
journalctl -u zyncbase-hooks | grep error

# Fix hook code bugs
# Optimize slow operations
# Add error handling
```

---

## Memory Issues

### Issue 14: Out of Memory (OOM)

**Symptoms**:
- Process killed by OOM killer
- "Cannot allocate memory" errors
- System becomes unresponsive

**Diagnosis**:

```bash
# 1. Check OOM killer logs
dmesg | grep -E '(oom|killed)'
journalctl -k | grep -E '(oom|killed)'

# 2. Check memory usage
free -h
ps aux --sort=-%mem | head -10

# 3. Check memory limits
cat /proc/$(pgrep zyncbase)/limits | grep "Max address space"

# 4. Check for memory leaks
valgrind --leak-check=full ./zyncbase-server
```

**Solutions**:

1. **Add more RAM**:
```bash
# Upgrade server memory
# Or use a larger instance type
```

2. **Reduce memory usage**:
```bash
# Reduce cache size
export CACHE_MAX_MEMORY_BYTES=2147483648  # 2GB
export SQLITE_CACHE_SIZE=-128000  # 128MB

# Reduce connection limit
export MAX_CONNECTIONS=50000

# Reduce buffer sizes
export CONNECTION_BUFFER_SIZE=4096
```

3. **Enable memory limits**:
```bash
# Set memory limit in systemd
[Service]
MemoryLimit=8G
MemoryMax=8G

# Or in Docker
docker run --memory=8g ...
```

4. **Fix memory leaks**:
```bash
# Enable leak detection
export ASAN_OPTIONS=detect_leaks=1

# Run with sanitizers
zig build -Dsanitize=address,leak

# Fix identified leaks in code
```


---

## Debug Mode and Logging

### Enabling Debug Mode

Debug mode provides detailed logging for troubleshooting:

**Method 1: Environment Variable**
```bash
# Enable debug logging
export LOG_LEVEL=debug

# Restart service
systemctl restart zyncbase
```

**Method 2: Configuration File**
```json
{
  "logging": {
    "level": "debug",
    "format": "json"
  }
}
```

**Method 3: Runtime (if supported)**
```bash
# Change log level without restart
curl -X POST http://localhost:3000/admin/log-level -d '{"level":"debug"}'
```

### Log Levels

| Level | Description | Use Case |
|-------|-------------|----------|
| `debug` | Verbose logging of all operations | Development, troubleshooting |
| `info` | Normal operational messages | Production default |
| `warn` | Warning messages, non-critical issues | Production |
| `error` | Error messages only | Minimal logging |

### Debug Logging Output

When debug mode is enabled, you'll see:

```json
{
  "timestamp": "2026-03-09T10:30:00.123Z",
  "level": "debug",
  "message": "Cache get operation",
  "namespace": "room:abc-123",
  "cache_hit": true,
  "ref_count": 3,
  "latency_ns": 87
}

{
  "timestamp": "2026-03-09T10:30:00.125Z",
  "level": "debug",
  "message": "MessagePack parse",
  "message_type": "store.set",
  "message_size": 1024,
  "parse_time_us": 45
}

{
  "timestamp": "2026-03-09T10:30:00.130Z",
  "level": "debug",
  "message": "Subscription match",
  "namespace": "room:abc-123",
  "collection": "tasks",
  "matched_subscriptions": 5,
  "match_time_us": 234
}
```

### Selective Debug Logging

Enable debug logging for specific components:

```bash
# Debug only cache operations
export LOG_LEVEL=info
export LOG_CACHE=debug

# Debug only Hook Server
export LOG_HOOK_SERVER=debug

# Debug only subscriptions
export LOG_SUBSCRIPTIONS=debug

# Debug only database operations
export LOG_DATABASE=debug
```

### Log Rotation

Configure log rotation to prevent disk space issues:

**Using logrotate:**
```bash
# Create /etc/logrotate.d/zyncbase
/var/log/zyncbase/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 zyncbase zyncbase
    sharedscripts
    postrotate
        systemctl reload zyncbase
    endscript
}
```

**Using Docker:**
```yaml
services:
  zyncbase:
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "10"
```

---

## Log Analysis

### Finding Errors

```bash
# Find all errors in last hour
journalctl -u zyncbase --since "1 hour ago" | grep -E '(ERROR|error)'

# Find specific error codes
journalctl -u zyncbase | grep "DATABASE_CORRUPT"

# Count errors by type
journalctl -u zyncbase | grep error | awk '{print $5}' | sort | uniq -c | sort -rn
```

### Analyzing Connection Issues

```bash
# Find connection failures
journalctl -u zyncbase | grep -E '(disconnect|connection.*failed|close)'

# Track connection lifecycle
journalctl -u zyncbase | grep -E '(connected|disconnected)' | tail -50

# Find rate limit violations
journalctl -u zyncbase | grep "RATE_LIMITED"
```

### Analyzing Performance Issues

```bash
# Find slow operations (> 100ms)
journalctl -u zyncbase | grep -E 'latency.*[0-9]{3,}ms'

# Find checkpoint operations
journalctl -u zyncbase | grep checkpoint

# Find cache misses
journalctl -u zyncbase | grep "cache_hit.*false"
```

### Analyzing Hook Server Issues

```bash
# Find Hook Server errors
journalctl -u zyncbase | grep -E '(HOOK|authorization.*failed)'

# Find circuit breaker events
journalctl -u zyncbase | grep "circuit_breaker"

# Find authorization timeouts
journalctl -u zyncbase | grep "authorization.*timeout"
```

### Log Aggregation

For production deployments, use log aggregation:

**Using Loki + Grafana:**
```yaml
# docker-compose.yml
services:
  loki:
    image: grafana/loki:latest
    ports:
      - "3100:3100"
    volumes:
      - ./loki-config.yaml:/etc/loki/local-config.yaml
      
  promtail:
    image: grafana/promtail:latest
    volumes:
      - /var/log:/var/log
      - ./promtail-config.yaml:/etc/promtail/config.yml
    command: -config.file=/etc/promtail/config.yml
```

**Using ELK Stack:**
```bash
# Ship logs to Elasticsearch
filebeat -e -c filebeat.yml
```

### Log Queries

**Find errors in specific namespace:**
```bash
journalctl -u zyncbase | grep "namespace.*room:abc-123" | grep error
```

**Find slow queries:**
```bash
journalctl -u zyncbase | awk '/query_time/ && $NF > 100 {print}'
```

**Track user activity:**
```bash
journalctl -u zyncbase | grep "user_id.*user-123"
```


---

## Performance Debugging

### CPU Profiling

**Using perf (Linux):**
```bash
# Record CPU profile
perf record -p $(pgrep zyncbase) -g -- sleep 30

# Generate report
perf report

# Generate flamegraph
perf script | stackcollapse-perf.pl | flamegraph.pl > flamegraph.svg
```

**Using built-in profiler:**
```bash
# Enable CPU profiling
export ENABLE_CPU_PROFILING=true

# Profile for 60 seconds
curl -X POST http://localhost:3000/admin/profile/cpu?duration=60

# Download profile
curl http://localhost:3000/admin/profile/cpu/latest > cpu-profile.pb.gz
```

### Memory Profiling

**Using Valgrind:**
```bash
# Memory leak detection
valgrind --leak-check=full --log-file=valgrind.log ./zyncbase-server

# Memory profiling
valgrind --tool=massif ./zyncbase-server
ms_print massif.out.12345
```

**Using built-in profiler:**
```bash
# Enable memory profiling
export ENABLE_MEMORY_PROFILING=true

# Take heap snapshot
curl -X POST http://localhost:3000/admin/profile/memory

# Download snapshot
curl http://localhost:3000/admin/profile/memory/latest > heap-snapshot.pb.gz
```

### Lock Contention Analysis

```bash
# Record lock contention
perf record -e lock:contention_begin -p $(pgrep zyncbase) -- sleep 30

# Analyze results
perf report

# Check for mutex contention
perf record -e syscalls:sys_enter_futex -p $(pgrep zyncbase) -- sleep 30
```

### I/O Profiling

```bash
# Monitor disk I/O
iostat -x 1 10

# Trace system calls
strace -p $(pgrep zyncbase) -e trace=read,write,open,close -c

# Monitor file access
inotifywatch -v -t 60 /var/lib/zyncbase/

# Check for slow I/O
iotop -p $(pgrep zyncbase)
```

### Network Profiling

```bash
# Monitor network traffic
iftop -i eth0 -f "port 3000"

# Capture packets
tcpdump -i eth0 -w capture.pcap port 3000

# Analyze WebSocket traffic
wireshark capture.pcap

# Monitor connection states
netstat -an | grep 3000 | awk '{print $6}' | sort | uniq -c
```

### Database Profiling

```bash
# Enable SQLite query logging
export SQLITE_TRACE=true

# Analyze query performance
sqlite3 /var/lib/zyncbase/zyncbase.db "EXPLAIN QUERY PLAN SELECT ..."

# Check index usage
sqlite3 /var/lib/zyncbase/zyncbase.db ".schema"
sqlite3 /var/lib/zyncbase/zyncbase.db "ANALYZE;"

# Monitor database operations
strace -p $(pgrep zyncbase) -e trace=read,write -f 2>&1 | grep zyncbase.db
```

### Benchmarking Tools

**Load testing:**
```bash
# Install load testing tool
npm install -g zyncbase-loadtest

# Run benchmark
zyncbase-loadtest \
  --url ws://localhost:3000 \
  --connections 10000 \
  --duration 60s \
  --message-rate 10 \
  --report benchmark-report.html
```

**Cache benchmark:**
```bash
# Build and run cache benchmark
zig build benchmark-cache
./zig-out/bin/benchmark-cache --threads=16 --duration=30s
```

**Parser benchmark:**
```bash
# Build and run parser benchmark
zig build benchmark-msgpack
./zig-out/bin/benchmark-msgpack --size=10kb --duration=30s
```

---

## Common Error Messages

### Error: "Connection refused"

**Meaning**: Cannot connect to ZyncBase server

**Causes**:
- Server not running
- Wrong port or host
- Firewall blocking connection

**Solution**: See [Issue 1: Clients Cannot Connect](#issue-1-clients-cannot-connect)

### Error: "AUTH_FAILED"

**Meaning**: Authentication failed

**Causes**:
- Invalid JWT token
- JWT secret mismatch
- Token expired
- Missing required claims

**Solution**: See [Issue 3: Authentication Failures](#issue-3-authentication-failures)

### Error: "PERMISSION_DENIED"

**Meaning**: Authorization failed

**Causes**:
- User lacks permission
- Hook Server denied access
- Invalid namespace access

**Solution**: Check authorization rules in `auth.json` or Hook Server code

### Error: "RATE_LIMITED"

**Meaning**: Rate limit exceeded

**Causes**:
- Too many messages per second
- Too many connections from IP

**Solution**:
```bash
# Increase rate limits
export RATE_LIMIT_MESSAGES_PER_SEC=200
export RATE_LIMIT_CONNECTIONS_PER_IP=20
```

### Error: "MSGPACK_MAX_DEPTH_EXCEEDED"

**Meaning**: Message nesting too deep

**Causes**:
- Deeply nested JSON structure
- Malicious payload

**Solution**:
```bash
# Increase limit (if legitimate)
export MSGPACK_MAX_DEPTH=64

# Or flatten data structure
```

### Error: "DATABASE_BUSY"

**Meaning**: Database is locked

**Causes**:
- Long-running transaction
- Checkpoint in progress
- Multiple writers

**Solution**: See [Issue 9: Database Locked](#issue-9-database-locked)

### Error: "DATABASE_CORRUPT"

**Meaning**: Database corruption detected

**Causes**:
- Disk failure
- Power loss
- Software bug

**Solution**: See [Issue 8: Database Corruption](#issue-8-database-corruption)

### Error: "HOOK_SERVER_UNAVAILABLE"

**Meaning**: Cannot connect to Hook Server

**Causes**:
- Hook Server not running
- Wrong URL
- Network issue

**Solution**: See [Issue 11: Hook Server Unavailable](#issue-11-hook-server-unavailable)

### Error: "CIRCUIT_BREAKER_OPEN"

**Meaning**: Circuit breaker protecting against failures

**Causes**:
- Too many Hook Server failures
- Hook Server slow or unresponsive

**Solution**: See [Issue 13: Hook Server Circuit Breaker Open](#issue-13-hook-server-circuit-breaker-open)

### Error: "CACHE_REF_COUNT_OVERFLOW"

**Meaning**: Too many concurrent readers

**Causes**:
- Bug in ref counting
- Extremely high concurrency

**Solution**:
```bash
# This indicates a bug - report to developers
# Temporary workaround: restart server
systemctl restart zyncbase
```

### Error: "WAL_SIZE_EXCEEDED"

**Meaning**: WAL file too large

**Causes**:
- Checkpoint not running
- Long-running readers
- High write rate

**Solution**: See [Issue 10: WAL File Growing Unbounded](#issue-10-wal-file-growing-unbounded)


---

## Advanced Troubleshooting

### Core Dumps

Enable core dumps for crash analysis:

```bash
# Enable core dumps
ulimit -c unlimited

# Set core dump pattern
echo "/var/crash/core.%e.%p.%t" | sudo tee /proc/sys/kernel/core_pattern

# Configure systemd to save core dumps
mkdir -p /var/crash
chown zyncbase:zyncbase /var/crash

# Add to systemd service
[Service]
LimitCORE=infinity
```

**Analyzing core dumps:**
```bash
# Load core dump in gdb
gdb /opt/zyncbase/zyncbase-server /var/crash/core.zyncbase.12345.1234567890

# Get backtrace
(gdb) bt full

# Examine variables
(gdb) info locals
(gdb) print variable_name
```

### Debugging with GDB

```bash
# Attach to running process
gdb -p $(pgrep zyncbase)

# Set breakpoint
(gdb) break main.zig:123

# Continue execution
(gdb) continue

# Step through code
(gdb) step
(gdb) next

# Print variables
(gdb) print my_variable

# Detach
(gdb) detach
(gdb) quit
```

### System Call Tracing

```bash
# Trace all system calls
strace -p $(pgrep zyncbase) -f -o strace.log

# Trace specific calls
strace -p $(pgrep zyncbase) -e trace=open,read,write,close

# Count system calls
strace -p $(pgrep zyncbase) -c

# Trace with timestamps
strace -p $(pgrep zyncbase) -tt -T
```

### Network Debugging

**Test WebSocket connection:**
```bash
# Using websocat
websocat ws://localhost:3000

# Using wscat
wscat -c ws://localhost:3000

# Send test message
{"type":"ping"}
```

**Capture WebSocket traffic:**
```bash
# Capture packets
tcpdump -i any -s 0 -w websocket.pcap port 3000

# Analyze in Wireshark
wireshark websocket.pcap

# Filter WebSocket frames
tcp.port == 3000 && websocket
```

**Test TLS/SSL:**
```bash
# Test SSL connection
openssl s_client -connect localhost:3000 -servername localhost

# Check certificate
openssl x509 -in /opt/zyncbase/ssl/cert.pem -text -noout

# Verify certificate chain
openssl verify -CAfile /opt/zyncbase/ssl/ca.pem /opt/zyncbase/ssl/cert.pem
```

### Database Debugging

**Analyze database:**
```bash
# Check database size
du -h /var/lib/zyncbase/zyncbase.db*

# Analyze tables
sqlite3 /var/lib/zyncbase/zyncbase.db "ANALYZE;"

# Check fragmentation
sqlite3 /var/lib/zyncbase/zyncbase.db "PRAGMA freelist_count;"

# Vacuum database (offline only)
systemctl stop zyncbase
sqlite3 /var/lib/zyncbase/zyncbase.db "VACUUM;"
systemctl start zyncbase
```

**Query performance:**
```bash
# Explain query plan
sqlite3 /var/lib/zyncbase/zyncbase.db "EXPLAIN QUERY PLAN SELECT * FROM state WHERE namespace = 'room:abc';"

# Enable query timing
sqlite3 /var/lib/zyncbase/zyncbase.db ".timer on"

# Run query
sqlite3 /var/lib/zyncbase/zyncbase.db "SELECT * FROM state WHERE namespace = 'room:abc';"
```

### Monitoring Scripts

**Connection monitor:**
```bash
#!/bin/bash
# monitor-connections.sh

while true; do
  CONNECTIONS=$(curl -s http://localhost:3000/metrics | grep active_connections | awk '{print $2}')
  TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
  echo "$TIMESTAMP: $CONNECTIONS connections"
  
  if [ "$CONNECTIONS" -gt 90000 ]; then
    echo "WARNING: High connection count!"
    # Send alert
  fi
  
  sleep 10
done
```

**Performance monitor:**
```bash
#!/bin/bash
# monitor-performance.sh

while true; do
  echo "=== $(date) ==="
  
  # CPU usage
  echo "CPU: $(top -bn1 | grep zyncbase | awk '{print $9}')%"
  
  # Memory usage
  echo "Memory: $(ps aux | grep zyncbase | awk '{print $4}')%"
  
  # Latency
  LATENCY=$(curl -s http://localhost:3000/metrics | grep message_latency | awk '{print $2}')
  echo "Latency: ${LATENCY}ms"
  
  # Cache hit rate
  HIT_RATE=$(curl -s http://localhost:3000/metrics | grep cache_hit_rate | awk '{print $2}')
  echo "Cache hit rate: ${HIT_RATE}"
  
  echo ""
  sleep 60
done
```

**Health check script:**
```bash
#!/bin/bash
# health-check.sh

# Check if server is responding
if ! curl -f http://localhost:3000/health > /dev/null 2>&1; then
  echo "ERROR: Health check failed"
  
  # Try to restart
  systemctl restart zyncbase
  
  # Wait for startup
  sleep 10
  
  # Check again
  if ! curl -f http://localhost:3000/health > /dev/null 2>&1; then
    echo "CRITICAL: Restart failed"
    # Send alert
    exit 1
  fi
  
  echo "INFO: Service restarted successfully"
fi

echo "OK: Service healthy"
```

---

## Getting Help

### Before Asking for Help

Collect this information:

1. **System Information**:
```bash
# OS and kernel
uname -a
cat /etc/os-release

# ZyncBase version
./zyncbase-server --version
docker exec zyncbase zyncbase-server --version

# Hardware specs
lscpu
free -h
df -h
```

2. **Configuration**:
```bash
# Configuration files
cat /opt/zyncbase/zyncbase-config.json

# Environment variables
docker exec zyncbase env | grep ZYNCBASE
```

3. **Logs**:
```bash
# Recent logs
journalctl -u zyncbase -n 500 --no-pager > zyncbase-logs.txt
docker logs zyncbase --tail 500 > zyncbase-logs.txt
```

4. **Metrics**:
```bash
# Current metrics
curl http://localhost:3000/metrics > zyncbase-metrics.txt
```

5. **Health Status**:
```bash
# Health check
curl http://localhost:3000/health > zyncbase-health.json
```

### Support Channels

- **GitHub Issues**: https://github.com/zyncbase/zyncbase/issues
- **Community Forum**: https://community.zyncbase.io
- **Discord**: https://discord.gg/zyncbase
- **Email**: support@zyncbase.io

### Issue Template

When reporting issues, use this template:

```markdown
## Description
Brief description of the issue

## Environment
- OS: Ubuntu 22.04
- ZyncBase Version: 1.0.0
- Deployment: Docker / Binary / Kubernetes
- Hardware: 16 CPU cores, 32GB RAM, NVMe SSD

## Steps to Reproduce
1. Start server with config X
2. Connect 10k clients
3. Send messages at rate Y
4. Observe error Z

## Expected Behavior
What should happen

## Actual Behavior
What actually happens

## Logs
```
Paste relevant logs here
```

## Metrics
```
Paste relevant metrics here
```

## Additional Context
Any other relevant information
```

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT.md) - Deployment instructions
- [Performance Tuning](./PERFORMANCE_TUNING.md) - Optimization guide
- [Error Taxonomy](./ERROR_TAXONOMY.md) - Complete error reference
- [Security Guide](./SECURITY.md) - Security best practices
- [Configuration Reference](./CONFIGURATION.md) - Configuration options

---

## Troubleshooting Checklist

Use this checklist when troubleshooting issues:

### Initial Checks
- [ ] Server is running (`systemctl status` or `docker ps`)
- [ ] Health endpoint returns 200 (`curl /health`)
- [ ] No errors in recent logs
- [ ] Disk space available (> 10% free)
- [ ] Memory available (< 90% used)
- [ ] CPU not maxed out (< 90% used)

### Connection Issues
- [ ] Port is listening (`netstat -tlnp`)
- [ ] Firewall allows connections
- [ ] TLS/SSL configured correctly (if enabled)
- [ ] Authentication working (valid JWT)
- [ ] Rate limits not exceeded

### Performance Issues
- [ ] Cache hit rate > 80%
- [ ] Message latency < 100ms (p99)
- [ ] No lock contention
- [ ] WAL file < 10MB
- [ ] Checkpoint running regularly
- [ ] No memory leaks

### Database Issues
- [ ] Database integrity check passes
- [ ] No "DATABASE_BUSY" errors
- [ ] WAL mode enabled
- [ ] Checkpoint threshold configured
- [ ] No long-running transactions

### Hook Server Issues
- [ ] Hook Server running (check health endpoint)
- [ ] Hook Server connected (check health endpoint)
- [ ] Circuit breaker closed
- [ ] Authorization latency < 5ms
- [ ] No timeout errors
- [ ] Hook functions have no errors

### Next Steps
- [ ] Reviewed relevant documentation
- [ ] Collected diagnostic information
- [ ] Attempted suggested solutions
- [ ] Ready to ask for help (if needed)

