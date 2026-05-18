#!/usr/bin/env bash
# Full deployment: Hetzner server + Cloudflare DNS + Docker setup
# Prerequisites: hcloud CLI authenticated, CLOUDFLARE_API_TOKEN env var set
set -euo pipefail

DOMAIN="noamelf.com"
N8N_DOMAIN="n8n.${DOMAIN}"
FEEDS_DOMAIN="feeds.${DOMAIN}"
CF_ZONE="${DOMAIN}"
PROJECT_DIR="/opt/newsletter-rss"
SERVER_NAME="newsletter-rss"
SSH_KEY_NAME=""  # Will be selected interactively

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Preflight checks ---
info "Checking prerequisites..."
command -v hcloud >/dev/null 2>&1 || error "hcloud CLI not found. Install: brew install hcloud"
command -v curl   >/dev/null 2>&1 || error "curl not found"
command -v jq     >/dev/null 2>&1 || error "jq not found. Install: brew install jq"
command -v ssh    >/dev/null 2>&1 || error "ssh not found"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  error "CLOUDFLARE_API_TOKEN not set. Export it: export CLOUDFLARE_API_TOKEN=your_token"
fi

# Verify Cloudflare token works
CF_VERIFY=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
if [[ "$(echo "$CF_VERIFY" | jq -r '.success')" != "true" ]]; then
  error "Cloudflare API token verification failed"
fi
info "Cloudflare token verified ✓"

# Verify hcloud context
hcloud context active >/dev/null 2>&1 || error "No active hcloud context. Run: hcloud context create <name>"
info "hcloud context: $(hcloud context active)"

# ============================================================
# PHASE 1: Create Hetzner Server
# ============================================================
echo ""
info "=== Phase 1: Hetzner Server ==="

# Check if server already exists
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  warn "Server '$SERVER_NAME' already exists"
  SERVER_IP=$(hcloud server ip "$SERVER_NAME")
  info "Using existing server at $SERVER_IP"
else
  # Select SSH key
  info "Available SSH keys:"
  hcloud ssh-key list -o columns=name
  echo ""
  read -rp "SSH key name to use: " SSH_KEY_NAME

  # Select location
  info "Available locations:"
  hcloud location list -o columns=name,city
  echo ""
  read -rp "Location (default: fsn1): " LOCATION
  LOCATION="${LOCATION:-fsn1}"

  # Select server type
  info "Recommended types for this workload:"
  echo "  cpx11 - 2 vCPU, 2GB RAM, €4.85/mo (minimum)"
  echo "  cpx21 - 3 vCPU, 4GB RAM, €8.49/mo (comfortable)"
  echo ""
  read -rp "Server type (default: cpx11): " SERVER_TYPE
  SERVER_TYPE="${SERVER_TYPE:-cpx11}"

  info "Creating server: $SERVER_NAME ($SERVER_TYPE in $LOCATION)..."
  hcloud server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --location "$LOCATION" \
    --image docker-ce \
    --ssh-key "$SSH_KEY_NAME"

  SERVER_IP=$(hcloud server ip "$SERVER_NAME")
  info "Server created at $SERVER_IP ✓"

  # Wait for SSH
  info "Waiting for SSH to become available..."
  for i in {1..30}; do
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new "root@${SERVER_IP}" true 2>/dev/null; then
      break
    fi
    sleep 2
  done
  info "SSH ready ✓"
fi

# ============================================================
# PHASE 2: Hetzner Firewall
# ============================================================
echo ""
info "=== Phase 2: Firewall ==="

FW_NAME="${SERVER_NAME}-fw"
if hcloud firewall describe "$FW_NAME" >/dev/null 2>&1; then
  info "Firewall '$FW_NAME' already exists"
else
  info "Creating firewall..."
  hcloud firewall create --name "$FW_NAME"

  hcloud firewall add-rule "$FW_NAME" \
    --direction in --protocol tcp --port 22 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 \
    --description "SSH"

  hcloud firewall add-rule "$FW_NAME" \
    --direction in --protocol tcp --port 80 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 \
    --description "HTTP"

  hcloud firewall add-rule "$FW_NAME" \
    --direction in --protocol tcp --port 443 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 \
    --description "HTTPS"

  info "Firewall created ✓"
fi

# Apply firewall to server
hcloud firewall apply-to-resource "$FW_NAME" --type server --server "$SERVER_NAME" 2>/dev/null || true
info "Firewall applied to server ✓"

# ============================================================
# PHASE 3: Cloudflare DNS
# ============================================================
echo ""
info "=== Phase 3: Cloudflare DNS ==="

# Get zone ID
CF_ZONE_ID=$(curl -s -X GET \
  "https://api.cloudflare.com/client/v4/zones?name=${CF_ZONE}" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  | jq -r '.result[0].id')

if [[ -z "$CF_ZONE_ID" || "$CF_ZONE_ID" == "null" ]]; then
  error "Could not find Cloudflare zone for ${CF_ZONE}"
fi
info "Zone ID: $CF_ZONE_ID"

