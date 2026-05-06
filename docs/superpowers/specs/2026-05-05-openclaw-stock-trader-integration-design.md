# OpenClaw ↔ stock-trader Integration

**Date:** 2026-05-05
**Status:** Draft

## Goal

Let OpenClaw answer Discord and web-chat questions about companies, stocks, options, and market news by calling the existing `stock-trader` REST service at `https://trader.vulcan.lan`. When the user asks "what's AAPL trading at?" or "tell me about Tesla", OpenClaw should invoke stock-trader's research endpoints rather than hallucinate.

## Non-Goals

- No changes to the `stock-trader` codebase (separate Gitea repo).
- No new alerting, monitoring, or self-heal coverage — existing `StockTraderEndpointDown` is sufficient.
- No support for placing trades. The full surface stays read/research only; `assess_trade_risk` is deterministic math, not order placement.
- No reuse from other MCP clients (Claude Desktop etc.). If that becomes a need later, we promote to a remote SSE MCP endpoint mounted on stock-trader itself.

## Architecture

```
┌──────────── Discord ────────────┐
              │
              ▼
  OpenClaw microVM (vulcan, 18789)
              │
              ▼  spawns as stdio child via mcporter
  scripts/stock-trader-mcp.py  (FastMCP, runs inside VM)
              │
              ▼  HTTPS GET/POST
  https://trader.vulcan.lan/api/*  (vulcan host, 127.0.0.1:8234)
```

A new local-stdio MCP server lives in this repo and is registered with `mcporter` from inside the OpenClaw microVM. It proxies eight named MCP tools to the corresponding stock-trader REST endpoints.

### Why local stdio (not remote SSE)

- Same pattern as `email-contacts-mcp.py` — the rollout shape is already proven on this host.
- All changes stay inside `/etc/nixos`. No cross-repo PR or version bump in stock-trader.
- Tool descriptions can be tuned for OpenClaw's prompt without negotiating with hypothetical other MCP consumers.

If a second MCP consumer ever appears (Claude Desktop, another agent on a different host), promoting to remote SSE is a single follow-up: mount FastMCP on stock-trader's FastAPI app and switch the mcporter.json entry from `command` to `url`.

### Network and trust

The microVM already routes `*.vulcan.lan` traffic via the bridge gateway (iptables OUTPUT DNAT in `openclaw-vm.nix`) and trusts the Vulcan Step-CA root cert (added via `security.pki.certificates`). So `httpx.get("https://trader.vulcan.lan/api/quote/AAPL")` from inside the VM resolves, connects, and validates without extra wiring.

stock-trader is network-gated — only reachable on the LAN — so no auth tokens are exchanged. The MCP wrapper sends bare HTTPS requests with no `Authorization` header.

## Components

### `scripts/stock-trader-mcp.py` (new)

Python FastMCP stdio server. Reads one env var (`STOCK_TRADER_BASE_URL`, default `https://trader.vulcan.lan`). Uses `httpx.Client` with a 30 s timeout.

Exposes these tools (signatures and docstrings shown abbreviated):

| Tool | Endpoint | Purpose |
|---|---|---|
| `get_quote(symbol)` | GET `/api/quote/{sym}` | Current price, bid/ask, day high/low, market cap, P/E |
| `get_price_history(symbol, period="1mo", interval="1d")` | GET `/api/history/{sym}` | OHLCV bars |
| `get_technical_analysis(symbol, timeframes="1d")` | GET `/api/analysis/technical/{sym}` | Trend, entry zones, targets, stop-loss |
| `get_news_sentiment(symbol, hours_back=24)` | GET `/api/analysis/sentiment/{sym}` | Sentiment score, themes, headlines, catalysts |
| `scan_market(preset="oversold", min_price=10, max_price=500, limit=10)` | GET `/api/scan` | Find tickers matching a preset |
| `analyze_options(symbol, outlook="neutral", timeframe_days=30)` | POST `/api/analysis/options/{sym}` | Options-strategy recommendation |
| `assess_trade_risk(entry, stop, target, symbol=None)` | POST `/api/risk/assess` | Position sizing + R:R math |
| `check_data_source_status()` | GET `/api/schwab/status` | Whether Schwab data is live (vs. yfinance fallback) |

Each docstring states clearly: "`symbol` is a US ticker like AAPL or TSLA — translate company names to tickers yourself before calling." Modern LLMs handle this mapping reliably and stock-trader has no symbol-search endpoint.

Responses are passed straight through as `json.dumps(response.json())`. The LLM does the Discord-friendly summarization, matching the convention of `email-contacts-mcp.py`.

Errors are returned as `{"error": "<short message>"}` rather than raised — this lets the LLM explain a problem to the user instead of OpenClaw treating the tool call as a hard failure. Sources of error captured:

