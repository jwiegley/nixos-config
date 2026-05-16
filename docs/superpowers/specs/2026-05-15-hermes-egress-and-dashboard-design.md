# Hermes Egress Tightening + Integration Dashboard — Design Spec

Two small post-config-refactor hardening + observability changes, sharing one spec because they touch the same surface (Hermes + OpenClaw monitoring layer) and their plans are short enough that decomposition adds more overhead than it saves.

## Why

1. **Hermes egress is wide-open in Phase 1.** The current FORWARD chain for `hermes-br0` is:
   - ACCEPT intra-bridge
   - DROP to 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 (private ranges except gateway)
   - LOG everything else outbound to `end0`
   - Falls through to the `FORWARD` policy (ACCEPT today)

   7 days of `hermes-egress:` kernel log entries (since 2026-05-08) show every observed destination is TCP 443 to Cloudflare ranges (104.18.x.x, 104.26.x.x). That's Discord. No other ports, no surprise destinations. We have enough data to tighten conservatively.

2. **No Grafana visibility for the four post-refactor metric files.** Today we emit `hermes_health.prom` (9), `openclaw_canary.prom` (10), `openclaw_mcporter.prom` (5), and `openclaw_hermes_smoke.prom` (4) — 28 metrics — but nothing queries them visually. Alerts catch failures; a dashboard catches drift and slow degradation that doesn't trip the existing thresholds.

## Deliverable A: Egress tightening

### Scope

In `modules/services/hermes-microvm.nix`, modify the iptables `firewall.extraCommands` block (around lines 148-159) and the matching `firewall.extraStopCommands` block (around lines 169-180):

1. **Insert four ACCEPT rules** ahead of the current LOG rule:
   - ACCEPT TCP dport 443 (HTTPS — covers Discord + OpenRouter + LiteLLM https endpoints)
   - ACCEPT UDP dport 443 (HTTP/3, increasingly used)
   - ACCEPT TCP dport 53 (DNS-over-TCP)
   - ACCEPT UDP dport 53 (DNS)
2. **Rename the LOG prefix** from `hermes-egress: ` → `hermes-egress-rejected: ` to reflect that LOG now fires only on traffic about to be dropped, not on all outbound. The `extraStopCommands` block must reference the same renamed prefix for the `iptables -D` cleanup line to find the rule on rebuild.
3. **Insert a final DROP rule** after the LOG, on the same `hermes-br0 → end0` match.

The intra-bridge ACCEPT (line 1 of the chain), the three RFC-1918 DROPs (lines 3-5 of the chain), and existing connection-tracking rules are unchanged.

### Why these ports

- **TCP 443**: Discord WebSocket gateway (`gateway.discord.gg`), Discord REST API, OpenRouter, internal hera HTTPS. Every observed outbound destination over the 7-day window.
- **UDP 443**: HTTP/3. Discord doesn't yet use h3 broadly, but Cloudflare frontends commonly do. Cheap to allow.
- **TCP/UDP 53**: DNS. Required for any name resolution to even attempt the 443 connections.

Anything else (SMTP 25, IMAP 143/993, IRC, FTP, gopher, etc.) is blocked. If a future workload needs an additional port, this is a one-line module edit.

### Verification

After switch:
- `sudo iptables -L FORWARD -n -v` shows the four new ACCEPT rules followed by LOG followed by a final DROP, all on `hermes-br0 → end0`.
- `sudo ssh -i /root/.ssh/hermes-debug hermes@10.99.1.2 'curl -fsS --max-time 5 https://discord.com/api/v10/gateway'` returns 200.
- `sudo ssh -i /root/.ssh/hermes-debug hermes@10.99.1.2 'curl -fsS --max-time 5 https://google.com'` returns content (sanity).
- `sudo ssh -i /root/.ssh/hermes-debug hermes@10.99.1.2 'curl -fsS --max-time 3 ftp://ftp.gnu.org/ || echo blocked'` shows `blocked` (negative path).
- `hermes_discord_event_age_seconds` stays under 14400 in the metric file (no Discord reconnection storm).

### Rollback

Single `nixos-rebuild switch --rollback` reverts to the wide-open policy. The four ACCEPT rules + final DROP are the only change.

