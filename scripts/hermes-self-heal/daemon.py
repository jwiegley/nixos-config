#!/usr/bin/env python3
"""hermes-self-heal — Alertmanager webhook receiver and remediation runner.

See docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md.
Ported from scripts/openclaw-self-heal/daemon.py with Hermes-specific
action set, alert mapping, metric prefix, and the explicit-ignore behavior
on unknown alerts (NO default fallback; OpenClaw's daemon matches this since 2026-07-30).
"""
__version__ = "0.1.0"

import time
import json
import fcntl
import os
import pathlib
import re
import subprocess
import urllib.request

ACTION_ALLOWLIST = (
    "restart_microvm",
    "restart_mcp",
    "restage_secrets",
    "reset_credential_pool",
    "restart_health_check",
)
WEBHOOK_PORT = 9098


class ActionRejectedError(ValueError):
    """Raised when a proposed action is not in the allowlist."""


def validate_action(name: str) -> str:
    """Return name if it's in the allowlist, else raise ActionRejectedError.

    Defense-in-depth: even if the AI returns garbage, the runner will reject.
    """
    if name in ACTION_ALLOWLIST:
        return name
    raise ActionRejectedError(f"action not allowlisted: {name!r}")


def correlation_key(alert: dict, window_s: int = 300) -> str:
    """Same firing episode (startsAt time bucket) → same incident.

    Deliberately does NOT include vm_active_enter_ts. Every Hermes remediation
    is restart_microvm, which CHANGES vm_active_enter_ts; keying on it meant
    each restart minted a fresh incident, so attempts never accumulated toward
    should_escalate and the daemon could restart the VM without bound (the
    identical latent bug that produced OpenClaw's 72-restart storm 2026-07-22).
    Keying on the alert's startsAt time bucket keeps one continuous firing
    episode in one incident across our own remediations, while a genuinely new
    episode (new startsAt) still gets its own incident. Distinct alerts of one
    outage that fire in the same bucket still correlate into a single incident.
    """
    ts = alert.get("starts_at", 0)
    bucket = ts // window_s
    return str(bucket)


def new_incident(alert: dict) -> dict:
    return {
        "first_seen_ts":      int(time.time()),
        "vm_active_enter_ts": alert.get("vm_active_enter_ts", 0),
        "alerts":             [alert["alert_name"]],
        "attempts":           [],
        "status":             "in_progress",
        "next_eligible_ts":   None,
    }


def next_attempt_n(incident: dict) -> int:
    return len(incident["attempts"]) + 1


def should_escalate(incident: dict) -> bool:
    return len(incident["attempts"]) >= 3


# Circuit breaker. should_escalate (per-incident attempts >= 3) is necessary
# but NOT sufficient: every Hermes remediation is restart_microvm, and a
# restart both changes vm_active_enter_ts and (for the warmup-gated alerts)
# resolves the alert until the VM re-warms, so each firing episode is a fresh
# single-attempt incident and the per-incident counter never reaches 3. That
# is the identical latent runaway that hit OpenClaw (72 restarts / 48 stranded
# incidents / ~90 flapping pages, 2026-07-22). This breaker counts remediation
# ACTIONS ACTUALLY TAKEN across ALL incidents in a rolling window, independent
# of how incidents correlate, and refuses to act once the budget is spent —
# turning an unfixable outage into a single sustained HermesSelfHealStuck page
# instead of a restart/flap storm. It re-arms as old attempts age out.
CIRCUIT_WINDOW_S = 3600
CIRCUIT_MAX_ATTEMPTS = 3


def recent_action_count(state, now=None, window_s=CIRCUIT_WINDOW_S) -> int:
    """Count real remediation actions taken across active+history within window_s.

    Excludes attempts whose action is None/"none" — the placeholder recorded
    when LiteLLM is unreachable took no remediation, so a flapping LiteLLM
    outage cannot trip the breaker on phantom actions.
    """
    now = int(time.time()) if now is None else int(now)
    count = 0
    for inc in list(state["active"].values()) + state["history"]:
        for att in inc.get("attempts", []):
            if att.get("action") in (None, "none"):
                continue
            if now - int(att.get("ts") or 0) < window_s:
                count += 1
    return count


