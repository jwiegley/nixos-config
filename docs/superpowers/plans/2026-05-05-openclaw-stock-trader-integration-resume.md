# OpenClaw ↔ stock-trader Integration — Resume Notes

> **Archival — 2026-05-05.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `scripts/stock-trader-mcp.py`).

Pick this work up here. The integration is **deployed** but the final end-to-end Discord verification (Task 6) is still pending, blocked on a fresh Schwab OAuth token.

## State at last checkpoint

- **Spec:** `docs/superpowers/specs/2026-05-05-openclaw-stock-trader-integration-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-05-openclaw-stock-trader-integration.md`
- **Commits on `main`** (in order):
  - `e4a6412` — spec doc
  - `114f531` — plan doc (first draft)
  - `711aae7` — plan doc (reviewer cleanups)
  - `f092b87` — Task 1: MCP server skeleton + `get_quote`
  - `d75d199` — Task 2: 4 GET tools (history, technical, sentiment, schwab-status)
  - `6961c0e` — Task 3: scan, options, risk
  - `538d5555` — Task 4: register with mcporter via `openclaw-vm.nix`
- **Task 5 (deploy + verify):** done — at the time, `mcporter.json` showed `stock-trader` registered with the correct `/nix/store/.../stock-trader-mcp` wrapper path, gateway started cleanly, no errors.
- **Task 6 (Discord E2E):** still **in_progress**. The blocker was that the Schwab OAuth token had lapsed, so `/api/quote/AAPL` was returning `data_unavailable`.

## Tools exposed to OpenClaw

8 MCP tools in `/etc/nixos/scripts/stock-trader-mcp.py`:

| Tool | Endpoint | Notes |
|---|---|---|
| `get_quote(symbol)` | GET `/api/quote/{sym}` | **Needs live Schwab data** |
| `get_price_history(symbol, period, interval)` | GET `/api/history/{sym}` | yfinance fallback works without Schwab |
| `get_technical_analysis(symbol, timeframes)` | GET `/api/analysis/technical/{sym}` | Depends on history; yfinance works |
| `get_news_sentiment(symbol, hours_back)` | GET `/api/analysis/sentiment/{sym}` | **Uses Finnhub, no Schwab** |
| `scan_market(preset, min_price, max_price, limit)` | GET `/api/scan` | yfinance works |
| `analyze_options(symbol, outlook, timeframe_days)` | POST `/api/analysis/options/{sym}` | **Needs Schwab options chain** |
| `assess_trade_risk(entry, stop, target, symbol?)` | POST `/api/risk/assess` | Pure math; no upstream data |
| `check_data_source_status()` | GET `/api/schwab/status` | Diagnostic — use this to verify the token is live |

## Step 0 — Re-verify deployment health

Time has passed since Task 5; before doing anything else, make sure the integration is still wired:

```sh
# Service active?
sudo systemctl is-active microvm@openclaw stock-trader

# Is stock-trader still in mcporter.json?
sudo /run/current-system/sw/bin/jq -r '.mcpServers | keys[]' \
  /var/lib/openclaw/.openclaw/.mcporter/mcporter.json
# expect: drafts, email-contacts, stock-trader (and any others)

# Is the wrapper path still resolvable?
sudo /run/current-system/sw/bin/jq -r '.mcpServers["stock-trader"].command' \
  /var/lib/openclaw/.openclaw/.mcporter/mcporter.json | xargs -I{} ls -la {}

# Is trader.vulcan.lan up?
curl -sk https://trader.vulcan.lan/api/schwab/status | jq .
```

If any of those fails, see the **Failure modes** section at the bottom.

## Step 1 — Refresh Schwab OAuth token

The refresh-token window is 7 days. Since Task 5 was on 2026-05-05 and you're picking this up later, the token is almost certainly expired. The Schwab OAuth flow is intentionally **laptop-only** — the server has `STOCK_TRADER_ALLOW_OAUTH_BOOTSTRAP` unset.

### On your laptop, in the `stock-trader` project dir:

```sh
python -m src.main schwab-auth
```

Complete the browser OAuth flow. The CLI prints the path of the resulting `schwab_token.json`.

### Copy it to vulcan with the dynamic UID:

```sh
TARGET_UID=$(ssh vulcan "stat -c %u /var/lib/private/stock-trader")
scp schwab_token.json johnw@vulcan:/tmp/schwab_token.json
ssh vulcan "sudo install -o $TARGET_UID -g $TARGET_UID -m 0600 \
  /tmp/schwab_token.json /var/lib/private/stock-trader/schwab_token.json && \
  sudo rm /tmp/schwab_token.json"
```

(Note: the trader runs DynamicUser; the real state dir is under `/var/lib/private/stock-trader/`, with `/var/lib/stock-trader/` typically being a symlink. Confirm with `ls -la /var/lib/stock-trader` first if unsure.)

### Verify on vulcan:

```sh
curl -sk https://trader.vulcan.lan/api/schwab/status | jq .
# expect: connected: true, expired: false, days_remaining: ~7

curl -sk https://trader.vulcan.lan/api/quote/AAPL | jq .
# expect: real symbol + price, not data_unavailable
```

