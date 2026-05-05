# OpenClaw self-heal — design

**Date:** 2026-05-05
**Status:** approved (brainstorming) — pending implementation plan
**Driver:** recurring weekly silent Discord outages on `vulcan` because the existing canary verifies plugins at startup, not whether the bot is currently responsive.

## 1. Goal

OpenClaw is the Discord-facing AI gateway running as a microVM (`microvm@openclaw.service`) on host `vulcan`. The bot must **stay responsive on Discord with no human intervention** for the failure modes that have actually happened — config-schema upgrade gotchas, plugin-runtime-deps cache rot, and silent Discord WebSocket disconnects. When something does break, monitoring detects it within minutes, deterministic remediation is attempted first, then a local AI (`hera/Qwen3.6-27B` via LiteLLM) picks the next action from a pre-authorized allowlist, and only after three unsuccessful attempts does a human get paged.

## 2. Non-goals

- Round-trip "user sends DM, bot replies" probing. The selected health floor is "Discord WebSocket connected" (option B during brainstorming).
- Auto-acting on WhatsApp / lobster / memory-qdrant outages. They alert but do not trigger self-heal.
- Auto-bumping flake inputs or running `nixos-rebuild` (would be L5 authority; user picked L3).
- Editing NixOS config files programmatically. New schema migrations remain human work.
- Round-trip latency / quality SLOs.

## 3. Health definition (the "B-floor")

OpenClaw is **healthy** if and only if all three are true:

1. `microvm@openclaw.service` is `active`.
2. `https://openclaw.vulcan.lan/health` returns `200 OK` with body `{"ok":true,"status":"live"}`.
3. The Discord WebSocket is in `connected` state (most recent `[discord] gateway: ready` log line is younger than the most recent `[discord] gateway: WebSocket closed`).

Anything below this floor for the configured `for:` window is a P1 incident eligible for auto-remediation.

## 4. Authority level (the "L3 set")

The self-heal service may **autonomously** execute exactly these three actions:

| Action | Effect | Reversibility |
|---|---|---|
| `restart_microvm` | `systemctl stop` then `start microvm@openclaw.service` | trivially reversible |
| `doctor_fix` | run `openclaw doctor --fix --non-interactive --yes` as user `openclaw` against `/var/lib/openclaw/.openclaw/`, then `restart_microvm` | doctor writes `openclaw.json.bak` automatically |
| `prune_stale_plugin_deps` | stop the VM, `mv` (not `rm`) any subdirs of `/var/lib/openclaw/.openclaw/plugin-runtime-deps/` whose name does not start with `openclaw-<current store path version>-` to a sibling `.bak-<ts>` directory, then start the VM | reversible until the weekly purge timer reaps backups >7 days old |

Any action outside this set requires a human. The action allowlist is enforced **in the action runner**, not in the AI prompt — even if the model hallucinates, the runner rejects.

## 5. Trigger model

**Deterministic-first, AI-second** (option B during brainstorming). The AI is not invoked on attempt 1, only on attempts 2 and 3. After 3 attempts the incident is marked `stuck` and a human is paged via the existing notification path; further auto-action on the same correlated incident is suppressed for the Alertmanager `repeat_interval` window (4 h).

## 6. System overview

