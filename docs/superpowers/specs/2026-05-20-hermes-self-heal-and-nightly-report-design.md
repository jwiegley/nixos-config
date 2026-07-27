# Hermes Self-Heal + Nightly Report — Design

> **Archival — 2026-05-20.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/hermes-self-heal.nix`, `modules/services/hermes-nightly-report.nix`).

**Status:** Draft
**Author:** Claude (Opus 4.7)
**Date:** 2026-05-20
**Related specs:** `2026-05-05-openclaw-self-heal-design.md` (the OpenClaw analog this spec mirrors), `2026-05-15-openclaw-hermes-runbook-smoke-design.md` (the bridge smoke probe this builds on).

## 1. Goal

Bring Hermes Agent up to OpenClaw parity for automated health management, and add a daily emailed report so the operator sees Hermes' state every morning without logging in.

Concretely:

1. **Replace** the existing shell-based `hermes-self-heal.nix` polling watchdog with an Alertmanager-webhook-driven Python daemon that:
   - Maps known Hermes alerts to deterministic first-attempt actions.
   - Escalates to an AI tier (LiteLLM `hera/Qwen3.6-27B`, same as OpenClaw) for attempts 2–3 when the deterministic action fails to clear the incident.
   - Marks incidents "stuck" after 3 attempts and emits a synthetic critical alert that goes to email via the existing critical receiver.
   - Exposes the same `/var/lib/prometheus-node-exporter-textfiles/hermes_self_heal.prom` heartbeat shape as OpenClaw so the existing dashboard panels can be extended without inventing a new metric vocabulary.
2. **Add** a daily nightly report (`hermes-nightly-report.service`) that aggregates Hermes' health signals into a plain-text email and pipes it through the host's `sendmail` to `johnw@vulcan.lan` at 06:15 local time daily.
3. **Wire** the new pieces into Alertmanager and the port registry, mirroring the OpenClaw wiring exactly.

## 2. Non-goals

- **No canary equivalent.** `modules/monitoring/services/hermes-health-check.nix` already round-trips the full chain (`api_server` → `hermes-mcp` SSE → `ask_hermes` → Qwen) every 5 min and emits 9 Hermes-prefixed Prometheus metrics. Re-implementing a canary would duplicate that.
- **No mcporter-check mirror.** `modules/monitoring/services/openclaw-hermes-smoke.nix` already does a stdlib-only bridge smoke probe every 15 min using SSE; the metrics it writes (`openclaw_hermes_smoke.prom`) are pulled into the nightly report instead of being re-collected.
- **No config-drift check.** Hermes' config surface is small and tightly coupled to the `hermes-agent` flake input; the OpenClaw drift-check was justified by 50+ config keys that the upstream package churns. Hermes doesn't have that exposure.
- **No replacement of `hermes-health-check.nix` or `hermes.yaml` alerts.** They stay as-is; this spec adds new pieces around them.

## 3. Out of scope (deferred)

- Migrating Hermes state to `/tank/hermes` (called out in the original Hermes microVM project notes; orthogonal).
- Adding a Phase-3 OpenClaw-side ability to *invoke* Hermes self-heal as a tool. Daemon-to-daemon healing across VMs is a separate spec.
- Notifying via Discord. Email is the channel for this round, matching the OpenClaw nightly report and the existing critical-receiver path.

## 4. Architecture

```
                   ┌───────────────────────────────┐
                   │  Prometheus                   │
                   │  rules: alerts/hermes.yaml    │
                   └──────────────┬────────────────┘
                                  │ fires
                                  ▼
                   ┌───────────────────────────────┐
                   │  Alertmanager                 │
                   │  route: service =~ hermes-*   │
                   │         continue=true         │
                   └────┬─────────────────┬────────┘
                        │ webhook         │ continue=true → critical-receiver
                        ▼                 ▼ (email path stays intact)
        ┌───────────────────────────┐    ┌─────────────────────────┐
        │ hermes-self-heal.service  │    │ Existing email pipeline │
        │ Python daemon             │    │ (sendmail → johnw)      │
        │ 127.0.0.1:9098            │    └─────────────────────────┘
        │                           │
        │ Tier 1: deterministic     │
        │ Tier 2/3: LiteLLM         │
        │ Tier 4: emit "Stuck" alrt │──────┐
        └──────────┬────────────────┘      │ synthetic alert (service=hermes-self-heal)
                   │                       │ goes back to Alertmanager
                   │ sudo -n               ▼
                   ▼                ┌──────────────────────────┐
        ┌───────────────────────────┐
        │ actions/* (5 scripts)     │
        │  • restart_microvm        │
        │  • restart_mcp            │
        │  • restage_secrets        │
        │  • reset_credential_pool  │
        │  • restart_health_check   │
        │ aux/* (read-only)         │
        │  • read_log_tail          │
        │  • kick_health_check      │
        └───────────────────────────┘

                   ┌───────────────────────────────┐
                   │  systemd timer 06:15 daily    │
                   └──────────────┬────────────────┘
                                  ▼
                   ┌───────────────────────────────┐
                   │ hermes-nightly-report.service │
                   │  • reads hermes_health.prom   │
                   │  • reads openclaw_hermes_     │
                   │    smoke.prom                 │
                   │  • systemctl show microvm@... │
                   │  • tails gateway.log+err.log  │
                   │  • optional SSH in-VM probe   │
                   │  • reads incidents.json       │
                   │  • renders ASCII tables       │
                   │  • pipes to /run/wrappers/    │
                   │    bin/sendmail               │
                   └───────────────────────────────┘
```

## 5. Components

### 5.1 NixOS modules

| File | Purpose |
|---|---|
| `modules/services/hermes-self-heal.nix` (REWRITE) | System user `hermes-heal`, sudoers allowlist for 5 actions + 2 aux helpers, systemd unit running the Python daemon, SOPS secret reuse for LiteLLM master key, hardening matching OpenClaw. |
| `modules/services/hermes-nightly-report.nix` (NEW) | systemd timer 06:15 daily + oneshot service, runs the report Python script as root with tight sandbox, SSH key loaded via `LoadCredential`. |

### 5.2 Scripts

| File | Purpose |
|---|---|
| `scripts/hermes-self-heal/daemon.py` (NEW) | Port of `scripts/openclaw-self-heal/daemon.py`, with Hermes-specific `ACTION_ALLOWLIST`, `ACTION_MAP`, `WEBHOOK_PORT=9098`, `SYSTEM_PROMPT`, log paths, and metric file. Heartbeat metric `hermes_self_heal_*`. |
| `scripts/hermes-self-heal/actions/restart_microvm` (NEW) | `systemctl restart microvm@hermes.service`. JSON output. |
| `scripts/hermes-self-heal/actions/restart_mcp` (NEW) | `systemctl restart hermes-mcp.service`. JSON output. |
| `scripts/hermes-self-heal/actions/restage_secrets` (NEW) | `systemctl restart hermes-prepare-secrets.service` → `microvm@hermes.service`. JSON output. |
| `scripts/hermes-self-heal/actions/reset_credential_pool` (NEW) | `rm /var/lib/hermes/.hermes/auth.json` → `microvm@hermes.service`. JSON output. Recovers from `last_status: exhausted` stuck state. |
| `scripts/hermes-self-heal/actions/restart_health_check` (NEW) | `systemctl restart hermes-health-check.service`. Refreshes `hermes_health.prom` after an action. JSON output. |
| `scripts/hermes-self-heal/aux/read_log_tail` (NEW) | Read N lines from `/var/lib/hermes/.hermes/logs/{gateway,errors}.log`. Argument-validated; only those two basenames allowed. |
| `scripts/hermes-self-heal/aux/kick_health_check` (NEW) | Synchronous restart of `hermes-health-check.service` after an action; daemon waits 15s then re-reads `hermes_health.prom`. |
| `scripts/hermes-nightly-report.py` (NEW) | The report generator. ~600 LOC max. Renders an ASCII-table email and pipes to `sendmail`. Supports `HERMES_REPORT_DRY_RUN=1` for stdout testing. |

### 5.3 Tests

| File | Purpose |
|---|---|
| `scripts/hermes-self-heal/tests/` (NEW) | Pytest suite mirroring `scripts/openclaw-self-heal/tests/`: unit tests for `correlation_key`, `validate_action`, `redact`, `first_attempt_action`, and a `handle_alertmanager_payload` integration test with `run_action` monkeypatched. |
| `scripts/hermes-nightly-report-tests/` (NEW) | Pytest suite with fixtures for parsing the textfile, gateway log, errors log, and rendering the report deterministically. |
| Wired into `flake.nix` `checks` per the pattern established by `tests/checks.nix:mkPytestCheck`. |

### 5.4 Alerts (additions)

Three new rules appended to `modules/monitoring/alerts/hermes.yaml`, mirroring OpenClaw's watchdog rules:

```yaml
- alert: HermesSelfHealDown
  expr: time() - hermes_self_heal_last_heartbeat_seconds > 600
  for: 5m
  labels:
    severity: warning
    category: monitoring
    service: hermes-self-heal          # NOT hermes-* — must not loop back
  annotations:
    summary: "hermes-self-heal daemon heartbeat stale (>10 min)"

- alert: HermesSelfHealStuck
  expr: hermes_self_heal_active_incidents > 0
  for: 30m
  labels:
    severity: critical
    category: availability
    service: hermes-self-heal
  annotations:
    summary: "Hermes self-heal incident open for >30 minutes"

- alert: HermesSelfHealLitellmUnreachable
  expr: increase(hermes_self_heal_litellm_unreachable_total[1h]) > 3
  for: 5m
  labels:
    severity: warning
    category: monitoring
    service: hermes-self-heal
  annotations:
    summary: ">3 LiteLLM unreachable events in last hour for hermes self-heal"
```

### 5.5 Alertmanager routing

Append a second top-priority route in `modules/services/alertmanager.nix` (before the existing storage/critical routes, after the OpenClaw self-heal route):

```nix
{
  match_re = {
    service = "hermes-(mcp|agent)";
  };
  receiver = "hermes-self-heal";
  group_wait = "10s";
  group_interval = "5m";
  repeat_interval = "4h";
  continue = true;
}
```

And a new receiver:

```nix
{
  name = "hermes-self-heal";
  webhook_configs = [
    { url = "http://127.0.0.1:9098/alert"; send_resolved = true; }
  ];
}
```

Rationale for `match_re` instead of two `match` routes: the Hermes alerts use two service labels (`hermes-mcp` and `hermes-agent`), unlike OpenClaw which uses one. `match_re` keeps the routing rule single-line and removes the maintenance burden of remembering to update two places when a new Hermes alert is added. **Note:** this is the first use of `match_re` in `modules/services/alertmanager.nix` — the existing OpenClaw, storage, and critical routes all use plain `match = { ... }`. The `services.prometheus.alertmanager.configuration` attrset is a passthrough to upstream Alertmanager YAML, which supports `match_re` natively, so no module change is needed to use it. Implementation should add an inline comment in `alertmanager.nix` noting this is the first such usage.

The synthetic alerts the daemon emits use `service: hermes-self-heal` (note the dash and full word, not regex-matched), so they explicitly do NOT loop back through this route — matching OpenClaw's pattern.

### 5.6 Port registry

Add to `docs/ports.txt`:

```
9098 127.0.0.1 Hermes Self-Heal webhook receiver
```

## 6. Daemon behavior

### 6.1 Action allowlist

```python
ACTION_ALLOWLIST = (
    "restart_microvm",
    "restart_mcp",
    "restage_secrets",
    "reset_credential_pool",
    "restart_health_check",
)
WEBHOOK_PORT = 9098
```

### 6.2 Deterministic first-attempt map

```python
ACTION_MAP = {
    "HermesAskFailing":            "restart_microvm",
    "HermesApiServerDown":         "restart_microvm",
    "HermesDiscordZombieSuspected":"restart_microvm",
    "HermesMcpBridgeDown":         "restart_mcp",
    "HermesHealthCheckStale":      "restart_health_check",
}
```

**No default fallback.** An alert with no `ACTION_MAP` entry is logged, the counter `hermes_self_heal_unknown_alerts_total` is incremented, and the daemon returns 200 to Alertmanager without taking any action. Rationale: an unknown alert is more often a sign of a new rule the operator hasn't classified yet than something the daemon should guess about; OpenClaw's `first_attempt_action` defaults to `restart_microvm`, but that's appropriate for OpenClaw because every OpenClaw alert today should respond to a VM restart, whereas Hermes already has `HermesApiKeyMissing` in its rule set — a SOPS/config failure that no allowlisted action can fix. Defaulting would just consume the AI tier on the next two attempts and end at `stuck` regardless.

This decision intentionally diverges from OpenClaw. The behavioral guard test in §11.1 (`test_handle_payload`) must cover the explicit-ignore path.

### 6.3 AI escalation

Identical to OpenClaw:
- Attempts 2 and 3: send `[ALERTS]`, `[ATTEMPTS SO FAR]`, `[METRICS]`, `[gateway.log tail]`, `[errors.log tail]` to LiteLLM `hera/Qwen3.6-27B` with the system prompt below.
- Strict JSON response with `{"action": "<one of allowlist>", "reason": "..."}` or `{"action": "escalate", "reason": "..."}`.
- Same redaction (`REDACT_PATTERNS`) applied to log tails before sending.

System prompt (adapted):

```
You are an SRE for Hermes Agent, a NousResearch LLM bot running as a microVM
on host vulcan. Hermes exposes a Discord bot (Hermes#2985) and an
OpenAI-compatible api_server consumed by hermes-mcp on the host (which
OpenClaw uses as an MCP tool). Your goal is to restore service. You may take
exactly ONE of:
  1. restart_microvm
  2. restart_mcp
  3. restage_secrets
  4. reset_credential_pool
  5. restart_health_check
Output STRICTLY this JSON, no other text:
  {"action": "<one of the five>", "reason": "<one sentence>"}
If you do not believe any of these will help, output:
  {"action": "escalate", "reason": "..."}
```

### 6.4 Heartbeat metric

`/var/lib/prometheus-node-exporter-textfiles/hermes_self_heal.prom`, written every 60s by a daemon background thread, with the same shape as OpenClaw:

```
hermes_self_heal_last_heartbeat_seconds {unix_ts}
hermes_self_heal_active_incidents {count}
hermes_self_heal_attempts_total{action="restart_microvm"} {n}
hermes_self_heal_attempts_total{action="restart_mcp"} {n}
hermes_self_heal_attempts_total{action="restage_secrets"} {n}
hermes_self_heal_attempts_total{action="reset_credential_pool"} {n}
hermes_self_heal_attempts_total{action="restart_health_check"} {n}
hermes_self_heal_litellm_unreachable_total {n}
hermes_self_heal_unknown_alerts_total {n}
```

### 6.5 State

`/var/lib/hermes-self-heal/incidents.json`. Same flock-protected atomic-replace pattern as OpenClaw. Owner: `hermes-heal:hermes-heal`, mode `0700`.

### 6.6 Probe-clear logic

After each action the daemon kicks `hermes-health-check.service`, waits 15s, and reads `hermes_mcp_ask_hermes_ok` from `hermes_health.prom`. If 1.0, marks incident `resolved`. Matches OpenClaw's `probe_clear()` semantics with the Hermes-specific signal.

## 7. Nightly report behavior

### 7.1 Schedule + delivery

- Timer: `OnCalendar = *-*-* 06:15:00`, `Persistent = true`, `RandomizedDelaySec = "5min"`.
- Service: `Type = oneshot`, `User = root`, `Group = root`, `TimeoutStartSec = "5min"`.
- Recipient: `johnw@vulcan.lan` via `HERMES_REPORT_SENDMAIL=/run/wrappers/bin/sendmail` (the script uses a `HERMES_REPORT_*` env-var family throughout — `HERMES_REPORT_TO`, `HERMES_REPORT_FROM`, `HERMES_REPORT_SENDMAIL`, `HERMES_REPORT_DRY_RUN`, `HERMES_REPORT_SSH_KEY`, `HERMES_REPORT_SSH_TARGET`, `HERMES_REPORT_PROMETHEUS_URL` — matching the `OPENCLAW_REPORT_*` convention but namespaced to Hermes).
- Subject: `[hermes-nightly] {hostname} {date} — {summary_one_liner}` where the summary is e.g. `all healthy` or `1 incident, 2 errors` so the operator can triage from the inbox.

### 7.2 Sections of the report

Each section is one ASCII table. If a source is unavailable, the section prints `(not available: <reason>)` rather than crashing.

1. **Headline** — overall health verdict (PASS / DEGRADED / FAIL) derived from `hermes_mcp_ask_hermes_ok` AND `hermes_api_server_ok` AND `hermes_mcp_sse_open_ok` at report time. FAIL if any is 0; DEGRADED if any is `> 1.0s slower` than the 24h median.
2. **Live metrics** — current values for all 9 `hermes_*` gauges from `hermes_health.prom` with stale-warning if `hermes_health_check_last_run_timestamp_seconds` is older than 10 min.
3. **microVM uptime** — `systemctl show -p ActiveEnterTimestamp,NRestarts microvm@hermes.service` and same for `hermes-mcp.service`.
4. **24h smoke probe summary** — three Prometheus HTTP API calls to `GET http://127.0.0.1:9090/api/v1/query?query=<urlencoded>`, with the response shape `{"status":"success","data":{"resultType":"vector","result":[{"metric":{...},"value":[<ts>,"<float_as_string>"]}]}}` (read `data.result[0].value[1]`):
   - Success ratio: `avg_over_time(openclaw_hermes_smoke_ok[24h])` → multiply by 100 for a percent.
   - Median latency: `quantile_over_time(0.5, openclaw_hermes_smoke_duration_seconds[24h])`.
   - p95 latency: `quantile_over_time(0.95, openclaw_hermes_smoke_duration_seconds[24h])`.

   The smoke probe emits a single binary gauge per 15-min run, not a counter — `avg_over_time` over the binary gauge IS the success ratio in this case. Also pull `openclaw_hermes_smoke_last_run_timestamp_seconds` from the textfile and report its age to surface staleness. If Prometheus is unreachable (connection refused, non-200, malformed JSON), fall back to the current single snapshot value from `openclaw_hermes_smoke.prom` and print `(history unavailable: Prometheus unreachable)`. The smoke probe's metric shape is NOT modified by this work.

   Sandbox note: §7.3 `RestrictAddressFamilies` already includes `AF_INET`/`AF_INET6` and there is no `IPAddressDeny`, so 127.0.0.1:9090 is reachable from the unit.
5. **Discord activity** — tail `gateway.log` for last 24h, breakdown by event type: connect / inbound / outbound / reconnect / error. Surface the time of the most recent event of each type.
6. **Errors digest** — top 10 distinct error patterns in `errors.log` over last 24h, ordered by count. Identical bucket-by-leading-regex logic as the OpenClaw `recent_errors`. Output piped through `REDACT_PATTERNS` before render.
7. **Self-heal incidents** — count of incidents started in last 24h from `/var/lib/hermes-self-heal/incidents.json`, breakdown by alert name + action + outcome (resolved / stuck / in_progress). If any are stuck, FLAG at top of report.
8. **In-VM corroboration (optional)** — SSH to `hermes@10.99.1.2` using `/root/.ssh/hermes-debug` (loaded via `LoadCredential`), run `curl -s -m 5 http://localhost:8080/v1/capabilities -o /dev/null -w '%{http_code}'`, report the HTTP code. Skipped (with `(probe skipped: <reason>)`) on SSH failure rather than failing the whole report.

### 7.3 Sandbox

- `ProtectSystem = "strict"`, `ProtectHome = true`, `PrivateTmp = true`, `NoNewPrivileges = true`.
- `ReadOnlyPaths`: `/var/lib/hermes`, `/var/lib/hermes-self-heal`, `/var/lib/prometheus-node-exporter-textfiles`, `/etc/nixos/certs`, `/etc/ssl`.
- `ReadWritePaths`: `/var/lib/postfix/queue` (so sendmail can drop into the maildrop).
- `RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" "AF_PACKET" ]`. AF_NETLINK is required because postfix sendmail calls `getifaddrs()` at startup — same gotcha that bit OpenClaw report.
- `LoadCredential = [ "probe-ssh-key:${config.sops.secrets."hermes/probe-ssh-private-key".path}" ]`.
- `path = with pkgs; [ systemd coreutils openssh ]`.

### 7.4 SOPS secret for the SSH probe

New SOPS entry `hermes/probe-ssh-private-key` (mode 0400, owner root). Contains the **same** ed25519 key currently at `/root/.ssh/hermes-debug` (authorized in the Hermes VM as `claude-hermes-debug`). The host-side `/root/.ssh/hermes-debug` remains for interactive debugging; the nightly report consumes the same key via `LoadCredential` so it never touches the disk path. Renaming/rotating: change the SOPS blob, re-add `claude-hermes-debug` public half to `hermes-vm.nix:openssh.authorizedKeys.keys`, redeploy. (Out of scope for this spec: rotating the key — track separately.)

## 8. Security posture

- **Daemon runs as `hermes-heal`**, NOT root. The only path to privileged action is the sudoers allowlist, which names absolute paths to scripts under `/etc/nixos/scripts/hermes-self-heal/{actions,aux}/`. No bare commands.
- **Action scripts validate their own arguments**. No script takes a free-form path or unit name; everything is hardcoded to Hermes-specific units and the Hermes state dir.
- **`reset_credential_pool` is the only state-deleting action.** It deletes exactly one file (`/var/lib/hermes/.hermes/auth.json`). The script must verify the file is under `/var/lib/hermes/.hermes/` before deleting (no traversal). The Hermes module's `system.activationScripts."hermes-agent-setup"` recreates this file fresh on next VM start from env vars, so the delete is recoverable.
- **No new firewall openings.** Webhook binds 127.0.0.1:9098, reachable only from Alertmanager on the same host.
- **AI tier sees redacted logs.** `REDACT_PATTERNS` strips Discord bot tokens, Anthropic/OpenAI/OpenRouter API key shapes, and generic `token=`/`password=`/`api_key=` assignments before any log line is sent to LiteLLM. Same patterns as OpenClaw; extend if Hermes' log corpus reveals new shapes.
- **Nightly report sandbox** — read-only access to Hermes state; the only writable path is the postfix maildrop. SSH probe uses a credential loaded into `$CREDENTIALS_DIRECTORY` rather than disk.
- **Sudo `mail_no_*` carve-outs** mirror OpenClaw's defense against the stuck-sendmail-loop bug (2026-05-08 → 2026-05-15 incident). Defaults:hermes-heal !mail_no_perms,!mail_no_user,!mail_badpass,!mail_always.
- **`/run/sudo` in ReadWritePaths.** Same reason as OpenClaw: sudo writes a per-uid timestamp file even with NOPASSWD, and without RW access the unit fails AND spawns a stuck sendmail.

## 9. Failure modes & responses

| Failure | Response |
|---|---|
| LiteLLM unreachable during AI tier | Daemon marks incident `stuck`, emits `HermesSelfHealLitellmUnreachable`, returns 200 to Alertmanager. |
| AI returns non-allowlisted action | Daemon raises `ActionRejectedError`, marks incident `stuck`, emits `HermesSelfHealStuck`. |
| Action script times out (240s) | Daemon records `{"ok": false, "notes": "action timed out"}`, treats as failed attempt, escalates next time. |
| Daemon itself crashes | systemd `Restart=always`, `RestartSec=5s`. Heartbeat metric stops updating → `HermesSelfHealDown` fires after 10 min. |
| Daemon health-check probe says still failing after action | Incident stays `in_progress`; next Alertmanager fire (after `repeat_interval=4h`) triggers next attempt. |
| Nightly report sendmail TEMPFAIL | systemd unit fails; `systemctl --failed` shows it; report next day still runs. No retry — same posture as OpenClaw report. |
| Nightly report SSH probe fails | Section prints `(probe skipped: <reason>)`; report still delivered. |
| Webhook port 9098 conflict | Build fails (nothing else uses 9098 today; registry will reserve it). |

## 10. Migration from the existing simple self-heal

The existing `modules/services/hermes-self-heal.nix` is a shell-script polling watchdog with a 15-minute cooldown. The replacement is a webhook-driven daemon with state in a JSON file. There is no live state in the old shell version (just timestamp stamps under `/var/lib/hermes-self-heal/last-restart-*`), so migration is:

1. Rebuild — the old systemd timer + service disappear, new daemon service appears.
2. Old `/var/lib/hermes-self-heal/` directory keeps its permissions (`d` directive in tmpfiles ensures no data loss). The old `last-restart-*` files are harmless and can be left in place; the new daemon writes `incidents.json` in the same directory.
3. The shell watchdog's failure thresholds (2-tick / 3-tick) are absorbed by Alertmanager's `for: 5m` clauses on the Hermes alerts. No functional regression.

The shell-script unit name (`hermes-self-heal.service`) is reused for the new Python daemon, so external observers don't need to learn a new unit name. Type changes from `oneshot` to `simple`, which systemd handles cleanly across rebuilds. The unit's `User` also changes from `root` to the new `hermes-heal` system user; the tmpfiles `d` directive for `/var/lib/hermes-self-heal` re-`chown`s the directory to `hermes-heal:hermes-heal` on rebuild (pre-existing `last-restart-*` files keep their old `root:root` ownership and `0644` mode but are harmless artifacts the new daemon never reads — operators inspecting the dir later will see a mixed-ownership state that's expected).

The old `hermes-self-heal.timer` (`OnUnitActiveSec = 300s`) is replaced by the always-on daemon. NixOS' switch-to-configuration deactivates the orphaned timer on rebuild.

## 11. Testing strategy

### 11.1 Unit tests

- `tests/test_daemon.py` — `validate_action`, `correlation_key`, `first_attempt_action`, `redact`, `render_prompt` snapshot, `_build_message` MIME shape.
- `tests/test_actions_shape.py` — every script in `actions/` and `aux/` is executable, has the right shebang, and (for actions) prints valid JSON on a smoke invocation (mock systemctl).
- `tests/test_handle_payload.py` — feed a synthetic Alertmanager POST through `handle_alertmanager_payload`, monkeypatch `run_action` to record calls, assert: deterministic action on attempt 1, AI on attempts 2-3, stuck on attempt 4.
- `tests/test_allowlist_is_exactly_the_authorized_actions.py` — guard test: sudoers allowlist in the NixOS module must equal the Python `ACTION_ALLOWLIST` tuple. Catches drift.

### 11.2 Nightly report tests

- `tests/test_parse_textfile.py` — fixtures for healthy + missing + stale `hermes_health.prom`.
- `tests/test_parse_gateway_log.py` — bundled fixture of `gateway.log` with each event type; assert event counts and most-recent-event timestamps.
- `tests/test_render_report.py` — golden-file render against deterministic inputs; renders match committed expected output.
- `tests/test_main_dry_run.py` — runs with `HERMES_REPORT_DRY_RUN=1`, asserts stdout has all section headers and doesn't crash.

### 11.3 Flake check wiring

Both suites added to `flake.nix` `checks` via the existing `tests/checks.nix:mkPytestCheck` helper.

### 11.4 Manual end-to-end before merge

1. Build + switch.
2. `curl -X POST http://127.0.0.1:9098/alert -d '{"alerts":[{"status":"firing","labels":{"alertname":"HermesAskFailing","service":"hermes-mcp"},"startsAt":"<isoz>"}]}'`.
3. Watch `journalctl -u hermes-self-heal -f` for: deterministic action, action invocation, probe-clear.
4. Verify `hermes_self_heal_attempts_total{action="restart_microvm"}` incremented in the textfile.
5. `systemctl start hermes-nightly-report.service` (manual trigger), check `journalctl` for delivery, check user's inbox for the email.
6. Verify SSH probe lands a green section by intentionally breaking it (wrong key) and re-running, expect `(probe skipped: ...)` rather than report failure.

## 12. Open questions / explicit decisions

- **Q:** Should the daemon also emit a synthetic `HermesSelfHealActed` info-level alert (OpenClaw does) so operators see action events in Alertmanager UI?
  - **A: Yes.** Same shape as OpenClaw. Goes to nowhere (info-level doesn't match any receiver) but shows up in the Alertmanager event log.
- **Q:** Should `restart_health_check` ever be a first-attempt deterministic action for `HermesHealthCheckStale`?
  - **A: Yes.** Added to the deterministic map above. If the health-check script itself died mid-run, a restart is the right first move.
- **Q:** Should the nightly report include OpenClaw's mcporter view of Hermes?
  - **A: No.** That's already implicit in `openclaw_hermes_smoke.prom` (which exercises the same mcporter SSE path every 15 min). Adding a third probe path would just add a third thing to keep in sync.
- **Q:** Should `reset_credential_pool` require any operator confirmation?
  - **A: No.** The file is recreated automatically on next VM start; loss is fully recoverable. The action is in the L3 allowlist, not invoked deterministically, so the AI tier has to actively pick it.

## 13. Rollout & rollback

- **Rollout:** single commit (or 2–3 small commits if review prefers) — daemon module, scripts, nightly-report module, alertmanager + ports + alerts. `nixos-rebuild switch` activates everything.
- **Rollback:** `nixos-rebuild switch --rollback`. The old shell watchdog comes back; daemon stops; nightly-report timer stops. State files under `/var/lib/hermes-self-heal/` are left in place but ignored.
- **Verification post-rollout:** acceptance criteria below.

## 14. Acceptance criteria

1. `nixos-rebuild switch --flake '.#vulcan'` succeeds with the new modules.
2. `nix flake check` passes including the new pytest suites.
3. `systemctl status hermes-self-heal.service` shows `active (running)`, listening on 127.0.0.1:9098.
4. `hermes_self_heal_last_heartbeat_seconds` is fresh (<2 min) in the textfile.
5. A synthetic alert POST to `/alert` results in a logged deterministic action and updated attempts counter.
6. `systemctl start hermes-nightly-report.service` delivers an email to johnw@vulcan.lan containing all 8 section headers.
7. Old `hermes-self-heal.timer` no longer exists in the system (`systemctl list-timers --all` does not list it).
8. Port registry `docs/ports.txt` lists `9098 127.0.0.1 Hermes Self-Heal webhook receiver`.

## 15. References

- `docs/superpowers/specs/2026-05-05-openclaw-self-heal-design.md` — the analog this mirrors.
- `modules/services/openclaw-self-heal.nix`, `scripts/openclaw-self-heal/daemon.py`, `scripts/openclaw-self-heal/actions/*`, `scripts/openclaw-self-heal/aux/*` — implementation reference.
- `modules/services/openclaw-nightly-report.nix`, `scripts/openclaw-nightly-report.py` — nightly report reference.
- `modules/monitoring/services/hermes-health-check.nix` — source of the metrics the daemon consumes.
- `modules/monitoring/services/openclaw-hermes-smoke.nix` — source of `openclaw_hermes_smoke.prom`.
- `modules/monitoring/alerts/hermes.yaml` — alerts that trigger the daemon.
- `modules/services/alertmanager.nix` — routing wiring.
- Memory: `project_hermes_agent.md` (Phase 1+2 details), `project_openclaw_self_heal.md` (the gotchas the daemon must avoid).