## Step 2 — Run Task 6 Discord tests

The pre-written test plan from `docs/superpowers/plans/2026-05-05-openclaw-stock-trader-integration.md` (Task 6). Send each message in your Discord channel and observe OpenClaw's reply.

- [ ] **Quote test** — *"What's AAPL trading at right now?"*
  Expected: a sentence summary of the AAPL quote with a price that matches `curl -sk https://trader.vulcan.lan/api/quote/AAPL | jq .price`.
- [ ] **Sentiment test** (Schwab-independent) — *"What's the news sentiment on TSLA?"*
  Expected: a summary of recent headlines and sentiment direction. Works even if Schwab is down.
- [ ] **Scan test** — *"Scan the market for oversold stocks under $100."*
  Expected: a short list of tickers with the diagnostic that explains why each made the list.
- [ ] **Negative path** — *"What's the news sentiment on ZZZZZZ?"*
  Expected: a graceful "no data" / "couldn't find that ticker" reply, no traceback, no Discord error.
- [ ] **Regression** — Ask a generic non-finance question that exercises a different MCP server (e.g. *"What's on my todo list for today?"* or *"Search my emails for X"*).
  Expected: same behavior as before this integration. The new tools should not have displaced the existing ones.

If all five pass, mark Task 6 complete:

```sh
# from /etc/nixos
git -C /etc/nixos log --oneline -5
# confirm last commit is 538d5555; integration is fully shipped
```

If something fails, capture the failure window from the gateway logs:

```sh
sudo journalctl -u microvm@openclaw --since '10 minutes ago' --no-pager | \
  grep -iE 'stock-trader|ImportError|Traceback|error' | tail -40
```

## Step 3 — Update memory after success

After Task 6 passes, add a memory entry so future sessions know the integration is live and how to use it. A minimal addition for `/home/johnw/.claude/projects/-etc-nixos/memory/`:

- New file `project_openclaw_stock_trader.md` (type: project), one-line index entry in `MEMORY.md`.
- Body: name the 8 tools, mention `STOCK_TRADER_BASE_URL` env override knob, link the commit `538d5555`, note the laptop-side Schwab token bootstrap as the only ongoing operator burden.

## Failure modes & quick recovery

| Symptom | Likely cause | Fix |
|---|---|---|
| `microvm@openclaw` not active | Unrelated VM problem | `sudo journalctl -u microvm@openclaw -n 100`. Probably handled by self-heal already; see `project_openclaw_self_heal.md` memory. |
| `stock-trader` missing from `mcporter.json` | preStart jq stanza got dropped or VM was rolled back | Re-run `sudo nixos-rebuild switch --flake '.#vulcan' && sudo systemctl restart microvm@openclaw` |
| Wrapper path in mcporter.json doesn't exist on disk | GC'd Nix store after a long downtime | `sudo nix-store --gc-keep-outputs` then `nixos-rebuild switch` again |
| `/api/quote/X` returns `data_unavailable` | Schwab token expired | Step 1 above |
| `/api/schwab/status` shows `connected: false` and `expired: true` | Same as above | Step 1 above |
| LLM calls a tool but reply is empty | Tool returned `{"error":"..."}` | Inspect the error string the LLM mentions; check `journalctl -u microvm@openclaw` |
| Python ImportError in gateway-vm.err.log | `mcp` or `requests` missing from `financialPython` | Verify package list in `modules/services/openclaw-microvm.nix` ~line 80-90 |
| New OpenClaw version broke the wrapper | mcporter API change | Check `OpenClaw 2026.x.y` release notes; preStart and the jq stanza may need updates |

## Deferred touch-ups from code review

These were flagged as Minor and explicitly deferred. None are load-bearing for Task 6. If you want to clean them up at any point:

1. **`TIMEOUT_S` validation** — `float(os.getenv(...))` raises ValueError at module import on a bad envvar. Wrap in try/except → fall back to 30.0.
2. **Error contract in per-tool docstrings** — Add one line to each tool's docstring noting that `{"error": "..."}` JSON is returned on failure. Currently only `_request`'s docstring says so.
3. **Triplicated mv/chmod 600 in preStart** — When adding a fourth MCP server to `openclaw-vm.nix`, factor `mcporter_apply_jq()` shell function.

## Where things live

- Python MCP server: `/etc/nixos/scripts/stock-trader-mcp.py`
- NixOS wiring: `/etc/nixos/modules/services/openclaw-vm.nix`
  - let block: ~lines 57–66 (`stockTraderMcpScript`, `stockTraderMcpServer`)
  - preStart jq stanza: ~lines 671–687
- mcporter.json on the host: `/var/lib/openclaw/.openclaw/.mcporter/mcporter.json` (regenerated on every microvm boot from preStart)
- Stock-trader on the host: systemd unit `stock-trader`, state at `/var/lib/private/stock-trader/`, nginx vhost `trader.vulcan.lan`
- Stock-trader module: `/etc/nixos/modules/services/stock-trader.nix`
