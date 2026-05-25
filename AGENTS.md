# Newsletter-to-RSS

Self-hosted n8n workflow that extracts links from Gmail newsletters and serves them as RSS feeds via Caddy.

## Architecture

```
Gmail (newsletter-rss label)
  → n8n (AI extract links via OpenRouter → dedupe)
    → /feeds/<FEED_TOKEN>/<slug>.xml + feeds.opml + state.json
      → Caddy (HTTPS, feeds.noamelf.com)
        → RSS reader (NetNewsWire, Feedbin, etc.)
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

1. **Gmail Trigger** — polls label `newsletter-rss` every minute
2. **Fetch Full Message** — Gmail API call for full body
3. **Normalize Email** — extracts headers (subject, from, date), decodes base64 body
4. **AI Extract Links** — Basic LLM Chain (gemini-2.5-flash-lite via OpenRouter) extracts article links with titles and descriptions from newsletter HTML, skipping tracking/social/junk links
5. **OpenRouter Chat Model** — sub-node providing the LLM to AI Extract Links
6. **Parse AI Output** — parses the LLM JSON response into individual items with newsletter metadata; handles both pre-parsed JSON (`.links` array) and text fallback
7. **Deduplicate Within Run** — dedupes by URL within a single execution
8. **Read Existing State** — reads `/feeds/<token>/state.json` (persists across runs)
9. **Merge and Deduplicate** — SHA-256 GUID per URL, keeps latest 500 items, stores description per item
10. **Generate RSS and Write Files** — writes per-sender `<slug>.xml` (with favicon via Google's s2/favicons), generates `feeds.opml` for easy import, updates `state.json`

## RSS Output

- Each RSS item includes: title, link, GUID, pubDate, description (AI-extracted + source newsletter), source
- Per-sender feeds include an `<image>` element with the newsletter domain's favicon (via `https://www.google.com/s2/favicons?domain=<domain>&sz=128`)
- Descriptions format: `"<AI description> — From: <subject> (<sender>)"`

## Conventions

- Feed files live at `/feeds/<FEED_TOKEN>/` inside the container, mounted from `./feeds/` on the host
- Sender slugs: email local-part, lowercased, non-alphanumeric → `-`, max 40 chars
- GUIDs: `sha256(url).slice(0, 32)` — stable, URL-based
- `state.json` is the source of truth for seen items; it's never served publicly (Caddy returns 403)
- `NODE_FUNCTION_ALLOW_BUILTIN: "fs,crypto,path,url"` is required in n8n for Code nodes to work
- n8n runs as user `1000:1000`; ensure `./feeds` and `./n8n_data` are writable by that UID

## Live Instance

- **Server**: `ssh root@n8n.noamelf.com` (Hetzner)
- **n8n UI**: `https://n8n.noamelf.com`
- **Feeds**: `https://feeds.noamelf.com/<FEED_TOKEN>/feeds.opml`
- **Workflow ID**: `A3ZlbZ8PUi0CvLvs`
- **Docker project dir**: `/opt/newsletter-rss`
- **Feed token (live)**: hardcoded in Read Existing State node (local `workflow.json` uses `process.env.FEED_TOKEN`)

## Deployment

```bash
export CLOUDFLARE_API_TOKEN=your_token
./setup.sh   # creates Hetzner server, DNS, deploys Docker stack
```

After deploy: open n8n UI → import `workflow.json` → add Gmail OAuth2 credentials → add OpenRouter API credentials → activate.

## Deploying Workflow Changes

To update the live workflow after editing `workflow.json`:

1. Use the n8n public API (`PUT /api/v1/workflows/<id>`) with the API key from the `user_api_keys` table
2. The API ignores `staticData` — it cannot be updated via REST (see below)
3. Settings must only include known fields (`executionOrder`, `timezone`, etc.) or the API returns 400

## Reprocessing a Newsletter

See `.agent/skills/reprocess-newsletter/SKILL.md` for the full step-by-step procedure.

**TL;DR**: deactivate workflow → update PostgreSQL `staticData` (remove message ID from `possibleDuplicates`) → optionally delete feed files → reactivate. Order is critical — deactivation flushes in-memory state to DB, so you must deactivate before modifying.

## Updates

```bash
ssh root@n8n.noamelf.com "cd /opt/newsletter-rss && ./backup.sh && docker compose pull && docker compose up -d"
```

## Known Limitations

- **`staticData` cannot be updated via n8n public API** — PATCH/PUT silently accept but don't persist. Must update PostgreSQL directly.
- **Basic LLM Chain with `responseFormat: json_object`** returns pre-parsed JSON on `items[i].json` (e.g., `.links` is an array), NOT wrapped in a `.text` string. Parse AI Output handles both cases.
- **Per-sender feed favicons** depend on the newsletter website having a proper favicon. Many newsletter platforms (MailerLite, Beehiiv, etc.) serve their own generic favicon instead of the newsletter's brand icon.
