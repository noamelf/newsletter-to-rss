#!/usr/bin/env bash
# Run this on the Hetzner server to initialize the project
set -euo pipefail

PROJECT_DIR="/opt/newsletter-rss"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Generate secrets
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

# Create directories
mkdir -p n8n_data postgres_data caddy_data caddy_config
source .env
mkdir -p "feeds/${FEED_TOKEN}"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Secrets written to: $PROJECT_DIR/.env"
echo ""
echo "Your feed URLs will be:"
echo "  Combined: https://feeds.noamelf.com/${FEED_TOKEN}/all.xml"
echo "  Per-newsletter: https://feeds.noamelf.com/${FEED_TOKEN}/<sender-slug>.xml"
echo ""
echo "Next steps:"
echo "  1. Copy docker-compose.yml, Caddyfile, and backup.sh to $PROJECT_DIR"
echo "  2. Run: docker compose up -d"
echo "  3. Verify: curl -I https://n8n.noamelf.com"
echo ""
