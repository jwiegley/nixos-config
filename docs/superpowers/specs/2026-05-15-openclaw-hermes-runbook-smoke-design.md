# OpenClaw ↔ Hermes Integration: Runbook + Smoke Test — Design Spec

**Status:** Approved by user, awaiting spec-reviewer round.
**Sibling docs:**
- `/etc/nixos/docs/superpowers/plans/2026-05-12-openclaw-hermes-mcp-bridge.md` — the original bridge plan; this spec closes its acceptance-criterion #7 (runbook).
- `/etc/nixos/docs/superpowers/specs/2026-05-14-openclaw-nix-config-design.md` — the config-refactor that just landed; this spec references the new merge pipeline as a load-bearing component.

## Why

Two gaps remain in the OpenClaw ↔ Hermes integration:

1. **No user-facing runbook.** The original `2026-05-12-openclaw-hermes-mcp-bridge.md` plan listed `docs/openclaw-hermes-integration.md` as acceptance criterion #7, but it was never written. The result: every diagnostic round-trip starts from zero. The most recent painful example was Claw repeatedly misdiagnosing Hermes as offline despite Hermes responding — a runbook with documented failure modes would have shortcut that loop.
2. **No end-to-end synthetic check from OpenClaw's side.** `hermes-health-check.service` probes the bridge as the host, but nothing currently exercises the path Claw itself takes (host loopback 9081 → DNAT to Claw's bridge IP, then back through MCP SSE). A bridge-level probe that talks the actual MCP protocol catches a class of regressions (SSE framing, MCP handshake, progress-notification plumbing) that the simpler curl-based hermes-health check skips.

## Architecture (recap of the integration this spec documents)

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
│                                                                    │
│   openclaw microVM at 10.99.0.2                                    │
│       └─ Claw agent / mcporter                                     │
│          └─ MCP client → http://127.0.0.1:9081/sse                 │
│             (resolves via two-stage DNAT chain:                    │
│              guest OUTPUT 127.0.0.1:9081 → br-openclaw 10.99.0.1   │
│              → host PREROUTING → 127.0.0.1:9081)                   │
└────────────────────────────────────────────────────────────────────┘
```

## Deliverables

### A. Runbook — `/etc/nixos/docs/openclaw-hermes-integration.md`

Single markdown file. Sections (in order):

1. **Topology** — the diagram above, plus a one-paragraph explanation of why the two-stage DNAT exists (microVM guest can't reach host loopback directly; a bridge IP is the only routable address from inside the VM).
2. **Components** — bulleted table listing each load-bearing systemd unit + its file path + one-line job:
   - `hermes-mcp.service` (host) — Python MCP SSE bridge to Hermes api_server.
   - `microvm@hermes.service` — runs the Hermes guest.
   - `microvm@openclaw.service` — runs the Claw guest.
   - `openclaw-prepare-secrets.service` — Nix-merges the structural template with atomic SOPS secrets; produces the openclaw-config staging file the Claw VM mounts via virtiofs.
   - `hermes-health-check.service` + `.timer` — host-side 4-axis health probe; emits `hermes_*.prom`.
   - `hermes-self-heal.service` + `.timer` — watchdog reading the metrics; restarts hermes-mcp or microvm@hermes on persistent failure.
   - `openclaw-canary.service` — Claw-side log-tailing canary; emits `openclaw_canary_*.prom`.
   - `openclaw-mcporter-check.service` — validates the mcporter.json structure.
   - **NEW** `openclaw-hermes-smoke.service` + `.timer` — end-to-end MCP probe (this spec).
3. **The six MCP tools** — for each: one-sentence description, expected latency, typical use. Pulled from the existing tool docstrings in `pkgs/hermes-mcp/src/hermes_mcp/server.py`.
4. **Verification — paste-and-run** — five labelled command blocks:
   - **4a.** Bridge SSE returns 200: `curl -sI --max-time 5 http://127.0.0.1:9081/sse`.
   - **4b.** Claw VM can reach the bridge (executed via the openclaw-probe SSH key): `sudo ssh -i /root/.ssh/openclaw-probe openclaw@10.99.0.2 'curl -sI --max-time 5 http://127.0.0.1:9081/sse'`.
   - **4c.** Health metrics summary: `cat /var/lib/prometheus-node-exporter-textfiles/hermes_health.prom | grep -E '^hermes_(ask|api_server|sse|api_key|discord)_'` plus a short "what each line means" key.
   - **4d.** Full Claw-side test (manual; documented as the gold-standard recovery probe):
     - Short variant: an SSH-in-and-prompt sequence that asks Claw to use the `ask_hermes` MCP tool with a short prompt (e.g. price of BTC). Expected 1–3 min.
     - Long variant: same but exercising Hermes's `execute_code` skill (e.g. `df -h` inside the Hermes sandbox). Expected 2–5 min.
   - **4e.** Hermes Discord age: `cat /var/lib/prometheus-node-exporter-textfiles/hermes_health.prom | grep ^hermes_discord_event_age_seconds`. <14400 = healthy; ≥14400 = self-heal will restart the Hermes microVM.