```
┌────────────────────── vulcan host (failure domain A) ──────────────────────┐
│                                                                            │
│  Probes (every 60 s, run by openclaw-canary.timer)                         │
│  ─────                                                                     │
│   1. microvm@openclaw active state            → systemd_exporter            │
│   2. https://openclaw.vulcan.lan/health       → blackbox_exporter (NEW or  │
│                                                  existing — verify in impl) │
│   3. Discord WebSocket state                  → openclaw-canary.py (EXTEND)│
│                                                                            │
│                              ↓ (textfile + scrape)                         │
│                         Prometheus                                         │
│                              ↓                                             │
│                         Alertmanager  ── routes service=openclaw ──┐       │
│                              ↓ (other alerts)                      │       │
│                         existing notification path                 │       │
│                                                                    ↓       │
│   ┌─── openclaw-self-heal.service (NEW, runs as user openclaw-heal) ──┐    │
│   │  • HTTP webhook receiver on 127.0.0.1:9099                        │    │
│   │  • Per-incident state in /var/lib/openclaw-self-heal/incidents.json│   │
│   │  • Action runner via sudo NOPASSWD on three exact scripts          │   │
│   │  • LiteLLM client → http://127.0.0.1:4000 (hera/Qwen3.6-27B)       │   │
│   │  • Emits *.prom heartbeat metrics + synthetic alerts to AM         │   │
│   └────────────────────────────────────────────────────────────────────┘   │
│                              │                                             │
│                              ↓ (sudo to root, allowlisted commands only)   │
│      /etc/nixos/scripts/openclaw-self-heal/actions/{                       │
│        restart_microvm, doctor_fix, prune_stale_plugin_deps                │
│      }                                                                     │
└────────────────────────────────────────────────────────────────────────────┘

  ┌── openclaw microVM (failure domain B) ──┐
  │ openclaw gateway → discord, whatsapp,    │
  │   lobster, memory-qdrant, perplexity     │
  └──────────────────────────────────────────┘
```

Two isolation invariants:

- The self-heal service runs **on the host**, never inside the microVM.
- The self-heal service **does not depend on OpenClaw** to function. It calls LiteLLM directly, so OpenClaw being down does not blind the AI step.

## 7. Components

### 7.1 New: `openclaw-self-heal.service`

Long-running Python daemon. Receives Alertmanager webhooks on `127.0.0.1:9099` (port reserved in `docs/ports.txt`).

- **User:** `openclaw-heal` (new system user, no shell, no home).
- **State dir:** `/var/lib/openclaw-self-heal/` mode `0700` owned by `openclaw-heal`.
- **State file:** `incidents.json` (file-locked); schema:
  ```json
  {
    "active": {
      "<correlation_key>": {
        "first_seen_ts": <epoch>,
        "alerts": ["OpenClawDiscordWsDown", "OpenClawDiscordPluginMissing"],
        "vm_active_enter_ts": <epoch>,
        "attempts": [
          {"ts": <epoch>, "action": "restart_microvm",
           "by": "deterministic" | "ai", "ai_reason": "...",
           "result": "ok" | "err" | "litellm_unreachable", "stderr": "..."}
        ],
        "status": "in_progress" | "stuck" | "resolved",
        "next_eligible_ts": <epoch> | null
      }
    },
    "history": [/* last 100 closed incidents */]
  }
  ```
- **Correlation key:** alerts that arrive within ≤5 min AND share the same
  `openclaw_microvm_active_enter_timestamp_seconds` are the **same incident**.
  A real new failure after a fix attempt will have a fresh
  `vm_active_enter_ts` and start a new incident.
- **Hardening:** Restart=always, ProtectSystem=strict, NoNewPrivileges (except
  for the sudo path), MemoryDenyWriteExecute, RestrictSUIDSGID, full systemd
  hardening matching the rest of the repo.
- **Self-monitoring:** every 60 s writes
  `/var/lib/prometheus-node-exporter-textfiles/openclaw_self_heal.prom`
  containing heartbeat, active-incident count, action counters, and
  LiteLLM-unreachable counter.

### 7.2 Action map (attempt 1, deterministic)

```python
ACTION_MAP = {
    "OpenClawDiscordWsDown":             "restart_microvm",
    "OpenClawHttpHealthDown":            "restart_microvm",
    "OpenClawGatewayReadyStale":         "restart_microvm",
    "OpenClawDiscordPluginMissing":      "doctor_fix",
    "OpenClawPluginInitFailuresPresent": "doctor_fix",
    "OpenClawMicroVMDown":               "wait_60s",  # Restart=always handles
}
```

