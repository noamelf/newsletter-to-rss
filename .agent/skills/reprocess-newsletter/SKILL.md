---
name: reprocess-newsletter
description: Use when the user wants to reprocess, re-trigger, or re-extract a previously seen newsletter email through the n8n workflow. Also use when feed output looks wrong and needs regeneration, or when workflow changes need to be verified against real data.
---

# Reprocess Newsletter

Force the n8n workflow to re-process a previously seen Gmail message by removing it from the Gmail Trigger's `possibleDuplicates` list in PostgreSQL.

## Why This Exists

The Gmail Trigger node tracks seen message IDs in `staticData.possibleDuplicates` to avoid re-processing. This state **cannot be modified via the n8n public API** — `staticData` changes in PUT/PATCH requests are silently ignored. The only path is direct PostgreSQL access.

## Prerequisites

- SSH access: `ssh root@n8n.noamelf.com`
- Docker project dir: `/opt/newsletter-rss`
- Workflow ID: `A3ZlbZ8PUi0CvLvs`
- n8n API key: query from DB with `SELECT "apiKey" FROM user_api_keys LIMIT 1;`

## Procedure

**⚠️ Order is critical: DEACTIVATE → UPDATE DB → REACTIVATE. Violating this order will lose your changes.**

### 1. Get the API key

```bash
ssh root@n8n.noamelf.com "cd /opt/newsletter-rss && \
  docker compose exec -T postgres psql -U n8n -d n8n -c \
  \"SELECT \\\"apiKey\\\" FROM user_api_keys LIMIT 1;\""
```

### 2. Deactivate the workflow

Deactivation flushes in-memory `staticData` to the database. You must deactivate **before** modifying the DB, otherwise the flush overwrites your update.

```bash
curl -s -X POST http://localhost:5678/api/v1/workflows/A3ZlbZ8PUi0CvLvs/deactivate \
  -H "X-N8N-API-KEY: $API_KEY"
```

### 3. Read current staticData

```bash
docker compose exec -T postgres psql -U n8n -d n8n -c \
  "SELECT \"staticData\" FROM workflow_entity WHERE id = 'A3ZlbZ8PUi0CvLvs';"
```

Output looks like:
```json
{"node:Gmail Trigger":{"lastTimeChecked":1779104342249,"possibleDuplicates":["19e3fa720b41cc23","19e3ec180192c546","19e56be1a4bd7470"]}}
```

### 4. Update staticData — remove target message ID

Remove the message ID you want to reprocess from the `possibleDuplicates` array. Keep all other IDs to avoid re-processing old newsletters.

```bash
docker compose exec -T postgres psql -U n8n -d n8n -c "
  UPDATE workflow_entity
  SET \"staticData\" = '{\"node:Gmail Trigger\":{\"lastTimeChecked\":1779104342249,\"possibleDuplicates\":[\"19e3fa720b41cc23\",\"19e3ec180192c546\"]}}'
  WHERE id = 'A3ZlbZ8PUi0CvLvs';"
```

### 5. Optionally clear feed files

If you want a completely fresh feed (no stale items):

```bash
rm -f /opt/newsletter-rss/feeds/396cbfc5186f36a43a8cd04ca43d1ef7/*.xml \
      /opt/newsletter-rss/feeds/396cbfc5186f36a43a8cd04ca43d1ef7/state.json
```

### 6. Reactivate the workflow

Reactivation reads `staticData` from DB, so it picks up your changes.

```bash
curl -s -X POST http://localhost:5678/api/v1/workflows/A3ZlbZ8PUi0CvLvs/activate \
  -H "X-N8N-API-KEY: $API_KEY"
```

### 7. Wait and verify

The Gmail Trigger polls every minute. Wait ~75 seconds, then check:

```bash
curl -s "https://feeds.noamelf.com/396cbfc5186f36a43a8cd04ca43d1ef7/all.xml" | head -30
```

## Finding a Message ID

The last entry in `possibleDuplicates` is typically the most recent newsletter. To correlate IDs with newsletter names, cross-reference the `addedAt` timestamps in `state.json` against execution times.

**state.json is a flat list** (not `{"items": [...]}`) — iterate it directly:

```bash
ssh root@n8n.noamelf.com "cat /opt/newsletter-rss/feeds/*/state.json" | python3 -c "
import json, sys
items = json.load(sys.stdin)  # list, not dict
for item in items[-5:]:
    print(item.get('addedAt'), item.get('senderSlug'), item.get('title'))
"
```

Cross-reference with execution times:

```bash
ssh root@n8n.noamelf.com "curl -s 'http://localhost:5678/api/v1/executions?workflowId=A3ZlbZ8PUi0CvLvs&limit=5' \
  -H 'X-N8N-API-KEY: $API_KEY'" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for ex in data.get('data', []):
    print(ex.get('id'), ex.get('startedAt'), ex.get('status'))
"
```

The most recently added items in `state.json` will have `addedAt` timestamps matching the execution `startedAt` — that execution's position in `possibleDuplicates` is the ID to remove (last entry = most recent).

## Common Mistakes

| Mistake | Consequence |
|---------|-------------|
| Update DB before deactivating | Deactivation flushes in-memory state, overwrites your DB change |
| Try to update staticData via API | Silently ignored — change appears accepted but isn't persisted |
| Remove all message IDs | All historical newsletters reprocess, creating duplicate feed items |
| Forget to delete `state.json` | Old items persist in feed alongside new ones (may be desired) |
