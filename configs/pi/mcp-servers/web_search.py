"""web_search.py - MCP server "web" for Pi: web search + page fetch in ONE process.

Base: duckduckgo-mcp-server==0.7.0, unchanged except two methods. Kept from upstream: tool
schemas/descriptions, fetch_content (SSRF guard on by default: loopback/private/link-local/metadata
refused, checked on every redirect; start_index/max_length pagination; 5-minute page cache;
text/main/markdown extraction) and the search/fetch rate limits (30/20 per minute).

Changed:
  1. Search uses ddgs==9.16.0 instead of DuckDuckGo. My ISP blocks duckduckgo.com at the DNS
     level, so upstream search returned nothing. ddgs engines on that network: yahoo 55-78% per
     attempt (random failures) -> up to 4 attempts; google 403, brave 429, startpage/mojeek
     parse nothing; bing always answers but ~50% of its results are unrelated (why ddgs
     disables it) -> last resort, kept only when a result contains >= half of the query words.
     Ad links are dropped.
  2. fetch_content max_length is clamped to [500, MAX_FETCH] characters to protect the context.

Install: uv tool install "duckduckgo-mcp-server[browser]==0.7.0" --with ddgs==9.16.0
Run:     <that tool's Scripts/python.exe> -I web_search.py [duckduckgo-mcp-server flags]
Installed as ~/.pi/agent/mcp-servers/web_search.py (see configs/pi/mcp.json).
"""
import asyncio
import re
import sys

import duckduckgo_mcp_server.server as srv
from ddgs import DDGS
from ddgs.engines.bing import Bing

ATTEMPTS = ["yahoo"] * 4 + ["bing"]
DEFAULT_REGION = "us-en"
MAX_FETCH = 16000
AD_MARKERS = ("bing.com/aclick", "r.search.yahoo.com/cbclk", "/aclk?")


def _yahoo(query: str, region: str, n: int) -> list:
    return DDGS(timeout=10).text(query, region=region, safesearch="moderate", max_results=n, backend="yahoo")


def _bing(query: str, region: str, n: int) -> list:
    found = Bing(proxy=None, timeout=10, verify=True).search(
        query, region=region, safesearch="moderate", timelimit=None, page=1) or []
    rows = [r if isinstance(r, dict) else dict(r.__dict__) for r in found]
    words = {w for w in re.findall(r"\w+", query.lower()) if len(w) >= 3}

    def relevant(r: dict) -> bool:
        text = set(re.findall(r"\w+", (r.get("title", "") + " " + r.get("body", "")).lower()))
        return not words or len(words & text) * 2 >= len(words)

    return [r for r in rows if relevant(r)][:n]


async def _search(self, query, ctx, max_results=10, region=""):
    await self.rate_limiter.acquire()
    n = max(1, min(int(max_results or 10), 20))
    reg = region or self.default_region or DEFAULT_REGION
    rows, last = [], None
    for i, engine in enumerate(ATTEMPTS):
        try:
            rows = await asyncio.to_thread(_yahoo if engine == "yahoo" else _bing, query, reg, n + 3)
        except Exception as e:  # noqa: BLE001 - every engine failure is retried/fallen back
            rows, last = [], e
        rows = [r for r in rows if r.get("href") and not any(m in r["href"] for m in AD_MARKERS)]
        if rows:
            break
        if i + 1 < len(ATTEMPTS):
            await asyncio.sleep(1.5)
    if not rows:
        print(f"web_search: no results for {query!r} ({last!r})", file=sys.stderr)
    return [
        srv.SearchResult(title=r.get("title", ""), link=r["href"], snippet=r.get("body", ""), position=i + 1)
        for i, r in enumerate(rows[:n])
    ]


_orig_format = srv.DuckDuckGoSearcher.format_results_for_llm


def _format(self, results):
    if not results:
        return ("No results found: every search engine failed or returned nothing (network or "
                "bot blocking). Rephrase the query (shorter, English keywords) or retry later.")
    return _orig_format(self, results)


_orig_fetch = srv.WebContentFetcher.fetch_and_parse


async def _fetch_and_parse(self, url, ctx, start_index=0, max_length=8000, backend=None, parse_mode=None):
    max_length = max(500, min(int(max_length or 8000), MAX_FETCH))
    return await _orig_fetch(self, url, ctx, start_index, max_length, backend=backend, parse_mode=parse_mode)


srv.DuckDuckGoSearcher.search = _search
srv.DuckDuckGoSearcher.format_results_for_llm = _format
srv.WebContentFetcher.fetch_and_parse = _fetch_and_parse

if __name__ == "__main__":
    srv.main()