`wait_60s` is the no-op that just verifies systemd's own restart loop did its
job; if VM still down at end of wait, the service moves to attempt 2.

### 7.3 Attempt loop

```
on alert webhook payload P:
  key = correlate(P)
  inc = state.active.get(key) or new_incident(P)
  if inc.status in ("resolved", "stuck"): return
  if now() < inc.next_eligible_ts: return

  attempt_n = len(inc.attempts) + 1
  if attempt_n == 1:
      action = ACTION_MAP[primary_alert(inc)]
      by = "deterministic"
      ai_reason = None
  elif attempt_n in (2, 3):
      ai_resp = ai_pick(context_for(inc))   # may raise on LiteLLM failure
      if ai_resp.action == "escalate":
          mark_stuck(inc); notify(inc); return
      action = ai_resp.action
      by = "ai"; ai_reason = ai_resp.reason
  else:  # attempt 4+
      mark_stuck(inc); notify(inc); return

  start_ts = now()
  result = run_action(action)              # see 7.4
  inc.attempts.append({...})
  systemctl_start("openclaw-canary.service")
  wait_until_canary_fresh(start_ts, max_s=30)
  if probe_clear(inc):
      inc.status = "resolved"; notify_resolved(inc); save(inc)
  else:
      inc.next_eligible_ts = now() + 60     # let things settle
      save(inc)
      # Alertmanager will re-fire the webhook on its repeat_interval if still red,
      # which re-enters the loop on attempt 2/3.
```

### 7.4 Action runner

Three POSIX-shell scripts in `/etc/nixos/scripts/openclaw-self-heal/actions/`,
invoked via `sudo`:

```
sudoers (declarative, security.sudo.extraRules):
  openclaw-heal ALL=(root) NOPASSWD: /etc/nixos/scripts/openclaw-self-heal/actions/restart_microvm
  openclaw-heal ALL=(root) NOPASSWD: /etc/nixos/scripts/openclaw-self-heal/actions/doctor_fix
  openclaw-heal ALL=(root) NOPASSWD: /etc/nixos/scripts/openclaw-self-heal/actions/prune_stale_plugin_deps
```

Each script:

- has `set -euo pipefail`,
- has hard timeout (`timeout 180s ...`),
- writes one-line JSON to stdout: `{"ok": true|false, "duration_s": <float>, "notes": "..."}`,
- routes full output to journal under syslog identifier `openclaw-self-heal-action`,
- verifies its own preconditions:
  - `restart_microvm`: VM unit must be loaded.
  - `doctor_fix`: `/var/lib/openclaw/.openclaw/openclaw.json` must exist; runs the doctor as user `openclaw` with `OPENCLAW_STATE_DIR=/var/lib/openclaw/.openclaw OPENCLAW_CONFIG_PATH=/var/lib/openclaw/.openclaw/openclaw.json HOME=/var/lib/openclaw`.
  - `prune_stale_plugin_deps`: refuses unless ≥1 stale subdir exists, and stops the VM before pruning, restarts after.

A separate systemd timer (`openclaw-self-heal-bak-purge.timer`, weekly)
removes `plugin-runtime-deps.bak-*` directories older than 7 days.

### 7.5 LiteLLM / AI client

- Endpoint: `http://127.0.0.1:4000/v1/chat/completions`.
- Model: `hera/Qwen3.6-27B`.
- Auth: API key from existing SOPS secret (e.g. `litellm/master-key` —
  reuse, do not introduce a new secret).
- Timeout: 30 s, 1 retry.
- Failure handling: if both attempts fail, do NOT call AI; mark current
  attempt as `litellm_unreachable`, escalate to `stuck`, notify human.
- Token budget per call: ≤12 k input, ≤200 output. Per incident upper bound:
  ≤30 k tokens (max two AI calls). Well within the model's daily budget on
  hera.

