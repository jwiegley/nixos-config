# OpenClaw ↔ stock-trader Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give OpenClaw the ability to answer Discord/web-chat questions about companies, stocks, options, and market news by calling stock-trader's REST API via a new local-stdio MCP server inside the OpenClaw microVM.

**Architecture:** A new Python FastMCP stdio server (`scripts/stock-trader-mcp.py`) wraps eight stock-trader REST endpoints as MCP tools. It runs as a child of OpenClaw's mcporter, registered via a jq stanza in `openclaw-vm.nix` preStart. The microVM already has Vulcan Step-CA in its trust store and DNAT routing for `*.vulcan.lan`, so HTTPS to `https://trader.vulcan.lan` works with no extra wiring. Pure additive change — no modifications to alerting, monitoring, or self-heal.

**Tech Stack:** Python 3.12 FastMCP (`mcp.server.fastmcp`), `requests` (already present in `financialPython`), Nix (jq in preStart), microvm.nix.

**Spec:** `docs/superpowers/specs/2026-05-05-openclaw-stock-trader-integration-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `scripts/stock-trader-mcp.py` | Create | FastMCP stdio server. One module, eight `@mcp.tool()` functions, one shared `_request` helper, `mcp.run(transport="stdio")` at the bottom. ~250 lines. |
| `modules/services/openclaw-vm.nix` | Modify | Add `stockTraderMcpScript` to the `let` block (mirror of `emailMcpServer`). Add a jq stanza in the preStart mcporter.json mutation block (mirror of email-contacts/drafts injections). |

No new NixOS modules. No changes to `openclaw-microvm.nix`, `openclaw.nix`, secrets, alertmanager, prometheus rules, or the self-heal pipeline.

---

## Pre-flight verification

Already done while writing this plan:

- `financialPython` includes `ps.requests` (line 80-90 of `modules/services/openclaw-microvm.nix`) → no need for `httpx` or new deps.
- `openclaw-vm.nix` already accepts `financialPython` via specialArgs (line 5-12) → wrapper script can reference it.
- stock-trader's OpenAPI confirms all eight endpoints exist with the schemas captured in the spec.
- The microVM's iptables rules cover port 443 (`dnatPorts` list at line 119 of `openclaw-microvm.nix` includes 443) → HTTPS to `trader.vulcan.lan` is reachable from inside the VM.
- Trader is reachable on host: `curl -sk https://trader.vulcan.lan/api/quote/AAPL` returns 200 with a JSON body.

**Deviation from the spec:** the spec mentions `httpx` as a candidate HTTP client. The plan uses `requests` instead because `financialPython` already ships `ps.requests` and does not ship `httpx`; using `requests` avoids modifying `openclaw-microvm.nix` to add a new dep. Same semantics for our use (sync HTTP, JSON, timeouts, configurable certs).

**Confirm before starting Task 1:**

- [ ] Run `curl -sk https://trader.vulcan.lan/api/quote/AAPL | head -c 200` — expect a JSON body containing `"symbol":"AAPL"` and a numeric `"price"`.
- [ ] Run `sudo systemctl is-active stock-trader` — expect `active`.
- [ ] Run `sudo systemctl is-active microvm@openclaw` — expect `active`.

If any are not green, stop and have the operator restore service before continuing.

---

## Task 1: MCP server — skeleton + shared HTTP helper + `get_quote`

**Files:**
- Create: `scripts/stock-trader-mcp.py`

This task lays down the file shape and proves end-to-end connectivity with the simplest tool.

- [ ] **Step 1: Create the script with module docstring, imports, configuration, and helper.**

```python
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
```

- [ ] **Step 2: Confirm the script parses and imports cleanly.**

Run: `python3 -m py_compile /etc/nixos/scripts/stock-trader-mcp.py`

Expected: exit code 0, no output.

- [ ] **Step 3: (Optional) Verify the script's HTTP path against live stock-trader.**

The script imports `mcp.server.fastmcp` at module top level, which the host's system Python typically does not have (`mcp` lives in `financialPython`, the VM's Python). Expect this step to fail on the host. The real connectivity test happens inside the VM after Task 5.

If you want a host-side connectivity sanity check that does not require importing the script:

```
curl -sk https://trader.vulcan.lan/api/quote/AAPL | head -c 200
```

