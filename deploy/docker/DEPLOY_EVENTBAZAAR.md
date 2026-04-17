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

- Docker Engine ≥ 24 with the Compose plugin (`docker compose` v2)
- Two DNS A records pointing to the server's public IP:
  - `otel-ui.eventbazaar.com`
  - `otel-push.eventbazaar.com`
- Ports 80 and 443 open in the server firewall
- In `deploy/docker`: committed **`.env.eventbazaar`** (defaults) and gitignored **`.env.eventbazaar.local`** (secrets and overrides). The `signoz` service loads both via `env_file` so secrets reach the container, not only Compose interpolation.

---

## Step 1 — Clone & navigate

```bash
git clone https://github.com/your-org/signoz-Eb.git
cd signoz-Eb/deploy/docker
```

## Step 2 — Prepare the environment file

```bash
cp .env.eventbazaar .env.eventbazaar.local
# Generate a strong JWT secret and set SIGNOZ_JWT_SECRET (used by Compose as ${SIGNOZ_JWT_SECRET} → container):
JWT=$(openssl rand -hex 32)
sed -i "s/CHANGE_ME_BEFORE_FIRST_RUN/$JWT/" .env.eventbazaar.local
```

> `.env.eventbazaar.local` is gitignored — never commit it.

### Compose `--env-file` vs service `env_file`

- **`docker compose --env-file .env.eventbazaar.local`** only supplies variables for **substitution** in `docker-compose.eventbazaar.yaml` (for example `${SIGNOZ_JWT_SECRET}`).
- Variables that SigNoz reads at runtime (for example **`SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD`**) must appear in a file listed under the **`signoz` service `env_file`** in the compose file. This stack loads **`.env.eventbazaar`** then **`.env.eventbazaar.local`** (same directory as the compose file); the second file overrides the first for duplicate keys. **`.env.eventbazaar.local` must exist** before `up` (create it with `cp .env.eventbazaar .env.eventbazaar.local` in Step 2).

### Alertmanager email (Gmail / Google Workspace)

Global SMTP is configured in **`signoz-config.yaml`** under `alertmanager.signoz.global` (`smtp.gmail.com:587`, `smtp_from`, `smtp_auth_username`, and an empty `smtp_auth_password` in YAML — password must not live in git).

Add the Gmail **app password** to **`.env.eventbazaar.local`** using the **exact** SigNoz variable name (double underscores are required):

```bash
# Append or edit in .env.eventbazaar.local.
# Use DOUBLE quotes for values that contain spaces (single quotes are often parsed wrong by Docker env_file):
SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD="your 16 char app password"
# Or use the app password without spaces (no quotes needed):
# SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD=vocgfguwufbarxab
```

After editing, **recreate** the SigNoz container so env is re-read:  
`docker compose -f docker-compose.eventbazaar.yaml --env-file .env.eventbazaar.local up -d --force-recreate signoz`

Do **not** rely on a generic name such as `GMAIL_SMTP_APP_PASSWORD` unless you map it yourself; the SigNoz process only merges keys that match the `SIGNOZ_…` hierarchy above.

After the stack is up, you can confirm the variable is present inside the container (do not paste the value into tickets or chat):

```bash
docker exec signoz-eb sh -c 'test -n "$SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD" && echo password_is_set || echo password_missing'
```

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

# Logs (all services) — always pass the same --env-file as for `up`
docker compose \
  -f docker-compose.eventbazaar.yaml \
  --env-file .env.eventbazaar.local \
  logs --tail=50
```

If you configured Alertmanager SMTP in Step 2, use **Settings → Notification channels → Email → Test** in the UI after `password_is_set` succeeds from the check above.

### Team invite emails (Organization members)

SigNoz team invites and password-reset emails do **not** use `alertmanager.signoz.global.smtp_*`. They use the SigNoz `emailing` SMTP config. In this stack, `docker-compose.eventbazaar.yaml` maps:

- `SIGNOZ_EMAILING_ENABLED=true`
- `SIGNOZ_EMAILING_SMTP_ADDRESS=smtp.gmail.com:587`
- `SIGNOZ_EMAILING_SMTP_FROM=dev@eventbazaar.com`
- `SIGNOZ_EMAILING_SMTP_AUTH_USERNAME=dev@eventbazaar.com`
- `SIGNOZ_EMAILING_SMTP_AUTH_PASSWORD=${SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD}`

So setting `SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD` in `.env.eventbazaar.local` enables both Alertmanager email channels and user invite emails.

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

---

## Stopping the stack

```bash
docker compose \
  -f docker-compose.eventbazaar.yaml \
  --env-file .env.eventbazaar.local \
  down
```
