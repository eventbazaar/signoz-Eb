#!/usr/bin/env bash
# =============================================================================
# SigNoz EventBazaar — Full Server Setup Script
# Ubuntu 22.04 / 24.04 LTS
# Server: 4 vCPU · 16 GB RAM · 200 GB NVMe
# =============================================================================
set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ─── Config ──────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/eventbazaar/signoz-Eb.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/signoz-eb}"
DOMAIN_UI="otel-ui.eventbazaar.com"
DOMAIN_OTEL="otel-push.eventbazaar.com"
CERT_EMAIL="${CERT_EMAIL:-}"   # set via env or prompted below
COMPOSE_FILE="docker-compose.eventbazaar.yaml"
ENV_FILE=".env.eventbazaar.local"

# ─── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root:  sudo bash setup-eventbazaar.sh"

# ─── Detect Ubuntu ───────────────────────────────────────────────────────────
. /etc/os-release
[[ "$ID" == "ubuntu" ]] || die "This script targets Ubuntu. Detected: $ID"
info "Ubuntu $VERSION_ID detected"

# =============================================================================
section "1 · System prerequisites"
# =============================================================================
export DEBIAN_FRONTEND=noninteractive

info "Updating package lists…"
apt-get update -qq

info "Installing base packages…"
apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release \
    git wget openssl ufw \
    certbot \
    software-properties-common \
    htop iotop ncdu \
    unattended-upgrades apt-listchanges

# =============================================================================
section "2 · System tuning"
# =============================================================================

info "Setting kernel parameters for ClickHouse…"
cat > /etc/sysctl.d/99-signoz.conf <<'EOF'
# ClickHouse recommended settings
vm.max_map_count = 262144
vm.swappiness = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
fs.file-max = 1048576
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
EOF
sysctl -p /etc/sysctl.d/99-signoz.conf -q

info "Setting file descriptor limits…"
cat > /etc/security/limits.d/99-signoz.conf <<'EOF'
*    soft nofile 262144
*    hard nofile 262144
root soft nofile 262144
root hard nofile 262144
EOF

# =============================================================================
section "3 · Docker Engine"
# =============================================================================

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    success "Docker + Compose plugin already installed — skipping"
else
    info "Adding Docker's official GPG key and repository…"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    info "Installing Docker Engine and Compose plugin…"
    apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    success "Docker $(docker --version | awk '{print $3}' | tr -d ',') installed"
fi

# Configure Docker daemon (log rotation, live-restore)
info "Configuring Docker daemon…"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
systemctl reload docker || systemctl restart docker

# =============================================================================
section "4 · Firewall (UFW)"
# =============================================================================

info "Configuring UFW…"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp    comment 'HTTP (ACME + redirect)'
ufw allow 443/tcp   comment 'HTTPS (UI + OTLP)'
ufw --force enable
success "Firewall active — ports 22, 80, 443 open"

# =============================================================================
section "5 · Clone repository"
# =============================================================================

if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Repository already exists at $INSTALL_DIR — pulling latest…"
    git -C "$INSTALL_DIR" pull --ff-only
else
    info "Cloning $REPO_URL → $INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR/deploy/docker"
success "Working directory: $(pwd)"

# =============================================================================
section "6 · Environment file"
# =============================================================================

if [[ -f "$ENV_FILE" ]]; then
    warn "$ENV_FILE already exists — skipping generation (delete it to regenerate)"
else
    info "Generating $ENV_FILE with a random JWT secret…"
    JWT_SECRET=$(openssl rand -hex 32)
    cp .env.eventbazaar "$ENV_FILE"
    sed -i "s/CHANGE_ME_BEFORE_FIRST_RUN/${JWT_SECRET}/" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    success "JWT secret generated and saved to $ENV_FILE"
fi

# =============================================================================
section "7 · TLS certificates (Let's Encrypt)"
# =============================================================================

CERT_DIR_UI="/etc/letsencrypt/live/${DOMAIN_UI}"
CERT_DIR_OTEL="/etc/letsencrypt/live/${DOMAIN_OTEL}"

needs_cert=false
[[ -f "${CERT_DIR_UI}/fullchain.pem"   ]] || needs_cert=true
[[ -f "${CERT_DIR_OTEL}/fullchain.pem" ]] || needs_cert=true

if $needs_cert; then
    if [[ -z "$CERT_EMAIL" ]]; then
        read -rp "Enter email address for Let's Encrypt notifications: " CERT_EMAIL
    fi

    info "Stopping any existing service on port 80 for ACME challenge…"
    systemctl stop nginx 2>/dev/null || true

    info "Obtaining certificate for $DOMAIN_UI…"
    certbot certonly --standalone \
        --non-interactive --agree-tos \
        --email "$CERT_EMAIL" \
        -d "$DOMAIN_UI"

    info "Obtaining certificate for $DOMAIN_OTEL…"
    certbot certonly --standalone \
        --non-interactive --agree-tos \
        --email "$CERT_EMAIL" \
        -d "$DOMAIN_OTEL"

    success "Certificates obtained"
else
    success "Certificates already present — skipping"
fi

# Copy certs into the Docker volume
section "7a · Copy certs into Docker volume"

info "Creating nginx-certs volume and loading certificates…"
docker volume create signoz-eb-nginx-certs 2>/dev/null || true

# Let's Encrypt stores real files in /etc/letsencrypt/archive/ and only
# symlinks in /live/. Docker volume mounts do not follow symlinks, so we
# copy directly on the host using cp -L (dereference) into the volume
# mountpoint — no intermediate container needed.
VOLUME_PATH=$(docker volume inspect signoz-eb-nginx-certs --format '{{ .Mountpoint }}')
mkdir -p "${VOLUME_PATH}/${DOMAIN_UI}" "${VOLUME_PATH}/${DOMAIN_OTEL}"

