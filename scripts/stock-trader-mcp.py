"""MCP server exposing stock-trader research tools over the REST API.

A thin FastMCP **stdio** server that wraps the stock-trader REST API
(default ``https://trader.vulcan.lan``) with named MCP tools — the same 18
tools OpenClaw/Hermes use (8 core + 10 Alpha Vantage). It depends only on
``requests`` + ``mcp``, so it can be packaged as a standalone Nix executable
(the ``nix-config`` repo packages it in ``overlays/30-stock-trader-mcp.nix``;
that repo is flake input ``nix-config`` here, not a local ``~/src`` checkout)
and pointed at any stock-trader deployment.

Environment variables:
  STOCK_TRADER_BASE_URL   default: https://trader.vulcan.lan
  STOCK_TRADER_TIMEOUT_S  default: 30 (seconds)
  REQUESTS_CA_BUNDLE      standard requests/urllib3 CA-bundle override; set
                          this when the deployment uses a private CA (the Nix
                          package bakes in the merged Vulcan CA bundle).

Run directly: python stock-trader-mcp.py
"""

from __future__ import annotations

import json
import os
from typing import Any

import requests
from mcp.server.fastmcp import FastMCP

BASE_URL = os.getenv("STOCK_TRADER_BASE_URL", "https://trader.vulcan.lan").rstrip("/")
TIMEOUT_S = float(os.getenv("STOCK_TRADER_TIMEOUT_S", "30"))


def _format_error_response(resp: Any, path: str) -> str:
    """Map an HTTP error response (status >= 400) to a JSON string.

    Prefer a STRUCTURED form when the body is JSON in stock-trader's FastAPI
    error shape ``{"detail": {"error", "code", "reasons"}}`` (or a plain-string
    ``detail``): the per-source ``reasons`` are already sanitized (closed-set)
    server-side, so forward them as-is. This lets the LLM see *why* each source
    failed instead of an opaque truncated blob.

    Fall back to the legacy truncated-text form (``HTTP <status> from <path>:
    <body[:500]>``) only when the body isn't JSON or lacks that shape. Never
    raises and never introduces a new raw-text path beyond that bounded fallback.
    """
    status = resp.status_code
    try:
        body = resp.json()
    except ValueError:
        body = None

    if isinstance(body, dict) and "detail" in body:
        detail = body["detail"]
        if isinstance(detail, dict):
            return json.dumps(
                {
                    "error": detail.get("error", "request failed"),
                    "code": detail.get("code"),
                    "reasons": detail.get("reasons", {}),
                    "status": status,
                }
            )
        if isinstance(detail, str):
            # FastAPI's default HTTPException renders detail as a plain string.
            return json.dumps({"error": detail, "status": status})

    # Fallback: body isn't JSON or lacks the recognized shape.
    return json.dumps({"error": f"HTTP {status} from {path}: {resp.text[:500]}"})


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
        return _format_error_response(resp, path)

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


# --- Alpha Vantage tools -------------------------------------------------
# These wrap stock-trader's /api/av/* endpoints (Alpha Vantage data). On the
# FREE tier Alpha Vantage allows only ~25 requests/day shared across ALL of
# these tools; stock-trader caches aggressively and enforces a daily quota, so
# expect an occasional {"error": "...quota exceeded..."} and use them sparingly.
# They cover asset classes and data Schwab/Finnhub do not. If a call returns
# {"error": "...not configured..."}, stock-trader has no Alpha Vantage key set.


@mcp.tool()
def get_av_news_sentiment(symbol: str, limit: int = 50) -> str:
    """Fetch Alpha Vantage structured news sentiment for a US stock.

    `symbol` is a US ticker like ``AAPL``. `limit` (1-1000) caps the number of
    articles. Unlike `get_news_sentiment` (an aggregated Finnhub-based summary),
    this returns Alpha Vantage's per-article, per-ticker sentiment.

    Returns JSON with `article_count` and an `articles` list — each has title,
    url, time_published, source, an overall_sentiment_score/label, `topics`,
    and a `ticker_sentiment` array (per-ticker relevance + bull/bear score).
    Alpha Vantage data — see the free-tier budget note above.
    """
    return _request(
        "GET",
        f"/api/av/news/{symbol.upper()}",
        params={"limit": limit},
    )


@mcp.tool()
def get_forex_rate(from_currency: str, to_currency: str) -> str:
    """Fetch a foreign-exchange spot rate from Alpha Vantage.

    `from_currency` and `to_currency` are 3-letter fiat codes like ``EUR``,
    ``USD``, ``JPY``, ``GBP``.

    Returns JSON with the spot `rate`, `bid`, `ask`, and `last_refreshed`.
    Alpha Vantage data — see the free-tier budget note above.
    """
    return _request(
        "GET",
        f"/api/av/forex/{from_currency.upper()}/{to_currency.upper()}",
    )