Expected: a JSON string starting with `{"symbol":"AAPL","price":` followed by a real number. This proves stock-trader is up; it does not exercise the wrapper.

- [ ] **Step 4: Make the script executable.**

Run: `chmod +x /etc/nixos/scripts/stock-trader-mcp.py`

- [ ] **Step 5: Commit.**

```
git add scripts/stock-trader-mcp.py
git commit -m "feat(openclaw): MCP server skeleton + get_quote tool

First tool of the openclaw-stock-trader integration. Establishes the
shared _request helper that turns HTTP/network failures into
{\"error\": ...} JSON so the LLM can explain to the user instead of
crashing the tool call.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Add the four remaining GET tools that take a symbol

**Files:**
- Modify: `scripts/stock-trader-mcp.py`

Adds `get_price_history`, `get_technical_analysis`, `get_news_sentiment`, and `check_data_source_status`. All are GET, all reuse `_request`.

- [ ] **Step 1: Add the four tools.**

Append below the `get_quote` definition, above `if __name__ == "__main__":`:

```python
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
```

- [ ] **Step 2: Confirm the script still parses.**

Run: `python3 -m py_compile /etc/nixos/scripts/stock-trader-mcp.py`

Expected: exit code 0.

- [ ] **Step 3: Commit.**

```
git add scripts/stock-trader-mcp.py
git commit -m "feat(openclaw): add 4 GET tools (history, technical, sentiment, schwab-status)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Add the remaining three tools (`scan_market`, `analyze_options`, `assess_trade_risk`)

**Files:**
- Modify: `scripts/stock-trader-mcp.py`

`scan_market` is the only GET tool with no symbol. The other two are POSTs with JSON bodies.

- [ ] **Step 1: Add `scan_market`.**

```python
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
```

- [ ] **Step 2: Add `analyze_options`.**

The OpenAPI spec defines this as POST with body `{"outlook": str, "timeframe_days": int}`.

```python
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
```

- [ ] **Step 3: Add `assess_trade_risk`.**

POST with body `{"entry": float, "stop": float, "target": float, "symbol": str | None}`.

```python
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
```

- [ ] **Step 4: Confirm the script still parses.**

Run: `python3 -m py_compile /etc/nixos/scripts/stock-trader-mcp.py`

Expected: exit code 0.

- [ ] **Step 5: Commit.**

```
git add scripts/stock-trader-mcp.py
git commit -m "feat(openclaw): add 3 remaining tools (scan, options, risk)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Wire the MCP server into `openclaw-vm.nix`

**Files:**
- Modify: `modules/services/openclaw-vm.nix`

Two additions: a wrapper script in the `let` block, and a jq stanza in the existing mcporter.json mutation in preStart.

- [ ] **Step 1: Add `stockTraderMcpScript` to the `let` block.**

Locate the `let` block — search for `emailMcpServer = pkgs.writeShellScript "email-contacts-mcp"` (around line 51). Just below the closing `''` of `emailMcpServer`, insert:

```nix
  # Wrapper for the stock-trader MCP server.  Sets the base URL so the
  # script can be tested elsewhere by overriding the env var, then
  # exec's the Python MCP server with financialPython's interpreter
  # (which already provides `mcp` and `requests`).
  stockTraderMcpScript = ../../scripts/stock-trader-mcp.py;
  stockTraderMcpServer = pkgs.writeShellScript "stock-trader-mcp" ''
    export STOCK_TRADER_BASE_URL="https://trader.vulcan.lan"
    exec ${financialPython}/bin/python3 ${stockTraderMcpScript}
  '';
```

- [ ] **Step 2: Add the jq stanza to the mcporter.json mutation block.**

Locate the existing stanza for `drafts` (search for `.mcpServers["drafts"]` — around line 655). Immediately below the trailing `chmod 600 "$MCPORTER_JSON"` of the drafts block (and before the closing `fi`), insert:

```nix
              # ──────────────────────────────────────────────────────────────
              # Inject stock-trader MCP server (local stdio, talks to
              # https://trader.vulcan.lan via the bridge gateway DNAT)
              # ──────────────────────────────────────────────────────────────
              ${pkgs.jq}/bin/jq --arg cmd "${stockTraderMcpServer}" '
                .mcpServers["stock-trader"] = {
                  "command": $cmd,
                  "args": [],
                  "env": {
                    "STOCK_TRADER_BASE_URL": "https://trader.vulcan.lan"
                  },
                  "description": "Stock quotes, technical analysis, news sentiment, options strategies, and risk assessment via the stock-trader service"
                }
              ' "$MCPORTER_JSON" > "$MCPORTER_JSON.tmp"
              mv "$MCPORTER_JSON.tmp" "$MCPORTER_JSON"
              chmod 600 "$MCPORTER_JSON"
