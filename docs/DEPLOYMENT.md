# ZyncBase Deployment Guide

**Last Updated**: 2026-03-09

Complete guide to deploying ZyncBase in production.

---

## Table of Contents

1. [Deployment Options](#deployment-options)
2. [Docker Deployment](#docker-deployment)
3. [Binary Deployment](#binary-deployment)
4. [Production Best Practices](#production-best-practices)
5. [Security](#security)
6. [Monitoring](#monitoring)
7. [Troubleshooting](#troubleshooting)

---

## Deployment Options

ZyncBase can be deployed in multiple ways:

1. **Docker** - Recommended for most use cases
2. **Binary** - Direct binary deployment on VPS
3. **Kubernetes** - For enterprise deployments
4. **Systemd** - For Linux servers

---

## Docker Deployment

### Basic Dockerfile

```dockerfile
FROM zyncbase/server:latest

COPY zyncbase-config.json /config/
COPY schema.json /config/
COPY auth.json /config/

EXPOSE 3000

CMD ["zyncbase-server", "--config", "/config/zyncbase-config.json"]
```

### Build and Run

```bash
# Build
docker build -t my-zyncbase-server .

# Run
docker run -p 3000:3000 -v $(pwd)/data:/data my-zyncbase-server
```

### Docker Compose

Complete production-ready docker-compose.yml with all services:

```yaml
version: '3.8'

services:
  zyncbase:
    image: zyncbase/server:latest
    ports:
      - "3000:3000"
    volumes:
      - ./config:/config
      - ./data:/data
      - ./hooks:/hooks
    environment:
      # Authentication
      - JWT_SECRET=${JWT_SECRET}
      
      # Server Configuration
      - ZYNCBASE_PORT=3000
      - ZYNCBASE_HOST=0.0.0.0
      - ZYNCBASE_ENV=production
      
      # Database Configuration
      - DB_PATH=/data/zyncbase.db
      - WAL_SIZE_THRESHOLD=10485760
      - CHECKPOINT_INTERVAL_SEC=300
      
      # Security
      - MAX_CONNECTIONS=100000
      - RATE_LIMIT_MESSAGES_PER_SEC=100
      - RATE_LIMIT_CONNECTIONS_PER_IP=10
      - MAX_MESSAGE_SIZE=10485760
      
      # MessagePack Parser Limits
      - MSGPACK_MAX_DEPTH=32
      - MSGPACK_MAX_SIZE=10485760
      - MSGPACK_MAX_STRING_LENGTH=1048576
      - MSGPACK_MAX_ARRAY_LENGTH=100000
      - MSGPACK_MAX_MAP_SIZE=100000
      
      # Note: Hook Server is automatically managed by ZyncBase CLI
      # No configuration needed - write auth logic in zyncbase.auth.ts
      
      # TLS Configuration (optional)
      - TLS_ENABLED=false
      - TLS_CERT_PATH=/config/ssl/cert.pem
      - TLS_KEY_PATH=/config/ssl/key.pem
      
      # Logging
      - LOG_LEVEL=info
      - LOG_FORMAT=json
      
      # Monitoring
      - METRICS_ENABLED=true
      - METRICS_PORT=9090
      
    command: ["zyncbase-server", "--config", "/config/zyncbase-config.json"]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    
**Note**: The Hook Server shown in the docker-compose example is automatically managed by ZyncBase. The environment variables shown (HOOK_SERVER_PORT, HOOKS_DIR, HOT_RELOAD) are internal to the bundled Hook Server and don't need to be configured by developers. You only need to write your hook functions in `zyncbase.auth.ts`.
    
  # Optional: Nginx reverse proxy
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./ssl:/etc/nginx/ssl
    depends_on:
      - zyncbase
    restart: unless-stopped
    
  # Optional: Prometheus for metrics
  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9091:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    restart: unless-stopped
    
  # Optional: Grafana for visualization
  grafana:
    image: grafana/grafana:latest
    ports:
      - "3001:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
    restart: unless-stopped
    depends_on:
      - prometheus

volumes:
  prometheus-data:
  grafana-data:
```

### Run with Docker Compose

```bash
# Single command deployment
docker-compose up -d

# View logs
docker-compose logs -f zyncbase

# Stop services
docker-compose down

# Stop and remove volumes (WARNING: deletes data)
docker-compose down -v
```

---

## Environment Variables Reference

Complete list of all environment variables supported by ZyncBase:

### Authentication & Security

| Variable | Default | Description |
|----------|---------|-------------|
| `JWT_SECRET` | *required* | Secret key for JWT token validation |
| `TLS_ENABLED` | `false` | Enable TLS/SSL for WebSocket connections |
| `TLS_CERT_PATH` | - | Path to TLS certificate file |
| `TLS_KEY_PATH` | - | Path to TLS private key file |

### Server Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ZYNCBASE_PORT` | `3000` | Port for WebSocket server |
| `ZYNCBASE_HOST` | `0.0.0.0` | Host address to bind to |
| `ZYNCBASE_ENV` | `development` | Environment: `development`, `production` |
| `MAX_CONNECTIONS` | `100000` | Maximum concurrent WebSocket connections |

### Database Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_PATH` | `./data/zyncbase.db` | Path to SQLite database file |
| `WAL_SIZE_THRESHOLD` | `10485760` | WAL size threshold for checkpoint (10MB) |
| `CHECKPOINT_INTERVAL_SEC` | `300` | Time interval for checkpoints (5 minutes) |
| `CHECKPOINT_MODE` | `passive` | Checkpoint mode: `passive`, `full`, `truncate` |

### Rate Limiting

| Variable | Default | Description |
|----------|---------|-------------|
| `RATE_LIMIT_MESSAGES_PER_SEC` | `100` | Max messages per second per connection |
| `RATE_LIMIT_CONNECTIONS_PER_IP` | `10` | Max connections per IP address |
| `MAX_MESSAGE_SIZE` | `10485760` | Maximum message size in bytes (10MB) |

### MessagePack Parser Security Limits

| Variable | Default | Description |
|----------|---------|-------------|
| `MSGPACK_MAX_DEPTH` | `32` | Maximum nesting depth for MessagePack |
| `MSGPACK_MAX_SIZE` | `10485760` | Maximum message size (10MB) |
| `MSGPACK_MAX_STRING_LENGTH` | `1048576` | Maximum string length (1MB) |
| `MSGPACK_MAX_ARRAY_LENGTH` | `100000` | Maximum array length |
| `MSGPACK_MAX_MAP_SIZE` | `100000` | Maximum map size |

### Hook Server

**Note**: The Hook Server is automatically managed by the ZyncBase CLI. You don't configure it via environment variables. Instead:

1. Write authorization logic in `zyncbase.auth.ts`
2. Run `zyncbase dev` or `zyncbase start` - the CLI automatically spins up the Hook Server
3. The Hook Server connects to the Zig core via internal IPC/WebSocket

See [AUTH_SPEC.md](./AUTH_SPEC.md) and [AUTH_EXCHANGE.md](./AUTH_EXCHANGE.md) for details on writing Hook Server functions.

### Logging

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_LEVEL` | `info` | Log level: `debug`, `info`, `warn`, `error` |
| `LOG_FORMAT` | `json` | Log format: `json`, `text` |

### Monitoring

| Variable | Default | Description |
|----------|---------|-------------|
| `METRICS_ENABLED` | `true` | Enable Prometheus metrics endpoint |
| `METRICS_PORT` | `9090` | Port for metrics endpoint |

### Example .env File

```bash
# .env (add to .gitignore)

# Authentication
JWT_SECRET=your-secret-key-here-change-in-production

# Server
ZYNCBASE_PORT=3000
ZYNCBASE_ENV=production
MAX_CONNECTIONS=100000

# Database
DB_PATH=/data/zyncbase.db
WAL_SIZE_THRESHOLD=10485760
CHECKPOINT_INTERVAL_SEC=300

# Security
RATE_LIMIT_MESSAGES_PER_SEC=100
RATE_LIMIT_CONNECTIONS_PER_IP=10
MAX_MESSAGE_SIZE=10485760

# Hook Server
# Logging
LOG_LEVEL=info
LOG_FORMAT=json

# Monitoring
METRICS_ENABLED=true
METRICS_PORT=9090

# Note: Hook Server is automatically managed by CLI
# No environment variables needed - write logic in zyncbase.auth.ts
```

---

## Hook Server (Automatic Management)

ZyncBase includes a bundled Hook Server that runs alongside the main server, providing authorization and custom hook functionality without requiring separate deployment or management.

### Overview

The Hook Server is a Bun-based TypeScript runtime that:
- **Automatically starts** when ZyncBase starts (no separate deployment needed)
- **Hot-reloads** hook files when you add or modify them
- **Communicates** with ZyncBase via localhost WebSocket connection
- **Runs custom logic** for authorization, validation, and event hooks

### Architecture

```
┌─────────────────────────────────────────┐
│         ZyncBase Container              │
│                                         │
│  ┌──────────────┐    ┌──────────────┐  │
│  │  ZyncBase    │◄──►│ Hook Server  │  │
│  │  Core        │    │ (Bun)        │  │
│  │  (Port 3000) │    │ (Port 3001)  │  │
│  └──────────────┘    └──────────────┘  │
│         │                    │          │
│         │                    │          │
│         ▼                    ▼          │
│  ┌──────────────┐    ┌──────────────┐  │
│  │   SQLite     │    │  /hooks/*.ts │  │
│  │   Database   │    │  TypeScript  │  │
│  └──────────────┘    └──────────────┘  │
└─────────────────────────────────────────┘
```

### Quick Start

**1. Create a hooks directory:**

```bash
mkdir -p ./hooks
```

**2. Add a hook file:**

Create `./hooks/auth.ts`:

```typescript
// Authorization hook - called before every write operation
export async function authorize(request: AuthRequest): Promise<AuthResponse> {
  const { userId, namespace, operation, resource } = request;
  
  // Example: Only allow users to write to their own namespace
  if (namespace !== `user:${userId}`) {
    return {
      allowed: false,
      reason: "Cannot write to other users' namespaces",
      cacheTtlSec: 60
    };
  }
  
  // Allow the operation
  return {
    allowed: true,
    cacheTtlSec: 300 // Cache this decision for 5 minutes
  };
}

// Types
interface AuthRequest {
  userId: string;
  namespace: string;
  operation: 'read' | 'write' | 'delete' | 'subscribe';
  resource: string;
}

interface AuthResponse {
  allowed: boolean;
  reason?: string;
  cacheTtlSec: number;
}
```

**3. Start ZyncBase:**

```bash
docker-compose up -d
```

That's it! The Hook Server automatically:
- Discovers your `auth.ts` file
- Loads and compiles it
- Makes it available for authorization requests
- Hot-reloads when you modify the file

### Hook File Locations

Place your TypeScript hook files in the configured hooks directory:

**Docker:**
```yaml
services:
  zyncbase:
    volumes:
      - ./hooks:/hooks  # Mount your hooks directory
    environment:
      - HOOKS_DIR=/hooks
```

**Binary:**
```bash
./zyncbase-server --hooks-dir ./hooks
```

**Systemd:**
```ini
[Service]
Environment="HOOKS_DIR=/opt/zyncbase/hooks"
```

### Hook Types

#### 1. Authorization Hooks

Control access to read/write operations:

```typescript
// hooks/auth.ts
export async function authorize(request: AuthRequest): Promise<AuthResponse> {
  // Check user permissions in your database
  const hasPermission = await checkPermission(
    request.userId,
    request.namespace,
    request.operation
  );
  
  return {
    allowed: hasPermission,
    reason: hasPermission ? undefined : "Insufficient permissions",
    cacheTtlSec: 60
  };
}
```

#### 2. Validation Hooks

Validate data before writes:

```typescript
// hooks/validate.ts
export async function beforeWrite(request: WriteRequest): Promise<ValidationResult> {
  const { path, value } = request;
  
  // Example: Validate task title length
  if (path.startsWith('tasks.') && path.endsWith('.title')) {
    if (typeof value !== 'string' || value.length < 3) {
      return {
        valid: false,
        error: "Task title must be at least 3 characters"
      };
    }
  }
  
  return { valid: true };
}
```

#### 3. Event Hooks

React to data changes:

```typescript
// hooks/events.ts
export async function afterWrite(event: WriteEvent): Promise<void> {
  const { namespace, path, oldValue, newValue } = event;
  
  // Example: Send notification when task is completed
  if (path.endsWith('.status') && newValue === 'completed') {
    await sendNotification({
      userId: event.userId,
      message: `Task completed: ${path}`
    });
  }
}
```

### Hook Server (Automatic Management)

**Note**: The Hook Server is automatically managed by the ZyncBase CLI. No configuration needed in environment variables or config files.

**How it works:**
1. Write authorization logic in `zyncbase.auth.ts`
2. Run `zyncbase dev` or `zyncbase start`
3. The CLI automatically spins up the Hook Server and manages the internal IPC/WebSocket connection

**What you control:**
- Authorization logic in TypeScript (`zyncbase.auth.ts`)
- Hook function implementations

**What the CLI manages automatically:**
- Hook Server process lifecycle
- Internal connection to Zig core
- Hot-reloading of hook files
- Circuit breaker and error handling

See [AUTH_SPEC.md](./AUTH_SPEC.md) and [AUTH_EXCHANGE.md](./AUTH_EXCHANGE.md) for details on writing Hook Server functions.

### Hot Reload

The Hook Server automatically detects changes to hook files and reloads them without restarting:

```bash
# Edit your hook file
vim ./hooks/auth.ts

# Save the file - Hook Server automatically reloads
# No restart needed!
```

**Hot reload behavior:**
- Watches all `.ts` files in the hooks directory
- Recompiles and reloads on file changes
- Validates TypeScript syntax before loading
- Falls back to previous version if new version has errors
- Logs reload events for debugging

### Example Hook Templates

#### Role-Based Access Control (RBAC)

```typescript
// hooks/rbac.ts
interface User {
  id: string;
  roles: string[];
}

const rolePermissions: Record<string, string[]> = {
  admin: ['read', 'write', 'delete'],
  editor: ['read', 'write'],
  viewer: ['read']
};

export async function authorize(request: AuthRequest): Promise<AuthResponse> {
  // Fetch user from your database
  const user = await getUser(request.userId);
  
  // Check if any of the user's roles allow this operation
  const allowed = user.roles.some(role => {
    const permissions = rolePermissions[role] || [];
    return permissions.includes(request.operation);
  });
  
  return {
    allowed,
    reason: allowed ? undefined : `Role ${user.roles.join(', ')} cannot ${request.operation}`,
    cacheTtlSec: 300
  };
}
```

#### Namespace Ownership

```typescript
// hooks/ownership.ts
export async function authorize(request: AuthRequest): Promise<AuthResponse> {
  const { userId, namespace, operation } = request;
  
  // Parse namespace format: "workspace:abc-123"
  const [type, id] = namespace.split(':');
  
  if (type === 'workspace') {
    // Check if user owns or is member of workspace
    const isMember = await isWorkspaceMember(userId, id);
    
    if (!isMember) {
      return {
        allowed: false,
        reason: "Not a member of this workspace",
        cacheTtlSec: 60
      };
    }
  }
  
  return {
    allowed: true,
    cacheTtlSec: 300
  };
}
```

#### Rate Limiting

```typescript
// hooks/rate-limit.ts
const rateLimits = new Map<string, { count: number; resetAt: number }>();

export async function authorize(request: AuthRequest): Promise<AuthResponse> {
  const key = `${request.userId}:${request.operation}`;
  const now = Date.now();
  const limit = 100; // 100 operations per minute
  const window = 60 * 1000; // 1 minute
  
  let bucket = rateLimits.get(key);
  
  if (!bucket || now > bucket.resetAt) {
    bucket = { count: 0, resetAt: now + window };
    rateLimits.set(key, bucket);
  }
  
  bucket.count++;
  
  if (bucket.count > limit) {
    return {
      allowed: false,
      reason: "Rate limit exceeded",
      cacheTtlSec: 0 // Don't cache rate limit denials
    };
  }
  
  return {
    allowed: true,
    cacheTtlSec: 1 // Short cache for rate-limited operations
  };
}
```

#### Audit Logging

```typescript
// hooks/audit.ts
export async function afterWrite(event: WriteEvent): Promise<void> {
  // Log all write operations to audit trail
  await logAuditEvent({
    timestamp: new Date().toISOString(),
    userId: event.userId,
    namespace: event.namespace,
    operation: 'write',
    path: event.path,
    oldValue: event.oldValue,
    newValue: event.newValue,
    ip: event.clientIp
  });
}

export async function afterDelete(event: DeleteEvent): Promise<void> {
  // Log deletions
  await logAuditEvent({
    timestamp: new Date().toISOString(),
    userId: event.userId,
    namespace: event.namespace,
    operation: 'delete',
    path: event.path,
    oldValue: event.oldValue,
    ip: event.clientIp
  });
}
```

### Debugging Hooks

#### Enable Debug Logging

```yaml
services:
  zyncbase:
    environment:
      - LOG_LEVEL=debug
```

#### View Hook Server Logs

```bash
# Docker
docker-compose logs -f zyncbase | grep "hook-server"

# Systemd
journalctl -u zyncbase -f | grep "hook-server"
```

#### Test Hooks Locally

```bash
# Run Hook Server standalone for testing
cd hooks
bun run --watch auth.ts

# Or use the test harness
bun test auth.test.ts
```

### Hook Server Health

The Hook Server health is included in the main health check:

```bash
curl http://localhost:3000/health
```

```json
{
  "status": "healthy",
  "hook_server": {
    "status": "connected",
    "circuit_breaker": "closed",
    "latency_ms": 2.5,
    "hooks_loaded": ["auth.ts", "validate.ts", "events.ts"]
  }
}
```

### Circuit Breaker

ZyncBase includes a circuit breaker to handle Hook Server failures gracefully:

**States:**
- **Closed** (normal): All requests go to Hook Server
- **Open** (failing): Requests fail fast without contacting Hook Server
- **Half-Open** (testing): Single request tests if Hook Server recovered

**Behavior when circuit is open:**
- Authorization requests are **denied by default** (fail secure)
- Cached authorization results are still used
- Circuit automatically tests recovery after timeout

**Note**: Circuit breaker settings are automatically managed by ZyncBase. Focus on fixing the underlying issues in your hook functions rather than tuning circuit breaker parameters.

### Performance Considerations

**Authorization Caching:**
- Hook Server returns `cacheTtlSec` with each response
- ZyncBase caches authorization decisions for the specified TTL
- Reduces Hook Server load for repeated operations
- Balance security (short TTL) vs performance (long TTL)

**Best Practices:**
- Keep hook logic fast (< 100ms)
- Use caching for expensive operations
- Implement proper error handling
- Monitor Hook Server latency via health endpoint

**Note**: Hook Server timeout and connection settings are automatically managed by the ZyncBase CLI. Focus on optimizing your hook functions rather than tuning timeouts.

### Security

**Localhost-Only Communication:**
- Hook Server binds to `localhost:3001` by default
- Not exposed to external network
- Communication stays within the container/host

**Fail Secure:**
- When Hook Server is unavailable, authorization is **denied**
- Circuit breaker prevents cascading failures
- Cached permissions continue to work during outages

**Note**: TLS and security settings for Hook Server communication are automatically managed by ZyncBase.

### Troubleshooting

#### Hook Server Not Starting

**Check logs:**
```bash
docker-compose logs zyncbase | grep "hook-server"
```

**Common issues:**
- TypeScript syntax errors in hook files
- Missing dependencies in hook files
- Port 3001 already in use
- Hooks directory not mounted correctly

#### Authorization Always Denied

**Check:**
1. Hook Server is running: `curl http://localhost:3000/health`
2. Circuit breaker state: Should be "closed"
3. Hook file exports `authorize` function
4. Hook function returns correct response format

#### Hot Reload Not Working

**Check:**
1. `HOT_RELOAD=true` is set
2. File changes are being saved
3. No TypeScript compilation errors
4. File watcher has permissions

### Migration from Separate Hook Server

If you previously ran Hook Server separately, migration is simple:

**Before (if you had a separate Hook Server):**
```yaml
services:
  zyncbase:
    image: zyncbase/server:latest
  
  hook-server:
    image: my-custom-hook-server:latest
    ports:
      - "3001:3001"
```

**After (bundled):**
```yaml
services:
  zyncbase:
    image: zyncbase/server:latest
    volumes:
      - ./hooks:/hooks  # Just mount your hooks directory
    environment:
      - HOOKS_DIR=/hooks
      - HOT_RELOAD=true
```

**Steps:**
1. Copy your hook logic to TypeScript files in `./hooks/`
2. Remove separate Hook Server service from docker-compose
3. Mount hooks directory to ZyncBase container
4. Restart ZyncBase

### No Separate Deployment Needed

**Key Points:**
- ✅ Hook Server is **bundled** with ZyncBase
- ✅ Starts **automatically** when ZyncBase starts
- ✅ No separate container or process to manage
- ✅ No additional ports to expose (uses localhost)
- ✅ No separate configuration files needed
- ✅ Hot-reload works out of the box
- ✅ Included in ZyncBase health checks
- ✅ Monitored via same metrics endpoint

**You only need to:**
1. Create a `./hooks/` directory
2. Add TypeScript hook files
3. Mount the directory to ZyncBase
4. Start ZyncBase

That's it! The Hook Server handles everything else automatically.

---

## Binary Deployment

### Download Binary

```bash
# Linux
curl -L https://zyncbase.dev/download/latest/linux-x64 -o zyncbase-server
chmod +x zyncbase-server

# macOS
curl -L https://zyncbase.dev/download/latest/darwin-x64 -o zyncbase-server
chmod +x zyncbase-server

# Windows
curl -L https://zyncbase.dev/download/latest/windows-x64.exe -o zyncbase-server.exe
```

### Run Directly

```bash
./zyncbase-server --config zyncbase-config.json
```

### Systemd Service

Create `/etc/systemd/system/zyncbase.service`:

```ini
[Unit]
Description=ZyncBase Real-time Collaborative Database
After=network.target

[Service]
Type=simple
User=zyncbase
WorkingDirectory=/opt/zyncbase
ExecStart=/opt/zyncbase/zyncbase-server --config /opt/zyncbase/zyncbase-config.json
Restart=always
RestartSec=10

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/zyncbase/data

[Install]
WantedBy=multi-user.target
```

### Enable and Start

```bash
# Copy files
sudo mkdir -p /opt/zyncbase/
sudo cp zyncbase-server /opt/zyncbase/
sudo cp zyncbase-config.json /opt/zyncbase/
sudo cp schema.json /opt/zyncbase/
sudo cp auth.json /opt/zyncbase/

# Create user
sudo useradd -r -s /bin/false zyncbase
sudo chown -R zyncbase:zyncbase /opt/zyncbase

# Enable service
sudo systemctl enable zyncbase
sudo systemctl start zyncbase

# Check status
sudo systemctl status zyncbase
```

---

## Production Best Practices

### 1. Use Environment Variables for Secrets

Never commit secrets to git:

```bash
# .env (add to .gitignore)
JWT_SECRET=your-secret-key-here
```

```json
{
  "auth": {
    "jwt": {
      "secret": "${JWT_SECRET}"
    }
  }
```

### 2. Enable HTTPS

Use a reverse proxy (Nginx, Caddy) for TLS termination:

**nginx.conf:**
```nginx
upstream ZyncBase {
    server localhost:3000;
}

server {
    listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    location / {
        proxy_pass http://ZyncBase;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 3. Configure Rate Limiting

```json
{
  "security": {
    "rateLimit": {
      "messagesPerSecond": 100,
      "connectionsPerIP": 10,
      "maxMessageSize": 1048576
    }
  }
}
```

### 4. Set Resource Limits

**Docker:**
```yaml
services:
  zyncbase:
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 4G
        reservations:
          cpus: '2'
          memory: 2G
```

**Systemd:**
```ini
[Service]
MemoryLimit=4G
CPUQuota=400%
```

### 5. Enable Logging

```json
{
  "logging": {
    "level": "info",
    "format": "json"
  }
}
```

### 6. Backup Data Directory

```bash
# Backup script
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
tar -czf /backups/zyncbase-$DATE.tar.gz /opt/ZyncBase/data

# Keep only last 7 days
find /backups -name "zyncbase-*.tar.gz" -mtime +7 -delete
```

### 7. Monitor Performance

See [Monitoring](#monitoring) section below.

---

## Security

### Authentication Best Practices

#### Use Ticket-Based Auth

```typescript
// Step 1: Client gets ticket from your API
const response = await fetch('/api/auth/ticket', {
  headers: { Authorization: `Bearer ${userJWT}` }
})
const { ticket } = await response.json()

// Step 2: Connect with ticket
const client = createClient({
  url: 'wss://api.yourdomain.com',
  auth: { ticket }, // Short-lived, single-use ticket
  namespace: 'room:abc-123'
})
```

**Why?**
- Tickets are short-lived (1-5 minutes)
- Single-use only
- Not logged in proxies/servers
- More secure than JWT in query params

#### Configure Allowed Origins

```json
{
  "security": {
    "allowedOrigins": [
      "https://yourdomain.com",
      "https://app.yourdomain.com"
    ],
    "allowLocalhost": false
  }
}
```

### Network Security

#### Firewall Rules

```bash
# Allow only HTTPS and SSH
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

#### Fail2Ban

Protect against brute force attacks:

```ini
# /etc/fail2ban/jail.local
[zyncbase]
enabled = true
port = 443
filter = ZyncBase
logpath = /var/log/zyncbase/access.log
maxretry = 5
bantime = 3600
```

### Data Security

#### Encrypt Data at Rest

Use encrypted volumes:

```bash
# Linux (LUKS)
sudo cryptsetup luksFormat /dev/sdb
sudo cryptsetup open /dev/sdb zyncbase-data
sudo mkfs.ext4 /dev/mapper/zyncbase-data
sudo mount /dev/mapper/zyncbase-data /opt/ZyncBase/data
```

#### Encrypt Data in Transit

Always use TLS/SSL for production:
- Use Let's Encrypt for free certificates
- Configure strong cipher suites
- Enable HTTP/2

---

## Monitoring

## Monitoring

### Health Check Endpoint

ZyncBase provides a comprehensive health check endpoint at `/health`:

```bash
curl http://localhost:3000/health
```

**Healthy Response (200 OK):**
```json
{
  "status": "healthy",
  "uptime": 3600,
  "version": "1.0.0",
  "connections": {
    "active": 1234,
    "max": 100000
  },
  "memory": {
    "used": 512000000,
    "total": 4000000000,
    "percentage": 12.8
  },
  "database": {
    "status": "healthy",
    "wal_size": 5242880,
    "last_checkpoint": "2026-03-09T10:25:00Z"
  },
  "hook_server": {
    "status": "connected",
    "circuit_breaker": "closed",
    "latency_ms": 2.5
  },
  "cache": {
    "entries": 150,
    "hit_rate": 0.95,
    "memory_bytes": 15728640
  }
}
```

**Unhealthy Response (503 Service Unavailable):**
```json
{
  "status": "unhealthy",
  "errors": [
    {
      "component": "database",
      "message": "Database connection failed",
      "code": "DB_CONNECTION_ERROR"
    },
    {
      "component": "hook_server",
      "message": "Circuit breaker open",
      "code": "CIRCUIT_BREAKER_OPEN"
    }
  ]
}
```

### Health Check Components

The health check validates:

1. **Server Status**: Process is running and responsive
2. **Database**: SQLite connection is healthy, WAL size is reasonable
3. **Hook Server**: Connection is established, circuit breaker is closed
4. **Memory**: Memory usage is within acceptable limits
5. **Cache**: Lock-free cache is operational

### Using Health Checks in Docker

```yaml
services:
  zyncbase:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### Using Health Checks in Kubernetes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: zyncbase
spec:
  containers:
  - name: zyncbase
    image: zyncbase/server:latest
    livenessProbe:
      httpGet:
        path: /health
        port: 3000
      initialDelaySeconds: 30
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 3
    readinessProbe:
      httpGet:
        path: /health
        port: 3000
      initialDelaySeconds: 10
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 2
```

### Prometheus Metrics

ZyncBase exposes comprehensive Prometheus metrics at `/metrics`:

```bash
curl http://localhost:3000/metrics
```

**Connection Metrics:**
- `zyncbase_connections_total` - Total active WebSocket connections
- `zyncbase_connections_max` - Maximum configured connections
- `zyncbase_messages_total` - Total messages processed (counter)
- `zyncbase_messages_per_second` - Current message rate (gauge)
- `zyncbase_message_latency_seconds` - Message processing latency (histogram)
- `zyncbase_bytes_transferred_total` - Total bytes sent/received (counter)

**Cache Metrics:**
- `zyncbase_cache_entries` - Number of cache entries (gauge)
- `zyncbase_cache_hit_rate` - Cache hit rate (gauge, 0-1)
- `zyncbase_cache_memory_bytes` - Cache memory usage (gauge)
- `zyncbase_cache_ref_count_total` - Total reference count across all entries (gauge)

**Checkpoint Metrics:**
- `zyncbase_checkpoint_count_total` - Total checkpoints performed (counter)
- `zyncbase_checkpoint_failed_total` - Failed checkpoint attempts (counter)
- `zyncbase_checkpoint_duration_seconds` - Checkpoint duration (histogram)
- `zyncbase_wal_size_bytes` - Current WAL file size (gauge)
- `zyncbase_last_checkpoint_timestamp` - Unix timestamp of last checkpoint (gauge)

**Hook Server Metrics:**
- `zyncbase_hook_server_status` - Hook Server connection status (gauge: 0=disconnected, 1=connected)
- `zyncbase_hook_server_circuit_breaker_state` - Circuit breaker state (gauge: 0=closed, 1=open, 2=half-open)
- `zyncbase_hook_server_authorization_latency_seconds` - Authorization request latency (histogram)
- `zyncbase_hook_server_failures_total` - Total Hook Server failures (counter)
- `zyncbase_hook_server_authorizations_total` - Total authorization requests (counter)

**Error Metrics:**
- `zyncbase_errors_total` - Total errors by type (counter with `error_type` label)
- `zyncbase_rate_limit_violations_total` - Rate limit violations (counter)
- `zyncbase_parsing_errors_total` - MessagePack parsing errors (counter with `error_type` label)
- `zyncbase_security_events_total` - Security events (counter with `event_type` label)

**Subscription Metrics:**
- `zyncbase_subscriptions_active` - Active subscriptions (gauge)
- `zyncbase_subscription_matching_duration_seconds` - Subscription matching latency (histogram)
- `zyncbase_subscription_notifications_total` - Total notifications sent (counter)

**System Metrics:**
- `zyncbase_memory_bytes` - Memory usage (gauge)
- `zyncbase_cpu_usage_percent` - CPU usage percentage (gauge)
- `zyncbase_uptime_seconds` - Server uptime (gauge)

### Example Prometheus Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'zyncbase'
    static_configs:
      - targets: ['zyncbase:9090']
    metrics_path: '/metrics'
```

### Grafana Dashboard

Import the ZyncBase dashboard:

```bash
# Download dashboard
curl -L https://ZyncBase.dev/grafana/dashboard.json -o zyncbase-dashboard.json

# Import to Grafana
# Dashboards > Import > Upload JSON file
```

### Logging

**Structured JSON logs:**
```json
{
  "timestamp": "2026-03-09T10:30:00Z",
  "level": "info",
  "message": "Client connected",
  "userId": "user-123",
  "namespace": "room:abc-123",
  "ip": "192.168.1.100"
}
```

**Log aggregation with Loki:**

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
```

### Alerting

**Prometheus alerts:**

```yaml
groups:
  - name: zyncbase
    rules:
      - alert: HighConnectionCount
        expr: zyncbase_connections_total > 90000
        for: 5m
        annotations:
          summary: "High connection count"
          
      - alert: HighMemoryUsage
        expr: zyncbase_memory_bytes > 3500000000
        for: 5m
        annotations:
          summary: "High memory usage"
          
      - alert: HighLatency
        expr: zyncbase_message_latency_seconds > 0.1
        for: 5m
        annotations:
          summary: "High message latency"
```

---

## Troubleshooting

### Common Issues

#### 1. Connection Refused

**Symptom:** Client can't connect to server

**Check:**
```bash
# Is server running?
systemctl status zyncbase

# Is port open?
netstat -tlnp | grep 3000

# Check firewall
sudo ufw status
```

#### 2. High Memory Usage

**Symptom:** Server using too much memory

**Check:**
```bash
# Check connections
curl http://localhost:3000/health

# Check for memory leaks
# Enable debug logging
```

**Fix:**
- Reduce `maxConnections` in config
- Add more RAM
- Check for subscription leaks

#### 3. Slow Performance

**Symptom:** High latency, slow updates

**Check:**
```bash
# Check CPU usage
top

# Check disk I/O
iostat -x 1

# Check network
iftop
```

**Fix:**
- Enable write batching
- Increase `messageBufferSize`
- Check SQLite checkpoint frequency
- Add more CPU cores

#### 4. Authentication Failures

**Symptom:** Clients can't authenticate

**Check:**
```bash
# Check JWT secret
echo $JWT_SECRET

# Check logs
journalctl -u zyncbase -f

# Test JWT
curl -H "Authorization: Bearer $TOKEN" http://localhost:3000/health
```

### Debug Mode

Enable debug logging:

```json
{
  "logging": {
    "level": "debug",
    "format": "text"
  }
}
```

### Performance Profiling

```bash
# CPU profiling
./ZyncBase-server --profile-cpu

# Memory profiling
./ZyncBase-server --profile-memory

# Generate flamegraph
./ZyncBase-server --flamegraph
```

---

## Scaling

### Vertical Scaling

ZyncBase is designed for vertical scaling (single server, all CPU cores).

**Recommended specs:**

| Connections | CPU | RAM | Disk |
|-------------|-----|-----|------|
| 10k | 4 cores | 4GB | 50GB SSD |
| 50k | 8 cores | 8GB | 100GB SSD |
| 100k | 16 cores | 16GB | 200GB SSD |

### Performance Tuning

**1. Increase file descriptors:**
```bash
# /etc/security/limits.conf
ZyncBase soft nofile 100000
ZyncBase hard nofile 100000
```

**2. Tune kernel parameters:**
```bash
# /etc/sysctl.conf
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
```

**3. Use faster storage:**
- NVMe SSD for data directory
- Separate disk for logs

---

## Backup and Recovery

### Backup Strategy

ZyncBase uses SQLite with WAL (Write-Ahead Logging) mode, which requires backing up both the main database file and the WAL file for consistency.

#### Simple Backup (Offline)

```bash
#!/bin/bash
# backup-offline.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups"
DATA_DIR="/opt/zyncbase/data"

# Stop server to ensure consistency
systemctl stop zyncbase

# Backup database and WAL
cp $DATA_DIR/zyncbase.db $BACKUP_DIR/zyncbase-$DATE.db
cp $DATA_DIR/zyncbase.db-wal $BACKUP_DIR/zyncbase-$DATE.db-wal
cp $DATA_DIR/zyncbase.db-shm $BACKUP_DIR/zyncbase-$DATE.db-shm

# Backup config
tar -czf $BACKUP_DIR/config-$DATE.tar.gz /opt/zyncbase/*.json

# Resume server
systemctl start zyncbase

# Upload to S3 (optional)
aws s3 cp $BACKUP_DIR/zyncbase-$DATE.db s3://my-backups/

# Cleanup old backups (keep last 7 days)
find $BACKUP_DIR -name "zyncbase-*.db" -mtime +7 -delete
```

#### Online Backup (Using SQLite Backup API)

```bash
#!/bin/bash
# backup-online.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups"
DATA_DIR="/opt/zyncbase/data"

# Use SQLite backup command (online, consistent)
sqlite3 $DATA_DIR/zyncbase.db ".backup $BACKUP_DIR/zyncbase-$DATE.db"

# Backup config
tar -czf $BACKUP_DIR/config-$DATE.tar.gz /opt/zyncbase/*.json

# Upload to S3 (optional)
aws s3 cp $BACKUP_DIR/zyncbase-$DATE.db s3://my-backups/

# Cleanup old backups
find $BACKUP_DIR -name "zyncbase-*.db" -mtime +7 -delete

echo "✓ Backup completed: zyncbase-$DATE.db"
```

#### Continuous Backup (WAL Archiving)

For point-in-time recovery, archive WAL files continuously:

```bash
#!/bin/bash
# backup-wal-continuous.sh

DATA_DIR="/opt/zyncbase/data"
WAL_ARCHIVE="/backups/wal-archive"

mkdir -p $WAL_ARCHIVE

# Run continuously
while true; do
  # Wait for WAL checkpoint
  sleep 60
  
  # Archive WAL file if it exists and has changed
  if [ -f "$DATA_DIR/zyncbase.db-wal" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp $DATA_DIR/zyncbase.db-wal $WAL_ARCHIVE/wal-$TIMESTAMP
    
    # Upload to S3
    aws s3 cp $WAL_ARCHIVE/wal-$TIMESTAMP s3://my-backups/wal/
  fi
done
```

### Automated Backup with Cron

```bash
# Add to crontab
crontab -e

# Backup every 6 hours
0 */6 * * * /opt/zyncbase/scripts/backup-online.sh

# Backup daily at 2 AM
0 2 * * * /opt/zyncbase/scripts/backup-offline.sh
```

### Docker Backup

```bash
# Backup from Docker container
docker exec zyncbase sqlite3 /data/zyncbase.db ".backup /data/backup.db"
docker cp zyncbase:/data/backup.db ./backups/zyncbase-$(date +%Y%m%d).db

# Or backup the entire data volume
docker run --rm \
  -v zyncbase_data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/zyncbase-data-$(date +%Y%m%d).tar.gz /data
```

### Recovery

#### Simple Restore

```bash
# Stop server
systemctl stop zyncbase

# Restore database
cp /backups/zyncbase-20260309.db /opt/zyncbase/data/zyncbase.db

# Remove WAL files (will be recreated)
rm -f /opt/zyncbase/data/zyncbase.db-wal
rm -f /opt/zyncbase/data/zyncbase.db-shm

# Restore config
tar -xzf /backups/config-20260309.tar.gz -C /opt/zyncbase

# Verify database integrity
sqlite3 /opt/zyncbase/data/zyncbase.db "PRAGMA integrity_check;"

# Start server
systemctl start zyncbase

echo "✓ Restore completed"
```

#### Point-in-Time Recovery

```bash
#!/bin/bash
# restore-point-in-time.sh

TARGET_TIME="2026-03-09 14:30:00"
BACKUP_DIR="/backups"
WAL_ARCHIVE="/backups/wal-archive"
DATA_DIR="/opt/zyncbase/data"

# Stop server
systemctl stop zyncbase

# Find base backup before target time
BASE_BACKUP=$(find $BACKUP_DIR -name "zyncbase-*.db" -type f | \
  awk -F'-' '{print $2}' | \
  awk -v target="$TARGET_TIME" '$0 < target {print}' | \
  sort -r | head -1)

# Restore base backup
cp $BACKUP_DIR/zyncbase-$BASE_BACKUP.db $DATA_DIR/zyncbase.db

# Apply WAL files up to target time
for wal in $(find $WAL_ARCHIVE -name "wal-*" -type f | sort); do
  WAL_TIME=$(basename $wal | sed 's/wal-//' | sed 's/_/ /')
  
  if [[ "$WAL_TIME" < "$TARGET_TIME" ]]; then
    # Apply WAL file
    sqlite3 $DATA_DIR/zyncbase.db ".restore $wal"
  else
    break
  fi
done

# Verify integrity
sqlite3 $DATA_DIR/zyncbase.db "PRAGMA integrity_check;"

# Start server
systemctl start zyncbase

echo "✓ Point-in-time recovery completed to $TARGET_TIME"
```

#### Docker Restore

```bash
# Stop container
docker-compose down

# Restore database
docker cp ./backups/zyncbase-20260309.db zyncbase:/data/zyncbase.db

# Or restore entire volume
docker run --rm \
  -v zyncbase_data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar xzf /backup/zyncbase-data-20260309.tar.gz -C /

# Start container
docker-compose up -d
```

### Backup Verification

Always verify backups are valid:

```bash
#!/bin/bash
# verify-backup.sh

BACKUP_FILE=$1

# Check file exists
if [ ! -f "$BACKUP_FILE" ]; then
  echo "❌ Backup file not found: $BACKUP_FILE"
  exit 1
fi

# Check SQLite integrity
sqlite3 $BACKUP_FILE "PRAGMA integrity_check;" | grep -q "ok"
if [ $? -eq 0 ]; then
  echo "✓ Backup integrity verified: $BACKUP_FILE"
else
  echo "❌ Backup integrity check failed: $BACKUP_FILE"
  exit 1
fi

# Check file size (should be > 0)
SIZE=$(stat -f%z "$BACKUP_FILE" 2>/dev/null || stat -c%s "$BACKUP_FILE")
if [ $SIZE -gt 0 ]; then
  echo "✓ Backup size: $(numfmt --to=iec-i --suffix=B $SIZE)"
else
  echo "❌ Backup file is empty"
  exit 1
fi
```

### Backup Best Practices

1. **Test Restores Regularly**: Verify backups can be restored successfully
2. **Multiple Backup Locations**: Store backups in multiple locations (local + cloud)
3. **Retention Policy**: Keep daily backups for 7 days, weekly for 4 weeks, monthly for 1 year
4. **Monitor Backup Jobs**: Alert on backup failures
5. **Encrypt Backups**: Use encryption for backups stored off-site
6. **Document Recovery Procedures**: Keep recovery runbooks up to date

### Backup Encryption

```bash
# Encrypt backup with GPG
gpg --symmetric --cipher-algo AES256 zyncbase-backup.db

# Decrypt backup
gpg --decrypt zyncbase-backup.db.gpg > zyncbase-backup.db

# Or use OpenSSL
openssl enc -aes-256-cbc -salt -in zyncbase-backup.db -out zyncbase-backup.db.enc
openssl enc -d -aes-256-cbc -in zyncbase-backup.db.enc -out zyncbase-backup.db
```

---

## Next Steps

- [Configuration](./CONFIGURATION.md) - Configure your server
- [API Reference](./API_REFERENCE.md) - Learn the client SDK
- [Monitoring Dashboard](https://ZyncBase.dev/grafana) - Import Grafana dashboard