- HTTP 4xx/5xx from stock-trader (invalid ticker, missing Schwab token, etc.).
- `httpx.TimeoutException`, `httpx.ConnectError`, `httpx.RemoteProtocolError`.
- JSON decode failure on the response body.

The script ends with `mcp.run(transport="stdio")` — same shape as `email-contacts-mcp.py`.

### `modules/services/openclaw-vm.nix` (modified)

Three additions, all inside the existing `let` block and `preStart` script:

1. **`stockTraderMcpScript`** — `pkgs.writeShellScript "stock-trader-mcp"` that exports `STOCK_TRADER_BASE_URL` then `exec`s `${financialPython}/bin/python3 ${../../scripts/stock-trader-mcp.py}`. Mirrors the existing `emailMcpServer` pattern.

2. **jq injection in preStart** — adds another stanza to the existing mcporter.json mutation block (the same one that already injects `email-contacts` and `drafts`):

   ```jq
   .mcpServers["stock-trader"] = {
     "command": $cmd,
     "args": [],
     "env": {
       "STOCK_TRADER_BASE_URL": "https://trader.vulcan.lan"
     },
     "description": "Stock quotes, technical analysis, news sentiment, options strategies, and risk assessment via the stock-trader service"
   }
   ```

3. **Dependency confirmation** — `financialPython` already provides `mcp` (used by email-contacts). It must also provide `httpx`. If not present, add it to the package list. This is verified during `nixos-rebuild build`.

No changes to alertmanager, prometheus rules, self-heal, or canary config.

## Data Flow

1. User on Discord: "What's NVDA doing today?"
2. OpenClaw gateway routes to LLM with the stock-trader tools advertised.
3. LLM emits a tool call: `get_quote(symbol="NVDA")`.
4. mcporter dispatches to the running `stock-trader-mcp` stdio child.
5. Wrapper does `GET https://trader.vulcan.lan/api/quote/NVDA`.
6. nginx terminates TLS on vulcan, proxies to `127.0.0.1:8234`.
7. stock-trader returns `QuoteResponse` JSON (price, bid, ask, change, ...).
8. Wrapper returns the raw JSON string to mcporter.
9. LLM summarizes it into a Discord-friendly sentence and replies.

## Testing

After `nixos-rebuild switch && systemctl restart microvm@openclaw`:

1. **Tool advertisement**: from the host, `curl -s http://localhost:18789/v1/tools | jq '[.tools[].name] | map(select(startswith("get_") or startswith("scan_") or startswith("analyze_") or startswith("assess_") or startswith("check_data_source")))'` should list the eight tool names.
2. **Direct call from VM**: `microvm-console openclaw` → run the wrapper interactively with `mcporter dev stock-trader` (or equivalent), invoke `get_quote AAPL`, confirm a JSON response.
3. **End-to-end Discord**: ask "What's AAPL trading at right now?" — expect a sentence-form summary based on the tool result.
4. **Bad ticker**: ask about "ZZZZZ" — expect a graceful "I couldn't find data for that ticker" reply, not a crash.
5. **stock-trader down**: stop `stock-trader.service` briefly, ask a quote question, expect graceful "couldn't reach the trading service" reply, then restart and re-test.

## Failure Modes

| Failure | Symptom | Recovery |
|---|---|---|
| stock-trader.service down | Tool returns `{"error": "..."}`; LLM apologizes | Existing `StockTraderEndpointDown` Prometheus alert fires; no new alerting |
| Schwab token expired | `get_quote` returns yfinance fallback (still works); `check_data_source_status` reports `connected=false`, `expired=true` | Operator re-bootstraps token on laptop; documented in stock-trader memory |
| mcporter.json jq injection breaks | OpenClaw fails to start | Existing canary alert fires; preStart logs show jq error |
| Wrapper crashes at startup | Tool count drops; LLM replies without tool data | OpenClaw still serves Discord; restart microvm@openclaw to recover |
| `httpx` missing from `financialPython` | Build fails at `nixos-rebuild build` | Add `httpx` to `financialPython` package list |

## Rollout

1. Write `scripts/stock-trader-mcp.py`.
2. Edit `modules/services/openclaw-vm.nix` (`stockTraderMcpScript` in let block; jq stanza in preStart).
3. If needed, add `httpx` to `financialPython`.
4. `sudo nixos-rebuild build --flake '.#vulcan'`.
5. `sudo nixos-rebuild switch --flake '.#vulcan'`.
6. `sudo systemctl restart microvm@openclaw`.
7. Run the smoke tests above.
8. User commits.

Pure additive change. Reverting is `git revert` plus `nixos-rebuild switch`.