5. **Failure modes + recovery** — short numbered list of the ones we've actually hit, each with a 1-2 line cause description and a one-command (or one-action) remediation:
   1. **Claw hallucinates "Hermes offline"** — model-reasoning limitation; Claw is a 27B local model, not Claude. Remediation: ignore, retry. The MCP description text already discourages diagnosis attempts.
   2. **Hermes Discord WebSocket zombies after a restart** — gateway silent for hours, `hermes_discord_event_age_seconds` climbs. Auto-remediation: `hermes-self-heal.service` restarts microvm@hermes at the 4h threshold. Manual remediation: `sudo systemctl restart microvm@hermes.service`.
   3. **MCP timeout during long Hermes runs** — `ask_hermes` blocks for 15-20 min while Hermes runs internal tool-use cycles. Mitigation already in place: `MCP_TOOL_TIMEOUT=1800000` (30 min) on the Claw side; progress heartbeats every 30s from hermes-mcp via `notifications/progress` with `resetTimeoutOnProgress: true`. Failure indicator: client-side timeout despite heartbeat presence — investigate hermes-mcp logs.
   4. **LiteLLM key rotation** — agent stops responding because Claw/openclaw-config's `litellm-virtual-key` SOPS secret has been re-keyed but openclaw-prepare-secrets.service didn't re-run. Remediation: `sudo systemctl restart openclaw-prepare-secrets.service && sudo systemctl restart microvm@openclaw.service`. `restartUnits` in the sops.secrets declaration handles this automatically on `nixos-rebuild switch`.
6. **Metrics reference** — single table: metric name | type | range | meaning. Covers `hermes_*` (5 metrics), `openclaw_canary_*` (5 metrics), `openclaw_mcporter_*` (5 metrics), and the new `openclaw_hermes_smoke_*` (4 metrics).
7. **Where to make changes** — six rows:
   - Bump MCP tool timeout: `modules/services/openclaw-vm.nix`, `MCP_TOOL_TIMEOUT` env var.
   - Add a new MCP tool: `pkgs/hermes-mcp/src/hermes_mcp/tools.py` + `server.py` registration.
   - Change Claw's agent model: `models.nix` `llm.agent.name`.
   - Add/rotate an atomic SOPS secret: edit `secrets.yaml` via `sops`, add a corresponding `sops.secrets."openclaw/<name>"` declaration in `openclaw-microvm.nix`, wire it into the overlay block in `openclaw-prepare-secrets.service`.
   - Adjust self-heal cooldowns/thresholds: `modules/services/hermes-self-heal.nix` (script body).
   - Bump the smoke probe schedule: `modules/monitoring/services/openclaw-hermes-smoke.nix` (`OnCalendar`).

Doc length target: ≈350 lines of markdown. Style matches `docs/HOME_ASSISTANT_ALERTING.md` (headings, copy-paste blocks, tables where they help).

### B. Smoke probe — Python script + NixOS module

#### B.1 Script: `/etc/nixos/scripts/openclaw-hermes-smoke.py`

A standalone Python 3.12 script (the hermes-mcp package already pins 3.12). It does NOT import from the `hermes_mcp` package — it speaks raw MCP-over-SSE so a hermes-mcp packaging change can't break it. ~150 LOC.

Behavior:

1. Open SSE connection to `http://127.0.0.1:9081/sse`. Receive the initial `endpoint` event (gives a session-scoped POST URL).
2. POST the MCP `initialize` request (protocol `2025-03-26`, client info: `openclaw-hermes-smoke/0.1.0`).
3. Wait for `initialized` notification ack from the SSE stream (~50ms).
4. POST `tools/call` with `name="ask_hermes"`, `arguments={"prompt": "Reply with exactly OK and nothing else."}`. Include a `progressToken` so the heartbeat path gets exercised.
5. Stream SSE events; ignore `notifications/progress`; capture the first `tools/call` result.
6. Timeout budget: 90 seconds total (Hermes typically replies to a trivial prompt in 2–10 seconds on the local 27B; 90s leaves margin for cold-cache + model swap).
7. Write `/var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom` atomically (write to `.tmp`, rename) with four metrics:
   - `openclaw_hermes_smoke_ok` — 1 if a non-empty text response was received; 0 otherwise.
   - `openclaw_hermes_smoke_duration_seconds` — wall-clock between initiate and result.
   - `openclaw_hermes_smoke_response_bytes` — length of the response text (0 on failure).
   - `openclaw_hermes_smoke_last_run_timestamp_seconds` — `time.time()` at end of probe.

Exit code: 0 always (we want the systemd unit to be "active (exited) status=0/SUCCESS" so the metric is the only signal). Failures go to stderr (visible in journal).

Dependencies: stdlib only (`http.client`, `json`, `urllib`, `time`, `os`, `sys`). No httpx, no aiosse — keep deps to zero so this script can run even when hermes-mcp's deps are mid-update.

