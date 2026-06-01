# Unified Agent Health Report — Design

Date: 2026-06-01
Status: Approved (design), pending implementation
Supersedes the section layout of:
- `scripts/openclaw-nightly-report.py`
- `scripts/hermes-nightly-report.py`

## 1. Goal

The two nightly health emails — OpenClaw (06:00) and Hermes (06:15) — share
almost no structure. They were authored independently weeks apart, each shaped
around whatever data happened to exist for that agent at the time:

- **OpenClaw** is *structure-forward*: MCP-server table, gateway uptime/ready/
  plugins, HA-MCP auth detail, error digest with benign-warning filtering.
- **Hermes** is *metrics-forward*: headline PASS/FAIL verdict, raw Prometheus
  gauge dump, microVM+sidecar uptime, 24h smoke probe from Prometheus, Discord
  activity breakdown, redacted error digest, self-heal incidents, in-VM SSH
  corroboration.

Make both emails render from a **single shared engine** so each report shows the
**union** of all section types, and each surface is **actually probed** for both
agents (not a placeholder) wherever a real signal exists.

## 2. Non-goals

- Not merging the two emails into one. Two separate emails remain (two `From:`
  addresses, two subjects, two timers, two recipients-of-record). The user
  explicitly wants "a pair of reports."
- Not changing the underlying metric producers (`openclaw-canary`,
  `openclaw-mcporter-check`, `hermes-health-check`, the smoke/e2e probes,
  the self-heal daemons). The report is a *consumer*; it reads what those
  already emit.
- Not adding new Prometheus alert rules or self-heal actions.
- Not changing schedules (06:00 / 06:15) or sandboxing posture beyond the two
  small additions in §8.

## 3. Root cause & fix

**Root cause:** two independently-authored scripts with zero shared code. Any
change to one never propagates to the other, so they drift.

**Fix:** one module, `scripts/agent_health_report.py`, containing a generic
report **engine** plus a `PROFILES` table with one entry per agent. The binary
is invoked `agent-health-report --agent {openclaw|hermes}`. The fixed ordered
section list lives in exactly one place, so the union holds by construction and
the two reports can never diverge again.

Single-file (engine + profiles) is chosen over a library + two thin scripts
because `pkgs.writers.writePython3Bin` packages a single source file; a sibling
import would require custom packaging. One file invoked twice with a flag is the
simplest thing that is also DRY.

## 4. Architecture

```
scripts/agent_health_report.py
  ├─ generic helpers
  │    redact(), parse_prom_textfile(), prometheus_query(),
  │    systemd_uptime(), parse_incidents(), parse_errors_log(),
  │    parse_mcporter_output(), run_mcporter_list(local|ssh), ssh_probe()
  ├─ section renderers  (each: (profile, data) -> list[str]; n/a-aware)
  │    render_headline, render_live_metrics, render_mcp_servers,
  │    render_gateway, render_uptime, render_probe_summary,
  │    render_discord, render_ha_mcp, render_errors,
  │    render_selfheal, render_invm
  ├─ PROFILES = {"openclaw": {...}, "hermes": {...}}
  ├─ collect(profile) -> dict        # gather every section's raw data
  ├─ render(profile, data) -> (subject, body)
  └─ main(argv): parse --agent, collect, render, deliver

modules/services/openclaw-nightly-report.nix  -> builds the file,
    ExecStart ".../agent-health-report --agent openclaw", keeps OPENCLAW_REPORT_* env
modules/services/hermes-nightly-report.nix     -> builds the file,
    ExecStart ".../agent-health-report --agent hermes",   keeps HERMES_REPORT_*  env
```

The old `openclaw-nightly-report.py` and `hermes-nightly-report.py` are deleted.

### 4.1 Profile schema

A profile is a plain dict. Fields (all optional unless noted; missing → section
renders `n/a`):

