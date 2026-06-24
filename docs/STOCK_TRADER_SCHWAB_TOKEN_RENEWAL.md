# Stock Trader — Schwab Token Renewal Runbook

Schwab OAuth refresh tokens are **not headlessly renewable** and expire roughly
every 7 days (sometimes earlier — see cautions). When the token dies,
`/api/quote/*` returns 503 and Alertmanager fires
**`StockTraderSchwabDataSourceDown`**. Re-bootstrapping requires a browser OAuth
flow, which must run on **hera**; the rest can run on **vulcan**.

## Steps

**1. On hera** (venv active in `~/src/stock-trader`):

```bash
python -m src.main schwab-auth
```

Completes the browser OAuth and writes `~/.config/stock-trader/schwab_token.json`.
(This build only prints "Schwab connected. Refresh token valid until …" — not the
path.)

**2. Push hera → vulcan** (vulcan can't ssh *to* hera, so push from hera into a
private staging dir):

```bash
mkdir -p ~/staging && chmod 700 ~/staging   # on vulcan, once
scp ~/.config/stock-trader/schwab_token.json johnw@vulcan:~/staging/
```

**3. On vulcan** — install 0600 + restart (the restart is required; the quote
client caches the token at process start):

```bash
sudo install -m 0600 ~/staging/schwab_token.json /var/lib/private/stock-trader/schwab_token.json
sudo systemctl restart stock-trader
```

**4. Verify:**

```bash
curl -sk https://trader.vulcan.lan/api/schwab/status | jq '{connected,expired,days_remaining}'
```

Expect `connected:true, expired:false, days_remaining ~7`, and a live
`/api/quote/AAPL` returns a real price. The alert clears once the probe sees the
source up.

## Cautions

- **DynamicUser re-chowns the StateDirectory on start**, so the install owner
  doesn't matter — only mode `0600` does.
- **Schwab can revoke early** (a 06-07 token died in ~2.5 days), so trust the
  `stock_trader_data_source_up{source="schwab"}` probe, not the synthetic 7-day
  expiry gauge.
- **Handle the token opaquely** — never `cat` it; validate only as JSON; show only
  market data and non-secret status fields.