### 7.6 AI prompt

System message:

```
You are an SRE for OpenClaw, a Discord-facing AI gateway running as a microVM
on host vulcan. Your goal is to restore service. You may take exactly ONE of
these actions:

  1. restart_microvm           — restart microvm@openclaw.service
  2. doctor_fix                — run `openclaw doctor --fix --non-interactive
                                 --yes` as user openclaw, then restart microvm
  3. prune_stale_plugin_deps   — move subdirs of /var/lib/openclaw/.openclaw/
                                 plugin-runtime-deps/ that don't match the
                                 current openclaw store path version to
                                 .bak-<ts>; then restart microvm

Output STRICTLY this JSON, no other text:
  {"action": "<one of: restart_microvm | doctor_fix | prune_stale_plugin_deps>",
   "reason": "<one sentence>"}

If you do not believe any of these will help, output:
  {"action": "escalate", "reason": "..."}
```

User message:

```
[ALERT] {alert_name}: {alert_summary}
[ATTEMPTS SO FAR]
  1. {action} ({by}) → {result}
  2. ...
[METRICS]
  openclaw_discord_ws_connected={...}
  openclaw_canary_parse_ok={...}
  openclaw_plugin_init_failures_recent_total={...}
  openclaw_gateway_ready_age_seconds={...}
  openclaw_microvm_active_enter_timestamp_seconds={...}
[err.log tail (last 80 lines, secrets redacted)]
{...}
[gateway.log tail (last 30 lines, secrets redacted)]
{...}
```

The renderer redacts anything matching common secret patterns (Discord
bot tokens `[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}`,
ANTHROPIC keys `sk-ant-…`, etc.) before submission. Redaction is a
defense-in-depth measure; the model is local on hera, but the prompt
goes through LiteLLM which does log.

### 7.7 Notifications

The self-heal service emits **synthetic alerts** back into Alertmanager via
`POST /api/v2/alerts`, so the user does not need to add a second
notification path:

| Synthetic alert | Severity | When |
|---|---|---|
| `OpenClawSelfHealActed` | info | every successful auto-action; auto-resolves on the next probe-green |
| `OpenClawSelfHealStuck` | critical | incident hits attempt 4 |
| `OpenClawSelfHealLitellmUnreachable` | warning | LiteLLM unreachable when AI was needed |

`OpenClawSelfHealDown` (heartbeat-stale) is the **only** alert that
intentionally bypasses the self-heal webhook and routes directly to the
human, so the watcher cannot become a single point of failure.

## 8. Reliability scaffolding (independent of the self-heal service)

These changes go in alongside the service because today's incident proved
each gap exists. Without them, the self-heal service spends its budget on
preventable problems.

