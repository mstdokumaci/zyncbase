# zyncBase Deployment Guide

**Last Updated**: 2026-03-09

Complete guide to deploying zyncBase in production.

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

zyncBase can be deployed in multiple ways:

1. **Docker** - Recommended for most use cases
2. **Binary** - Direct binary deployment on VPS
3. **Kubernetes** - For enterprise deployments
4. **Systemd** - For Linux servers

---

## Docker Deployment

### Basic Dockerfile

```dockerfile
FROM zyncBase/server:latest

COPY zyncBase.config.json /config/
COPY schema.json /config/
COPY auth.json /config/

EXPOSE 3000

CMD ["zyncBase-server", "--config", "/config/zyncBase.config.json"]
```

### Build and Run

```bash
# Build
docker build -t my-zyncBase-server .

# Run
docker run -p 3000:3000 -v $(pwd)/data:/data my-zyncBase-server
```

### Docker Compose

```yaml
version: '3.8'

services:
  zyncBase:
    image: zyncBase/server:latest
    ports:
      - "3000:3000"
    volumes:
      - ./config:/config
      - ./data:/data
    environment:
      - JWT_SECRET=${JWT_SECRET}
      - WEBHOOK_SECRET=${WEBHOOK_SECRET}
    command: ["zyncBase-server", "--config", "/config/zyncBase.config.json"]
    restart: unless-stopped
    
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
      - zyncBase
    restart: unless-stopped
```

### Run with Docker Compose

```bash
docker-compose up -d
```

---

## Binary Deployment

### Download Binary

```bash
# Linux
curl -L https://zyncBase.dev/download/latest/linux-x64 -o zyncBase-server
chmod +x zyncBase-server

# macOS
curl -L https://zyncBase.dev/download/latest/darwin-x64 -o zyncBase-server
chmod +x zyncBase-server

# Windows
curl -L https://zyncBase.dev/download/latest/windows-x64.exe -o zyncBase-server.exe
```

### Run Directly

```bash
./zyncBase-server --config zyncBase.config.json
```

### Systemd Service

Create `/etc/systemd/system/zyncBase.service`:

```ini
[Unit]
Description=ZyncBase Real-time Collaborative Database
After=network.target

[Service]
Type=simple
User=zyncBase
WorkingDirectory=/opt/zyncBase
ExecStart=/opt/zyncBase/zyncBase-server --config /opt/zyncBase/zyncBase.config.json
Restart=always
RestartSec=10

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/zyncBase/data

[Install]
WantedBy=multi-user.target
```

### Enable and Start

```bash
# Copy files
sudo mkdir -p /opt/zyncBase
sudo cp zyncBase-server /opt/zyncBase/
sudo cp zyncBase.config.json /opt/zyncBase/
sudo cp schema.json /opt/zyncBase/
sudo cp auth.json /opt/zyncBase/

# Create user
sudo useradd -r -s /bin/false zyncBase
sudo chown -R zyncBase:zyncBase /opt/zyncBase

# Enable service
sudo systemctl enable zyncBase
sudo systemctl start zyncBase

# Check status
sudo systemctl status zyncBase
```

---

## Production Best Practices

### 1. Use Environment Variables for Secrets

Never commit secrets to git:

```bash
# .env (add to .gitignore)
JWT_SECRET=your-secret-key-here
WEBHOOK_SECRET=webhook-auth-token
```

```json
{
  "auth": {
    "jwt": {
      "secret": "${JWT_SECRET}"
    }
  }
}
```

### 2. Enable HTTPS

Use a reverse proxy (Nginx, Caddy) for TLS termination:

**nginx.conf:**
```nginx
upstream zyncBase {
    server localhost:3000;
}

server {
    listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    location / {
        proxy_pass http://zyncBase;
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
  zyncBase:
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
tar -czf /backups/zyncBase-$DATE.tar.gz /opt/zyncBase/data

# Keep only last 7 days
find /backups -name "zyncBase-*.tar.gz" -mtime +7 -delete
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
[zyncBase]
enabled = true
port = 443
filter = zyncBase
logpath = /var/log/zyncBase/access.log
maxretry = 5
bantime = 3600
```