```
{
  "agent": "openclaw",                       # required, used in header/From default
  "display_name": "OpenClaw",                # required
  "env_prefix": "OPENCLAW_REPORT",           # required; recipient/sender/sendmail/ssh/prom read under this
  "report_header": "X-Openclaw-Report",      # mail header tag

  # section 1 — live metrics: list of prom textfiles to dump
  "live_textfiles": [".../openclaw_mcporter.prom", ".../openclaw_canary.prom"],

  # section 2 — mcp servers
  "expected_servers": ("home-assistant", "stock-trader", ...),
  "mcporter_struct_textfile": ".../openclaw_mcporter.prom",  # server_ok gauges; None -> struct col "—"
  "mcporter_live": "host+ssh" | "ssh" | None,                # how to get live tool counts
  "host_blind_servers": frozenset({...}),                    # probed only via in-VM ssh

  # section 3 — gateway + plugins
  "gateway": { "ready_age_metric": "openclaw_gateway_ready_age_seconds",
               "plugins_total_metric": "openclaw_gateway_ready_plugins_total",
               "channels_metric": "openclaw_channel_plugin_loaded",
               "init_fail_metric": "openclaw_plugin_init_failures_recent_total" }
            | None,    # None -> n/a (Hermes), with mcp-server-count note

  # section 4 — uptime
  "units": ["microvm@openclaw.service", "openclaw-self-heal.service"],

  # section 5 — 24h probe summary: list of probe families
  "probe_families": [ { "label": "OpenClaw→Hermes bridge smoke",
                        "ok": "openclaw_hermes_smoke_ok",
                        "dur": "openclaw_hermes_smoke_duration_seconds" } ],

  # section 6 — discord
  "discord": { "mode": "metrics", "connected": "openclaw_discord_ws_connected",
               "last_ready_age": "openclaw_discord_ws_last_ready_age_seconds" }
           | { "mode": "log", "log": ".../gateway.log" },

  # section 7 — ha-mcp
  "ha_mcp": { "mode": "textfile", "token": "openclaw_mcporter_ha_token_present",
              "reachable": "openclaw_mcporter_ha_endpoint_reachable",
              "auth": "openclaw_mcporter_ha_auth_ok",
              "last_run": "openclaw_mcporter_check_last_run_timestamp_seconds" }
           | { "mode": "mcporter_row", "server": "home-assistant" },

  # section 8 — errors
  "errors_log": ".../gateway-vm.err.log",
  "errors_ts_re": <compiled>,        # agent-specific timestamp/level grammar
  "benign_patterns": [<compiled>, ...],

  # section 9 — self-heal
  "incidents_json": "/var/lib/openclaw-self-heal/incidents.json",
  "selfheal_textfile": ".../openclaw_self_heal.prom",

  # section 10 — in-vm corroboration: ordered list of remote checks
  "invm_checks": [ {"label": "trader /api/schwab/status",
                    "kind": "curl", "url": "https://trader.vulcan.lan/api/schwab/status"},
                   {"label": "trader requests-TLS", "kind": "requests_tls",
                    "url": "https://trader.vulcan.lan/api/schwab/status"} ],
}
```

## 5. The eleven sections

Fixed order, identical for both agents. Bold = newly-wired real coverage.

0. **Header + headline verdict.** `<Display> health report — <host> — <iso>`, then
   `Headline: PASS|FAIL|OK — <summary>`. Verdict logic is profile-driven over the
   live metrics + in-VM probe (FAIL if any core probe is 0 or a stuck self-heal
   incident exists). Issues are listed beneath.
1. **Live metrics.** Dump the agent's `.prom` textfile gauges, sorted, one
   `name  value` per line. OpenClaw: `openclaw_mcporter.prom` + `openclaw_canary.prom`.
   Hermes: `hermes_health.prom` (+ `hermes_e2e_chat.prom`, `hermes_self_heal.prom`).