| ID | Change | File | Reason |
|---|---|---|---|
| 8a | **Auto-`doctor --fix` in preStart**, idempotent. | `modules/services/openclaw-vm.nix` | Today's missing-discord-plugin needed `doctor --fix` to migrate plugin registry state. Running it on every boot makes upgrades self-healing before any alert fires. Adds ~5 s to boot. |
| 8b | **Stale `plugin-runtime-deps` GC in preStart** — at boot, `mv` subdirs whose name does not start with `openclaw-<current version>-` into `.bak-<ts>`; weekly timer purges backups >7 days. | `modules/services/openclaw-vm.nix` | 14 GB / 349 stale dirs accumulated. With the upstream `stageBundledPluginRuntimeDeps` patch dropped in 2026.5.x, these are dead weight. |
| 8c | **Canary: bare-`ready` support** — add fallback regex `[gateway] http server listening (N plugins: ...)` so plugin-presence gauges keep working. **Plus `expectedChannels` becomes a NixOS option** with default `[discord, whatsapp, lobster, memory-qdrant]` (drop `acpx`, now a backend, not a plugin). | `modules/monitoring/services/openclaw-canary.nix` | 2026.5.3 emits bare `[gateway] ready`; current canary silently flatlines plugin presence to 0. |
| 8d | **Canary: Discord WS state probe** — second log scan emits `openclaw_discord_ws_connected` and `openclaw_discord_ws_last_ready_age_seconds`. | same | The actual signal for "is the bot working" per §3. |
| 8e | **Alert-rule re-tune** — add `OpenClawDiscordWsDown` (`for: 3m`), `OpenClawHttpHealthDown` (`for: 1m`), `OpenClawSelfHealDown` (`for: 2m`); route service=openclaw alerts to the self-heal webhook receiver in Alertmanager config. Existing alerts retained but routed. | `modules/monitoring/alerts/openclaw.yaml` + Alertmanager route config | §3 / §6. |
| 8f | **Blackbox probe of `https://openclaw.vulcan.lan/health`** — verify it's already configured; if not, add it. | TBD by impl plan — likely `modules/monitoring/blackbox-exporter.nix` if the host runs it, else `openclaw-canary` becomes a third probe source. | Independent of canary so a canary bug does not mask a real outage. |
| 8g | **`channels.<x>.streaming` jq coercion in preStart** — already deployed today as part of the immediate fix; documented here so it isn't lost. | `modules/services/openclaw-vm.nix` | 2026.5.x stricter schema; SOPS source still has older boolean form. |

## 9. Failure modes (what does and does not get handled)

**Handled:**

- Discord WebSocket quiet disconnect → detected ≤3 min via §3.3; deterministic `restart_microvm` on attempt 1.
- Config-schema upgrade gotchas → §8a auto-doctor on every boot eliminates them at the source.
- Plugin-runtime-deps cache rot → §8b GC.
- Today's exact incident (`channels.discord.streaming: invalid config: must be object`) → §8g jq coercion + §8a auto-doctor.
- Self-heal daemon crash → `OpenClawSelfHealDown` alert bypasses self-heal, pages human.
- LiteLLM unreachable when AI is needed → escalate immediately, no infinite retry.
- Multiple simultaneous alerts on the same wedged VM → correlated into one incident (§7.1).

**Intentionally not handled:**

- "User sends DM, bot silently does nothing" beyond the WS layer — that's option C, not chosen.
- WhatsApp / lobster / memory-qdrant outage → alerts route to existing notification path, no self-heal.
- Auto-bumping flake input → would be L5, not chosen.
- Code edits to add new schema migrations → human only.

## 10. Open questions for the impl plan

- **Port allocation:** the design proposes `127.0.0.1:9099` for the webhook receiver; impl plan must verify against `docs/ports.txt` and pick a free one if 9099 is taken.
- **Blackbox exporter:** verify whether vulcan already runs it before creating a new probe definition (§8f).
- **LiteLLM auth secret:** confirm reuse of an existing SOPS key vs. needing a new one (§7.5).
- **Existing notification path:** confirm what Alertmanager currently uses (Pushover / ntfy / email) and that synthetic alert injection (§7.7) hits the same receiver.
- **Existing systemd-exporter for `microvm@openclaw.service{state="active"}` metric:** the existing alert `OpenClawMicroVMDown` already references this — confirm the metric source is healthy and reused.
- **Ad-hoc canary invocation:** §7.3 calls `systemctl start --no-block openclaw-canary.service` to force a fresh metrics emit after each action. Confirm the unit is a oneshot triggerable independently of `openclaw-canary.timer` (not blocked by `RemainAfterExit` or similar).

These are implementation-time confirmations, not design changes.

## 11. Out of scope (for this spec)

- Any change to OpenClaw's own behavior or configuration beyond the runtime-config patches in §8.
- Changes to other vulcan services (LiteLLM, Qdrant, Postgres, hera link).
- Long-term openclaw migration to multi-host / clustered deployment.
- Telemetry / observability beyond what is needed for the alert vocabulary in §8e.