```

(`STOCK_TRADER_BASE_URL` is set in both places — the wrapper script's `export` always wins at runtime because it runs after mcporter spawns the child. The duplicate in the mcporter env block exists only as documentation: anyone inspecting `mcporter.json` can see the URL the wrapper uses. Keep both values in sync if you ever change the URL.)

- [ ] **Step 3: Format and verify the Nix file builds.**

Run: `cd /etc/nixos && nix fmt`

Then: `cd /etc/nixos && sudo nixos-rebuild build --flake '.#vulcan'`

Expected: build completes without error. `result/` symlink appears.

If the build fails:
- A jq syntax error: re-check that the new stanza's quoting matches the email-contacts/drafts stanzas exactly.
- A "path does not exist" error for `stockTraderMcpScript`: verify `scripts/stock-trader-mcp.py` is committed to git and the Nix path is `../../scripts/stock-trader-mcp.py` relative to `modules/services/`.

- [ ] **Step 4: Commit.**

```
git add modules/services/openclaw-vm.nix
git commit -m "feat(openclaw): register stock-trader MCP server with mcporter

Adds stockTraderMcpServer wrapper in the let block and a jq injection
stanza in preStart that adds 'stock-trader' to mcporter.json's
mcpServers map. Mirrors the existing email-contacts/drafts pattern.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Deploy and verify mcporter registration

**Files:** None modified — runtime activation only.

- [ ] **Step 1: Switch to the new generation.**

Run: `cd /etc/nixos && sudo nixos-rebuild switch --flake '.#vulcan'`

Expected: switches successfully. `microvm@openclaw` may be flagged for restart; we restart it explicitly next.

- [ ] **Step 2: Restart the OpenClaw microVM.**

Run: `sudo systemctl restart microvm@openclaw`

Then wait ~30 seconds for the VM to boot and OpenClaw to register plugins.

- [ ] **Step 3: Confirm the service is active.**

Run: `sudo systemctl is-active microvm@openclaw`

Expected: `active`. If not, run `sudo journalctl -u microvm@openclaw -n 100 --no-pager` and address the failure before continuing.

- [ ] **Step 4: Confirm `stock-trader` is in mcporter.json.**

Run:

```
sudo /run/current-system/sw/bin/jq -r '.mcpServers | keys[]' /var/lib/openclaw/.openclaw/.mcporter/mcporter.json
```

Expected output (in some order): `drafts`, `email-contacts`, `stock-trader`.

If `stock-trader` is missing: the jq stanza was skipped (the `if [ -f "$MCPORTER_JSON" ]` guard failed) or jq errored. Check `journalctl -u microvm@openclaw` for the preStart log, and re-run `nixos-rebuild switch` after fixing.

- [ ] **Step 5: Confirm OpenClaw discovers the tools.**

Check the gateway log for evidence mcporter loaded the new server. Try the file log first; fall back to `journalctl` if the file path differs in your OpenClaw version:

```
sudo grep -E 'stock-trader|get_quote|analyze_options' \
  /var/lib/openclaw/.openclaw/logs/gateway-vm.log 2>/dev/null | tail -20

# Fallback if the file isn't there:
sudo journalctl -u microvm@openclaw -n 200 --no-pager | grep -E 'stock-trader|get_quote'
```

Expected: lines indicating mcporter loaded the `stock-trader` server and registered its tools (exact format depends on the OpenClaw version; lines containing "registered MCP tool" or "loaded MCP server stock-trader" are positive signals).

If the server loads but no tools register, check the err log:

```
sudo grep -i 'stock-trader' /var/lib/openclaw/.openclaw/logs/gateway-vm.err.log 2>/dev/null | tail -20
sudo journalctl -u microvm@openclaw -n 200 --no-pager | grep -iE 'stock-trader|ImportError|Traceback'
```

