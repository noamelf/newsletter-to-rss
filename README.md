# Newsletter-to-RSS

Self-hosted n8n workflow that extracts individual links from aggregated newsletters and generates RSS feeds for Feedbin.

## Architecture

```
Gmail (newsletter-rss label)
  → n8n (AI extract links via OpenRouter/gemini-2.5-flash, dedupe)
    → RSS XML files (per-newsletter + combined)
      → Caddy serves over HTTPS
        → Feedbin subscribes
```

## One-Command Deployment

Prerequisites:
- `hcloud` CLI authenticated (`hcloud context create myproject`)
- `CLOUDFLARE_API_TOKEN` env var with DNS edit permissions
- `jq` installed (`brew install jq`)

```bash
export CLOUDFLARE_API_TOKEN=your_token_here
./setup.sh
```

This will interactively:
1. Create a Hetzner server (Docker pre-installed)
2. Configure Hetzner firewall (22, 80, 443 only)
3. Create Cloudflare DNS records (n8n.noamelf.com, feeds.noamelf.com)
4. Deploy Docker Compose stack (n8n + Postgres + Caddy)
5. Generate secrets and feed token
6. Set up daily backup cron

## After Deployment

### 1. n8n Setup

1. Open https://n8n.noamelf.com
2. Create your n8n account
3. Add Gmail OAuth2 credentials (see below)
4. Add OpenRouter API credentials (Credentials → New → OpenRouter → paste API key)
5. Import `workflow.json` (already on server at `/opt/newsletter-rss/`)
6. Update the "OpenRouter Chat Model" node to use your OpenRouter credential
7. Activate the workflow

### 2. Gmail OAuth2

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create/select a project → Enable Gmail API
3. Create OAuth 2.0 credentials (Web application)
4. Redirect URI: `https://n8n.noamelf.com/rest/oauth2-credential/callback`
5. In n8n: Credentials → New → Gmail OAuth2 → paste Client ID & Secret → Connect

### 3. Gmail Filters

Create a label `newsletter-rss`, then add filters for each newsletter:
- From: `newsletter@example.com` → Apply label: `newsletter-rss`

### 4. Feedbin

Subscribe to your feeds (token shown at end of setup):
- Combined: `https://feeds.noamelf.com/<FEED_TOKEN>/all.xml`
- Per-newsletter: `https://feeds.noamelf.com/<FEED_TOKEN>/<sender-slug>.xml`

## Updates

```bash
ssh root@<SERVER_IP> "cd /opt/newsletter-rss && ./backup.sh && docker compose pull && docker compose up -d"
```

## Security

Handled automatically by `setup.sh`:
- ✅ HTTPS via Caddy (automatic Let's Encrypt)
- ✅ n8n bound to 127.0.0.1 only
- ✅ Postgres not exposed outside Docker
- ✅ Feed path is unguessable token
- ✅ state.json returns 403 publicly
- ✅ Hetzner firewall: only 22, 80, 443
- ✅ Daily backup with pg_dump + 14-day retention
