#!/usr/bin/env python3
"""MCP server exposing SearXNG metasearch to OpenClaw.

Designed to run inside the OpenClaw microVM as an mcporter stdio child.
Wraps the SearXNG JSON API at https://searxng.vulcan.lan with privacy-
respecting metasearch tools.

Environment variables:
  SEARXNG_BASE_URL   default: https://searxng.vulcan.lan
  SEARXNG_TIMEOUT_S  default: 20 (seconds)
  SEARXNG_LANGUAGE   default: en
  SEARXNG_SAFESEARCH default: 0 (0=off, 1=moderate, 2=strict)

The script trusts the system CA bundle. The microVM's
security.pki.certificates already includes the Vulcan Step-CA root, so
TLS validation succeeds for searxng.vulcan.lan.
"""

import json
import os
from typing import Any

import requests
from mcp.server.fastmcp import FastMCP

BASE_URL = os.getenv("SEARXNG_BASE_URL", "https://searxng.vulcan.lan").rstrip("/")
TIMEOUT_S = float(os.getenv("SEARXNG_TIMEOUT_S", "20"))
DEFAULT_LANGUAGE = os.getenv("SEARXNG_LANGUAGE", "en")
DEFAULT_SAFESEARCH = os.getenv("SEARXNG_SAFESEARCH", "0")

# SearXNG categories that group engines. Only those configured on the
# instance will return results — querying an unconfigured category is
# silently empty rather than an error.
VALID_CATEGORIES = frozenset(
    {
        "general",
        "images",
        "videos",
        "news",
        "map",
        "music",
        "it",
        "science",
        "files",
        "social media",
    }
)

# SearXNG time-range filter values accepted by the JSON API.
VALID_TIME_RANGES = frozenset({"", "day", "week", "month", "year"})


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _searxng(
    query: str,
    *,
    categories: list[str] | None,
    time_range: str,
    language: str,
    safesearch: str,
    page: int,
) -> dict[str, Any]:
    """Run a SearXNG search and return the parsed JSON."""
    params: dict[str, Any] = {
        "q": query,
        "format": "json",
        "language": language,
        "safesearch": safesearch,
        "pageno": str(page),
    }
    if categories:
        params["categories"] = ",".join(categories)
    if time_range:
        params["time_range"] = time_range

    resp = requests.get(
        f"{BASE_URL}/search",
        params=params,
        timeout=TIMEOUT_S,
        headers={"Accept": "application/json"},
    )
    resp.raise_for_status()
    return resp.json()


mcp = FastMCP("searxng")


@mcp.tool()
def web_search(
    query: str,
    num_results: int = 10,
    categories: str = "general",
    time_range: str = "",
    language: str = "",
    safesearch: int = -1,
    page: int = 1,
) -> str:
    """Search the web via SearXNG metasearch (DuckDuckGo, Bing, Wikipedia, etc.).

    Returns a list of search results — title, url, content snippet, source
    engines, and score — drawn from multiple search engines simultaneously.
    No tracking, no profiling. Use this when you want raw search results to
    inspect; use ``web_research`` (Vane) when you want an AI-synthesized
    answer with citations.

    Args:
      query: search terms. Supports SearXNG bang shortcuts like ``!wp paris``
        (Wikipedia) or ``!gh react`` (GitHub).
      num_results: maximum results to return (1–30). Default 10.
      categories: comma-separated list of SearXNG categories. Common values:
        ``general``, ``news``, ``images``, ``videos``, ``science``,
        ``it``, ``files``, ``social media``, ``map``, ``music``. Default
        ``general``.
      time_range: limit by recency. One of ``""`` (any time, default),
        ``day``, ``week``, ``month``, ``year``.
      language: result language code (e.g. ``en``, ``de``, ``fr``).
        Default uses the SEARXNG_LANGUAGE env var (``en``).
      safesearch: 0=off, 1=moderate, 2=strict. ``-1`` (default) uses the
        SEARXNG_SAFESEARCH env var.
      page: 1-based page number. Default 1.

    Returns JSON: ``{"query": ..., "num_results": N, "results": [...]}``.
    Each result has ``title``, ``url``, ``content``, ``engines``, ``score``,
    and (when available) ``publishedDate``.
    """
    if not query.strip():
        return _err("query is empty")
    if num_results < 1 or num_results > 30:
        return _err("num_results must be between 1 and 30")
    if time_range not in VALID_TIME_RANGES:
        return _err(
            f"time_range must be one of {sorted(VALID_TIME_RANGES)}; got {time_range!r}"
        )
    if page < 1 or page > 10:
        return _err("page must be between 1 and 10")

    cat_list = [c.strip() for c in categories.split(",") if c.strip()]
    unknown = [c for c in cat_list if c not in VALID_CATEGORIES]
    if unknown:
        return _err(
            f"unknown categories {unknown}; valid: {sorted(VALID_CATEGORIES)}"
        )

    lang = language.strip() or DEFAULT_LANGUAGE
    ss = str(safesearch) if safesearch in (0, 1, 2) else DEFAULT_SAFESEARCH

    try:
        data = _searxng(
            query,
            categories=cat_list or None,
            time_range=time_range,
            language=lang,
            safesearch=ss,
            page=page,
        )
    except requests.Timeout:
        return _err(f"SearXNG timed out after {TIMEOUT_S}s")
    except requests.ConnectionError as exc:
        return _err(f"could not reach SearXNG at {BASE_URL}: {exc}")
    except requests.HTTPError as exc:
        body = exc.response.text[:200] if exc.response is not None else ""
        return _err(f"SearXNG HTTP {exc.response.status_code if exc.response else '?'}: {body}")
    except (ValueError, requests.RequestException) as exc:
        return _err(f"SearXNG request failed: {exc}")

    raw_results = data.get("results", []) or []
    trimmed = []
    for r in raw_results[:num_results]:
        trimmed.append(
            {
                "title": r.get("title"),
                "url": r.get("url"),
                "content": r.get("content"),
                "engines": r.get("engines") or [r.get("engine")] if r.get("engine") else [],
                "score": r.get("score"),
                "category": r.get("category"),
                "publishedDate": r.get("publishedDate"),
                "thumbnail": r.get("thumbnail") or None,
            }
        )

    return json.dumps(
        {
            "query": data.get("query", query),
            "num_results": len(trimmed),
            "total_estimate": data.get("number_of_results"),
            "results": trimmed,
            "suggestions": data.get("suggestions") or [],
            "infoboxes": [
                {"infobox": ib.get("infobox"), "content": ib.get("content")}
                for ib in (data.get("infoboxes") or [])
            ][:3],
        }
    )


@mcp.tool()
def search_news(query: str, num_results: int = 10, time_range: str = "week") -> str:
    """Search news via SearXNG (shortcut for category=news).

    Args:
      query: news topic.
      num_results: 1–30 (default 10).
      time_range: ``day`` / ``week`` (default) / ``month`` / ``year`` / ``""``.

    Returns the same JSON shape as ``web_search`` but restricted to news
    engines (DuckDuckGo News, Bing News, etc.).
    """
    return web_search(
        query=query,
        num_results=num_results,
        categories="news",
        time_range=time_range,
    )


if __name__ == "__main__":
    mcp.run()
