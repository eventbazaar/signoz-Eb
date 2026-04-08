# EventBazaar — SigNoz Production Deployment

## Server Specifications

| Resource | Value |
|---|---|
| CPU | 4 vCPU |
| RAM | 16 GB |
| Disk | 200 GB NVMe |
| Bandwidth | 16 TB |

## Endpoints

| Purpose | URL |
|---|---|
| SigNoz Web UI | https://otel-ui.eventbazaar.com |
| OTLP gRPC | https://otel-push.eventbazaar.com:443 (content-type: application/grpc) |
| OTLP HTTP | https://otel-push.eventbazaar.com:443/v1/{traces,metrics,logs} |

## Resource Allocation

| Service | RAM | CPU |
|---|---|---|
| ClickHouse | 8 GB | 2.0 vCPU |
| SigNoz | 2 GB | 1.0 vCPU |
| OTel Collector | 1 GB | 0.5 vCPU |
| ZooKeeper | 512 MB | 0.25 vCPU |
| Migrator | 512 MB | 0.25 vCPU |
| Nginx | 256 MB | 0.1 vCPU |

---

## Prerequisites

- Docker Engine ≥ 24 with the Compose plugin (`docker compose`)
- Two DNS A records pointing to the server's public IP:
  - `otel-ui.eventbazaar.com`
  - `otel-push.eventbazaar.com`
- Ports 80 and 443 open in the server firewall

---

## Step 1 — Clone & navigate

```bash
git clone https://github.com/your-org/signoz-Eb.git
cd signoz-Eb/deploy/docker
```

## Step 2 — Prepare the environment file

```bash
cp .env.eventbazaar .env.eventbazaar.local
# Generate a strong JWT secret and set it:
JWT=$(openssl rand -hex 32)
sed -i "s/CHANGE_ME_BEFORE_FIRST_RUN/$JWT/" .env.eventbazaar.local
```

> `.env.eventbazaar.local` is gitignored — never commit it.

## Step 3 — Obtain TLS certificates

### Option A — Certbot standalone (recommended first time)

```bash
# Install certbot
apt-get install -y certbot

# Obtain certs for both domains (port 80 must be free)
certbot certonly --standalone \
  -d otel-ui.eventbazaar.com \
  -d otel-push.eventbazaar.com \
  --agree-tos --non-interactive --email admin@eventbazaar.com
```

### Option B — Certbot with DNS challenge

```bash
certbot certonly --manual --preferred-challenges dns \
  -d otel-ui.eventbazaar.com \
  -d otel-push.eventbazaar.com
```

### Copy certs into the nginx-certs volume

```bash
# Create the volume first
docker volume create signoz-eb-nginx-certs

# Copy Let's Encrypt certs into the volume
TMPDIR=$(docker run --rm -d -v signoz-eb-nginx-certs:/certs alpine sleep 60)
docker exec $TMPDIR mkdir -p /certs/otel-ui.eventbazaar.com /certs/otel-push.eventbazaar.com
docker cp /etc/letsencrypt/live/otel-ui.eventbazaar.com/fullchain.pem $TMPDIR:/certs/otel-ui.eventbazaar.com/
docker cp /etc/letsencrypt/live/otel-ui.eventbazaar.com/privkey.pem   $TMPDIR:/certs/otel-ui.eventbazaar.com/
docker cp /etc/letsencrypt/live/otel-push.eventbazaar.com/fullchain.pem $TMPDIR:/certs/otel-push.eventbazaar.com/
docker cp /etc/letsencrypt/live/otel-push.eventbazaar.com/privkey.pem   $TMPDIR:/certs/otel-push.eventbazaar.com/
docker stop $TMPDIR
```

## Step 4 — Start the stack

```bash
docker compose \
  -f docker-compose.eventbazaar.yaml \
  --env-file .env.eventbazaar.local \
  up -d
```

## Step 5 — Verify

```bash
# UI health check
curl -L https://otel-ui.eventbazaar.com/api/v1/health

# OTLP HTTP (expect 200 or 400 — not a connection error)
curl -X POST https://otel-push.eventbazaar.com/v1/traces \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[]}'

# Container resource usage
docker stats --no-stream

# Logs (all services)
docker compose -f docker-compose.eventbazaar.yaml logs --tail=50
```

---

## SDK Configuration

Configure your instrumented applications with these environment variables:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://otel-push.eventbazaar.com:443
# Or individually:
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://otel-push.eventbazaar.com:443
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://otel-push.eventbazaar.com:443
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://otel-push.eventbazaar.com:443
```

For gRPC exporters, ensure the SDK uses TLS (most do automatically on port 443).

For HTTP exporters, the full paths are:
- `/v1/traces`
- `/v1/metrics`
- `/v1/logs`

---

## Certificate Renewal

Add a cron job or systemd timer to renew and redeploy certs:

```bash
# /etc/cron.d/signoz-certbot
0 3 * * * root certbot renew --quiet && \
  docker exec signoz-eb-nginx nginx -s reload
```

---

## Upgrading SigNoz

```bash
# Update VERSION in .env.eventbazaar.local, then:
docker compose \
  -f docker-compose.eventbazaar.yaml \
  --env-file .env.eventbazaar.local \
  pull && \
docker compose \
  -f docker-compose.eventbazaar.yaml \
  --env-file .env.eventbazaar.local \
  up -d
```

## Backup

```bash
# SQLite state (users, dashboards, alerts)
docker run --rm \
  -v signoz-eb-sqlite:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/signoz-sqlite-$(date +%F).tar.gz /data

# ClickHouse data (for full telemetry backup)
docker exec signoz-eb-clickhouse clickhouse-backup create signoz-$(date +%F)
```
