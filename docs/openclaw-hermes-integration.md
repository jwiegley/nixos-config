# OpenClaw ↔ Hermes Integration

Runbook for the OpenClaw ↔ Hermes integration on vulcan. Covers topology,
the component map, the six MCP tools the bridge exposes, paste-and-run
verification commands, known failure modes with one-command remediation,
the full metrics reference, and a map of where to make changes for each
common edit path.

**Last updated:** 2026-05-15. **Spec:** `docs/superpowers/specs/2026-05-15-openclaw-hermes-runbook-smoke-design.md`.

## 1. Topology

```
┌────────────────────────────────────────────────────────────────────┐
│ host (vulcan)                                                      │
│                                                                    │
│   hermes-mcp.service (Python, port 9081 on 127.0.0.1)              │
│       └─ MCP SSE server, six tools                                 │
│          ask_hermes / start_session / continue_session /           │
│          list_sessions / summarize_session / delete_session        │
│       │                                                            │
│       ▼  loopback HTTP                                             │
│   hermes microVM at 10.99.1.2                                      │
│       └─ Hermes Agent api_server :8080 (HTTPS, bridge-IP only)     │
│          └─ NousResearch hermes-agent (Discord bot Hermes#2985)    │
│                                                                    │
│   openclaw microVM at 10.99.0.2                                    │
│       └─ Claw agent / mcporter                                     │
│          └─ MCP client → http://127.0.0.1:9081/sse                 │
│             (resolves via two-stage DNAT chain:                    │
│              guest OUTPUT 127.0.0.1:9081 → br-openclaw 10.99.0.1   │
│              → host PREROUTING → 127.0.0.1:9081)                   │
└────────────────────────────────────────────────────────────────────┘
```

**Why the two-stage DNAT exists:** a microVM guest cannot route to the
host's `127.0.0.1` directly because the loopback interface isn't shared
across the virtio network boundary. The bridge IP (`10.99.0.1` for
br-openclaw, `10.99.1.1` for br-hermes) is the only routable host
address from inside the VM. The guest's `OUTPUT` chain rewrites
`127.0.0.1:9081` to the bridge gateway, and the host's `PREROUTING`
chain rewrites that back to `127.0.0.1:9081` so the bound hermes-mcp
socket accepts the connection. This keeps the bridge bound to loopback
(not exposed to the 192.168.1.0/24 LAN) while still being reachable
from inside the openclaw VM.

## 2. Components

| Unit | Path | One-line role |
| --- | --- | --- |
| `hermes-mcp.service` | `modules/services/hermes-mcp.nix` | Host Python MCP-SSE bridge; consumed by Claw, calls Hermes api_server |
| `microvm@hermes.service` | `modules/services/hermes-microvm.nix` + `hermes-vm.nix` | Runs the Hermes Agent guest at 10.99.1.2 |
| `microvm@openclaw.service` | `modules/services/openclaw-microvm.nix` + `openclaw-vm.nix` | Runs the Claw agent guest at 10.99.0.2 |
| `openclaw-prepare-secrets.service` | `modules/services/openclaw-microvm.nix` | Nix-merges the structural template with atomic SOPS secrets, writes `${secretsStagingDir}/openclaw-config` |
| `hermes-health-check.service` + `.timer` | `modules/monitoring/services/hermes-health-check.nix` | Host-side 4-axis probe (every 5min); emits `hermes_*.prom` |
| `hermes-self-heal.service` + `.timer` | `modules/services/hermes-self-heal.nix` | Watchdog reading hermes_*.prom; restarts hermes-mcp or microvm@hermes on persistent failure |
| `openclaw-canary.service` | `modules/monitoring/services/openclaw-canary.nix` | Claw-side log-tailing canary; emits `openclaw_canary_*.prom` |
| `openclaw-mcporter-check.service` | `modules/monitoring/services/openclaw-mcporter-check.nix` | Validates the in-guest mcporter.json structure |
| `openclaw-hermes-smoke.service` + `.timer` | `modules/monitoring/services/openclaw-hermes-smoke.nix` | End-to-end MCP-SSE probe (every 15min); emits `openclaw_hermes_smoke_*.prom` |
| `openclaw-self-heal.service` | `modules/services/openclaw-self-heal.nix` | Alertmanager webhook receiver + remediation runner |

## 3. The six MCP tools

The hermes-mcp bridge exposes six tools, all returning a JSON envelope
`{session_id, reply, message_count}` (or an `error` field on failure).

- **`ask_hermes(prompt, session_id?)`** — Send a prompt to Hermes. If
  session_id is omitted, a fresh session is created. *Latency: 1–5min
  for prompts that need tool use (yfinance, execute_code); ~5–20s for
  trivial prompts answered from the model alone.* This is the only
  tool whose response time depends on what Hermes does internally.