## Deliverable B: Grafana dashboard

### Scope

Create `/etc/nixos/modules/monitoring/dashboards/openclaw-hermes-integration.json` — a Grafana dashboard JSON loaded via `localDashboards` in `modules/services/grafana.nix`. Style and structure mirror the existing local dashboards (`home-assistant.json`, `node-red-events.json`, etc.).

Panels:

1. **Stat panel — Bridge health (top row)**
   - `hermes_mcp_sse_open_ok` (green/red)
   - `hermes_api_server_ok`
   - `hermes_mcp_ask_hermes_ok`
   - `openclaw_hermes_smoke_ok`
   - `openclaw_canary_parse_ok`
   - `hermes_api_key_present`

2. **Graph panel — Probe durations over time**
   - `hermes_api_server_probe_seconds`
   - `hermes_mcp_ask_hermes_seconds`
   - `openclaw_hermes_smoke_duration_seconds`
   - 24h window default

3. **Stat panel — Discord liveness**
   - `hermes_discord_event_present`
   - `openclaw_discord_ws_connected`
   - `hermes_discord_last_event_age_seconds` (color thresholds: green <3600, yellow <14400, red ≥14400)
   - `openclaw_discord_ws_last_ready_age_seconds`

4. **Graph panel — OpenClaw gateway plugin count + init failures**
   - `openclaw_gateway_ready_plugins_total`
   - `openclaw_gateway_ready_age_seconds` (secondary axis)
   - `openclaw_plugin_init_failures_recent_total` (overlay; rising counter is the most actionable view for a "plugins not loading" incident)
   - `openclaw_channel_plugin_loaded{name=...}` rendered as a per-channel table sidebar (uses the `name` label: discord/whatsapp/lobster — at-a-glance which channel plugins are present in the most recent ready list)

5. **Table + stat row — MCP servers**
   - 5a. Table panel `openclaw_mcporter_server_ok` (one row per `name` label value — discord, gh-issues, hass, etc.)
   - 5b. Three single-value stat panels in a row: `openclaw_mcporter_ha_auth_ok`, `openclaw_mcporter_ha_endpoint_reachable`, `openclaw_mcporter_ha_token_present`

6. **Graph panel — Smoke probe outcomes**
   - `openclaw_hermes_smoke_ok` (line, 0/1)
   - `openclaw_hermes_smoke_response_bytes` (secondary axis)
   - 7-day window default

7. **Stat panel — Last-run timestamps (freshness)**
   - `hermes_health_check_last_run_timestamp_seconds` (age, via `time() - <metric>`)
   - `openclaw_canary_last_run_timestamp_seconds` (age)
   - `openclaw_mcporter_check_last_run_timestamp_seconds` (age)
   - `openclaw_hermes_smoke_last_run_timestamp_seconds` (age)
   - `openclaw_gateway_ready_timestamp_seconds` (age — when the gateway last emitted ready)
   - `openclaw_microvm_active_enter_timestamp_seconds` (age — when microvm@openclaw last entered active)

### Metric coverage map (all 28 metrics)

Every metric across the four files is in at least one panel:

| File | Metric | Panel(s) |
|---|---|---|
| hermes_health.prom | hermes_api_key_present | 1 |
| | hermes_api_server_ok | 1 |
| | hermes_api_server_probe_seconds | 2 |
| | hermes_discord_event_present | 3 |
| | hermes_discord_last_event_age_seconds | 3 |
| | hermes_health_check_last_run_timestamp_seconds | 7 |
| | hermes_mcp_ask_hermes_ok | 1 |
| | hermes_mcp_ask_hermes_seconds | 2 |
| | hermes_mcp_sse_open_ok | 1 |
| openclaw_canary.prom | openclaw_gateway_ready_plugins_total | 4 |
| | openclaw_gateway_ready_timestamp_seconds | 7 |
| | openclaw_gateway_ready_age_seconds | 4 |
| | openclaw_plugin_init_failures_recent_total | 4 |
| | openclaw_canary_parse_ok | 1 |
| | openclaw_canary_last_run_timestamp_seconds | 7 |
| | openclaw_microvm_active_enter_timestamp_seconds | 7 |
| | openclaw_discord_ws_connected | 3 |
| | openclaw_discord_ws_last_ready_age_seconds | 3 |
| | openclaw_channel_plugin_loaded | 4 (sidebar) |
| openclaw_mcporter.prom | openclaw_mcporter_server_ok | 5 |
| | openclaw_mcporter_ha_auth_ok | 5 |
| | openclaw_mcporter_ha_endpoint_reachable | 5 |
| | openclaw_mcporter_ha_token_present | 5 |
| | openclaw_mcporter_check_last_run_timestamp_seconds | 7 |
| openclaw_hermes_smoke.prom | openclaw_hermes_smoke_ok | 1 (current state) + 6 (trend) |
| | openclaw_hermes_smoke_duration_seconds | 2 |
| | openclaw_hermes_smoke_response_bytes | 6 |
| | openclaw_hermes_smoke_last_run_timestamp_seconds | 7 |

