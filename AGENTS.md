# Newsletter-to-RSS

Self-hosted n8n workflow that extracts links from Gmail newsletters and serves them as RSS feeds via Caddy.

## Architecture

```
Gmail (newsletter-rss label)
  → n8n (AI extract links via OpenRouter → dedupe)
    → /feeds/<FEED_TOKEN>/<slug>.xml + all.xml + state.json
      → Caddy (HTTPS, feeds.noamelf.com)
        → Feedbin
```

**Services** (docker-compose.yml): `postgres`, `n8n`, `caddy`

## Key Files

- `workflow.json` — the n8n workflow (import into n8n UI after deploy)
- `Caddyfile` — serves `/feeds` as static files; blocks `state.json` (403); sets RSS content-type
- `docker-compose.yml` — all services; n8n bound to `127.0.0.1:5678`
- `.env.example` → `.env` — secrets: `POSTGRES_PASSWORD`, `FEED_TOKEN`, `N8N_DOMAIN`, `FEEDS_DOMAIN`, `TZ`
- `setup.sh` — one-command deploy to Hetzner + Cloudflare DNS
- `backup.sh` — daily `pg_dump` with 14-day retention

## n8n Workflow Pipeline

The workflow nodes in order:

1. **Gmail Trigger** — polls label `newsletter-rss` every 5 min
2. **Fetch Full Message** — Gmail API call for full body
3. **Normalize Email** — extracts headers (subject, from, date), decodes base64 body
4. **AI Extract Links** — Basic LLM Chain (gemini-2.5-flash via OpenRouter) extracts article links with titles from newsletter HTML, skipping tracking/social/junk links
5. **OpenRouter Chat Model** — sub-node providing the LLM to AI Extract Links
6. **Parse AI Output** — parses the LLM JSON response into individual items with newsletter metadata
7. **Deduplicate Within Run** — dedupes by URL within a single execution
8. **Read Existing State** — reads `/feeds/<token>/state.json` (persists across runs)
9. **Merge and Deduplicate** — SHA-256 GUID per URL, keeps latest 500 items
10. **Generate RSS and Write Files** — writes `all.xml`, per-sender `<slug>.xml`, updates `state.json`

## Conventions

- Feed files live at `/feeds/<FEED_TOKEN>/` inside the container, mounted from `./feeds/` on the host
- Sender slugs: email local-part, lowercased, non-alphanumeric → `-`, max 40 chars
- GUIDs: `sha256(url).slice(0, 32)` — stable, URL-based
- `state.json` is the source of truth for seen items; it's never served publicly (Caddy returns 403)
- `NODE_FUNCTION_ALLOW_BUILTIN: "fs,crypto,path,url"` is required in n8n for Code nodes to work
- n8n runs as user `1000:1000`; ensure `./feeds` and `./n8n_data` are writable by that UID

## Deployment

```bash
export CLOUDFLARE_API_TOKEN=your_token
./setup.sh   # creates Hetzner server, DNS, deploys Docker stack
```

After deploy: open n8n UI → import `workflow.json` → add Gmail OAuth2 credentials → add OpenRouter API credentials → activate.

## Updates

```bash
ssh root@<SERVER_IP> "cd /opt/newsletter-rss && ./backup.sh && docker compose pull && docker compose up -d"
```
