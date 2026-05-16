# Hermes Egress Tightening + Integration Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conservatively tighten Hermes microVM egress (allow TCP 443, UDP 443, TCP/UDP 53; final DROP everything else) and add a Grafana dashboard visualizing the 28 metrics across `hermes_health.prom`, `openclaw_canary.prom`, `openclaw_mcporter.prom`, and `openclaw_hermes_smoke.prom`.

**Architecture:** Two independent edits in two files. (a) `modules/services/hermes-microvm.nix` — modify the `firewall.extraCommands` + `firewall.extraStopCommands` blocks. (b) Create `modules/monitoring/dashboards/openclaw-hermes-integration.json` and wire into `modules/services/grafana.nix` via the `localDashboards` map.

**Spec:** [`/etc/nixos/docs/superpowers/specs/2026-05-15-hermes-egress-and-dashboard-design.md`](../specs/2026-05-15-hermes-egress-and-dashboard-design.md)

**Security invariants:**
- No new secrets. Egress changes affect FORWARD chain only; sshd/api_server input rules unchanged.
- Dashboard JSON contains no credentials — Grafana provisions data sources separately.
- Rollback for both deliverables is a single `nixos-rebuild switch --rollback`.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `/etc/nixos/modules/services/hermes-microvm.nix` | **modify** | Egress ACCEPT rules + LOG-prefix rename + final DROP, plus matching `extraStopCommands` cleanups |
| `/etc/nixos/modules/monitoring/dashboards/openclaw-hermes-integration.json` | **create** | The Grafana dashboard (7 panels + metric-coverage map) |
| `/etc/nixos/modules/services/grafana.nix` | **modify** | Wire the new dashboard into `localDashboards` |

---

## Task 1: Egress rule modifications

**Files:**
- Modify: `/etc/nixos/modules/services/hermes-microvm.nix` (the `firewall.extraCommands` block around lines 148-161 and the `firewall.extraStopCommands` block around lines 162-180)

- [ ] **Step 1: Single Edit replacing the LOG block in `firewall.extraCommands`**

Use the Edit tool with these exact strings.

`old_string`:
```nix
    # Egress logging — log new outbound connections from the bridge
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress: " --log-level info
```

`new_string`:
```nix
    # Allow conservative outbound set (per 7-day egress log review):
    # - TCP 443 (HTTPS — Discord, OpenRouter, internal hera)
    # - UDP 443 (HTTP/3 — Cloudflare-fronted services increasingly use it)
    # - TCP/UDP 53 (DNS)
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 443 -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 443 -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 53  -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 53  -j ACCEPT

    # Egress logging — log new outbound connections that didn't match
    # any ACCEPT above (i.e. about to be DROPped by the final rule).
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress-rejected: " --log-level info

    # Final DROP — anything not matched by the ACCEPT rules above is rejected
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -j DROP
```

This single Edit applies all three actions (the four ACCEPTs, the LOG-prefix rename, and the final DROP). Steps 2-3 below are now done; jump to Step 4.

- [ ] **Step 2: (subsumed by Step 1)**
- [ ] **Step 3: (subsumed by Step 1)**

- [ ] **Step 4: Single Edit replacing the LOG-cleanup block in `firewall.extraStopCommands`**

Use the Edit tool with these exact strings.

`old_string`:
```nix
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress: " --log-level info 2>/dev/null || true
```

`new_string`:
```nix
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 53  -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 53  -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress-rejected: " --log-level info 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -j DROP 2>/dev/null || true
```

- [ ] **Step 5: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/modules/services/hermes-microvm.nix'
```

- [ ] **Step 6: Eval-check**

```bash
nix flake check --no-build /etc/nixos 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add modules/services/hermes-microvm.nix
git commit -m "$(cat <<'EOF'
feat(hermes): tighten egress to TCP/UDP 443 + TCP/UDP 53 + final DROP

Conservative tightening informed by 7 days of hermes-egress kernel
log entries (2026-05-08 → 2026-05-15): every observed outbound
destination was TCP 443 to Cloudflare ranges (Discord). Adds explicit
ACCEPTs for 443 (TCP/UDP) and DNS (53 TCP/UDP), renames the LOG prefix
to "hermes-egress-rejected: " (LOG now only fires on about-to-DROP
traffic), and adds a final DROP for everything else.

Rollback: nixos-rebuild switch --rollback. The change is contained to
firewall.extraCommands + extraStopCommands; the SSH/api_server input
rules and intra-bridge ACCEPT are unchanged.
EOF
)"
```

---

## Task 2: Build + switch + egress verification

**Files:** none modified

- [ ] **Step 1: Acquire build lock**

```bash
if [ -f /etc/nixos/.nixos-build ]; then echo "Lock held; aborting"; exit 1; fi
touch /etc/nixos/.nixos-build
```

- [ ] **Step 2: Switch**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -10
rm -f /etc/nixos/.nixos-build
```