def load_state(path):
    p = pathlib.Path(path)
    if not p.exists():
        return {"active": {}, "history": []}
    with p.open("r") as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        try:
            return json.load(f)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def save_state(path, state):
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            json.dump(state, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)
    os.replace(tmp, p)


# Resolved incidents are retained in the active map for this long so that
# repeat alertmanager sends of the same firing episode (the correlation key
# is stable for the entire time an alert fires) are de-duped instead of
# re-triggering the action; after that they are archived to history.
# Previously resolved incidents were never removed from active and
# accumulated without bound (20 stale entries observed 2026-05-28).
RESOLVED_RETENTION_S = 3600
HISTORY_MAX = 500


def sweep_resolved(state, now=None):
    """Archive aged-out resolved incidents from active -> history.

    Keeps the active working set bounded while preserving same-episode
    de-duplication for RESOLVED_RETENTION_S after an incident resolves.
    history is capped at HISTORY_MAX (most-recent kept). The cumulative
    hermes_self_heal_attempts_total counter is unaffected: heartbeat_loop
    sums attempts across active + history, so moving an incident between
    the two does not change the total. Returns the number archived.
    """
    now = int(time.time()) if now is None else int(now)
    aged = [
        k
        for k, v in state["active"].items()
        if v.get("status") == "resolved"
        and now - int(v.get("resolved_ts") or v.get("first_seen_ts") or 0)
        >= RESOLVED_RETENTION_S
    ]
    for k in aged:
        state["history"].append(state["active"].pop(k))
    if len(state["history"]) > HISTORY_MAX:
        del state["history"][:-HISTORY_MAX]
    return len(aged)


# An incident interrupted mid-remediation is stranded forever otherwise:
# resolution only happens via the post-action re-probe in
# handle_alertmanager_payload (resolved webhooks are skipped), no future
# webhook matches its correlation key once vm_active_enter_ts changes, and
# sweep_resolved only archives resolved incidents. Mirror of the openclaw
# fix for the 2026-07-03 orphan (host reboot 14 s after a restart_microvm
# attempt killed the daemon inside its 15 s pre-verification sleep).
ORPHAN_MIN_QUIET_S = 300


def _last_activity_ts(incident) -> int:
    return max(
        [int(incident.get("first_seen_ts") or 0)]
        + [int(a.get("ts") or 0) for a in incident.get("attempts", [])]
    )


def reconcile_orphans(state, now=None, vm_ts=None, probe=None):
    """Resolve in_progress/stuck incidents the VM has provably restarted past.

    Conditions (all required):
      - the current VM boot timestamp is known (>0) and differs from the
        incident's, so its correlation key can never match a webhook again;
      - the probe is clear — the same oracle the normal post-action
        resolution path uses, so this never fabricates health;
      - no incident activity within ORPHAN_MIN_QUIET_S, so an in-flight
        remediation in the webhook thread is left alone. (A concurrent
        webhook save can still overwrite a reconciliation; both
        interleavings converge to resolved within the next tick.)

    A residual class stays open by design: an orphan whose VM never
    restarted afterwards (non-VM action interrupted, alert self-cleared)
    clears on the next VM restart instead. Returns the number resolved.
    """
    now = int(time.time()) if now is None else int(now)
    if vm_ts is None:
        vm_ts = microvm_active_enter_ts()
    if probe is None:
        probe = probe_clear
    if vm_ts <= 0:
        return 0
    n = 0
    for key, inc in state["active"].items():
        if inc.get("status") not in ("in_progress", "stuck"):
            continue
        if int(inc.get("vm_active_enter_ts") or 0) == vm_ts:
            continue
        if now - _last_activity_ts(inc) < ORPHAN_MIN_QUIET_S:
            continue
        if not probe(inc):
            continue
        inc["resolved_from_status"] = inc["status"]
        inc["status"] = "resolved"
        inc["resolved_ts"] = now
        inc["resolved_by"] = "orphan_reconcile"
        print(f"reconciled orphaned incident {key} "
              f"(was {inc['resolved_from_status']}, alerts={inc.get('alerts')}): "
              f"vm restarted past it and probe is clear", flush=True)
        n += 1
    return n


