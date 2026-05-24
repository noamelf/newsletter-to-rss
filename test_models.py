#!/usr/bin/env python3
"""Benchmark OpenRouter models for newsletter link extraction.

Usage:
  # Test with a local HTML file:
  OPENROUTER_API_KEY=sk-or-... python3 test_models.py newsletter.html

  # Fetch real newsletter from live server (requires SSH access):
  OPENROUTER_API_KEY=sk-or-... python3 test_models.py --from-server

  # Test specific models only:
  OPENROUTER_API_KEY=sk-or-... python3 test_models.py newsletter.html -m gemini-2.0-flash-001 gpt-5.4-nano

  # Skip HTTP verification (faster):
  OPENROUTER_API_KEY=sk-or-... python3 test_models.py newsletter.html --no-http

  # Fetch pricing info:
  OPENROUTER_API_KEY=sk-or-... python3 test_models.py --list-models
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field

API_KEY = os.environ.get("OPENROUTER_API_KEY", "")
API_URL = "https://openrouter.ai/api/v1/chat/completions"

SYSTEM_PROMPT = (
    'You extract article links from newsletter emails and return JSON.\n\n'
    'Output format: {"links": [{"url": "https://...", "title": "Article Title", '
    '"description": "1-2 sentence summary of what the article covers"}]}\n\n'
    'Rules:\n'
    '- Extract only meaningful article/content links (blog posts, articles, tools, resources)\n'
    '- Skip: tracking URLs, social media (twitter/x.com, facebook, instagram, linkedin, '
    'youtube, tiktok, threads), unsubscribe/preferences/manage-subscription links, '
    'image files (.png/.jpg/.gif/.svg/.webp/.ico), root domains with no path, '
    'email platform links (mailchimp, beehiiv, substack, convertkit, sendgrid, buttondown)\n'
    '- Clean URLs: strip tracking params (utm_*, mc_cid, mc_eid, fbclid, gclid, etc.), '
    'unwrap redirect/tracking wrappers\n'
    '- Titles: use anchor text if descriptive, otherwise infer from URL path and context\n'
    '- Descriptions: extract or synthesize 1-2 sentences about the article from surrounding '
    'newsletter text; if no context is available, leave as empty string\n'
    '- Deduplicate by URL\n'
    '- If no content links found, return {"links": []}'
)

DEFAULT_MODELS = [
    "google/gemini-2.5-flash",
    "google/gemini-2.5-flash-lite",
    "google/gemini-2.0-flash-001",
    "google/gemini-2.0-flash-lite-001",
    "google/gemma-4-26b-a4b-it",
    "openai/gpt-5.4-nano",
    "openai/gpt-4.1-nano",
    "anthropic/claude-3-haiku",
    "deepseek/deepseek-v4-flash",
    "meta-llama/llama-4-scout",
    "qwen/qwen3-235b-a22b-2507",
    "mistralai/mistral-small-3.2-24b-instruct",
]


@dataclass
class ModelResult:
    model: str
    links: list = field(default_factory=list)
    elapsed: float = 0.0
    tokens_in: int = 0
    tokens_out: int = 0
    error: str = ""
    http_ok: int = 0
    http_fail: int = 0
    http_errors: list = field(default_factory=list)
    hallucinated: int = 0
    hallucinated_urls: list = field(default_factory=list)


def extract_source_urls(html: str) -> set[str]:
    """Extract all URLs present in the source HTML."""
    urls = set()
    for m in re.finditer(r'href=["\']([^"\']+)["\']', html):
        raw = m.group(1)
        urls.add(raw)
        # Also extract wrapped/redirect targets
        redir = re.search(r'[?&]url=([^&]+)', raw)
        if redir:
            urls.add(urllib.request.unquote(redir.group(1)))
    return urls


def normalize_url(url: str) -> str:
    try:
        from urllib.parse import urlparse
        p = urlparse(url)
        return (p.scheme + "://" + p.netloc + p.path.rstrip("/")).lower()
    except Exception:
        return url.lower()


def check_hallucination(extracted_url: str, source_urls: set[str]) -> bool:
    """Return True if the URL appears hallucinated (not in source HTML)."""
    norm = normalize_url(extracted_url)
    for src in source_urls:
        if norm in normalize_url(src) or normalize_url(src) in norm:
            return False
        # Check if domain+path prefix matches (model may have cleaned URL)
        if len(norm) > 20 and norm[:40] in normalize_url(src):
            return False
    return True


def http_check(url: str, timeout: int = 8) -> tuple[bool, str]:
    """HEAD-check a URL. Returns (ok, error_msg)."""
    try:
        req = urllib.request.Request(url, method="HEAD", headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        })
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return (r.status < 400, f"{r.status}")
    except urllib.error.HTTPError as e:
        return (False, f"{e.code}")
    except Exception as e:
        return (False, f"ERR:{type(e).__name__}")


def call_model(model: str, html: str) -> ModelResult:
    """Call a single model and return results."""
    result = ModelResult(model=model)

    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": html},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.1,
    }).encode()

    req = urllib.request.Request(API_URL, data=body, headers={
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    })

    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
        result.elapsed = time.time() - start

        content = data["choices"][0]["message"]["content"]
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError:
            m = re.search(r"\{[\s\S]*\}", content)
            parsed = json.loads(m.group()) if m else {"links": []}

        result.links = parsed.get("links", [])
        usage = data.get("usage", {})
        result.tokens_in = usage.get("prompt_tokens", 0)
        result.tokens_out = usage.get("completion_tokens", 0)

    except Exception as e:
        result.elapsed = time.time() - start
        body_text = ""
        if hasattr(e, "read"):
            try:
                body_text = e.read().decode()[:200]
            except Exception:
                pass
        result.error = body_text or str(e)[:150]

    return result


def run_hallucination_check(result: ModelResult, source_urls: set[str]) -> None:
    if not source_urls:
        return
    for link in result.links:
        url = link.get("url", "")
        if check_hallucination(url, source_urls):
            result.hallucinated += 1
            result.hallucinated_urls.append(url)


def run_http_checks(result: ModelResult, max_checks: int = 15) -> None:
    urls = [l["url"] for l in result.links[:max_checks] if l.get("url")]
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(http_check, u): u for u in urls}
        for f in as_completed(futures):
            ok, msg = f.result()
            if ok:
                result.http_ok += 1
            else:
                result.http_fail += 1
                result.http_errors.append(f"  {msg} {futures[f][:70]}")


def fetch_newsletter_from_server() -> str:
    """Fetch the latest newsletter HTML from the live n8n server."""
    print("Fetching newsletter from server...", flush=True)
    cmd = """
    API_KEY=$(cd /opt/newsletter-rss && docker compose exec -T postgres psql -U n8n -d n8n -t -c "SELECT \\"apiKey\\" FROM user_api_keys LIMIT 1;" | tr -d ' \\n')
    EXEC_ID=$(curl -s -H "X-N8N-API-KEY: $API_KEY" 'http://localhost:5678/api/v1/executions?status=success&limit=1' | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])")
    curl -s -H "X-N8N-API-KEY: $API_KEY" "http://localhost:5678/api/v1/executions/$EXEC_ID?includeData=true" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rd = data['data']['resultData']['runData']