- [ ] **Step 3: Verify FORWARD chain shape**

```bash
sudo iptables -L FORWARD -n -v 2>&1 | grep -E 'hermes-br0|target' | head -15
```

Expected order:
1. ACCEPT (intra-bridge)
2. DROP 10.0.0.0/8
3. DROP 172.16.0.0/12
4. DROP 192.168.0.0/16
5-8. ACCEPT TCP/UDP 443/53 (the four new rules)
9. LOG `hermes-egress-rejected: `
10. DROP final

- [ ] **Step 4: Positive smoke — allowed paths**

```bash
sudo ssh -i /root/.ssh/hermes-debug -o StrictHostKeyChecking=no hermes@10.99.1.2 \
  'curl -fsS --max-time 5 -o /dev/null -w "%{http_code}\n" https://discord.com/api/v10/gateway'
```

Expected: `200`.

```bash
sudo ssh -i /root/.ssh/hermes-debug hermes@10.99.1.2 \
  'getent hosts discord.com | head -1'
```

Expected: an IP address (DNS resolved → port 53 path works).

- [ ] **Step 5: Negative smoke — blocked path (fires traffic at a blocked port)**

```bash
sudo ssh -i /root/.ssh/hermes-debug hermes@10.99.1.2 \
  'timeout 3 curl -fsS ftp://ftp.gnu.org/ >/dev/null 2>&1 && echo NOT_BLOCKED || echo BLOCKED'
```