ACTION_MAP = {
    "HermesAskFailing":             "restart_microvm",
    "HermesApiServerDown":          "restart_microvm",
    "HermesDiscordZombieSuspected":   "restart_microvm",
    "HermesDiscordPostSelfHealRestart": "restart_microvm",
    "HermesMcpBridgeDown":            "restart_mcp",
    "HermesHealthCheckStale":       "restart_health_check",
}


def first_attempt_action(alert_name: str) -> str | None:
    """Return the deterministic first-attempt action for an alert name,
    or None if the alert is unknown.

    No default fallback (spec §6.2). Unknown alerts are explicitly ignored and
    counted in hermes_self_heal_unknown_alerts_total.

    This was originally a deliberate divergence from OpenClaw's daemon, which
    defaulted to restart_microvm. OpenClaw adopted the same no-fallback rule on
    2026-07-30 after that default rebooted its VM every ~26min in a closed loop,
    so the two daemons now agree; keep them that way.
    """
    return ACTION_MAP.get(alert_name)


REDACT_PATTERNS = [
    # Discord bot token: 24+ chars . 6 chars . 27+ chars
    re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
    # Anthropic
    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    # OpenAI / OpenRouter virtual keys (Hermes consumes these)
    re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-or-v1-[A-Za-z0-9_-]{20,}"),
    # Common bearer headers
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    # Generic ?token=... or password=... or api_key=...
    re.compile(r"(?i)(token|password|api[_-]?key)=[^\s&\"]+"),
]


def redact(s: str) -> str:
    for p in REDACT_PATTERNS:
        s = p.sub("[REDACTED]", s)
    return s


ACTIONS_DIR = "/etc/nixos/scripts/hermes-self-heal/actions"
STATE_PATH = "/var/lib/hermes-self-heal/incidents.json"
AUX_DIR = "/etc/nixos/scripts/hermes-self-heal/aux"
HERMES_HEALTH_PROM = "/var/lib/prometheus-node-exporter-textfiles/hermes_health.prom"


def current_metrics():
    """Read freshest values from prom textfile collector."""
    out = {}
    try:
        for line in pathlib.Path(HERMES_HEALTH_PROM).read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            k, _, v = line.rpartition(" ")
            try:
                out[k] = float(v)
            except ValueError:
                pass
    except FileNotFoundError:
        pass
    return out


def probe_clear(incident):
    m = current_metrics()
    return m.get("hermes_mcp_ask_hermes_ok", 0.0) == 1.0