- **`start_session(name?)`** — Create a new named (or anonymous)
  Hermes conversation session. *Latency: <1s.*
- **`continue_session(session_id, prompt)`** — Send a follow-up prompt
  within an existing session. *Latency: same as `ask_hermes`.*
- **`list_sessions(limit?)`** — List Hermes sessions, MRU first.
  *Latency: <1s.*
- **`summarize_session(session_id)`** — Ask Hermes to summarise a
  session; stores the summary. *Latency: 1–3min (one model call).*
- **`delete_session(session_id)`** — Delete a Hermes session from
  local bookkeeping. *Latency: <1s.*

Tools backed by Hermes inference (`ask_hermes`, `continue_session`,
`summarize_session`) participate in the MCP progress-heartbeat
protocol — the bridge emits a `notifications/progress` event every
30s with `resetTimeoutOnProgress: true` so the Claw side's MCP client
timer doesn't expire mid-call.

## 4. Verification — paste-and-run

### 4a. Bridge SSE accepts connections

```bash
curl -sI --max-time 5 http://127.0.0.1:9081/sse | head -3
```

Expected: `HTTP/1.1 200 OK` and a `content-type: text/event-stream`
in the headers.

### 4b. The Claw VM can reach the bridge

```bash
sudo ssh -i /root/.ssh/openclaw-probe -o StrictHostKeyChecking=no \
  openclaw@10.99.0.2 \
  'curl -sI --max-time 5 http://127.0.0.1:9081/sse | head -3'
```

Expected: `HTTP/1.1 200 OK`. The SSH key probe pattern is documented
in `memory/project_openclaw_vm_ssh_probe.md`. If you get a 502/timeout,
check the two-stage DNAT chain via `sudo nft list table ip nat`.

### 4c. Health-check metrics summary

```bash
cat /var/lib/prometheus-node-exporter-textfiles/hermes_health.prom \
  | grep -E '^hermes_(ask|api_server|mcp_sse|api_key|discord)_'
```

Quick read-out:
- `hermes_api_key_present 1` — `API_SERVER_KEY` is readable
- `hermes_api_server_ok 1` — Hermes /v1/capabilities returns 200
- `hermes_mcp_sse_open_ok 1` — hermes-mcp /sse accepts connections
- `hermes_mcp_ask_hermes_ok 1` — a full ask_hermes round-trip
  completed within 60s
- `hermes_discord_event_present 1` — Discord gateway has events
  in the recent log tail

If any of these is `0`, see Section 5.

### 4d. Full Claw-side test (manual only — gold-standard recovery probe)

**Not run by the automated smoke probe**; this exists for operators
to verify the agent loop end-to-end when investigating an outage. It
takes 1–5 minutes (short) or 2–5+ minutes (long) and is *not* bounded
by the automated probe's 90s budget.

Short variant — Hermes price lookup (exercises yfinance):
```bash
sudo ssh -i /root/.ssh/openclaw-probe openclaw@10.99.0.2 \
  'openclaw chat "Ask Hermes for the current Bitcoin price."'
```

Long variant — Hermes execute_code:
```bash
sudo ssh -i /root/.ssh/openclaw-probe openclaw@10.99.0.2 \
  'openclaw chat "Have Hermes execute df -h and report the results."'
```

A passing run returns a coherent reply through Claw (which itself
went through the MCP bridge to Hermes and back). A failing run
typically times out or returns "Hermes appears to be offline" — see
Section 5 item 1.

### 4e. Hermes Discord age

```bash
cat /var/lib/prometheus-node-exporter-textfiles/hermes_health.prom \
  | grep ^hermes_discord_last_event_age_seconds
```

Healthy: `<14400` (less than 4h). Self-heal triggers a microvm restart
at the 4h threshold (see `modules/services/hermes-self-heal.nix`).

## 5. Failure modes and recovery

1. **Claw hallucinates "Hermes offline" or "Hermes unreachable".**
   Cause: Claw is a 27B local model (currently `hera/omlx/Qwen3.6-27B-MLX-8bit`),
   not Claude — its model-reasoning capacity is limited, and it
   sometimes confabulates outages from ICMP failures on unrelated IPs
   despite Hermes responding correctly to MCP calls. The hermes MCP
   tool description in `openclaw.json` already discourages this
   diagnosis pattern. **Remediation:** ignore the diagnosis; ask Claw
   to call `ask_hermes` again, and if the smoke metric
   (`openclaw_hermes_smoke_ok 1`) and `hermes_mcp_ask_hermes_ok 1`
   both stay healthy, the bridge is fine and you can disregard Claw's
   self-narration.

