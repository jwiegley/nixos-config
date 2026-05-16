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

In `modules/services/hermes-microvm.nix`, immediately before the existing LOG rule (added at line 154), insert two ACCEPT rules and after the LOG rule, add a final DROP rule. The end state for the `hermes-br0 → end0` traffic is:

1. ACCEPT TCP dport 443 (HTTPS — covers Discord + OpenRouter + LiteLLM https endpoints)
2. ACCEPT UDP dport 443 (HTTP/3, increasingly used)
3. ACCEPT TCP dport 53 (DNS-over-TCP)
4. ACCEPT UDP dport 53 (DNS)
5. (kept) LOG the rest with prefix `hermes-egress-rejected: `
6. (new) DROP everything else

The intra-bridge ACCEPT (line 1 of the chain) and the three RFC-1918 DROPs (lines 3-5 of the chain) are unchanged.

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

4. **Graph panel — OpenClaw gateway plugin count**
   - `openclaw_gateway_ready_plugins_total`
   - `openclaw_gateway_ready_age_seconds` (secondary axis)

5. **Stat panel — MCP servers**
   - `openclaw_mcporter_server_ok` (per-name table; uses the `name` label)
   - `openclaw_mcporter_ha_auth_ok`
   - `openclaw_mcporter_ha_endpoint_reachable`

6. **Graph panel — Smoke probe outcomes**
   - `openclaw_hermes_smoke_ok` (line, 0/1)
   - `openclaw_hermes_smoke_response_bytes` (secondary axis)
   - 7-day window default

7. **Stat panel — Last-run timestamps (freshness)**
   - `hermes_health_check_last_run_timestamp_seconds` (age, via `time() - <metric>`)
   - `openclaw_canary_last_run_timestamp_seconds` (age)
   - `openclaw_mcporter_check_last_run_timestamp_seconds` (age)
   - `openclaw_hermes_smoke_last_run_timestamp_seconds` (age)

### Wiring

Add one line to `grafana.nix`'s `localDashboards`:
```nix
"openclaw-hermes-integration.json" = ../monitoring/dashboards/openclaw-hermes-integration.json;
```

### Verification

- `nix-shell -p nixfmt-rfc-style --run 'nixfmt --check modules/services/grafana.nix'` exits 0.
- After switch, the dashboard appears at `https://grafana.vulcan.lan/dashboards` under "default" provider.
- All 7 panels render at least some data (no "No data" placeholders on day-1 since all four .prom files are already emitting).
- The 24h probe-duration graph shows a continuous line for `openclaw_hermes_smoke_duration_seconds` (the smoke probe has been emitting for 2+ hours by now).

### What's deliberately NOT in this deliverable

- **No new alerts** keyed off dashboard panel state. Alerts continue to live in `modules/monitoring/alerts/*.yaml`.
- **No dashboard imports from grafana.com**. Single self-authored JSON, reviewable in git.
- **No drilldown panels** for individual mcporter servers. The table form is enough; per-server detail can be a follow-up if a specific server starts misbehaving.

## Deliverable C (trivial, doing inline): ports.txt update

The Phase 1 Hermes sshd was actually implemented in `modules/services/hermes-vm.nix` (line 346+) — `services.openssh.enable = true`, listening on `10.99.1.2:22`, host-only via `networking.firewall.extraInputRules`. The `/root/.ssh/hermes-debug` probe key has been in place since 2026-05-12. The ports.txt comment "Phase 2; not enabled in Phase 1" is stale and was already corrected in this same commit batch.

## Risks

| Risk | Mitigation |
| --- | --- |
| Egress tightening breaks an undiscovered Hermes dependency (e.g. some skill uses port 80 HTTP). | The LOG rule (still in place ahead of the final DROP) captures any blocked attempt with the destination IP and port. After switch, watch `journalctl -k -g hermes-egress-rejected --since "1h ago"` for the first hour. Roll back if needed. |
| Dashboard JSON syntax error breaks Grafana provisioning. | `nix flake check` won't catch this — Grafana parses the file at startup. After switch, `journalctl -u grafana.service --since "5m ago"` shows parse errors. If found, fix the JSON or roll back. |
| Egress final DROP races with the LOG rule (kernel log floods if traffic is high). | Rate-limit not necessary at observed traffic volumes (~1 destination probe per 30s). If logs flood post-deploy, add `--limit 10/min` to the LOG rule. |

## Out of scope (future sessions)

- Per-mcporter-server drilldown panels in the dashboard.
- Wyoming STT/TTS metrics on the same dashboard (separate workload).
- Stricter egress (FQDN-based via cgroup tagging or eBPF) — too complex for the value.
- New alert rules for smoke probe failure (still rely on existing `HermesAskFailing`).
