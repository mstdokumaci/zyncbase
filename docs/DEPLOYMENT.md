# STX Deployment Guide

**Last Updated**: 2026-03-09

Complete guide to deploying STX in production.

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

STX can be deployed in multiple ways:

1. **Docker** - Recommended for most use cases
2. **Binary** - Direct binary deployment on VPS
3. **Kubernetes** - For enterprise deployments
4. **Systemd** - For Linux servers

---

## Docker Deployment

### Basic Dockerfile

```dockerfile
FROM stx/server:latest

COPY stx.config.json /config/
COPY schema.json /config/
COPY auth.json /config/

EXPOSE 3000

CMD ["stx-server", "--config", "/config/stx.config.json"]
```

### Build and Run

```bash
# Build
docker build -t my-stx-server .

# Run
docker run -p 3000:3000 -v $(pwd)/data:/data my-stx-server
```

### Docker Compose

```yaml
version: '3.8'

services:
  stx:
    image: stx/server:latest
    ports:
      - "3000:3000"
    volumes:
      - ./config:/config
      - ./data:/data
    environment:
      - JWT_SECRET=${JWT_SECRET}
      - WEBHOOK_SECRET=${WEBHOOK_SECRET}
    command: ["stx-server", "--config", "/config/stx.config.json"]
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
      - stx
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
curl -L https://stx.dev/download/latest/linux-x64 -o stx-server
chmod +x stx-server

# macOS
curl -L https://stx.dev/download/latest/darwin-x64 -o stx-server
chmod +x stx-server

# Windows
curl -L https://stx.dev/download/latest/windows-x64.exe -o stx-server.exe
```

### Run Directly

```bash
./stx-server --config stx.config.json
```

### Systemd Service

Create `/etc/systemd/system/stx.service`:

```ini
[Unit]
Description=STX Real-time State Manager
After=network.target

[Service]
Type=simple
User=stx
WorkingDirectory=/opt/stx
ExecStart=/opt/stx/stx-server --config /opt/stx/stx.config.json
Restart=always
RestartSec=10

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/stx/data

[Install]
WantedBy=multi-user.target
```

### Enable and Start

```bash
# Copy files
sudo mkdir -p /opt/stx
sudo cp stx-server /opt/stx/
sudo cp stx.config.json /opt/stx/
sudo cp schema.json /opt/stx/
sudo cp auth.json /opt/stx/

# Create user
sudo useradd -r -s /bin/false stx
sudo chown -R stx:stx /opt/stx

# Enable service
sudo systemctl enable stx
sudo systemctl start stx

# Check status
sudo systemctl status stx
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
upstream stx {
    server localhost:3000;
}

server {
    listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    location / {
        proxy_pass http://stx;
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
  stx:
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
tar -czf /backups/stx-$DATE.tar.gz /opt/stx/data

# Keep only last 7 days
find /backups -name "stx-*.tar.gz" -mtime +7 -delete
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
[stx]
enabled = true
port = 443
filter = stx
logpath = /var/log/stx/access.log
maxretry = 5
bantime = 3600
```

### Data Security

#### Encrypt Data at Rest

Use encrypted volumes:

```bash
# Linux (LUKS)
sudo cryptsetup luksFormat /dev/sdb
sudo cryptsetup open /dev/sdb stx-data
sudo mkfs.ext4 /dev/mapper/stx-data
sudo mount /dev/mapper/stx-data /opt/stx/data
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

STX exposes Prometheus metrics at `/metrics`:

```bash
curl http://localhost:3000/metrics
```

**Key metrics:**
- `stx_connections_total` - Total active connections
- `stx_messages_total` - Total messages processed
- `stx_message_latency_seconds` - Message processing latency
- `stx_memory_bytes` - Memory usage
- `stx_cpu_usage_percent` - CPU usage

### Grafana Dashboard

Import the STX dashboard:

```bash
# Download dashboard
curl -L https://stx.dev/grafana/dashboard.json -o stx-dashboard.json

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
  - name: stx
    rules:
      - alert: HighConnectionCount
        expr: stx_connections_total > 90000
        for: 5m
        annotations:
          summary: "High connection count"
          
      - alert: HighMemoryUsage
        expr: stx_memory_bytes > 3500000000
        for: 5m
        annotations:
          summary: "High memory usage"
          
      - alert: HighLatency
        expr: stx_message_latency_seconds > 0.1
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
systemctl status stx

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
journalctl -u stx -f

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
./stx-server --profile-cpu

# Memory profiling
./stx-server --profile-memory

# Generate flamegraph
./stx-server --flamegraph
```

---

## Scaling

### Vertical Scaling

STX is designed for vertical scaling (single server, all CPU cores).

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
stx soft nofile 100000
stx hard nofile 100000
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
DATA_DIR="/opt/stx/data"

# Stop writes (optional)
# systemctl stop stx

# Backup SQLite database
sqlite3 $DATA_DIR/stx.db ".backup $BACKUP_DIR/stx-$DATE.db"

# Backup config
tar -czf $BACKUP_DIR/config-$DATE.tar.gz /opt/stx/*.json

# Resume writes
# systemctl start stx

# Upload to S3 (optional)
aws s3 cp $BACKUP_DIR/stx-$DATE.db s3://my-backups/

# Cleanup old backups
find $BACKUP_DIR -name "stx-*.db" -mtime +7 -delete
```

### Recovery

```bash
# Stop server
systemctl stop stx

# Restore database
cp /backups/stx-20260309.db /opt/stx/data/stx.db

# Restore config
tar -xzf /backups/config-20260309.tar.gz -C /opt/stx

# Start server
systemctl start stx
```

---

## Next Steps

- [Configuration](./CONFIGURATION.md) - Configure your server
- [API Reference](./API_REFERENCE.md) - Learn the client SDK
- [Monitoring Dashboard](https://stx.dev/grafana) - Import Grafana dashboard