2. **Hermes Discord WebSocket zombies after a restart.**
   Cause: the upstream NousResearch hermes-agent's Discord client
   sometimes goes silent after the microVM restarts but does not
   surface a connection error, so `hermes_discord_last_event_age_seconds`
   climbs while everything else looks fine. **Auto-remediation:**
   `hermes-self-heal.service` triggers a `systemctl restart microvm@hermes.service`
   once `hermes_discord_last_event_age_seconds > 14400`.
   **Manual remediation:** `sudo systemctl restart microvm@hermes.service`.

3. **MCP timeout during long Hermes runs.**
   Cause: a Claw-initiated `ask_hermes` call kicks off Hermes's
   internal tool-use cycle (yfinance, execute_code, etc.); these can
   take 15–20 min for a single user prompt that requires several
   tool invocations. **Mitigation in place:**
   `MCP_TOOL_TIMEOUT=1800000` (30 min) on the Claw side (env var on
   `microvm@openclaw.service`), plus progress heartbeats every 30s
   via `notifications/progress` with `resetTimeoutOnProgress: true`.
   **Failure signal:** if a Claw-side timeout fires despite heartbeats
   visible in `journalctl -u hermes-mcp.service`, investigate the
   hermes-mcp logs and the Claw-side mcporter logs.
   **Remediation:** `sudo systemctl restart hermes-mcp.service`.

4. **LiteLLM virtual key rotation breaks agent inference.**
   Cause: the openclaw config consumes a LiteLLM virtual key as one of
   the four atomic SOPS secrets (`openclaw/litellm-virtual-key`). When
   that key is rotated, `openclaw-prepare-secrets.service` must re-run
   to bake the new value into `${secretsStagingDir}/openclaw-config`,
   then the openclaw microVM must restart. **Auto-remediation:**
   `restartUnits = [ "openclaw-prepare-secrets.service"
   "microvm@openclaw.service" ]` on the sops.secrets declaration
   handles this on `nixos-rebuild switch`. **Manual remediation
   (e.g. mid-rotation without rebuild):**
   `sudo systemctl restart openclaw-prepare-secrets.service && sudo systemctl restart microvm@openclaw.service`.

## 6. Metrics reference

All metrics are gauges. Files live at
`/var/lib/prometheus-node-exporter-textfiles/`.

### `hermes_health.prom` (9 metrics)

| Metric | Range | Meaning |
| --- | --- | --- |
| `hermes_api_key_present` | 0/1 | `API_SERVER_KEY` was readable from `/run/secrets/hermes/env` |
| `hermes_api_server_ok` | 0/1 | Hermes api_server `/v1/capabilities` returned 200 |
| `hermes_api_server_probe_seconds` | float | Wall-clock seconds for the api_server capabilities probe |
| `hermes_discord_event_present` | 0/1 | At least one Discord event was found in `gateway.log` tail |
| `hermes_discord_last_event_age_seconds` | float | Wall-clock seconds since the most recent Discord gateway event |
| `hermes_health_check_last_run_timestamp_seconds` | float (unix) | When the health check last ran |
| `hermes_mcp_ask_hermes_ok` | 0/1 | A full ask_hermes round-trip completed within 60s |
| `hermes_mcp_ask_hermes_seconds` | float | Wall-clock seconds for the end-to-end ask_hermes probe |
| `hermes_mcp_sse_open_ok` | 0/1 | hermes-mcp `/sse` accepted a connection and emitted the endpoint event |

### `openclaw_canary.prom` (10 metrics, excerpted)

| Metric | Range | Meaning |
| --- | --- | --- |
| `openclaw_gateway_ready_plugins_total` | int | Plugin count from the most recent `[gateway] ready` line |
| `openclaw_gateway_ready_timestamp_seconds` | float (unix) | Unix timestamp of the most recent `[gateway] ready` line |
| `openclaw_gateway_ready_age_seconds` | float | Seconds since the most recent `[gateway] ready` line |
| `openclaw_plugin_init_failures_recent_total` | int | Plugin init failures seen in the log tail |
| `openclaw_canary_parse_ok` | 0/1 | Canary successfully parsed a recent ready line |
| `openclaw_canary_last_run_timestamp_seconds` | float (unix) | When the canary last ran |
| `openclaw_microvm_active_enter_timestamp_seconds` | float (unix) | When `microvm@openclaw.service` last entered active state |
| `openclaw_discord_ws_connected` | 0/1 | Discord WebSocket is currently connected |
| `openclaw_discord_ws_last_ready_age_seconds` | float | Seconds since the most recent positive Discord ready event |
| `openclaw_channel_plugin_loaded{name=...}` | 0/1 | The named plugin is present in the most recent ready list |

