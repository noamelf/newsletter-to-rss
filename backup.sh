#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/backups/newsletter-rss"
PROJECT_DIR="/opt/newsletter-rss"
DATE="$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"

# Postgres dump (compressed)
if ! docker compose -f "${PROJECT_DIR}/docker-compose.yml" \
  exec -T postgres pg_dump -U n8n n8n \
  | gzip > "$BACKUP_DIR/n8n-db-$DATE.sql.gz"; then
  echo "ERROR: pg_dump failed at $DATE" >&2
  exit 1
fi

# Config and feed state
if ! tar -czf "$BACKUP_DIR/newsletter-rss-$DATE.tar.gz" \
  "${PROJECT_DIR}/docker-compose.yml" \
  "${PROJECT_DIR}/Caddyfile" \
  "${PROJECT_DIR}/.env" \
  "${PROJECT_DIR}/feeds"; then
  echo "ERROR: tar backup failed at $DATE" >&2
  exit 1
fi

# Prune backups older than 14 days
find "$BACKUP_DIR" -type f -mtime +14 -delete

echo "Backup completed: $DATE"