# Function to create/update DNS record
cf_dns_record() {
  local name="$1"
  local ip="$2"

  # Check if record exists
  local existing
  existing=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${name}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")

  local record_id
  record_id=$(echo "$existing" | jq -r '.result[0].id // empty')

  if [[ -n "$record_id" ]]; then
    # Update existing record
    curl -s -X PUT \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}" \
      | jq -r '.success' >/dev/null
    info "Updated DNS: $name → $ip"
  else
    # Create new record
    curl -s -X POST \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}" \
      | jq -r '.success' >/dev/null
    info "Created DNS: $name → $ip"
  fi
}

# proxied:false because Caddy handles TLS directly
cf_dns_record "$N8N_DOMAIN" "$SERVER_IP"
cf_dns_record "$FEEDS_DOMAIN" "$SERVER_IP"
info "DNS records configured ✓ (not proxied — Caddy handles TLS)"

# ============================================================
# PHASE 4: Deploy to Server
# ============================================================
echo ""
info "=== Phase 4: Deploy Application ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy project files to server
info "Copying files to server..."
ssh "root@${SERVER_IP}" "mkdir -p ${PROJECT_DIR}"
scp "${SCRIPT_DIR}/docker-compose.yml" "root@${SERVER_IP}:${PROJECT_DIR}/"
scp "${SCRIPT_DIR}/Caddyfile" "root@${SERVER_IP}:${PROJECT_DIR}/"
scp "${SCRIPT_DIR}/backup.sh" "root@${SERVER_IP}:${PROJECT_DIR}/"
scp "${SCRIPT_DIR}/workflow.json" "root@${SERVER_IP}:${PROJECT_DIR}/"

# Generate .env and start services on server
info "Initializing server..."
ssh "root@${SERVER_IP}" bash <<'REMOTE_SCRIPT'
set -euo pipefail
cd /opt/newsletter-rss

# Generate secrets if .env doesn't exist
if [[ ! -f .env ]]; then
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  FEED_TOKEN=$(openssl rand -hex 16)

  cat > .env <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
FEED_TOKEN=$FEED_TOKEN
N8N_DOMAIN=n8n.noamelf.com
FEEDS_DOMAIN=feeds.noamelf.com
TZ=Asia/Jerusalem
EOF

  chmod 600 .env
  echo "Generated new .env with secrets"
else
  echo ".env already exists, keeping existing secrets"
fi

source .env

# Create directories
mkdir -p n8n_data postgres_data caddy_data caddy_config
mkdir -p "feeds/${FEED_TOKEN}"

# Make backup executable
chmod +x backup.sh

# Start services
docker compose up -d

# Wait for services
echo "Waiting for services to start..."
sleep 10

# Check health
docker compose ps
REMOTE_SCRIPT

info "Services deployed ✓"

# ============================================================
# PHASE 5: Setup Backup Cron
# ============================================================
echo ""
info "=== Phase 5: Backup Cron ==="

ssh "root@${SERVER_IP}" bash <<'REMOTE_SCRIPT'
# Add backup cron if not already present
if ! crontab -l 2>/dev/null | grep -q "newsletter-rss/backup.sh"; then
  (crontab -l 2>/dev/null; echo "0 3 * * * /opt/newsletter-rss/backup.sh >> /var/log/newsletter-rss-backup.log 2>&1") | crontab -
  echo "Backup cron added (daily at 3am)"
else
  echo "Backup cron already exists"
fi
REMOTE_SCRIPT

info "Backup cron configured ✓"

# ============================================================
# PHASE 6: Verify
# ============================================================
echo ""
info "=== Phase 6: Verification ==="

# Get feed token from server
FEED_TOKEN=$(ssh "root@${SERVER_IP}" "source /opt/newsletter-rss/.env && echo \$FEED_TOKEN")

# Wait for Caddy to get TLS certs
info "Waiting for TLS certificates (may take 30-60s)..."
sleep 15

# Test n8n
N8N_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${N8N_DOMAIN}" 2>/dev/null || echo "000")
if [[ "$N8N_STATUS" == "200" || "$N8N_STATUS" == "302" ]]; then
  info "n8n is live at https://${N8N_DOMAIN} ✓"
else
  warn "n8n returned HTTP $N8N_STATUS — may still be starting up. Check: https://${N8N_DOMAIN}"
fi

# Test feeds
FEEDS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${FEEDS_DOMAIN}/${FEED_TOKEN}/" 2>/dev/null || echo "000")
info "Feeds endpoint: HTTP $FEEDS_STATUS"

echo ""
echo "============================================"
echo ""
info "🎉 Deployment complete!"
echo ""
echo "  n8n UI:     https://${N8N_DOMAIN}"
echo "  Server IP:  ${SERVER_IP}"
echo "  Feed token: ${FEED_TOKEN}"
echo ""
echo "  Feed URLs (after workflow runs):"
echo "    Combined:       https://${FEEDS_DOMAIN}/${FEED_TOKEN}/all.xml"
echo "    Per-newsletter: https://${FEEDS_DOMAIN}/${FEED_TOKEN}/<sender-slug>.xml"
echo ""
echo "  Next steps:"
echo "    1. Open https://${N8N_DOMAIN} and create your account"
echo "    2. Add Gmail OAuth2 credentials"
echo "    3. Import workflow.json (in /opt/newsletter-rss/ on server)"
echo "    4. Create Gmail label 'newsletter-rss' + filters"
echo "    5. Activate the workflow"
echo "    6. Subscribe Feedbin to the feed URL"
echo ""
