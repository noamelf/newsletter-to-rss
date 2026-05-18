#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/backups/newsletter-rss"
DATE="$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"

# Postgres dump
docker compose -f /opt/newsletter-rss/docker-compose.yml \
  exec -T postgres pg_dump -U n8n n8n \
  > "$BACKUP_DIR/n8n-db-$DATE.sql"

# Config and feed state
tar -czf "$BACKUP_DIR/newsletter-rss-$DATE.tar.gz" \
  /opt/newsletter-rss/docker-compose.yml \
  /opt/newsletter-rss/Caddyfile \
  /opt/newsletter-rss/.env \
  /opt/newsletter-rss/feeds

# Prune backups older than 14 days
find "$BACKUP_DIR" -type f -mtime +14 -delete

echo "Backup completed: $DATE"
