#!/usr/bin/env python3
"""MCP server exposing the Vane (Perplexica) AI answer engine to OpenClaw.

Vane synthesizes an answer from web sources retrieved via SearXNG, with
inline citations. Use this when you want a researched response rather
than a list of search hits.

Designed to run inside the OpenClaw microVM as an mcporter stdio child.
Talks to https://vane.vulcan.lan over HTTPS using the Vulcan Step-CA root
trusted at the system level.

Provider/model selection is discovered at first call by GET-ing
``/api/config`` and picking the first chat+embedding model that matches
the configured preferences. The full config response is **never logged
or returned** — only the IDs/keys we need are extracted from it. This
matters because that endpoint also exposes the LiteLLM apiKey.

Environment variables:
  VANE_BASE_URL         default: https://vane.vulcan.lan
  VANE_TIMEOUT_S        default: 600 (seconds — Vane synthesizes from web
                        sources and can take several minutes; pair this with
                        a matching `mcporter --timeout 600000` from callers)
  VANE_CHAT_MODEL_KEY   optional override; if set, must match a key in
                        Vane's modelProviders[].chatModels[].key
  VANE_EMBED_MODEL_KEY  optional override (same shape as above)
"""

import json
import os
import threading
from typing import Any

import requests
from mcp.server.fastmcp import FastMCP

BASE_URL = os.getenv("VANE_BASE_URL", "https://vane.vulcan.lan").rstrip("/")
TIMEOUT_S = float(os.getenv("VANE_TIMEOUT_S", "600"))
PREFERRED_CHAT_KEY = os.getenv("VANE_CHAT_MODEL_KEY", "").strip() or None
PREFERRED_EMBED_KEY = os.getenv("VANE_EMBED_MODEL_KEY", "").strip() or None

VALID_FOCUS_MODES = frozenset(
    {
        "webSearch",
        "academicSearch",
        "writingAssistant",
        "wolframAlphaSearch",
        "youtubeSearch",
        "redditSearch",
    }
)

VALID_OPTIMIZATION_MODES = frozenset({"speed", "balanced", "quality"})

# Mapping from public focus_mode to the internal `sources` field that
# Vane uses to gate which engines run. Vane's API requires both fields;
# omitting `sources` returns a 400 "Missing sources or query".
FOCUS_TO_SOURCES = {
    "webSearch": ["web"],
    "academicSearch": ["academic"],
    "writingAssistant": ["web"],
    "wolframAlphaSearch": ["web"],
    "youtubeSearch": ["web"],
    "redditSearch": ["reddit"],
}


_provider_lock = threading.Lock()
_provider_cache: dict[str, str] | None = None


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _discover_models() -> dict[str, str]:
    """Return ``{providerId, chatKey, embedKey}`` from /api/config.

    Caches the result process-wide. Never logs the response body — that
    body contains the LiteLLM apiKey for the configured provider.
    """
    global _provider_cache
    with _provider_lock:
        if _provider_cache is not None:
            return _provider_cache

        resp = requests.get(f"{BASE_URL}/api/config", timeout=TIMEOUT_S)
        resp.raise_for_status()
        # Extract only the fields we need; do not log or return the body.
        payload = resp.json()
        providers = (
            (payload.get("values") or {}).get("modelProviders") or []
        )

        chat_provider_id: str | None = None
        chat_key: str | None = None
        embed_provider_id: str | None = None
        embed_key: str | None = None

        for p in providers:
            pid = p.get("id")
            if not pid:
                continue
            chats = p.get("chatModels") or []
            embeds = p.get("embeddingModels") or []
            if chat_key is None and chats:
                if PREFERRED_CHAT_KEY:
                    for m in chats:
                        if m.get("key") == PREFERRED_CHAT_KEY:
                            chat_key = m["key"]
                            chat_provider_id = pid
                            break
                else:
                    chat_key = chats[0].get("key")
                    if chat_key:
                        chat_provider_id = pid
            if embed_key is None and embeds:
                if PREFERRED_EMBED_KEY:
                    for m in embeds:
                        if m.get("key") == PREFERRED_EMBED_KEY:
                            embed_key = m["key"]
                            embed_provider_id = pid
                            break
                else:
                    embed_key = embeds[0].get("key")
                    if embed_key:
                        embed_provider_id = pid

        del payload, providers  # encourage gc; do not let the body linger

        if not (chat_key and chat_provider_id and embed_key and embed_provider_id):
            raise RuntimeError(
                "Vane has no usable chat+embedding model pair configured"
            )

        _provider_cache = {
            "chat_provider_id": chat_provider_id,
            "chat_key": chat_key,
            "embed_provider_id": embed_provider_id,
            "embed_key": embed_key,
        }
        return _provider_cache