Expected: `BLOCKED`. (`&&/||` gates on `curl`'s exit, which is non-zero when blocked; piping to `head` would falsely return 0 from `head` and mask the test. The traffic still fires at port 21 even when blocked, which is what we need for Step 6.)

- [ ] **Step 6: Confirm new LOG prefix is firing (primary evidence)**

```bash
sudo journalctl -k --since "5m ago" -g "hermes-egress-rejected" --no-pager 2>&1 | tail -5
```

Expected: 1+ lines from the FTP attempt in Step 5, with `hermes-egress-rejected:` prefix and `DPT=21`. This is the load-bearing signal — Step 5's `BLOCKED` token can be falsified by a curl quirk; the kernel log entry can't.

- [ ] **Step 7: Confirm Hermes continues to function (no Discord reconnect storm)**

```bash
grep ^hermes_discord_event_present /var/lib/prometheus-node-exporter-textfiles/hermes_health.prom
grep ^hermes_discord_last_event_age_seconds /var/lib/prometheus-node-exporter-textfiles/hermes_health.prom
```

Expected: `hermes_discord_event_present 1` and `hermes_discord_last_event_age_seconds` < 600 (event in the last 10 min). If event_age is climbing, Hermes is having trouble — roll back.

- [ ] **Step 8: No commit (verification only)**

---

## Task 3: Dashboard JSON skeleton + Panel 1 (Bridge health stat)

**Files:**
- Create: `/etc/nixos/modules/monitoring/dashboards/openclaw-hermes-integration.json`

- [ ] **Step 1: Create the dashboard skeleton**

Write a minimal Grafana dashboard JSON to `/etc/nixos/modules/monitoring/dashboards/openclaw-hermes-integration.json`. Use the existing local dashboards (`copyparty.json`, `home-assistant.json`) as the structural template — they all share the same top-level fields: `annotations`, `editable`, `panels`, `schemaVersion`, `tags`, `templating`, `time`, `timepicker`, `title`, `uid`, `version`.

Suggested header values:
```json
{
  "annotations": {"list": []},
  "editable": true,
  "panels": [],
  "schemaVersion": 39,
  "tags": ["openclaw", "hermes", "integration"],
  "templating": {"list": []},
  "time": {"from": "now-24h", "to": "now"},
  "timepicker": {},
  "title": "OpenClaw ↔ Hermes Integration",
  "uid": "openclaw-hermes-integration",
  "version": 1
}
```

- [ ] **Step 2: Add Panel 1 — Bridge health stats**

Append six entries to `panels`. Each is its own stat panel (Grafana renders them side-by-side via `gridPos.x`). The first one is the canonical template — clone its structure for tiles 2-6 and for the equivalents in later tasks, changing only `id`, `gridPos.x`, `title`, and `targets[0].expr`:

```json
{
  "type": "stat",
  "id": 1,
  "title": "SSE bridge",
  "datasource": {"type": "prometheus", "uid": "prometheus"},
  "gridPos": {"h": 5, "w": 4, "x": 0, "y": 0},
  "targets": [
    {
      "refId": "A",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "expr": "hermes_mcp_sse_open_ok",
      "legendFormat": ""
    }
  ],
  "fieldConfig": {
    "defaults": {
      "mappings": [
        {"type": "value", "options": {"0": {"text": "DOWN", "color": "red"},
                                       "1": {"text": "OK",   "color": "green"}}}
      ],
      "thresholds": {"mode": "absolute", "steps": [
        {"color": "red",   "value": null},
        {"color": "green", "value": 1}
      ]},
      "color": {"mode": "thresholds"}
    },
    "overrides": []
  },
  "options": {
    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
    "orientation": "auto",
    "textMode": "value_and_name",
    "colorMode": "background",
    "graphMode": "none",
    "justifyMode": "auto"
  },
  "pluginVersion": "11.3.0"
}
```

Tiles 2-6 — same shape, only these fields change:
| id | x | title | expr |
|---|---|---|---|
| 2 | 4 | API server | `hermes_api_server_ok` |
| 3 | 8 | ask_hermes | `hermes_mcp_ask_hermes_ok` |
| 4 | 12 | Smoke probe | `openclaw_hermes_smoke_ok` |
| 5 | 16 | Canary parse | `openclaw_canary_parse_ok` |
| 6 | 20 | API key present | `hermes_api_key_present` |

- [ ] **Step 3: Validate JSON syntax**

```bash
jq . /etc/nixos/modules/monitoring/dashboards/openclaw-hermes-integration.json >/dev/null && echo OK
```

Expected: `OK`.

- [ ] **Step 4: No commit yet (Panels 2-7 follow in Tasks 4-9)**

---

## Task 4: Panel 2 — Probe durations graph

- [ ] **Step 1: Append a `timeseries` panel** with three queries:
  - `hermes_api_server_probe_seconds`
  - `hermes_mcp_ask_hermes_seconds`
  - `openclaw_hermes_smoke_duration_seconds`

Title: "Probe wall-clock durations (last 24h)". `gridPos` height 8, width 24 in the next row.

- [ ] **Step 2: Validate JSON syntax**

```bash
jq . /etc/nixos/modules/monitoring/dashboards/openclaw-hermes-integration.json >/dev/null && echo OK
```

---

## Task 5: Panel 3 — Discord liveness

- [ ] **Step 1: Append a `stat` panel** with four tiles:
  - `hermes_discord_event_present` (0/1)
  - `openclaw_discord_ws_connected` (0/1)
  - `hermes_discord_last_event_age_seconds` (with thresholds: green <3600, yellow <14400, red ≥14400)
  - `openclaw_discord_ws_last_ready_age_seconds` (same thresholds)

- [ ] **Step 2: Validate JSON syntax**

---

## Task 6: Panel 4 — OpenClaw gateway plugin count + init failures

- [ ] **Step 1: Append a `timeseries` panel** with:
  - Primary axis: `openclaw_gateway_ready_plugins_total`
  - Primary axis: `openclaw_plugin_init_failures_recent_total` (different colour; a rising failure counter alongside the ready count is the most actionable view)
  - Secondary axis: `openclaw_gateway_ready_age_seconds`

- [ ] **Step 2: Append a sidebar table** for `openclaw_channel_plugin_loaded` grouped by the `name` label — one row per channel (discord/whatsapp/lobster) showing 0/1 for current presence.

- [ ] **Step 3: Validate JSON syntax**

---

## Task 7: Panel 5 — MCP servers (5a table + 5b three stats)

- [ ] **Step 1: Append Panel 5a — Table panel**: `openclaw_mcporter_server_ok` rendered as a table with one row per `name` label value. Title: "MCP servers — structural validity".

- [ ] **Step 2: Append Panel 5b — Three single-value stat panels in a row**:
  - `openclaw_mcporter_ha_auth_ok` (title: "HA Bearer token accepted")
  - `openclaw_mcporter_ha_endpoint_reachable` (title: "HA /api/mcp reachable")
  - `openclaw_mcporter_ha_token_present` (title: "HA token file present")

- [ ] **Step 3: Validate JSON syntax**

---

## Task 8: Panel 6 — Smoke probe outcomes (7-day trend)

- [ ] **Step 1: Append a `timeseries` panel** with:
  - Primary axis: `openclaw_hermes_smoke_ok` (line, 0/1 plot — catches flapping)
  - Secondary axis: `openclaw_hermes_smoke_response_bytes`
  - Override default time range to 7 days (panel-level)

- [ ] **Step 2: Validate JSON syntax**

---

## Task 9: Panel 7 — Last-run freshness stats

- [ ] **Step 1: Append a `stat` panel** with six PromQL queries, each computing `time() - <metric>` to show seconds since the last run:
  - `hermes_health_check_last_run_timestamp_seconds`
  - `openclaw_canary_last_run_timestamp_seconds`
  - `openclaw_mcporter_check_last_run_timestamp_seconds`
  - `openclaw_hermes_smoke_last_run_timestamp_seconds`
  - `openclaw_gateway_ready_timestamp_seconds`
  - `openclaw_microvm_active_enter_timestamp_seconds`

Color thresholds (in seconds, applied uniformly): green <600, yellow <1800, red ≥1800.

- [ ] **Step 2: Validate JSON syntax**

- [ ] **Step 3: Commit the dashboard file**

```bash
git add modules/monitoring/dashboards/openclaw-hermes-integration.json
git commit -m "$(cat <<'EOF'
feat(monitoring): Grafana dashboard for OpenClaw ↔ Hermes integration

Seven panels covering all 28 metrics across hermes_health.prom (9),
openclaw_canary.prom (10), openclaw_mcporter.prom (5), and
openclaw_hermes_smoke.prom (4):

1. Bridge health stats (sse_open, api_server, ask_hermes, smoke_ok,
   canary_parse, api_key_present)
2. Probe wall-clock durations (24h trend)
3. Discord liveness (event_present, ws_connected, last-event ages)
4. OpenClaw gateway plugin count + init failures + per-channel table
5a/5b. MCP servers (per-name table + 3 HA stats)
6. Smoke probe trend (7-day window)
7. Last-run freshness for all six probe-timestamps

UID openclaw-hermes-integration; tagged openclaw/hermes/integration.
EOF
)"
```

---

## Task 10: Wire dashboard into grafana.nix

**Files:**
- Modify: `/etc/nixos/modules/services/grafana.nix`

- [ ] **Step 1: Add the entry to `localDashboards`**

Find the `localDashboards` attrset (search for `localDashboards = {`) and add a new line keeping alphabetical-ish order:
```nix
"openclaw-hermes-integration.json" = ../monitoring/dashboards/openclaw-hermes-integration.json;
```

- [ ] **Step 2: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/modules/services/grafana.nix'
```

- [ ] **Step 3: Eval-check**

```bash
nix flake check --no-build /etc/nixos 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add modules/services/grafana.nix
git commit -m "chore(grafana): provision openclaw-hermes-integration dashboard"
```

---

## Task 11: Build + switch + dashboard verification

- [ ] **Step 1: Acquire build lock**

```bash
touch /etc/nixos/.nixos-build
```

- [ ] **Step 2: Switch**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -8
rm -f /etc/nixos/.nixos-build
```

- [ ] **Step 3: Verify Grafana ingested the dashboard without errors**

```bash
sudo journalctl -u grafana.service --since "1m ago" --no-pager 2>&1 \
  | grep -E 'error|fail|dashboard' | head -10
```

Expected: no `error parsing dashboard`, no `failed to provision dashboard`. Some provisioning info lines are OK.

- [ ] **Step 4: Confirm the dashboard file landed in Grafana's provisioning directory**

Grafana's anonymous API is disabled (`auth.anonymous.enabled = false`) so an unauthenticated `/api/search` call would 401. Easier: check the provisioned file on disk and validate its title:

```bash
sudo ls -la /var/lib/grafana/dashboards/openclaw-hermes-integration.json
sudo jq -r .title /var/lib/grafana/dashboards/openclaw-hermes-integration.json
```

Expected: file exists, title is `OpenClaw ↔ Hermes Integration`.

- [ ] **Step 5: Browser smoke (manual sanity check, optional)**

Open `https://grafana.vulcan.lan/d/openclaw-hermes-integration/openclaw-hermes-integration` in a browser and visually confirm:
- All 7 panels render
- No "No data" placeholders on Panel 1 (six green tiles expected)
- Panel 2 shows continuous lines for at least `openclaw_hermes_smoke_duration_seconds` (we have 2+ hours of data)
- Panel 5a table has rows for each mcporter server

If any panel shows "No data", check the PromQL — most likely a typo on a metric name.

---

## What this plan deliberately does NOT do

- **No new alerts.** Existing alert rules in `modules/monitoring/alerts/` continue unchanged.
- **No per-mcporter-server drilldown.** Panel 5a's table is the at-a-glance view; per-server detail is a follow-up.
- **No FQDN-based egress restrictions** (would require cgroup tagging or eBPF — too complex for the value at this scale).

## Rollback

For either deliverable:
1. `sudo nixos-rebuild switch --rollback` reverts both the egress rules and the dashboard provisioning.
2. The legacy LOG prefix `hermes-egress: ` will reappear on the rolled-back generation; no orphan rules persist because `extraStopCommands` removes the renamed-prefix rule on the way out.

If only the egress change is problematic but the dashboard is fine (or vice versa), revert just the relevant commit and rebuild — neither deliverable depends on the other.