### `openclaw_mcporter.prom` (5 metrics)

| Metric | Range | Meaning |
| --- | --- | --- |
| `openclaw_mcporter_server_ok{name=...}` | 0/1 | The named mcporter entry is structurally valid |
| `openclaw_mcporter_ha_auth_ok` | 0/1 | HA `/api/mcp` accepts the staged Bearer token (not 401/403) |
| `openclaw_mcporter_ha_endpoint_reachable` | 0/1 | HA `/api/mcp` returned any HTTP response (no network error) |
| `openclaw_mcporter_ha_token_present` | 0/1 | `/run/secrets/openclaw/home-assistant-token` exists and is non-empty |
| `openclaw_mcporter_check_last_run_timestamp_seconds` | float (unix) | When the mcporter check last ran |

### `openclaw_hermes_smoke.prom` (4 metrics — NEW)

| Metric | Range | Meaning |
| --- | --- | --- |
| `openclaw_hermes_smoke_ok` | 0/1 | The round-trip ask_hermes probe succeeded |
| `openclaw_hermes_smoke_duration_seconds` | float | Wall-clock seconds for the round-trip |
| `openclaw_hermes_smoke_response_bytes` | int | Length of the response envelope (0 on failure; ~90 typical) |
| `openclaw_hermes_smoke_last_run_timestamp_seconds` | float (unix) | When the probe last ran |

## 7. Where to make changes

| Edit | File / mechanism |
| --- | --- |
| Bump the Claw-side MCP tool timeout | `modules/services/openclaw-vm.nix`, the `MCP_TOOL_TIMEOUT` env var |
| Add a new MCP tool | `pkgs/hermes-mcp/src/hermes_mcp/tools.py` (handler) + `server.py` (`_TOOL_SCHEMAS` + `_TOOL_HANDLERS`) |
| Change Claw's agent model | `models.yaml` `llm.agent.name` (propagates via the `models.nix` compatibility adapter) |
| Add or rotate an atomic SOPS secret consumed by openclaw | `sops /etc/nixos/secrets/secrets.yaml` to edit the value; declare in `openclaw-microvm.nix` as `sops.secrets."openclaw/<name>"` with `restartUnits`; wire into the overlay block in `openclaw-prepare-secrets.service` |
| Adjust self-heal cooldowns or thresholds | `modules/services/hermes-self-heal.nix` (script body) |
| Bump the smoke probe schedule | `modules/monitoring/services/openclaw-hermes-smoke.nix`, the `intervalSeconds` option (default 900) |
| Kill switch — disable the smoke probe | `sudo systemctl stop --now openclaw-hermes-smoke.timer` (transient), or set `services.openclawHermesSmoke.enable = false;` in `hosts/vulcan/default.nix` and `nixos-rebuild switch` (persistent) |

## 8. Hermes service parity (2026-05-28)

This doc covers the **bridge** direction (OpenClaw → Hermes via the 9081 `ask_hermes`
path). Separately, as of 2026-05-28 Hermes reached **host-service parity** with OpenClaw:
the Hermes microVM (`10.99.1.2`) now reaches the same seven host services OpenClaw does,
via its own `hermes-br0` gateway DNAT (`10.99.1.1:PORT→127.0.0.1:PORT`, mirroring the
`br-openclaw` pattern; the new ports are recorded in `docs/ports.txt`).

- **Web search:** native SearXNG backend (`SEARXNG_URL` + `web.search_backend="searxng"`).
- **MCP servers:** Vane (cited research), Home Assistant, stock-trader, email + contacts,
  Perplexity, and read-only org PostgreSQL — registered via the `hermes-agent` native MCP
  client. Most reuse OpenClaw's shipped scripts/secrets; only `perplexity-mcp.py` and
  `org-db-mcp.py` are net-new.

These widen the Hermes VM's reach but stay inside the microVM isolation boundary; egress
stays restricted to the enumerated DNAT ports plus 443/53, the org-DB role is read-only,
and no new plaintext enters `secrets.yaml`. See the design spec for the full rationale.

## Related documents

- **Service parity spec:** `docs/superpowers/specs/2026-05-28-hermes-service-parity-design.md`
- **Spec:** `docs/superpowers/specs/2026-05-15-openclaw-hermes-runbook-smoke-design.md`
- **Bridge plan:** `docs/superpowers/plans/2026-05-12-openclaw-hermes-mcp-bridge.md`
- **Config refactor:** `docs/superpowers/specs/2026-05-14-openclaw-nix-config-design.md`
- **Memory:** `project_hermes_agent.md`, `project_openclaw_migration.md`, `project_openclaw_vm_ssh_probe.md`