def _ask_vane(
    query: str,
    focus_mode: str,
    optimization_mode: str,
    history: list[list[str]] | None,
    system_instructions: str | None,
) -> dict[str, Any]:
    """POST to /api/search with stream=false and return the parsed body."""
    models = _discover_models()
    body: dict[str, Any] = {
        "query": query,
        "sources": FOCUS_TO_SOURCES.get(focus_mode, ["web"]),
        "focusMode": focus_mode,
        "optimizationMode": optimization_mode,
        "stream": False,
        "history": history or [],
        "systemInstructions": system_instructions,
        "chatModel": {
            "providerId": models["chat_provider_id"],
            "key": models["chat_key"],
        },
        "embeddingModel": {
            "providerId": models["embed_provider_id"],
            "key": models["embed_key"],
        },
    }
    resp = requests.post(
        f"{BASE_URL}/api/search",
        json=body,
        timeout=TIMEOUT_S,
        headers={"Accept": "application/json"},
    )
    resp.raise_for_status()
    return resp.json()


mcp = FastMCP("vane")


@mcp.tool()
def web_research(
    query: str,
    focus_mode: str = "webSearch",
    optimization_mode: str = "speed",
    history: list[list[str]] | None = None,
    system_instructions: str | None = None,
) -> str:
    """Ask Vane (Perplexica) for an AI-synthesized answer with citations.

    Vane runs SearXNG behind the scenes, ranks the hits, fetches the
    pages, and asks an LLM to compose an answer that cites the sources
    inline. Use this for "what does the web say about X?" style queries
    where you want a digest. For raw result lists, use ``web_search``
    from the searxng MCP server.

    Args:
      query: the question to research.
      focus_mode: research style. One of:
        - ``webSearch``     — general web (default)
        - ``academicSearch``— scholarly papers
        - ``writingAssistant`` — phrasing/writing help with web context
        - ``wolframAlphaSearch`` — computational queries
        - ``youtubeSearch`` — video-focused
        - ``redditSearch``  — Reddit discussions
      optimization_mode: ``speed`` (default), ``balanced``, or ``quality``.
        ``quality`` follows more links and takes longer.
      history: optional prior conversation as a list of ``[role, text]``
        pairs, where role is ``human`` or ``assistant``. Used so Vane can
        resolve pronouns like "it" or "that". Default: no history.
      system_instructions: optional system-level instructions to bias
        the answer style (e.g. "Cite each fact with a numbered source.").

    Returns JSON: ``{"answer": "...", "sources": [{"title", "url",
    "content"}], "focus_mode": "...", "optimization_mode": "..."}``.
    """
    if not query.strip():
        return _err("query is empty")
    if focus_mode not in VALID_FOCUS_MODES:
        return _err(
            f"focus_mode must be one of {sorted(VALID_FOCUS_MODES)}; got {focus_mode!r}"
        )
    if optimization_mode not in VALID_OPTIMIZATION_MODES:
        return _err(
            f"optimization_mode must be one of {sorted(VALID_OPTIMIZATION_MODES)}"
        )

    try:
        data = _ask_vane(
            query=query,
            focus_mode=focus_mode,
            optimization_mode=optimization_mode,
            history=history,
            system_instructions=system_instructions,
        )
    except requests.Timeout:
        return _err(f"Vane timed out after {TIMEOUT_S}s")
    except requests.ConnectionError as exc:
        return _err(f"could not reach Vane at {BASE_URL}: {exc}")
    except requests.HTTPError as exc:
        body = exc.response.text[:200] if exc.response is not None else ""
        status = exc.response.status_code if exc.response is not None else "?"
        return _err(f"Vane HTTP {status}: {body}")
    except RuntimeError as exc:
        return _err(str(exc))
    except (ValueError, requests.RequestException) as exc:
        return _err(f"Vane request failed: {exc}")

    sources_out = []
    for s in (data.get("sources") or [])[:25]:
        meta = s.get("metadata") or {}
        sources_out.append(
            {
                "title": meta.get("title") or s.get("title"),
                "url": meta.get("url") or s.get("url"),
                "content": (s.get("pageContent") or s.get("content") or "")[:1000],
            }
        )

    return json.dumps(
        {
            "answer": data.get("message", ""),
            "sources": sources_out,
            "focus_mode": focus_mode,
            "optimization_mode": optimization_mode,
        }
    )


if __name__ == "__main__":
    mcp.run()