### Data Security

#### Encrypt Data at Rest

Use encrypted volumes:

```bash
# Linux (LUKS)
sudo cryptsetup luksFormat /dev/sdb
sudo cryptsetup open /dev/sdb zyncBase-data
sudo mkfs.ext4 /dev/mapper/zyncBase-data
sudo mount /dev/mapper/zyncBase-data /opt/zyncBase/data
```

#### Encrypt Data in Transit

Always use TLS/SSL for production:
- Use Let's Encrypt for free certificates
- Configure strong cipher suites
- Enable HTTP/2

---

## Monitoring

### Health Check Endpoint

```bash
curl http://localhost:3000/health
```

Response:
```json
{
  "status": "healthy",
  "uptime": 3600,
  "connections": 1234,
  "memory": {
    "used": 512000000,
    "total": 4000000000
  }
}
```

### Prometheus Metrics

zyncBase exposes Prometheus metrics at `/metrics`:

```bash
curl http://localhost:3000/metrics
```

**Key metrics:**
- `zyncBase_connections_total` - Total active connections
- `zyncBase_messages_total` - Total messages processed
- `zyncBase_message_latency_seconds` - Message processing latency
- `zyncBase_memory_bytes` - Memory usage
- `zyncBase_cpu_usage_percent` - CPU usage

### Grafana Dashboard

Import the zyncBase dashboard:

```bash
# Download dashboard
curl -L https://zyncBase.dev/grafana/dashboard.json -o zyncBase-dashboard.json

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
  - name: zyncBase
    rules:
      - alert: HighConnectionCount
        expr: zyncBase_connections_total > 90000
        for: 5m
        annotations:
          summary: "High connection count"
          
      - alert: HighMemoryUsage
        expr: zyncBase_memory_bytes > 3500000000
        for: 5m
        annotations:
          summary: "High memory usage"
          
      - alert: HighLatency
        expr: zyncBase_message_latency_seconds > 0.1
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
systemctl status zyncBase

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
journalctl -u zyncBase -f

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
./zyncBase-server --profile-cpu

# Memory profiling
./zyncBase-server --profile-memory

# Generate flamegraph
./zyncBase-server --flamegraph
```

---

## Scaling

### Vertical Scaling

zyncBase is designed for vertical scaling (single server, all CPU cores).

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
zyncBase soft nofile 100000
zyncBase hard nofile 100000
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

```bash
#!/bin/bash
# backup.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups"
DATA_DIR="/opt/zyncBase/data"

# Stop writes (optional)
# systemctl stop zyncBase

# Backup SQLite database
sqlite3 $DATA_DIR/zyncBase.db ".backup $BACKUP_DIR/zyncBase-$DATE.db"

# Backup config
tar -czf $BACKUP_DIR/config-$DATE.tar.gz /opt/zyncBase/*.json

# Resume writes
# systemctl start zyncBase

# Upload to S3 (optional)
aws s3 cp $BACKUP_DIR/zyncBase-$DATE.db s3://my-backups/

# Cleanup old backups
find $BACKUP_DIR -name "zyncBase-*.db" -mtime +7 -delete
```

### Recovery

```bash
# Stop server
systemctl stop zyncBase

# Restore database
cp /backups/zyncBase-20260309.db /opt/zyncBase/data/zyncBase.db

# Restore config
tar -xzf /backups/config-20260309.tar.gz -C /opt/zyncBase

# Start server
systemctl start zyncBase
```

---

## Next Steps

- [Configuration](./CONFIGURATION.md) - Configure your server
- [API Reference](./API_REFERENCE.md) - Learn the client SDK
- [Monitoring Dashboard](https://zyncBase.dev/grafana) - Import Grafana dashboard
