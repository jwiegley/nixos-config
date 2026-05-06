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


@mcp.tool()
def get_price_history(
    symbol: str,
    period: str = "1mo",
    interval: str = "1d",
) -> str:
    """Fetch historical price bars for a US stock.

    `symbol` is a US ticker like ``AAPL``. `period` accepts yfinance-style
    strings: ``1d``, ``5d``, ``1mo``, ``3mo``, ``6mo``, ``1y``, ``2y``,
    ``5y``, ``10y``, ``ytd``, ``max``. `interval` accepts ``1m``, ``5m``,
    ``15m``, ``30m``, ``1h``, ``1d``, ``1wk``, ``1mo``.

    Returns JSON with an OHLCV list under `data`.
    """
    return _request(
        "GET",
        f"/api/history/{symbol.upper()}",
        params={"period": period, "interval": interval},
    )


@mcp.tool()
def get_technical_analysis(symbol: str, timeframes: str = "1d") -> str:
    """Run a technical analysis report for a US stock.

    `symbol` is a US ticker like ``AAPL``. `timeframes` is a
    comma-separated list of bar sizes such as ``1h,1d,1wk``.

    Returns JSON with consensus trend/strength/confidence, per-timeframe
    indicator readings, entry zones, price targets, and a stop-loss.
    """
    return _request(
        "GET",
        f"/api/analysis/technical/{symbol.upper()}",
        params={"timeframes": timeframes},
    )


@mcp.tool()
def get_news_sentiment(symbol: str, hours_back: int = 24) -> str:
    """Fetch news sentiment, themes, and headlines for a US stock.

    `symbol` is a US ticker like ``AAPL``. `hours_back` (1-168) is the
    look-back window. Defaults to 24 (last day).

    Returns JSON with overall sentiment score, article count, themes,
    top headlines, upcoming catalysts, and risk factors.
    """
    return _request(
        "GET",
        f"/api/analysis/sentiment/{symbol.upper()}",
        params={"hours_back": hours_back},
    )


@mcp.tool()
def check_data_source_status() -> str:
    """Check whether stock-trader's primary Schwab data source is live.

    Use this when a quote looks stale or sentiment is empty — it tells
    you whether stock-trader is using live Schwab data or a yfinance
    fallback.

    Returns JSON with `configured`, `connected`, `expires_at`,
    `refresh_expires_at`, `days_remaining`, `stale`, and `expired`.
    """
    return _request("GET", "/api/schwab/status")


@mcp.tool()
def scan_market(
    preset: str = "oversold",
    min_price: float = 10.0,
    max_price: float = 500.0,
    limit: int = 10,
) -> str:
    """Scan the market for tickers matching a preset.

    `preset` is one of stock-trader's named scan presets (e.g.
    ``oversold``, ``momentum``, ``breakout``). `min_price`/`max_price`
    bracket the share-price range. `limit` caps the result count.

    Returns JSON with `preset`, `count`, and a `results` list — each
    entry has the ticker plus the preset's diagnostic fields.
    """
    return _request(
        "GET",
        "/api/scan",
        params={
            "preset": preset,
            "min_price": min_price,
            "max_price": max_price,
            "limit": limit,
        },
    )


@mcp.tool()
def analyze_options(
    symbol: str,
    outlook: str = "neutral",
    timeframe_days: int = 30,
) -> str:
    """Recommend an options strategy for a US stock given an outlook.

    `symbol` is a US ticker like ``AAPL``. `outlook` is one of
    ``bullish``, ``bearish``, ``neutral``. `timeframe_days` is the
    expiry horizon in days (1-365).

    Returns JSON with the chosen `outlook` and a `recommendations` list
    of strategies (calls, puts, spreads, etc.) with strikes, expiries,
    and Greeks.
    """
    return _request(
        "POST",
        f"/api/analysis/options/{symbol.upper()}",
        json_body={"outlook": outlook, "timeframe_days": timeframe_days},
    )


@mcp.tool()
def assess_trade_risk(
    entry: float,
    stop: float,
    target: float,
    symbol: str | None = None,
) -> str:
    """Compute position sizing and risk/reward for a candidate trade.

    `entry` is the planned entry price. `stop` is the protective stop.
    `target` is the price target. `symbol` is optional and only affects
    diagnostic context — the math is symbol-agnostic.

    Returns JSON with `is_acceptable`, `dollar_risk`, `percentage_risk`,
    `risk_reward_ratio`, `recommended_size` (shares), `position_cost`,
    and any `warnings`.
    """
    body: dict[str, Any] = {"entry": entry, "stop": stop, "target": target}
    if symbol:
        body["symbol"] = symbol.upper()
    return _request("POST", "/api/risk/assess", json_body=body)


if __name__ == "__main__":
    mcp.run(transport="stdio")
