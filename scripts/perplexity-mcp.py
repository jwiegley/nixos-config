#!/usr/bin/env python3
"""MCP server exposing the Perplexity AI answer engine to OpenClaw.

Perplexity synthesizes an answer from live web sources and returns it with
citations. Use this when you want a researched, sourced response rather
than a list of raw search hits.

Designed to run inside the OpenClaw microVM as an mcporter stdio child.
Talks to the public Perplexity API at https://api.perplexity.ai over HTTPS.

The API key is read from the PERPLEXITY_API_KEY environment variable — a
wrapper exports it from /run/secrets. The key is **never logged, echoed, or
returned**; only the Bearer header carries it, and error paths surface
status/body text but never the Authorization header.

Environment variables:
  PERPLEXITY_API_KEY  required; the Perplexity API key (sk-...).
  PERPLEXITY_BASE_URL default: https://api.perplexity.ai
  PERPLEXITY_MODEL    default: sonar (overridable per call via the model arg)
  PERPLEXITY_TIMEOUT_S default: 60 (seconds — Perplexity searches the web and
                       can take a while; pair with a matching mcporter timeout)
"""

import json
import os
from typing import Any

import requests
from mcp.server.fastmcp import FastMCP

BASE_URL = os.getenv("PERPLEXITY_BASE_URL", "https://api.perplexity.ai").rstrip("/")
DEFAULT_MODEL = os.getenv("PERPLEXITY_MODEL", "sonar").strip() or "sonar"
TIMEOUT_S = float(os.getenv("PERPLEXITY_TIMEOUT_S", "60"))


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _ask_perplexity(query: str, model: str) -> dict[str, Any]:
    """POST a single user turn to /chat/completions and return the body.

    The API key is pulled fresh from the environment here so the process
    never caches it. It travels only in the Authorization header.
    """
    api_key = os.getenv("PERPLEXITY_API_KEY", "").strip()
    if not api_key:
        # Raise so the caller maps it to a clean _err without touching the key.
        raise RuntimeError("PERPLEXITY_API_KEY is not set in the environment")

    body = {
        "model": model,
        "messages": [{"role": "user", "content": query}],
    }
    resp = requests.post(
        f"{BASE_URL}/chat/completions",
        json=body,
        timeout=TIMEOUT_S,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    resp.raise_for_status()
    return resp.json()


mcp = FastMCP("perplexity")


@mcp.tool()
def web_search(query: str, model: str = "") -> str:
    """Ask Perplexity for an AI-synthesized answer with web citations.

    Perplexity searches the live web, ranks the hits, and asks an LLM to
    compose a sourced answer. Use this for "what does the web say about X?"
    style queries where you want a digest with references. For raw result
    lists use ``web_search`` from the searxng MCP server; for the self-hosted
    Vane engine use ``web_research``.

    Args:
      query: the question to research.
      model: Perplexity model to use. Empty (default) uses the
        PERPLEXITY_MODEL env var (``sonar``). Other common values include
        ``sonar-pro`` and ``sonar-reasoning``.

    Returns JSON: ``{"answer": "...", "citations": [...], "model": "..."}``.
    ``citations`` is the list of source URLs Perplexity attributes the
    answer to (empty when the API returns none).
    """
    if not query.strip():
        return _err("query is empty")

    chosen_model = model.strip() or DEFAULT_MODEL

    try:
        data = _ask_perplexity(query, chosen_model)
    except requests.Timeout:
        return _err(f"Perplexity timed out after {TIMEOUT_S}s")
    except requests.ConnectionError as exc:
        return _err(f"could not reach Perplexity at {BASE_URL}: {exc}")
    except requests.HTTPError as exc:
        body = exc.response.text[:200] if exc.response is not None else ""
        status = exc.response.status_code if exc.response is not None else "?"
        return _err(f"Perplexity HTTP {status}: {body}")
    except RuntimeError as exc:
        return _err(str(exc))
    except (ValueError, requests.RequestException) as exc:
        return _err(f"Perplexity request failed: {exc}")

    # Pull the assistant message out of the first choice.
    choices = data.get("choices") or []
    answer = ""
    if choices:
        answer = (choices[0].get("message") or {}).get("content", "") or ""

    # Citations may surface at the top level or, on newer responses, as
    # structured search_results; accept either and normalize to a URL list.
    citations = data.get("citations") or []
    if not citations:
        citations = [
            r.get("url")
            for r in (data.get("search_results") or [])
            if r.get("url")
        ]

    return json.dumps(
        {
            "answer": answer,
            "citations": citations,
            "model": data.get("model", chosen_model),
        }
    )


if __name__ == "__main__":
    mcp.run()