@mcp.tool()
def get_crypto_quote(symbol: str, market: str = "USD") -> str:
    """Fetch a cryptocurrency spot rate from Alpha Vantage.

    `symbol` is a crypto code like ``BTC``, ``ETH``, ``SOL``. `market` is the
    fiat quote currency (default ``USD``).

    Returns JSON with the spot `rate`, `bid`, `ask`, and `last_refreshed`.
    Alpha Vantage data — see the free-tier budget note above.
    """
    return _request(
        "GET",
        f"/api/av/crypto/{symbol.upper()}",
        params={"market": market.upper()},
    )


@mcp.tool()
def get_commodity(name: str, interval: str = "monthly") -> str:
    """Fetch a commodity price/index series from Alpha Vantage.

    `name` is one of ``WTI``, ``BRENT``, ``NATURAL_GAS``, ``COPPER``,
    ``ALUMINUM``, ``WHEAT``, ``CORN``, ``COTTON``, ``SUGAR``, ``COFFEE``, or
    ``ALL_COMMODITIES`` (global index). `interval` is ``daily``, ``weekly``,
    ``monthly``, ``quarterly``, or ``annual`` (not all combos are valid).

    Returns JSON with `name`, `unit`, `interval`, and a `data` list of
    {date, value} points. Alpha Vantage data — see the free-tier budget note.
    """
    return _request(
        "GET",
        f"/api/av/commodities/{name.upper()}",
        params={"interval": interval.lower()},
    )


@mcp.tool()
def get_insider_transactions(symbol: str, limit: int = 50) -> str:
    """Fetch recent insider transactions for a US stock from Alpha Vantage.

    `symbol` is a US ticker like ``AAPL``. `limit` caps the number of records.

    Returns JSON with a `transactions` list — each has transaction_date,
    executive, executive_title, acquisition_or_disposal (``A``=buy/``D``=sell),
    shares, and share_price. Alpha Vantage data — see the free-tier budget note.
    """
    return _request(
        "GET",
        f"/api/av/insider/{symbol.upper()}",
        params={"limit": limit},
    )


@mcp.tool()
def get_etf_profile(symbol: str) -> str:
    """Fetch an ETF's profile (holdings + sector weights) from Alpha Vantage.

    `symbol` is an ETF ticker like ``SPY``, ``QQQ``, ``VTI``.

    Returns JSON with net_assets, net_expense_ratio, dividend_yield, a
    `leveraged` flag, a `sectors` list (sector + weight), and a `holdings` list
    (symbol + description + weight). Alpha Vantage data — see the budget note.
    """
    return _request("GET", f"/api/av/etf-profile/{symbol.upper()}")


@mcp.tool()
def get_earnings_calendar(symbol: str | None = None, horizon: str = "3month") -> str:
    """Fetch the upcoming earnings calendar from Alpha Vantage.

    `symbol` optionally restricts to one US ticker; omit for the whole market.
    `horizon` is ``3month``, ``6month``, or ``12month``.

    Returns JSON with an `entries` list — each has symbol, name, report_date,
    fiscal_date_ending, and an estimate. Alpha Vantage data — see the budget note.
    """
    params: dict[str, Any] = {"horizon": horizon}
    if symbol:
        params["symbol"] = symbol.upper()
    return _request("GET", "/api/av/calendar/earnings", params=params)


@mcp.tool()
def get_ipo_calendar() -> str:
    """Fetch the upcoming IPO calendar from Alpha Vantage.

    Returns JSON with an `entries` list — each has symbol, name, ipo_date,
    price_range_low/high, currency, and exchange. Alpha Vantage data — see the
    free-tier budget note above.
    """
    return _request("GET", "/api/av/calendar/ipo")


@mcp.tool()
def get_listing_status(state: str = "active", date: str | None = None) -> str:
    """Fetch the equity listing universe from Alpha Vantage.

    `state` is ``active`` or ``delisted``. `date` optionally requests a
    historical snapshot (``YYYY-MM-DD``); omit for the current set. Useful for
    survivorship-bias-free symbol universes. This is a large response.

    Returns JSON with an `entries` list — each has symbol, name, exchange,
    asset_type, ipo_date, delisting_date, and status. Alpha Vantage data.
    """
    params: dict[str, Any] = {"state": state}
    if date:
        params["date"] = date
    return _request("GET", "/api/av/listing-status", params=params)


@mcp.tool()
def get_historical_options(symbol: str, date: str | None = None) -> str:
    """Fetch a historical options chain (with Greeks) from Alpha Vantage.

    `symbol` is a US ticker like ``AAPL``. `date` is the trade date
    (``YYYY-MM-DD``, on or after 2008-01-01); omit for the most recent session.
    Unlike the live `analyze_options`, this returns a full *historical* chain.

    Returns JSON with `symbol`, `date`, and a `chain` of `calls`/`puts` — each
    contract carries strike, expiration, bid/ask/last, volume, open interest,
    implied volatility, and Greeks (delta/gamma/theta/vega/rho). Alpha Vantage
    data — see the free-tier budget note above.
    """
    params: dict[str, Any] = {}
    if date:
        params["date"] = date
    return _request(
        "GET",
        f"/api/av/historical-options/{symbol.upper()}",
        params=params or None,
    )


if __name__ == "__main__":
    mcp.run(transport="stdio")