def microvm_active_enter_ts(unit: str = "microvm@hermes.service") -> int:
    """Return the unix timestamp of the unit's last ActiveEnter, or 0 on error.

    Used by handle_alertmanager_payload() to stamp each incident's
    vm_active_enter_ts, and by reconcile_orphans() to tell that the VM has
    restarted past a stranded incident. correlation_key() deliberately does
    NOT key on it any more — see its docstring. The Hermes-side equivalent of
    the openclaw_microvm_active_enter_timestamp_seconds gauge that
    openclaw-canary writes for OpenClaw — Hermes has no canary, so we read
    systemd directly.
    """
    from datetime import datetime
    try:
        out = subprocess.check_output(
            ["systemctl", "show", "-p", "ActiveEnterTimestamp", "--value", unit],
            text=True, timeout=10,
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return 0
    # Format: "Mon 2026-05-20 13:42:01 PDT" — or "n/a" if never active.
    if not out or out == "n/a":
        return 0
    # systemd uses %a %Y-%m-%d %H:%M:%S %Z. The TZ name (e.g. "PDT") isn't
    # parseable by strptime portably; strip it and parse the rest as naive
    # local time, then convert to a unix timestamp. Drop the weekday too —
    # %a is locale-dependent (e.g. "Mer" under fr_FR.UTF-8) and the date
    # already uniquely identifies the day.
    parts = out.rsplit(" ", 1)  # drop the trailing TZ
    if len(parts) != 2:
        return 0
    _, _, date_part = parts[0].partition(" ")
    try:
        dt_naive = datetime.strptime(date_part, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return 0
    # Assume the timestamp is local time (matches what systemd prints).
    return int(dt_naive.timestamp())


def run_action(name: str, timeout_s: int = 240) -> dict:
    validate_action(name)
    cmd = ["sudo", "-n", f"{ACTIONS_DIR}/{name}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return {"ok": False, "notes": "action timed out", "duration_s": timeout_s}
    try:
        parsed = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
    except (json.JSONDecodeError, IndexError):
        return {"ok": False, "notes": f"non-json action output (rc={r.returncode}): {r.stderr[-200:]}"}
    parsed.setdefault("ok", r.returncode == 0)
    return parsed


LITELLM_URL = "http://127.0.0.1:4000/v1/chat/completions"
LITELLM_KEY_ENV = "LITELLM_KEY"
LITELLM_MODEL = os.environ.get(
    "LITELLM_MODEL", "hera/omlx/Qwen3.6-27B-oQ4e-mtp"
)


class LitellmUnreachable(RuntimeError):
    pass


def _http_post_json(url, headers, data, timeout):
    req = urllib.request.Request(url, data=data.encode(), headers=headers, method="POST")
    return urllib.request.urlopen(req, timeout=timeout)


def call_litellm(messages, model=None, timeout_s=30):
    model = model or LITELLM_MODEL
    key = os.environ.get(LITELLM_KEY_ENV)
    if not key:
        raise LitellmUnreachable("LITELLM_KEY not set")
    headers = {"Content-Type": "application/json",
               "Authorization": f"Bearer {key}"}
    body = json.dumps({"model": model, "messages": messages,
                       "temperature": 0.0,
                       "response_format": {"type": "json_object"}})
    try:
        resp = _http_post_json(LITELLM_URL, headers, body, timeout=timeout_s)
    except Exception as e:
        raise LitellmUnreachable(str(e))
    payload = json.loads(resp.read())
    content = payload["choices"][0]["message"]["content"]
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        raise LitellmUnreachable(f"non-json AI response: {content[:200]}")


def _read_log_tail(which: str, n: int) -> str:
    """which = "err" | "out". The aux script enforces the path allowlist;
    the daemon never sees a free-form path. sudo command is invoked by
    absolute path that EXACTLY matches the sudoers allowlist entry."""
    if which not in ("err", "out"):
        raise ValueError(f"bad log selector: {which!r}")
    try:
        return subprocess.check_output(
            ["sudo", "-n", f"{AUX_DIR}/read_log_tail", which, str(int(n))],
            text=True, timeout=10,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def _err_tail(n: int = 80) -> str:
    return _read_log_tail("err", n)


def _out_tail(n: int = 30) -> str:
    return _read_log_tail("out", n)


def _kick_health_check() -> None:
    try:
        subprocess.run(
            ["sudo", "-n", f"{AUX_DIR}/kick_health_check"],
            check=False, timeout=10,
        )
    except subprocess.TimeoutExpired:
        pass


ALERTMANAGER_URL = "http://127.0.0.1:9093/api/v2/alerts"


def emit_synthetic_alert(name, annotations, severity="info", duration_s=300):
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    payload = [{
        "labels": {"alertname": name, "severity": severity, "service": "hermes-self-heal"},
        "annotations": {k: str(v) for k, v in annotations.items()},
        "startsAt": now.isoformat(),
        "endsAt":   (now + timedelta(seconds=duration_s)).isoformat(),
    }]
    try:
        _http_post_json(ALERTMANAGER_URL, {"Content-Type": "application/json"},
                        json.dumps(payload), timeout=10)
    except Exception as e:
        print(f"emit_synthetic_alert failed: {e}", flush=True)


SYSTEM_PROMPT = """You are an SRE for Hermes Agent, a NousResearch LLM bot running as a microVM
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
  {"action": "escalate", "reason": "..."}"""


def render_prompt(incident, metrics, err_log_tail, out_log_tail):
    attempts_str = "\n".join(
        f"  {i+1}. {a.get('action','?')} ({a.get('by','?')}) -> {a.get('ok','?')}"
        for i, a in enumerate(incident["attempts"])
    ) or "  (none)"
    metrics_str = "\n".join(f"  {k}={v}" for k, v in metrics.items())
    user = (
        f"[ALERTS] {', '.join(incident['alerts'])}\n"
        f"[ATTEMPTS SO FAR]\n{attempts_str}\n"
        f"[METRICS]\n{metrics_str}\n"
        f"[errors.log tail]\n{redact(err_log_tail)}\n"
        f"[gateway.log tail]\n{redact(out_log_tail)}\n"
    )
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user",   "content": user},
    ]


def handle_alertmanager_payload(payload):
    from datetime import datetime
    state = load_state(STATE_PATH)
    if sweep_resolved(state):
        save_state(STATE_PATH, state)
    metrics = current_metrics()
    vm_ts = microvm_active_enter_ts()  # NOT from metrics — Hermes has no canary producer
    for a in payload.get("alerts", []):
        if a.get("status") != "firing":
            continue
        alert_name = a["labels"]["alertname"]

        # Explicit ignore on unknown alerts — no default remediation exists.
        if alert_name not in ACTION_MAP:
            _bump_unknown_counter()
            print(f"ignoring unknown alert: {alert_name}", flush=True)
            continue

        alert_meta = {
            "alert_name":         alert_name,
            "vm_active_enter_ts": vm_ts,
            "starts_at":          int(datetime.fromisoformat(a["startsAt"].replace("Z", "+00:00")).timestamp()),
        }
        key = correlation_key(alert_meta)
        inc = state["active"].get(key) or new_incident(alert_meta)
        state["active"][key] = inc
        if inc["status"] != "in_progress":
            continue
        # Circuit breaker: refuse to act once the rolling-window remediation
        # budget is spent, regardless of how incidents correlate. This is the
        # bound the per-incident attempt counter cannot provide when the
        # remediation resolves the alert before the next attempt arrives
        # (see recent_action_count).
        if recent_action_count(state) >= CIRCUIT_MAX_ATTEMPTS:
            inc["status"] = "stuck"
            inc["stuck_ts"] = int(time.time())
            inc["stuck_reason"] = "circuit_breaker"
            save_state(STATE_PATH, state)
            emit_synthetic_alert(
                "HermesSelfHealStuck",
                {"alert": alert_meta["alert_name"],
                 "attempts": recent_action_count(state),
                 "reason": "circuit breaker: too many recent remediations, backing off"},
                severity="critical", duration_s=14400)
            continue
        n = next_attempt_n(inc)
        ai_reason = None
        if n == 1:
            action = ACTION_MAP[alert_name]  # membership validated above; satisfies type checker
            by = "deterministic"
        elif n in (2, 3):
            try:
                ai_resp = call_litellm(render_prompt(inc, metrics, _err_tail(), _out_tail()))
            except LitellmUnreachable as e:
                inc["attempts"].append({"action": "none", "by": "ai", "ok": False,
                                        "notes": "litellm_unreachable", "stderr": str(e)})
                emit_synthetic_alert(
                    "HermesSelfHealLitellmUnreachable",
                    {"alert": alert_meta["alert_name"], "err": str(e)[:200]},
                    severity="warning", duration_s=3600,
                )
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                continue
            if ai_resp.get("action") == "escalate":
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                emit_synthetic_alert("HermesSelfHealStuck",
                    {"alert": alert_meta["alert_name"], "attempts": len(inc["attempts"])},
                    severity="critical", duration_s=14400)
                continue
            try:
                action = validate_action(ai_resp["action"])
            except (ActionRejectedError, KeyError):
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                emit_synthetic_alert("HermesSelfHealStuck",
                    {"alert": alert_meta["alert_name"], "attempts": len(inc["attempts"])},
                    severity="critical", duration_s=14400)
                continue
            by = "ai"
            ai_reason = ai_resp.get("reason")
        else:
            inc["status"] = "stuck"
            save_state(STATE_PATH, state)
            emit_synthetic_alert("HermesSelfHealStuck",
                {"alert": alert_meta["alert_name"], "attempts": len(inc["attempts"])},
                severity="critical", duration_s=14400)
            continue
        result = run_action(action)
        inc["attempts"].append({"ts": int(time.time()), "action": action, "by": by,
                                "ai_reason": ai_reason, **result})
        save_state(STATE_PATH, state)
        emit_synthetic_alert("HermesSelfHealActed",
            {"action": action, "alert": alert_meta["alert_name"], "by": by,
             "ok": result.get("ok")})
        _kick_health_check()
        time.sleep(15)
        if probe_clear(inc):
            inc["status"] = "resolved"
            inc["resolved_ts"] = int(time.time())
        save_state(STATE_PATH, state)


_UNKNOWN_ALERTS_TOTAL = 0


def _bump_unknown_counter():
    global _UNKNOWN_ALERTS_TOTAL
    _UNKNOWN_ALERTS_TOTAL += 1


TEXTFILE_DIR = "/var/lib/prometheus-node-exporter-textfiles"
HEARTBEAT_PATH = pathlib.Path(TEXTFILE_DIR) / "hermes_self_heal.prom"


def write_heartbeat(out_path=HEARTBEAT_PATH, active_count=0, action_counts=None,
                    litellm_unreachable=0, unknown_alerts=0):
    action_counts = action_counts or {}
    tmp = pathlib.Path(str(out_path) + ".tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    with tmp.open("w") as f:
        f.write(
            "# HELP hermes_self_heal_last_heartbeat_seconds Last heartbeat from hermes-self-heal daemon\n"
            "# TYPE hermes_self_heal_last_heartbeat_seconds gauge\n"
            f"hermes_self_heal_last_heartbeat_seconds {time.time()}\n"
            "# HELP hermes_self_heal_active_incidents Currently in_progress incidents\n"
            "# TYPE hermes_self_heal_active_incidents gauge\n"
            f"hermes_self_heal_active_incidents {active_count}\n"
            "# HELP hermes_self_heal_attempts_total Cumulative attempts by action\n"
            "# TYPE hermes_self_heal_attempts_total counter\n"
        )
        for a in ACTION_ALLOWLIST:
            f.write(f'hermes_self_heal_attempts_total{{action="{a}"}} {action_counts.get(a, 0)}\n')
        f.write(
            "# HELP hermes_self_heal_litellm_unreachable_total Cumulative LiteLLM unreachable events\n"
            "# TYPE hermes_self_heal_litellm_unreachable_total counter\n"
            f"hermes_self_heal_litellm_unreachable_total {litellm_unreachable}\n"
            "# HELP hermes_self_heal_unknown_alerts_total Cumulative unknown-alert ignore events\n"
            "# TYPE hermes_self_heal_unknown_alerts_total counter\n"
            f"hermes_self_heal_unknown_alerts_total {unknown_alerts}\n"
        )
    os.replace(tmp, out_path)


import threading


def heartbeat_tick():
    state = load_state(STATE_PATH)
    # State maintenance must run here, not only in handle_alertmanager_payload:
    # with no incoming hermes alerts nothing else ever reconciles orphans or
    # archives aged resolved incidents.
    if reconcile_orphans(state) + sweep_resolved(state):
        save_state(STATE_PATH, state)
    active = sum(1 for v in state["active"].values() if v["status"] == "in_progress")
    counts = {a: 0 for a in ACTION_ALLOWLIST}
    litellm_unreachable = 0
    for inc in list(state["active"].values()) + state["history"]:
        for att in inc.get("attempts", []):
            if att.get("action") in counts:
                counts[att["action"]] += 1
            if att.get("notes") == "litellm_unreachable":
                litellm_unreachable += 1
    write_heartbeat(active_count=active, action_counts=counts,
                    litellm_unreachable=litellm_unreachable,
                    unknown_alerts=_UNKNOWN_ALERTS_TOTAL)


def heartbeat_loop():
    while True:
        try:
            heartbeat_tick()
        except Exception as e:
            print(f"heartbeat error: {e}", flush=True)
        time.sleep(60)


from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/alert":
            self.send_response(404)
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        try:
            payload = json.loads(body)
            handle_alertmanager_payload(payload)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}\n')
        except Exception as e:
            print(f"do_POST error: {e!r}", flush=True)
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"ok":false,"err":"internal error"}\n')

    def log_message(self, *a, **kw):
        pass  # silence default access logs


def main():
    threading.Thread(target=heartbeat_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", WEBHOOK_PORT), Handler)
    print(f"hermes-self-heal listening on 127.0.0.1:{WEBHOOK_PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