cp -L "${CERT_DIR_UI}/fullchain.pem"   "${VOLUME_PATH}/${DOMAIN_UI}/fullchain.pem"
cp -L "${CERT_DIR_UI}/privkey.pem"     "${VOLUME_PATH}/${DOMAIN_UI}/privkey.pem"
cp -L "${CERT_DIR_OTEL}/fullchain.pem" "${VOLUME_PATH}/${DOMAIN_OTEL}/fullchain.pem"
cp -L "${CERT_DIR_OTEL}/privkey.pem"   "${VOLUME_PATH}/${DOMAIN_OTEL}/privkey.pem"

chmod 600 \
    "${VOLUME_PATH}/${DOMAIN_UI}/privkey.pem" \
    "${VOLUME_PATH}/${DOMAIN_OTEL}/privkey.pem"

success "Certificates loaded into Docker volume (${VOLUME_PATH})"

# =============================================================================
section "8 · Auto-renewal cron"
# =============================================================================

RENEW_SCRIPT="/etc/cron.weekly/signoz-cert-renew"
cat > "$RENEW_SCRIPT" <<CRONEOF
#!/usr/bin/env bash
# Weekly Let's Encrypt renewal + nginx reload for SigNoz EventBazaar
# Uses cp -L to dereference symlinks from /etc/letsencrypt/live/ before
# copying into the Docker volume mountpoint directly on the host.
set -euo pipefail

certbot renew --quiet

VOLUME_PATH=\$(docker volume inspect signoz-eb-nginx-certs --format '{{ .Mountpoint }}')
cp -L /etc/letsencrypt/live/${DOMAIN_UI}/fullchain.pem   "\${VOLUME_PATH}/${DOMAIN_UI}/fullchain.pem"
cp -L /etc/letsencrypt/live/${DOMAIN_UI}/privkey.pem     "\${VOLUME_PATH}/${DOMAIN_UI}/privkey.pem"
cp -L /etc/letsencrypt/live/${DOMAIN_OTEL}/fullchain.pem "\${VOLUME_PATH}/${DOMAIN_OTEL}/fullchain.pem"
cp -L /etc/letsencrypt/live/${DOMAIN_OTEL}/privkey.pem   "\${VOLUME_PATH}/${DOMAIN_OTEL}/privkey.pem"
chmod 600 "\${VOLUME_PATH}/${DOMAIN_UI}/privkey.pem" "\${VOLUME_PATH}/${DOMAIN_OTEL}/privkey.pem"

docker exec signoz-eb-nginx nginx -s reload
CRONEOF
chmod +x "$RENEW_SCRIPT"
success "Weekly renewal cron installed at $RENEW_SCRIPT"

# =============================================================================
section "9 · Pull Docker images"
# =============================================================================

info "Pulling images (this may take a few minutes)…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
success "Images pulled"

# =============================================================================
section "10 · Start the stack"
# =============================================================================

info "Starting SigNoz stack…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
success "Stack started"

# =============================================================================
section "11 · Health check"
# =============================================================================

info "Waiting for SigNoz to become healthy (up to 3 minutes)…"
for i in $(seq 1 36); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/api/v1/health" 2>/dev/null || true)
    if [[ "$HTTP" == "200" ]]; then
        success "SigNoz is healthy (internal check passed)"
        break
    fi
    if [[ $i -eq 36 ]]; then
        warn "SigNoz did not report healthy within 3 minutes."
        warn "Run: docker compose -f ${COMPOSE_FILE} logs --tail=50"
    fi
    echo -n "."
    sleep 5
done
echo ""

# =============================================================================
section "12 · Systemd service (auto-start on reboot)"
# =============================================================================

WORK_DIR="$INSTALL_DIR/deploy/docker"
cat > /etc/systemd/system/signoz-eb.service <<SVCEOF
[Unit]
Description=SigNoz EventBazaar stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${WORK_DIR}
ExecStart=/usr/bin/docker compose -f ${COMPOSE_FILE} --env-file ${WORK_DIR}/${ENV_FILE} up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f ${COMPOSE_FILE} --env-file ${WORK_DIR}/${ENV_FILE} down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable signoz-eb
success "signoz-eb.service enabled (auto-starts on boot)"

# =============================================================================
section "Done!"
# =============================================================================

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "<your-server-ip>")

echo ""
echo -e "${GREEN}${BOLD}SigNoz EventBazaar is running!${NC}"
echo ""
echo -e "  UI:        ${CYAN}https://${DOMAIN_UI}${NC}"
echo -e "  OTLP gRPC: ${CYAN}https://${DOMAIN_OTEL}:443${NC}"
echo -e "  OTLP HTTP: ${CYAN}https://${DOMAIN_OTEL}:443/v1/{traces,metrics,logs}${NC}"
echo ""
echo -e "${BOLD}SDK environment variables for your apps:${NC}"
echo "  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://${DOMAIN_OTEL}:443"
echo "  OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://${DOMAIN_OTEL}:443"
echo "  OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://${DOMAIN_OTEL}:443"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  Logs:    docker compose -f ${WORK_DIR}/${COMPOSE_FILE} logs -f"
echo "  Status:  docker compose -f ${WORK_DIR}/${COMPOSE_FILE} ps"
echo "  Stats:   docker stats --no-stream"
echo "  Restart: systemctl restart signoz-eb"
echo ""
echo -e "${YELLOW}First login: open https://${DOMAIN_UI} and create your admin account.${NC}"
echo ""