A common cause is a Python import error (e.g., `mcp` missing from `financialPython`) — the wrapper's exec fails and mcporter logs the child exit code. Fix and `systemctl restart microvm@openclaw`.

- [ ] **Step 6: Confirm the VM can reach trader.vulcan.lan.**

Smoke-test the network path from inside the VM (no MCP protocol drive needed — we're just checking that the wrapper *would* succeed):

```
sudo machinectl shell openclaw.host /run/current-system/sw/bin/curl -sS \
  https://trader.vulcan.lan/api/quote/AAPL | head -c 200
```

(If `machinectl shell` doesn't work for the microvm flavor in use, an equivalent is `sudo microvm -s openclaw` to attach a console, then `curl -sS https://trader.vulcan.lan/api/quote/AAPL | head -c 200` inside.)

Expected: a JSON response containing `"symbol":"AAPL"` and a numeric `"price"`. This confirms the VM can resolve `trader.vulcan.lan`, route via the bridge gateway, and validate TLS against Vulcan Step-CA. If this fails but the host-side `curl` succeeds, suspect an iptables/DNAT issue rather than a stock-trader issue.

- [ ] **Step 7: No commit.** This task changes runtime state only.

---

## Task 6: End-to-end Discord verification

**Files:** None modified.

This is a manual / human-in-the-loop step. The agentic worker should *not* attempt to drive a Discord client; instead, prompt the operator and report the outcome.

- [ ] **Step 1: Ask the operator to send a test message in Discord.**

Suggested message: `What's AAPL trading at right now?`

- [ ] **Step 2: Operator observes the bot's reply.**

Expected: a sentence-form summary of the AAPL quote (e.g., "AAPL is trading at $XYZ, up X%, with a market cap of …"). The number must be plausible against `curl -sk https://trader.vulcan.lan/api/quote/AAPL`.

- [ ] **Step 3: Operator sends a negative-path message.**

Suggested message: `What's the news sentiment on ZZZZZZ?`

Expected: a graceful "I couldn't find data for that ticker" / "stock-trader returned an error" reply, not a crash, no traceback.

- [ ] **Step 4: Operator confirms the existing Discord behaviors still work.**

Suggested message: a generic non-finance question (e.g. ask the bot to search the org task database). Expected: same answer quality as before — the new tools should not have displaced existing tools.

- [ ] **Step 5: If all three pass, the integration is done.**

If any fail, capture `/var/lib/openclaw/.openclaw/logs/gateway-vm.{log,err.log}` lines from the failure window before fixing.

---

## Failure modes encountered during implementation (recovery)

| Failure | Where it shows up | Recovery |
|---|---|---|
| `from mcp.server.fastmcp import FastMCP` ImportError | `gateway-vm.err.log` after VM restart | Confirm `mcp` is in the financialPython package list. It was at the time of writing (line 81 of `openclaw-microvm.nix`). |
| `requests.exceptions.SSLError` from inside the VM | `gateway-vm.err.log` | The Vulcan Step-CA root cert isn't being picked up by `requests`. Ensure `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` is exported VM-wide (it already is — see `environment.variables` in `openclaw-vm.nix`). |
| Connection refused to `trader.vulcan.lan` | Tool returns `{"error": "could not reach stock-trader"}` | Check `sudo systemctl is-active stock-trader` on the host. The `StockTraderEndpointDown` Prometheus alert covers this. |
| jq syntax error during preStart | VM fails to start; `journalctl -u microvm@openclaw` shows jq parse error | Re-check the new jq stanza's quoting against the email-contacts/drafts ones. Common mistake: using `\n` literally inside the JSON object (jq doesn't need it). |
| mcporter.json write fails | preStart logs a permission error | Confirm the `chmod 600` line is present at the end of the new stanza. |

---

## Post-implementation cleanup

Nothing additional. The integration is purely additive. If the user later wants to undo:

1. `git revert <both feature commits>`
2. `sudo nixos-rebuild switch --flake '.#vulcan'`
3. `sudo systemctl restart microvm@openclaw`

The mcporter.json regenerates on every preStart, so the `stock-trader` entry disappears on the next restart automatically.
