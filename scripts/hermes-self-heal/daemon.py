#!/usr/bin/env python3
"""hermes-self-heal — Alertmanager webhook receiver and remediation runner.

See docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md.
Ported from scripts/openclaw-self-heal/daemon.py with Hermes-specific
action set, alert mapping, metric prefix, and the explicit-ignore behavior
on unknown alerts (NO default fallback — diverges from OpenClaw).
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
    """Same VM boot + 5-min bucket → same incident."""
    ts = alert.get("starts_at", 0)
    bucket = ts // window_s
    return f"{alert.get('vm_active_enter_ts', 0)}:{bucket}"


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


ACTION_MAP = {
    "HermesAskFailing":             "restart_microvm",
    "HermesApiServerDown":          "restart_microvm",
    "HermesDiscordZombieSuspected": "restart_microvm",
    "HermesMcpBridgeDown":          "restart_mcp",
    "HermesHealthCheckStale":       "restart_health_check",
}


def first_attempt_action(alert_name: str) -> str | None:
    """Return the deterministic first-attempt action for an alert name,
    or None if the alert is unknown.

    DIVERGES FROM OpenClaw: no default fallback. Spec §6.2 decision.
    Unknown alerts are explicitly ignored (counted in
    hermes_self_heal_unknown_alerts_total).
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


class LitellmUnreachable(RuntimeError):
    pass


def _http_post_json(url, headers, data, timeout):
    req = urllib.request.Request(url, data=data.encode(), headers=headers, method="POST")
    return urllib.request.urlopen(req, timeout=timeout)


def call_litellm(messages, model="hera/Qwen3.6-27B", timeout_s=30):
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