2. **MCP-servers table.** `Server | Struct | Live | Status`. Struct from the
   `*_server_ok` gauge where available (OpenClaw), else `—`. Live tool counts via
   `mcporter list` — host-side for OpenClaw with an in-VM SSH probe for
   `host_blind_servers`; **Hermes: in-VM `mcporter list` over its existing SSH
   path** (`hermes@10.99.1.2`). Each profile carries an `expected_servers` tuple:
   OpenClaw's is the existing `EXPECTED_SERVERS` set; **Hermes' is its
   service-parity set** (`vane`, `home-assistant`, `stock-trader`,
   `email-contacts`, `perplexity`, `org-db`, `searxng` — exact names confirmed
   against the VM's `mcporter.json` at implementation time). Rows returned by
   `mcporter list` but not in `expected_servers` are still shown; an
   expected-but-absent server renders `Struct —  Live ?  (not seen)` so a
   dropped server is visible rather than silently omitted.
3. **Gateway + plugins.** OpenClaw: ready age, plugins-loaded count + per-channel
   presence, init failures (all from `canary`). **Hermes: `n/a — not applicable
   (NousResearch agent has no plugin gateway; N MCP servers loaded)`** where N is
   the §2 in-VM server count; if that probe could not run, the line reads
   `… MCP server count unavailable` rather than printing `None`.
4. **microVM + sidecars uptime.** `systemctl show` over the profile's `units`:
   `active / since / restarts`. OpenClaw: `microvm@openclaw`, `openclaw-self-heal`.
   Hermes: `microvm@hermes`, `hermes-mcp`, `hermes-self-heal`.
5. **24h probe summary (Prometheus).** Per probe family: success ratio
   = `avg_over_time(<ok>[24h])`, p50/p95 = `quantile_over_time(.5|.95,
   <dur>[24h])`. **OpenClaw gains Prometheus querying** (it has none today).
   OpenClaw: bridge smoke. Hermes: own e2e chat + bridge smoke.
6. **Discord activity (24h).** Hermes: event-type counts (connected / disconnected
   / registered / flushing / skipping) + most-recent timestamps + heartbeat age.
   **OpenClaw: `ws_connected` 0/1 + last-ready age** from canary metrics (its
   gateway log uses a different vocabulary; the canary already distills it).
7. **HA-MCP.** OpenClaw: token-present / reachable / bearer-accepted + last-check
   age from `openclaw_mcporter_*` gauges. **Hermes: derived from the in-VM
   `home-assistant` mcporter row** (present with tool_count>0 ⇒ reachable+auth ok);
   `n/a` if the in-VM probe could not run.
8. **Errors digest (24h).** Tail the agent's error log, bucket identical lines,
   show top patterns + total. **Both now apply redaction AND benign-warning
   filtering** (pattern lists are profile fields; OpenClaw keeps its existing
   benign set + gains redaction; Hermes keeps redaction + gains a benign set).
9. **Self-heal incidents (24h).** `active`, `resolved 24h`, `stuck` from
   `incidents.json` ({active: dict, history: list} — identical schema for both),
   plus attempts-by-action and last-heartbeat age from `*_self_heal.prom`.
   **OpenClaw gains this whole section.**
10. **In-VM corroboration.** One SSH round-trip running the profile's `invm_checks`.
    Hermes: `/v1/capabilities` HTTP code + trader curl + requests-TLS (existing).
    **OpenClaw: trader curl + requests-TLS added** (both VMs reach trader per the
    service-parity work); plus the existing in-VM `mcporter list` feeding §2.

### 5.1 n/a policy

A section whose profile data is absent renders exactly one explicit line:
`n/a — not applicable (<reason>)` (genuine non-applicability, e.g. Hermes §3) or
`n/a — unavailable (<reason>)` (a probe that should work but didn't this run,
e.g. Prometheus unreachable, SSH key missing). The section header is always
printed, so every surface is visibly accounted for.

## 6. Security posture

- **No secrets in output.** The error digest passes every emitted line through
  `redact()` (the existing Hermes pattern set: JWT-ish triples, `sk-ant`/`sk-proj`/
  `sk-or-v1`, Bearer, `token|password|api_key=`). Applied to **both** agents now.
- The live-metrics dump emits only numeric gauges from the node-exporter
  textfiles — non-secret by construction.
- SSH probes use `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=no`
  with `UserKnownHostsFile=/dev/null` + `GlobalKnownHostsFile=/dev/null` (the
  Hermes VM host key rotates every boot), `ConnectTimeout` + hard `timeout=`. The
  key arrives via `LoadCredential`; it is never logged. **Convergence note:** the
  current Hermes `in_vm_probe` omits `IdentitiesOnly` and `GlobalKnownHostsFile`;
  the unified `ssh_probe()` adds them (matching OpenClaw's existing
  `run_mcporter_list_via_ssh`). This is a hardening improvement, not a regression
  — verify the Hermes in-VM probe still connects after the change (host-key churn
  is already covered by `UserKnownHostsFile=/dev/null`).
- The in-VM probe prints only HTTP status codes and `OK/FAIL/ERR/NOPY` tokens —
  never response bodies.
- Reports run as `root` (both units already do) but read-only against the agent
  state dirs via `ReadOnlyPaths`; the only writable path is the postfix maildrop.

## 7. Failure modes & responses

| Failure | Response |
|---|---|
| A `.prom` textfile missing | that gauge absent from §1; dependent sections render `n/a — unavailable` |
| Prometheus unreachable | §5 (and any metric-derived line) → `n/a — unavailable (Prometheus unreachable)`; never FAIL the headline on this alone |
| SSH key absent / probe times out | §2 live (blind/all), §7 (Hermes), §10 → `n/a — unavailable`; headline NOT flipped to FAIL by a skipped probe |
| `mcporter list` format changes | per-server `Live` shows `?`; a stderr diagnostic is logged (existing behavior preserved) |
| `incidents.json` malformed | self-heal section shows `active 0 / resolved 0` and notes parse failure |
| `sendmail` missing | non-zero exit, logged to journal (existing behavior) |

A probe that *could not run* must never mask a real problem nor manufacture a
false FAIL. Verdict FAIL is reserved for an affirmative `0` from a core
liveness probe or a stuck self-heal incident.

## 8. NixOS module changes

- `modules/services/openclaw-nightly-report.nix`
  - `ExecStart = ".../agent-health-report --agent openclaw"` (build the shared file).
  - add `OPENCLAW_REPORT_PROMETHEUS_URL = "http://127.0.0.1:9090"`.
  - add `/var/lib/openclaw-self-heal` to `ReadOnlyPaths`.
  - keep all existing env, sandbox, `LoadCredential`, timer.
- `modules/services/hermes-nightly-report.nix`
  - `ExecStart = ".../agent-health-report --agent hermes"`.
  - keep all existing env, sandbox, `LoadCredential`, timer.
  - (no new ReadOnlyPaths — `/var/lib/hermes-self-heal` already present.)
- `flakeIgnore` lint set: union of the two existing sets.
- No `flake.nix` topology change (both modules already imported).

## 9. Testing strategy

- **Port existing tests** onto the engine, preserving coverage:
  - Hermes: `parse_errors_log`, `parse_gateway_log`, `parse_incidents`,
    `prometheus_query`, `render_report` (dry-run), `parse_textfile`.
  - OpenClaw: `_parse_mcporter_output`.
- **New engine tests:**
  - `render(profile, data)` for each agent over a fixed synthetic `data` dict
    produces all 11 section headers in order (golden-ish structural assertions).
  - n/a rendering: a profile with a section's data removed emits the
    `n/a — …` line, not a traceback.
  - redaction applies to the OpenClaw error digest (regression for the new
    redaction path).
  - profile validation: both profiles have the required keys.
- **flake check wiring:** keep both test dirs discoverable (or consolidate into
  one `agent-health-report-tests/`); update the checks in `flake.nix` if the
  paths move.
- **Manual end-to-end before merge (§10).**

## 10. Rollout & rollback

1. `nixos-rebuild build --flake '.#vulcan'` — must build clean.
2. `pytest` the engine test suite — must pass.
3. Code review (nix-pro + python-reviewer subagents); address findings.
4. `nixos-rebuild switch --flake '.#vulcan'`.
5. `systemctl start openclaw-nightly-report.service hermes-nightly-report.service`
   — two real emails land in `johnw@vulcan.lan` with the full SSH/Prometheus
   probes exercised. Also capture `*_REPORT_DRY_RUN=1` renders to show inline.
6. Commit as a small atomic series; save a project memory.

**Rollback:** `git revert` the commit(s) and `nixos-rebuild switch`. The metric
producers are untouched, so reverting the report restores the prior two emails
exactly.

## 11. Acceptance criteria

- One source file owns the section list; both emails render from it.
- Both emails contain all 11 section headers in the same order.
- Every section is a real probe for both agents except Hermes §3 (gateway/
  plugins), which shows an explicit `n/a — not applicable` line with the MCP
  server count.
- OpenClaw error digest is redacted; both digests are benign-filtered.
- No secret, token, PSK, phone number, or response body appears in either email.
- A skipped/failed probe degrades to `n/a — unavailable` and never forces FAIL.
- `nixos-rebuild build` is clean; the ported + new tests pass.

## 12. References

- `scripts/openclaw-nightly-report.py`, `scripts/hermes-nightly-report.py`
- `modules/monitoring/services/openclaw-canary.nix` (gateway/Discord/plugin metrics)
- `modules/monitoring/services/openclaw-mcporter-check.nix` (HA-MCP gauges)
- `modules/monitoring/services/hermes-health-check.nix` (Hermes live metrics)
- `docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md`
