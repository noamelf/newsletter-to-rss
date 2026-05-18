# Newsletter-to-RSS

Self-hosted n8n workflow that extracts individual links from aggregated newsletters and generates RSS feeds for Feedbin.

## Architecture

```
Gmail (newsletter-rss label)
  → n8n (extract links, clean, dedupe, fetch titles)
    → RSS XML files (per-newsletter + combined)
      → Caddy serves over HTTPS
        → Feedbin subscribes
```

## Deployment

### 1. DNS

Create A records pointing to your Hetzner instance:
```
n8n.noamelf.com    → <HETZNER_IP>
feeds.noamelf.com  → <HETZNER_IP>
```

### 2. Server Setup

```bash
# Copy files to server
scp docker-compose.yml Caddyfile backup.sh setup.sh root@<HETZNER_IP>:/opt/newsletter-rss/

# SSH in and run setup
ssh root@<HETZNER_IP>
cd /opt/newsletter-rss
chmod +x setup.sh backup.sh
./setup.sh
docker compose up -d
```

### 3. n8n Setup

1. Open https://n8n.noamelf.com
2. Create your n8n account
3. Add Gmail OAuth2 credentials (see below)
4. Import the workflow from `workflow.json`
5. Activate the workflow

### 4. Gmail OAuth2

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create/select a project
3. Enable Gmail API
4. Create OAuth 2.0 credentials (Web application)
5. Redirect URI: `https://n8n.noamelf.com/rest/oauth2-credential/callback`
6. In n8n: Credentials → New → Gmail OAuth2 → paste Client ID & Secret → Connect

### 5. Gmail Filters

Create filters for each newsletter:
- From: `newsletter@example.com`
- Apply label: `newsletter-rss`

### 6. Feedbin

Subscribe to:
- Combined: `https://feeds.noamelf.com/<FEED_TOKEN>/all.xml`
- Per-newsletter: `https://feeds.noamelf.com/<FEED_TOKEN>/<sender-slug>.xml`

(Find your FEED_TOKEN in `/opt/newsletter-rss/.env` on the server)

## Backups

Daily backup via cron:
```bash
# Add to crontab
0 3 * * * /opt/newsletter-rss/backup.sh >> /var/log/newsletter-rss-backup.log 2>&1
```

## Updates

```bash
cd /opt/newsletter-rss
./backup.sh  # backup first
docker compose pull
docker compose up -d
```

## Security Checklist

- [x] HTTPS via Caddy (automatic)
- [x] n8n bound to 127.0.0.1 only
- [x] Postgres not exposed
- [x] Feed path is unguessable
- [x] state.json blocked from public access
- [ ] Hetzner firewall: allow only 22, 80, 443
- [ ] SSH: key-only auth
- [ ] Consider Tailscale/Cloudflare Access for n8n UI