#### B.2 Tests: `/etc/nixos/scripts/openclaw-hermes-smoke-tests/`

`test_smoke.py` — unit-tests the parser and the metric-writer with a fake SSE server (stdlib `http.server` in a thread). Two tests:
- `test_happy_path_emits_ok=1` — bridge returns a content envelope; metric writer emits `openclaw_hermes_smoke_ok 1`.
- `test_timeout_emits_ok=0` — bridge stalls; metric writer emits `openclaw_hermes_smoke_ok 0` and zero response_bytes.

Pytest is invoked from a `nix run` derivation hooked into `flake.nix` via the existing pattern (see `scripts/openclaw-self-heal/tests/`).

#### B.3 NixOS module: `/etc/nixos/modules/monitoring/services/openclaw-hermes-smoke.nix`

Provides:
- `systemd.services.openclaw-hermes-smoke` (oneshot)
  - `Type=oneshot`, `ExecStart=${pkgs.writers.writePython3Bin "..." ... script}`
  - `User=hermes-mcp` (already exists; this user is the principal of the bridge service so it's the natural "from the bridge's perspective" actor — but for the smoke probe we actually want a separate identity to catch permission regressions; see open question below)
  - `WorkingDirectory=/var/lib/openclaw-hermes-smoke` (a tmpfs-style state dir, created via `tmpfiles.rules` `d`)
- `systemd.timers.openclaw-hermes-smoke`
  - `OnCalendar=*:0/15` (every 15 min, matching `hermes-health-check.timer`)
  - `RandomizedDelaySec=120` (so it doesn't fire same second as hermes-health-check)
  - `Persistent=true`
- Imported from `hosts/vulcan/default.nix`.

#### B.4 Port registry update: `/etc/nixos/docs/ports.txt`

No new port (probe uses existing 9081). Just add a comment line near the 9081 entry noting that openclaw-hermes-smoke is a second loopback consumer.

### What this spec deliberately does NOT do

- **No new alert rule.** The existing `HermesAskFailing` rule in `modules/monitoring/alerts/hermes.yaml` already fires on `hermes_ask_ok == 0` for 15min. The smoke probe is a second observational vantage point that joins the existing dashboard but doesn't double-page on the same failure. If we later see the smoke probe catching a class of failures the existing rule misses, that's the trigger for a new alert — not this spec.
- **No Grafana dashboard updates.** The 4 new metrics can be queried ad-hoc; a dashboard adds polish but isn't load-bearing. Deferred follow-up if useful.
- **No changes to hermes-mcp itself.** The probe speaks the bridge's public MCP-SSE contract; it doesn't need any new server-side affordances.
- **No changes to the openclaw guest VM.** The probe runs entirely on the host.

## Open questions

1. **User identity for the smoke probe.** Three reasonable choices: (a) reuse the existing `hermes-mcp` user (simplest; no new user); (b) reuse the `prometheus` user that owns the textfile-collector directory (clean separation but requires the textfile dir to be writeable by it); (c) create a new `openclaw-hermes-smoke` system user (most isolated). The textfile dir at `/var/lib/prometheus-node-exporter-textfiles/` is owned by `prometheus:prometheus` mode `0775` — both `hermes-mcp` (in supplementary group `prometheus`? need to check) and a new user (with the prometheus supplementary group) can write there. Recommendation: option (a) — `hermes-mcp` already has the right adjacency; verify in Task 1 of the plan that it's in the `prometheus` group or can be added cleanly.
2. **What exactly to ask Hermes.** "Reply with exactly OK and nothing else" is a deterministic short prompt, but Hermes (NousResearch agent) may interpolate explanation. Better wording recommended: `"Respond with exactly two characters: the letters O and K. No other content."` — and assert `len(response) <= 16` rather than `response == "OK"` (room for trailing whitespace/newline). The smoke is for liveness, not response correctness.

## Verification (what "done" looks like)

1. `cat /etc/nixos/docs/openclaw-hermes-integration.md | wc -l` ≥ 300 and ≤ 500.
2. `nix-shell -p nixfmt-rfc-style --run 'nixfmt --check modules/monitoring/services/openclaw-hermes-smoke.nix'` exits 0.
3. `pytest scripts/openclaw-hermes-smoke-tests/ -v` passes (≥2 tests).
4. After `nixos-rebuild switch`: `systemctl is-active openclaw-hermes-smoke.timer` → `active`; first run finishes within ≤120s.
5. `cat /var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom` shows all 4 metrics with `_ok=1`.
6. The doc cross-references the new metrics in Section 6 (Metrics reference).
7. `systemctl --failed` is empty.

## Out of scope (future sessions)

- Grafana dashboard for the new metrics.
- Phase E of the openclaw config refactor (legacy `openclaw/config` blob removal — waits on bake clock).
- Hermes Phase 2 sshd at 10.99.1.2:22.
- Hermes egress nftables tightening based on observation.
- A new alert specifically for smoke probe failures (only add when we have evidence the existing `HermesAskFailing` misses something).
