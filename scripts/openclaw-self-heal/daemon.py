#!/usr/bin/env python3
"""openclaw-self-heal — Alertmanager webhook receiver and remediation runner.

See docs/superpowers/specs/2026-05-05-openclaw-self-heal-design.md.
"""
__version__ = "0.1.0"

import time
import json
import fcntl
import os
import pathlib
import subprocess
import re
import urllib.request

ACTION_ALLOWLIST = ("restart_microvm", "doctor_fix", "prune_stale_plugin_deps")
WEBHOOK_PORT = 9092


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


ACTION_MAP = {
    "OpenClawDiscordWsDown":             "restart_microvm",
    "OpenClawHttpHealthDown":            "restart_microvm",
    "OpenClawGatewayReadyStale":         "restart_microvm",
    "OpenClawDiscordPluginMissing":      "doctor_fix",
    "OpenClawPluginInitFailuresPresent": "doctor_fix",
    "OpenClawMicroVMDown":               "wait_60s",
}


def first_attempt_action(alert_name: str) -> str:
    return ACTION_MAP.get(alert_name, "restart_microvm")


ACTIONS_DIR = "/etc/nixos/scripts/openclaw-self-heal/actions"


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


REDACT_PATTERNS = [
    # Discord bot token: 24-30+ chars . 6 chars . 27+ chars
    re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
    # Anthropic
    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    # OpenAI
    re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
    # Common bearer headers
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    # Generic ?token=... or password=...
    re.compile(r"(?i)(token|password|api[_-]?key)=[^\s&\"]+"),
]


def redact(s: str) -> str:
    for p in REDACT_PATTERNS:
        s = p.sub("[REDACTED]", s)
    return s


SYSTEM_PROMPT = """You are an SRE for OpenClaw, a Discord-facing AI gateway running as a microVM
on host vulcan. Your goal is to restore service. You may take exactly ONE of:
  1. restart_microvm
  2. doctor_fix
  3. prune_stale_plugin_deps
Output STRICTLY this JSON, no other text:
  {"action": "<one of the three>", "reason": "<one sentence>"}
If you do not believe any of these will help, output:
  {"action": "escalate", "reason": "..."}"""


def render_prompt(incident, metrics, err_log_tail, out_log_tail):
    attempts_str = "\n".join(
        f"  {i+1}. {a.get('action','?')} ({a.get('by','?')}) -> {a.get('result','?')}"
        for i, a in enumerate(incident["attempts"])
    ) or "  (none)"
    metrics_str = "\n".join(f"  {k}={v}" for k, v in metrics.items())
    user = (
        f"[ALERTS] {', '.join(incident['alerts'])}\n"
        f"[ATTEMPTS SO FAR]\n{attempts_str}\n"
        f"[METRICS]\n{metrics_str}\n"
        f"[err.log tail]\n{redact(err_log_tail)}\n"
        f"[gateway.log tail]\n{redact(out_log_tail)}\n"
    )
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user",   "content": user},
    ]


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


STATE_PATH = "/var/lib/openclaw-self-heal/incidents.json"
AUX_DIR = "/etc/nixos/scripts/openclaw-self-heal/aux"


def current_metrics():
    """Read freshest values from prom textfile collector."""
    out = {}
    path = "/var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom"
    try:
        for line in pathlib.Path(path).read_text().splitlines():
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
    return m.get("openclaw_discord_ws_connected", 0.0) == 1.0


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


def _kick_canary() -> None:
    try:
        subprocess.run(
            ["sudo", "-n", f"{AUX_DIR}/kick_canary"],
            check=False, timeout=10,
        )
    except subprocess.TimeoutExpired:
        pass


def emit_synthetic_alert(name, annotations, severity="info", duration_s=300):
    """Stub overridden in B10; defined here so handle_alertmanager_payload can call it."""
    return None