Note: `openclaw_hermes_smoke_ok` appears twice — Panel 1 shows current state (live red/green tile), Panel 6 shows the 7-day trend (catches flapping). That's intentional, not duplication.

### Wiring

Add one line to `grafana.nix`'s `localDashboards`:
```nix
"openclaw-hermes-integration.json" = ../monitoring/dashboards/openclaw-hermes-integration.json;
```

### Verification

- `jq . modules/monitoring/dashboards/openclaw-hermes-integration.json >/dev/null` exits 0 (catches JSON syntax errors before rebuild; `nix flake check` won't).
- `nix-shell -p nixfmt-rfc-style --run 'nixfmt --check modules/services/grafana.nix'` exits 0.
- After switch, the dashboard appears at `https://grafana.vulcan.lan/dashboards` under "default" provider.
- All 7 panels render at least some data (no "No data" placeholders on day-1 since all four .prom files are already emitting).
- The 24h probe-duration graph shows a continuous line for `openclaw_hermes_smoke_duration_seconds` (the smoke probe has been emitting for 2+ hours by now).

### What's deliberately NOT in this deliverable

- **No new alerts** keyed off dashboard panel state. Alerts continue to live in `modules/monitoring/alerts/*.yaml`.
- **No dashboard imports from grafana.com**. Single self-authored JSON, reviewable in git.
- **No drilldown panels** for individual mcporter servers. The table form is enough; per-server detail can be a follow-up if a specific server starts misbehaving.

## Already done (no plan tasks required)

The Phase 1 Hermes sshd was actually implemented in `modules/services/hermes-vm.nix` (line 346+) — `services.openssh.enable = true`, listening on `10.99.1.2:22`, host-only via `networking.firewall.extraInputRules`. The `/root/.ssh/hermes-debug` probe key has been in place since 2026-05-12. The ports.txt comment was corrected to remove the stale "Phase 2; not enabled" suffix in the same commit batch (c7cbecb). Listed here for spec completeness; the plan does not need to repeat this work.

## Risks

| Risk | Mitigation |
| --- | --- |
| Egress tightening breaks an undiscovered Hermes dependency (e.g. some skill uses port 80 HTTP). | The LOG rule (still in place ahead of the final DROP) captures any blocked attempt with the destination IP and port. After switch, watch `journalctl -k -g hermes-egress-rejected --since "1h ago"` for the first hour. Roll back if needed. |
| Dashboard JSON syntax error breaks Grafana provisioning. | `nix flake check` won't catch this — Grafana parses the file at startup. After switch, `journalctl -u grafana.service --since "5m ago"` shows parse errors. If found, fix the JSON or roll back. |
| LOG rule floods the kernel log if blocked-traffic volume is high (LOG is non-terminating, so packets continue to the DROP regardless — there's no race; the concern is volume). | Rate-limit not necessary at observed traffic volumes (~1 destination probe per 30s). If logs flood post-deploy, add `-m limit --limit 10/min --limit-burst 10` to the LOG rule. |

## Out of scope (future sessions)

- Per-mcporter-server drilldown panels in the dashboard.
- Wyoming STT/TTS metrics on the same dashboard (separate workload).
- Stricter egress (FQDN-based via cgroup tagging or eBPF) — too complex for the value.
- New alert rules for smoke probe failure (still rely on existing `HermesAskFailing`).
