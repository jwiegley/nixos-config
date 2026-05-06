#!/usr/bin/env python3
"""MCP server exposing stock-trader research tools to OpenClaw.

Designed to run inside the OpenClaw microVM as an mcporter stdio child.
Wraps the stock-trader REST API at https://trader.vulcan.lan with eight
named MCP tools.

Environment variables:
  STOCK_TRADER_BASE_URL   default: https://trader.vulcan.lan
  STOCK_TRADER_TIMEOUT_S  default: 30 (seconds)

The script trusts the system CA bundle. The microVM's
security.pki.certificates already includes the Vulcan Step-CA root, so
TLS validation succeeds for trader.vulcan.lan.
"""

import json
import os
from typing import Any

import requests
from mcp.server.fastmcp import FastMCP

BASE_URL = os.getenv("STOCK_TRADER_BASE_URL", "https://trader.vulcan.lan").rstrip("/")
TIMEOUT_S = float(os.getenv("STOCK_TRADER_TIMEOUT_S", "30"))


def _request(
    method: str,
    path: str,
    *,
    params: dict[str, Any] | None = None,
    json_body: dict[str, Any] | None = None,
) -> str:
    """Call stock-trader and return a JSON string.

    On any failure (HTTP error, timeout, network error, decode error)
    return ``{"error": "<message>"}`` so the LLM can explain to the
    user. Never raises.
    """
    url = f"{BASE_URL}{path}"
    try:
        resp = requests.request(
            method,
            url,
            params=params,
            json=json_body,
            timeout=TIMEOUT_S,
        )
    except requests.Timeout:
        return json.dumps({"error": f"timed out after {TIMEOUT_S}s calling {path}"})
    except requests.ConnectionError as exc:
        return json.dumps({"error": f"could not reach stock-trader: {exc}"})
    except requests.RequestException as exc:
        return json.dumps({"error": f"request failed: {exc}"})

    if resp.status_code >= 400:
        body = resp.text[:500]
        return json.dumps(
            {"error": f"HTTP {resp.status_code} from {path}: {body}"}
        )

    try:
        return json.dumps(resp.json())
    except ValueError:
        return json.dumps({"error": f"non-JSON response from {path}"})


mcp = FastMCP("stock-trader")


@mcp.tool()
def get_quote(symbol: str) -> str:
    """Fetch the current quote for a US stock.

    `symbol` is a US ticker like ``AAPL``, ``TSLA``, or ``NVDA``.
    Translate company names to tickers yourself before calling.

    Returns JSON with current price, bid/ask, day high/low, change,
    change percent, market cap, P/E ratio, and previous close.
    """
    return _request("GET", f"/api/quote/{symbol.upper()}")


if __name__ == "__main__":
    mcp.run(transport="stdio")