def handle_alertmanager_payload(payload):
    from datetime import datetime
    state = load_state(STATE_PATH)
    metrics = current_metrics()
    vm_ts = int(metrics.get("openclaw_microvm_active_enter_timestamp_seconds", 0))
    for a in payload.get("alerts", []):
        if a.get("status") != "firing":
            continue
        alert_meta = {
            "alert_name":         a["labels"]["alertname"],
            "vm_active_enter_ts": vm_ts,
            "starts_at":          int(datetime.fromisoformat(a["startsAt"].replace("Z", "+00:00")).timestamp()),
        }
        key = correlation_key(alert_meta)
        inc = state["active"].get(key) or new_incident(alert_meta)
        state["active"][key] = inc
        if inc["status"] != "in_progress":
            continue
        n = next_attempt_n(inc)
        ai_reason = None
        if n == 1:
            action = first_attempt_action(alert_meta["alert_name"])
            by = "deterministic"
        elif n in (2, 3):
            try:
                ai_resp = call_litellm(render_prompt(inc, metrics, _err_tail(), _out_tail()))
            except LitellmUnreachable as e:
                inc["attempts"].append({"action": "none", "by": "ai", "result": "litellm_unreachable", "stderr": str(e)})
                emit_synthetic_alert(
                    "OpenClawSelfHealLitellmUnreachable",
                    {"alert": alert_meta["alert_name"], "err": str(e)[:200]},
                    severity="warning", duration_s=3600,
                )
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                continue
            if ai_resp.get("action") == "escalate":
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                continue
            try:
                action = validate_action(ai_resp["action"])
            except (ActionRejectedError, KeyError):
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                continue
            by = "ai"
            ai_reason = ai_resp.get("reason")
        else:
            inc["status"] = "stuck"
            save_state(STATE_PATH, state)
            continue
        if action == "wait_60s":
            time.sleep(60)
            result = {"ok": True, "notes": "waited"}
        else:
            result = run_action(action)
        inc["attempts"].append({"ts": int(time.time()), "action": action, "by": by,
                                "ai_reason": ai_reason, **result})
        save_state(STATE_PATH, state)
        # force fresh metrics via the aux/kick_canary helper
        _kick_canary()
        # short wait, then re-probe
        time.sleep(15)
        if probe_clear(inc):
            inc["status"] = "resolved"
        save_state(STATE_PATH, state)


TEXTFILE_DIR = "/var/lib/prometheus-node-exporter-textfiles"
HEARTBEAT_PATH = pathlib.Path(TEXTFILE_DIR) / "openclaw_self_heal.prom"


def write_heartbeat(out_path=HEARTBEAT_PATH, active_count=0, action_counts=None,
                    litellm_unreachable=0):
    action_counts = action_counts or {}
    tmp = pathlib.Path(str(out_path) + ".tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    with tmp.open("w") as f:
        f.write(
            "# HELP openclaw_self_heal_last_heartbeat_seconds Last heartbeat from openclaw-self-heal daemon\n"
            "# TYPE openclaw_self_heal_last_heartbeat_seconds gauge\n"
            f"openclaw_self_heal_last_heartbeat_seconds {time.time()}\n"
            "# HELP openclaw_self_heal_active_incidents Currently in_progress incidents\n"
            "# TYPE openclaw_self_heal_active_incidents gauge\n"
            f"openclaw_self_heal_active_incidents {active_count}\n"
            "# HELP openclaw_self_heal_attempts_total Cumulative attempts by action\n"
            "# TYPE openclaw_self_heal_attempts_total counter\n"
        )
        for a in ACTION_ALLOWLIST:
            f.write(f'openclaw_self_heal_attempts_total{{action="{a}"}} {action_counts.get(a, 0)}\n')
        f.write(
            "# HELP openclaw_self_heal_litellm_unreachable_total Cumulative LiteLLM unreachable events\n"
            "# TYPE openclaw_self_heal_litellm_unreachable_total counter\n"
            f"openclaw_self_heal_litellm_unreachable_total {litellm_unreachable}\n"
        )
    os.replace(tmp, out_path)


import threading


def heartbeat_loop():
    while True:
        try:
            state = load_state(STATE_PATH)
            active = sum(1 for v in state["active"].values() if v["status"] == "in_progress")
            counts = {a: 0 for a in ACTION_ALLOWLIST}
            for inc in list(state["active"].values()) + state["history"]:
                for att in inc.get("attempts", []):
                    if att.get("action") in counts:
                        counts[att["action"]] += 1
            write_heartbeat(active_count=active, action_counts=counts)
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
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f'{{"ok":false,"err":{json.dumps(str(e))}}}\n'.encode())

    def log_message(self, *a, **kw):
        pass  # silence default access logs


def main():
    threading.Thread(target=heartbeat_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", WEBHOOK_PORT), Handler)
    print(f"openclaw-self-heal listening on 127.0.0.1:{WEBHOOK_PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()


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