items = rd.get('Normalize Email', [{}])[0].get('data', {}).get('main', [[]])[0]
if items:
    print(items[0].get('json', {}).get('html', ''))
"
    """
    r = subprocess.run(
        ["ssh", "root@n8n.noamelf.com", cmd],
        capture_output=True, text=True, timeout=30,
    )
    html = r.stdout.strip()
    if not html or len(html) < 100:
        print(f"Failed to fetch newsletter: {r.stderr[:200]}", file=sys.stderr)
        sys.exit(1)
    print(f"Got newsletter: {len(html)} chars")
    return html


def list_models() -> None:
    """List cheap models available on OpenRouter."""
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/models",
        headers={"Authorization": f"Bearer {API_KEY}"},
    )
    with urllib.request.urlopen(req) as r:
        models = json.loads(r.read())["data"]

    print(f"{'Model':<55} {'$/M in':>7} {'$/M out':>8} {'Context':>8}")
    print("-" * 82)
    for m in sorted(models, key=lambda x: float(x.get("pricing", {}).get("completion", "999"))):
        p = m.get("pricing", {})
        inp = float(p.get("prompt", "999")) * 1_000_000
        out = float(p.get("completion", "999")) * 1_000_000
        ctx = m.get("context_length", 0)
        if inp <= 0.5 and out <= 2.0 and ctx >= 30000 and inp > 0:
            print(f"{m['id']:<55} ${inp:>5.2f}  ${out:>6.2f}  {ctx:>7}")


def print_results(results: list[ModelResult], do_http: bool) -> None:
    print("\n" + "=" * 90)
    print("  RESULTS SUMMARY")
    print("=" * 90)

    header = f"{'Model':<42} {'Time':>5} {'Links':>5} {'Halluc':>6}"
    if do_http:
        header += f" {'HTTP✅':>6} {'HTTP❌':>6}"
    header += "  Status"
    print(header)
    print("-" * 90)

    for r in results:
        if r.error:
            print(f"{r.model:<42} {r.elapsed:>4.1f}s {'':>5} {'':>6}  ❌ {r.error[:40]}")
            continue

        status = "✅" if r.hallucinated == 0 and r.http_fail == 0 else "⚠️"
        if r.hallucinated > 0:
            status = f"❌ {r.hallucinated} hallucinated"
        elif r.http_fail > 0:
            status = f"⚠️  {r.http_fail} HTTP fails"

        line = f"{r.model:<42} {r.elapsed:>4.1f}s {len(r.links):>5} {r.hallucinated:>6}"
        if do_http:
            line += f" {r.http_ok:>6} {r.http_fail:>6}"
        line += f"  {status}"
        print(line)

    # Show hallucinated URLs
    for r in results:
        if r.hallucinated_urls:
            print(f"\n  {r.model} — hallucinated URLs:")
            for u in r.hallucinated_urls[:5]:
                print(f"    ❌ {u[:80]}")
            if len(r.hallucinated_urls) > 5:
                print(f"    ... and {len(r.hallucinated_urls) - 5} more")

    # Show HTTP errors
    if do_http:
        for r in results:
            if r.http_errors:
                print(f"\n  {r.model} — HTTP failures:")
                for e in r.http_errors[:5]:
                    print(f"    {e}")


def main():
    parser = argparse.ArgumentParser(description="Benchmark OpenRouter models for newsletter link extraction")
    parser.add_argument("html_file", nargs="?", help="Path to newsletter HTML file")
    parser.add_argument("--from-server", action="store_true", help="Fetch newsletter from live server via SSH")
    parser.add_argument("-m", "--models", nargs="+", help="Model IDs to test (partial match OK)")
    parser.add_argument("--no-http", action="store_true", help="Skip HTTP verification (faster)")
    parser.add_argument("--no-hallucination-check", action="store_true", help="Skip source-URL hallucination check")
    parser.add_argument("--list-models", action="store_true", help="List cheap models on OpenRouter and exit")
    parser.add_argument("--max-http", type=int, default=15, help="Max URLs to HTTP-check per model (default: 15)")
    parser.add_argument("--parallel", type=int, default=3, help="Max parallel model API calls (default: 3)")
    args = parser.parse_args()

    if not API_KEY:
        print("Set OPENROUTER_API_KEY environment variable", file=sys.stderr)
        sys.exit(1)

    if args.list_models:
        list_models()
        return

    # Load newsletter HTML
    if args.from_server:
        html = fetch_newsletter_from_server()
    elif args.html_file:
        with open(args.html_file) as f:
            html = f.read()
    else:
        parser.print_help()
        sys.exit(1)

    print(f"Newsletter: {len(html)} chars")

    # Resolve models
    models = DEFAULT_MODELS
    if args.models:
        resolved = []
        for pattern in args.models:
            matched = [m for m in DEFAULT_MODELS if pattern in m]
            if matched:
                resolved.extend(matched)
            else:
                resolved.append(pattern)  # assume full model ID
        models = resolved

    print(f"Testing {len(models)} models...")

    # Extract source URLs for hallucination check
    source_urls = set()
    if not args.no_hallucination_check:
        source_urls = extract_source_urls(html)
        print(f"Source HTML contains {len(source_urls)} URLs for hallucination check")

    # Run model calls in parallel
    results: list[ModelResult] = []
    with ThreadPoolExecutor(max_workers=args.parallel) as pool:
        futures = {pool.submit(call_model, m, html): m for m in models}
        for f in as_completed(futures):
            r = f.result()
            model_name = r.model.split("/")[-1]
            if r.error:
                print(f"  ❌ {model_name}: {r.error[:60]}")
            else:
                print(f"  ✓ {model_name}: {len(r.links)} links in {r.elapsed:.1f}s")

                if source_urls:
                    run_hallucination_check(r, source_urls)

                if not args.no_http and r.hallucinated == 0:
                    run_http_checks(r, args.max_http)

            results.append(r)

    # Sort by model order
    order = {m: i for i, m in enumerate(models)}
    results.sort(key=lambda r: order.get(r.model, 999))

    print_results(results, not args.no_http)


if __name__ == "__main__":
    main()
