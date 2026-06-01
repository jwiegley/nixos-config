#!/usr/bin/env python3
"""Unified nightly agent health report → email to johnw@vulcan.lan.

ONE engine, two agents. Invoked `agent-health-report --agent {openclaw|hermes}`.
Both the OpenClaw (06:00) and Hermes (06:15) nightly emails render the same
fixed 11-section layout from a per-agent profile, so the two reports show the
*union* of all section types and can never drift apart again.

See docs/superpowers/specs/2026-06-01-unified-agent-health-report-design.md.

Sections (fixed order, identical for both agents):
  0. Header + headline verdict (PASS/FAIL + issues)
  1. Live metrics            — dump the agent's Prometheus textfile gauges
  2. MCP servers             — OpenClaw: struct+live tool counts (mcporter,
                               host+in-VM SSH); Hermes: configured inventory
                               from nix + aggregate MCP-liveness from metrics
  3. Gateway + plugins       — OpenClaw: canary metrics; Hermes: n/a (no gateway)
  4. microVM + sidecars      — systemctl show over the profile's units
  5. 24h probe summary       — Prometheus success ratio + p50/p95 per family
  6. Discord activity        — OpenClaw: ws metrics; Hermes: gateway-log events
  7. Home Assistant MCP      — OpenClaw: dedicated probe gauges; Hermes: n/a
  8. Errors digest           — redacted + benign-filtered, both agents
  9. Self-heal incidents     — incidents.json + *_self_heal_* metrics
 10. In-VM corroboration     — one SSH round-trip (trader curl + requests-TLS,
                               plus api/gateway reachability)

Environment overrides (read under the profile's <PREFIX>, e.g. OPENCLAW_REPORT):
  <PREFIX>_TO              recipient (default: johnw@vulcan.lan)
  <PREFIX>_FROM            sender    (default: <agent>-health@vulcan.lan)
  <PREFIX>_SENDMAIL        sendmail path (default: /run/wrappers/bin/sendmail)
  <PREFIX>_DRY_RUN         if non-empty, print to stdout instead of mailing
  <PREFIX>_PROMETHEUS_URL  default http://127.0.0.1:9090
  <PREFIX>_SSH_KEY         path to ssh key for the in-VM probe
  <PREFIX>_SSH_TARGET      e.g. openclaw@10.99.0.2 / hermes@10.99.1.2
  <PREFIX>_MCPORTER        mcporter binary (OpenClaw only)
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import math
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Optional

TF = "/var/lib/prometheus-node-exporter-textfiles"
# Module-level so prometheus_query keeps a single-arg signature (tests rely on
# this); collect() overrides it from <PREFIX>_PROMETHEUS_URL before querying.
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://127.0.0.1:9090")
VULCAN_CA = pathlib.Path("/etc/nixos/certs/vulcan-root-ca.crt")
SYSTEM_CA = pathlib.Path("/etc/ssl/certs/ca-certificates.crt")
SECTION_RULE = "-" * 76


# ---------------------------------------------------------------------------
# Redaction (shared by both error grammars — same secret shapes as self-heal)
# ---------------------------------------------------------------------------

REDACT_PATTERNS = [
    re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-or-v1-[A-Za-z0-9_-]{20,}"),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    # key=value secret shapes (superset of the documented leak forms).
    re.compile(
        r"(?i)(token|password|passwd|passphrase|api[_-]?key|secret|client_secret|"
        r"psk|refresh_token|access_token)=[^\s&\"]+"
    ),
    # E.164 phone number (PII — the 2026-05-18 SOPS leak shape).
    re.compile(r"(?<!\d)\+\d{10,15}(?!\d)"),
    # Pairing / registration / verification codes (the 2026-05-21 HomeKit shape).
    re.compile(r"(?i)\b(?:pairing|registration|verification)\s+code[:\s]+\S+"),
]


def redact(s: str) -> str:
    for p in REDACT_PATTERNS:
        s = p.sub("[REDACTED]", s)
    return s


def _safe_read_lines(path) -> list[str]:
    """Read a file's lines, never raising (the report must never abort).

    `errors="replace"` tolerates a non-UTF-8 byte in a rotated log; the
    try/except covers a read-time race or permission flip the is_file()
    check upstream cannot.
    """
    try:
        return pathlib.Path(path).read_text(errors="replace").splitlines()
    except OSError:
        return []


def _label(key: str, label: str) -> Optional[str]:
    """Extract a label value from a `metric{...,label="value",...}` key.

    Robust to label order and extra labels, and never raises — used so a
    non-canonical series can't crash a section renderer (H1/M2).
    """
    m = re.search(label + r'="([^"]+)"', key)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# Prometheus textfile parsing (handles `name{label="v"}` keys)
# ---------------------------------------------------------------------------

def parse_prom_textfile(path) -> dict[str, float]:
    """Return gauges from a node-exporter textfile, keeping label suffixes."""
    out: dict[str, float] = {}
    for line in _safe_read_lines(path):
        if line.startswith("#") or not line.strip():
            continue
        k, _, v = line.rpartition(" ")
        try:
            fv = float(v)
        except ValueError:
            continue
        # Reject NaN/Inf so they never reach the email's arithmetic/formatting.
        if math.isfinite(fv):
            out[k.strip()] = fv
    return out


def parse_prom_textfiles(paths) -> dict[str, float]:
    """Merge several textfiles into one gauge dict (later files win on clash)."""
    merged: dict[str, float] = {}
    for path in paths:
        merged.update(parse_prom_textfile(path))
    return merged


# ---------------------------------------------------------------------------
# Prometheus HTTP API
# ---------------------------------------------------------------------------

def prometheus_query(promql: str, base_url: Optional[str] = None) -> Optional[float]:
    """Query /api/v1/query and return the scalar value, or None on error."""
    base = base_url or PROMETHEUS_URL
    url = f"{base}/api/v1/query?query={urllib.parse.quote(promql)}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
    except (OSError, json.JSONDecodeError, urllib.error.URLError):
        return None
    if data.get("status") != "success":
        return None
    result = data.get("data", {}).get("result", [])
    if not result:
        return None
    try:
        return float(result[0]["value"][1])
    except (KeyError, IndexError, ValueError):
        return None


def probe_summary_24h(ok_metric: str, dur_metric: str) -> dict:
    """24h success ratio + p50/p95 latency for one probe family."""
    success = prometheus_query(f"avg_over_time({ok_metric}[24h])")
    p50 = prometheus_query(f"quantile_over_time(0.5, {dur_metric}[24h])")
    p95 = prometheus_query(f"quantile_over_time(0.95, {dur_metric}[24h])")
    return {
        "success_ratio": success,
        "p50_seconds": p50,
        "p95_seconds": p95,
        "available": all(v is not None for v in (success, p50, p95)),
    }


# ---------------------------------------------------------------------------
# systemd unit uptime
# ---------------------------------------------------------------------------

def systemd_uptime(unit: str) -> dict[str, Any]:
    """Return {active, since, n_restarts} via `systemctl show`."""
    try:
        out = subprocess.check_output(
            ["systemctl", "show", "-p",
             "ActiveState,ActiveEnterTimestamp,NRestarts", unit],
            text=True, timeout=10,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return {"active": "unknown", "since": None, "n_restarts": None}
    fields = dict(
        line.split("=", 1) for line in out.strip().splitlines() if "=" in line
    )
    enter_ts = fields.get("ActiveEnterTimestamp", "").strip()
    try:
        nrestarts = int(fields.get("NRestarts", "0").strip())
    except ValueError:
        nrestarts = 0
    return {
        "active": fields.get("ActiveState", "unknown").strip(),
        "since": enter_ts or None,
        "n_restarts": nrestarts,
    }


# ---------------------------------------------------------------------------
# Self-heal incidents (identical {active: dict, history: list} schema for both)
# ---------------------------------------------------------------------------

def parse_incidents(path, now=None) -> dict:
    """Summarize self-heal incidents.json."""
    p = pathlib.Path(path)
    if not p.is_file():
        return {"active": 0, "resolved_24h": 0, "stuck_alerts": []}
    try:
        data = json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return {"active": 0, "resolved_24h": 0, "stuck_alerts": []}

    now = now or dt.datetime.now()
    cutoff_ts = int((now - dt.timedelta(hours=24)).timestamp())

    active = sum(
        1 for v in data.get("active", {}).values()
        if v.get("status") == "in_progress"
    )
    stuck_alerts = [
        v["alerts"][0]
        for v in data.get("active", {}).values()
        if v.get("status") == "stuck" and v.get("alerts")
    ]
    resolved_24h = sum(
        1 for v in data.get("history", [])
        if v.get("status") == "resolved"
        and v.get("first_seen_ts", 0) >= cutoff_ts
    )
    return {"active": active, "resolved_24h": resolved_24h, "stuck_alerts": stuck_alerts}


# ---------------------------------------------------------------------------
# Errors digest — one parser, two grammars, always redacted + benign-filtered
# ---------------------------------------------------------------------------

# OpenClaw: freeform line beginning with an RFC3339 timestamp.
_OC_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T[\d:.+-]+)")
# Hermes: "<iso> ERROR|WARN <msg>".
_HERMES_TS_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\s+(?:ERROR|WARN)\s+(?P<msg>.*)$"
)

# Known-benign stderr noise systemd captures into err.log. Filtering these out
# of the headline error count lets a real regression stand out.
_BENIGN_WARNING_PATTERNS = [
    re.compile(r"must declare contracts\.tools before registering"),
    re.compile(r"Gateway is binding to a non-loopback address"),
    re.compile(r"controlUi\.dangerouslyAllowHostHeaderOriginFallback"),
    re.compile(r"security warning: dangerous config flags enabled"),
    re.compile(r"Api key is used with unsecure connection"),
    re.compile(r"\[diagnostic\] long-running session\b"),
    re.compile(r"\[diagnostic\] stalled session\b"),
    re.compile(r"\[diagnostic\] liveness warning\b"),
    re.compile(r"\[whatsapp\] watchdog timeout\b"),
    re.compile(r"\[whatsapp\] Web connection closed\b"),
]

_BENIGN_BY_GRAMMAR = {
    "openclaw": _BENIGN_WARNING_PATTERNS,
    "hermes": [],  # Hermes errors.log is already curated; profile-overridable.
}


def _is_benign(line: str, grammar: str) -> bool:
    return any(p.search(line) for p in _BENIGN_BY_GRAMMAR.get(grammar, []))


def parse_errors_log(path, grammar: str = "openclaw",
                     window_hours: int = 24, now=None) -> dict:
    """Count + bucket error-log lines in the window, redacting every line.

    Returns a superset dict usable by the renderer for either grammar:
      {available, total, errors_total, warnings_total,
       patterns:[{pattern,count}], warnings:[{pattern,count}], window_hours}
    `patterns` are the real (non-benign) error buckets; `warnings` are the
    benign ones (openclaw only). `total` counts in-window lines (errors+warnings).
    """
    p = pathlib.Path(path)
    if not p.is_file():
        # Minimal contract for a missing log (renderer uses .get() defaults;
        # absent "available" key → renders "err log not found").
        return {"total": 0, "patterns": []}
    out = {
        "available": True, "total": 0, "errors_total": 0, "warnings_total": 0,
        "patterns": [], "warnings": [], "window_hours": window_hours,
    }

    if grammar == "hermes":
        now = now or dt.datetime.now()
        cutoff = now - dt.timedelta(hours=window_hours)
        errors: collections.Counter = collections.Counter()
        total = 0
        for line in _safe_read_lines(p):
            m = _HERMES_TS_RE.match(line)
            if not m:
                continue
            try:
                ts = dt.datetime.fromisoformat(m.group("ts"))
            except ValueError:
                continue
            if ts < cutoff:
                continue
            total += 1
            errors[redact(m.group("msg").strip())] += 1
        out["total"] = total
        out["errors_total"] = total
        out["patterns"] = [{"pattern": k, "count": c} for k, c in errors.most_common(10)]
        return out

    # openclaw grammar — normalize everything to UTC-aware so a `Z`-suffixed
    # line (regex stops before `Z` → naive) or a naive caller `now` can't trip
    # the "can't compare offset-naive and offset-aware" TypeError.
    now = now or dt.datetime.now(dt.timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    cutoff = now - dt.timedelta(hours=window_hours)
    err_counts: collections.Counter = collections.Counter()
    warn_counts: collections.Counter = collections.Counter()
    for line in _safe_read_lines(p):
        if not line.strip():
            continue
        m = _OC_TS_RE.match(line)
        if not m:
            continue  # skip undated noise rather than count forever-old lines
        try:
            ts = dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
        except ValueError:
            continue
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=dt.timezone.utc)
        if ts < cutoff:
            continue
        out["total"] += 1
        body = line[m.end():].strip()
        body = re.sub(r"\s*\(status=[^)]*\)\s*$", "", body)
        body = re.sub(r"\d+(?:\.\d+)?ms\b", "Nms", body)
        body = re.sub(r"\b\d{2,}\b", "N", body)
        pattern = redact(body[:120])
        if _is_benign(line, grammar):
            warn_counts[pattern] += 1
            out["warnings_total"] += 1
        else:
            err_counts[pattern] += 1
            out["errors_total"] += 1
    out["patterns"] = [{"pattern": k, "count": c} for k, c in err_counts.most_common(5)]
    out["warnings"] = [{"pattern": k, "count": c} for k, c in warn_counts.most_common(3)]
    return out


# ---------------------------------------------------------------------------
# Discord gateway-log parsing (Hermes "log" mode)
# ---------------------------------------------------------------------------

GATEWAY_TS_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}).*?"
    r"\[?gateway\.platforms\.discord(?:\]|:)\s*(?P<rest>.*)$"
)
EVENT_KEYWORDS = {
    "disconnected": re.compile(r"\[Discord\]\s+(?:Safely\s+)?[Dd]isconnect(?:ed)?\b"),
    "connected":    re.compile(r"\[Discord\]\s+Connected\b"),
    "registered":   re.compile(r"\[Discord\]\s+Registered\b"),
    "flushing":     re.compile(r"\[Discord\]\s+Flushing\b"),
    "skipping":     re.compile(r"\[Discord\]\s+Skipping\b"),
}


def _iter_gateway_events(path, now, window_hours=24):
    p = pathlib.Path(path)
    if not p.is_file():
        return
    cutoff = now - dt.timedelta(hours=window_hours)
    for line in _safe_read_lines(p):
        m = GATEWAY_TS_RE.match(line)
        if not m:
            continue
        try:
            ts = dt.datetime.fromisoformat(m.group("ts"))
        except ValueError:
            continue
        if ts < cutoff:
            continue
        rest = m.group("rest")
        for event_type, regex in EVENT_KEYWORDS.items():
            if regex.search(rest):
                yield ts, event_type
                break


def parse_gateway_log(path, window_hours: int = 24, now=None) -> dict[str, int]:
    now = now or dt.datetime.now()
    counts = {t: 0 for t in EVENT_KEYWORDS}
    for _ts, etype in _iter_gateway_events(path, now, window_hours):
        counts[etype] += 1
    return counts


def most_recent_per_type(path, now=None) -> dict[str, dt.datetime]:
    now = now or dt.datetime.now()
    out: dict[str, dt.datetime] = {}
    for ts, etype in _iter_gateway_events(path, now):
        if etype not in out or ts > out[etype]:
            out[etype] = ts
    return out


# ---------------------------------------------------------------------------
# mcporter (OpenClaw only) — structural + live tool counts
# ---------------------------------------------------------------------------

_MCPORTER_LIST_RE = re.compile(
    r"^- (?P<name>\S+) — (?P<desc>.*?) \((?P<status>[^)]+)\)$"
)


def _parse_mcporter_output(stdout: str) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for line in stdout.splitlines():
        m = _MCPORTER_LIST_RE.match(line)
        if not m:
            continue
        name = m.group("name")
        status = m.group("status")
        tool_count: Optional[int] = None
        tm = re.match(r"(\d+)\s+tools?", status)
        if tm:
            tool_count = int(tm.group(1))
        out[name] = {"status": status, "tool_count": tool_count, "raw": line}
    return out


def _build_ca_bundle() -> Optional[str]:
    if not SYSTEM_CA.is_file():
        return None
    fd, path = tempfile.mkstemp(prefix="agent-report-ca-", suffix=".crt")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(SYSTEM_CA.read_bytes())
            if VULCAN_CA.is_file():
                f.write(b"\n")
                f.write(VULCAN_CA.read_bytes())
    except OSError:
        try:
            os.unlink(path)
        except OSError:
            pass
        return None
    return path


def _find_mcporter(env_prefix: str) -> Optional[str]:
    explicit = os.getenv(f"{env_prefix}_MCPORTER")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit
    found = shutil.which("mcporter")
    if found:
        return found
    candidates: list[tuple[tuple[int, ...], str]] = []
    try:
        for p in pathlib.Path("/nix/store").glob("*mcporter-*/bin/mcporter"):
            m = re.search(r"mcporter-(\d+(?:\.\d+){0,3})", p.parent.parent.name)
            if not m:
                continue
            ver = tuple(int(x) for x in m.group(1).split("."))
            candidates.append((ver, str(p)))
    except OSError:
        pass
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]


def run_mcporter_list(env_prefix: str = "OPENCLAW_REPORT",
                      home: str = "/var/lib/openclaw") -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    binary = _find_mcporter(env_prefix)
    if not binary:
        sys.stderr.write("run_mcporter_list: could not locate mcporter\n")
        return out
    mcporter_json = pathlib.Path(home) / ".openclaw/.mcporter/mcporter.json"
    if not mcporter_json.is_file():
        sys.stderr.write(f"run_mcporter_list: mcporter.json missing at {mcporter_json}\n")
        return out

    ca_bundle = _build_ca_bundle()
    env = os.environ.copy()
    env["HOME"] = home
    if ca_bundle:
        env["REQUESTS_CA_BUNDLE"] = ca_bundle
        env["NODE_EXTRA_CA_CERTS"] = ca_bundle
    env.setdefault("MCPORTER_LIST_TIMEOUT", "30000")
    try:
        proc = subprocess.run(
            [binary, "list"], cwd=home, env=env,
            capture_output=True, text=True, timeout=180,
        )
    except (subprocess.TimeoutExpired, OSError, ValueError) as exc:
        sys.stderr.write(f"run_mcporter_list: {type(exc).__name__}: {exc}\n")
        return out
    finally:
        if ca_bundle:
            try:
                os.unlink(ca_bundle)
            except OSError:
                pass
    if proc.returncode != 0:
        sys.stderr.write(
            f"run_mcporter_list: exited {proc.returncode}: {proc.stderr[:300]}\n"
        )
    out = _parse_mcporter_output(proc.stdout)
    if not out:
        sys.stderr.write(
            f"run_mcporter_list: parsed 0 servers. head: {proc.stdout[:400]!r}\n"
        )
    return out


def run_mcporter_list_via_ssh(key: Optional[str] = None,
                              target: Optional[str] = None,
                              env_prefix: str = "OPENCLAW_REPORT"
                              ) -> dict[str, dict[str, Any]]:
    key = key or os.getenv(f"{env_prefix}_SSH_KEY")
    target = target or os.getenv(f"{env_prefix}_SSH_TARGET")
    if not key or not target:
        sys.stderr.write("run_mcporter_list_via_ssh: SSH env not configured\n")
        return {}
    ssh_cmd = [
        "ssh", "-i", key,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "LogLevel=ERROR",
        "-o", "IdentitiesOnly=yes",
        target, "mcporter list",
    ]
    try:
        proc = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError) as exc:
        sys.stderr.write(f"run_mcporter_list_via_ssh: {type(exc).__name__}\n")
        return {}
    if proc.returncode != 0:
        sys.stderr.write(
            f"run_mcporter_list_via_ssh: exited {proc.returncode}: {proc.stderr[:300]}\n"
        )
        return {}
    return _parse_mcporter_output(proc.stdout)


# ---------------------------------------------------------------------------
# Generic in-VM SSH probe (section 10) — one round-trip, results-only output
# ---------------------------------------------------------------------------

def _curl_frag(cid: str, url: str) -> str:
    return (
        f'{cid}=$(curl -s -m 8 -o /dev/null -w "%{{http_code}}" "{url}" '
        f'2>/dev/null || echo 000)\n'
        f'printf "{cid}=%s\\n" "${cid}"'
    )


def _tls_frag(cid: str, url: str) -> str:
    py = (
        "import requests\n"
        "try:\n"
        f"    r = requests.get('{url}', "
        "verify='/etc/ssl/certs/ca-certificates.crt', timeout=8)\n"
        "    print('OK' if r.status_code == 200 else 'FAIL')\n"
        "except Exception:\n"
        "    print('ERR')"
    )
    return (
        f"{cid}=NOPY\n"
        "for p in /nix/store/*-python3-*-env/bin/python3 "
        "/nix/store/*-python3-*/bin/python3; do\n"
        '  "$p" -c "import requests" 2>/dev/null || continue\n'
        f'  {cid}=$("$p" -c {shlex.quote(py)} 2>/dev/null || echo ERR)\n'
        "  break\n"
        "done\n"
        f'printf "{cid}=%s\\n" "${cid}"'
    )


def ssh_probe(key: Optional[str], target: Optional[str], checks: list[dict]) -> dict:
    """Run the profile's in-VM checks in one SSH round-trip.

    Returns {skipped, reason, results:{label: value}}. Emits only HTTP codes
    and OK/FAIL/ERR/NOPY tokens — never response bodies or secrets.
    """
    blank = {"skipped": True, "reason": "no SSH key available", "results": {}}
    if not key or not pathlib.Path(key).is_file() or not target:
        return blank
    frags = ["set -u"]
    for i, chk in enumerate(checks):
        cid = f"c{i}"
        if chk["kind"] == "curl":
            frags.append(_curl_frag(cid, chk["url"]))
        elif chk["kind"] == "requests_tls":
            frags.append(_tls_frag(cid, chk["url"]))
    remote = "\n".join(frags)
    ssh_cmd = [
        "ssh", "-i", key,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "LogLevel=ERROR",
        "-o", "IdentitiesOnly=yes",
        target, remote,
    ]
    try:
        out = subprocess.check_output(
            ssh_cmd, text=True, timeout=45, stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
        return {**blank, "skipped": False, "reason": f"ssh probe failed: {type(e).__name__}",
                "results": {}}
    raw = dict(
        line.split("=", 1) for line in out.strip().splitlines() if "=" in line
    )
    results = {}
    for i, chk in enumerate(checks):
        results[chk["label"]] = raw.get(f"c{i}")
    return {"skipped": False, "reason": None, "results": results}


# ---------------------------------------------------------------------------
# Small render helpers
# ---------------------------------------------------------------------------

def _ok(value: Any) -> str:
    if value is None:
        return "?"
    try:
        return "OK" if int(value) == 1 else "FAIL"
    except (TypeError, ValueError):
        return "?"


def _na(reason: str, kind: str = "unavailable") -> str:
    return f"  n/a — {kind} ({reason})"


def _server_ok_map(live: dict[str, float], metric: Optional[str]) -> dict[str, int]:
    """Extract {name: 0/1} from `metric{...,name="...",...}` gauge keys.

    Tolerant of extra labels / label order (M2) so a healthy server is never
    misrendered as "not seen" just because the series gained a label.
    """
    out: dict[str, int] = {}
    if not metric:
        return out
    for key, val in live.items():
        if not key.startswith(metric + "{"):
            continue
        name = _label(key, "name")
        if name:
            out[name] = int(val)
    return out


def _age_str(age_seconds: float) -> str:
    if age_seconds >= 3600:
        return f"{age_seconds / 3600:.1f}h"
    if age_seconds >= 60:
        return f"{age_seconds / 60:.1f}m"
    return f"{age_seconds:.0f}s"


# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

PROFILES: dict[str, dict] = {
    "openclaw": {
        "agent": "openclaw", "display_name": "OpenClaw",
        "env_prefix": "OPENCLAW_REPORT", "report_header": "X-Openclaw-Report",
        "default_from": "openclaw-health@vulcan.lan",
        "live_textfiles": [f"{TF}/openclaw_mcporter.prom", f"{TF}/openclaw_canary.prom"],
        "expected_servers": (
            "email-contacts", "google-calendar-personal", "google-calendar-work",
            "home-assistant", "searxng", "stock-trader", "vane"),
        "mcp_servers_mode": "mcporter",
        "server_ok_metric": "openclaw_mcporter_server_ok",
        "mcporter_home": "/var/lib/openclaw",
        "host_blind_servers": frozenset(
            {"google-calendar-personal", "google-calendar-work", "home-assistant"}),
        "gateway": {
            "ready_age": "openclaw_gateway_ready_age_seconds",
            "plugins_total": "openclaw_gateway_ready_plugins_total",
            "channels": "openclaw_channel_plugin_loaded",
            "init_fails": "openclaw_plugin_init_failures_recent_total"},
        "units": ["microvm@openclaw.service", "openclaw-self-heal.service"],
        "probe_families": [{"label": "OpenClaw→Hermes bridge smoke",
                            "ok": "openclaw_hermes_smoke_ok",
                            "dur": "openclaw_hermes_smoke_duration_seconds"}],
        "discord": {"mode": "metrics",
                    "connected": "openclaw_discord_ws_connected",
                    "last_ready_age": "openclaw_discord_ws_last_ready_age_seconds"},
        "ha_mcp": {"mode": "textfile",
                   "token": "openclaw_mcporter_ha_token_present",
                   "reachable": "openclaw_mcporter_ha_endpoint_reachable",
                   "auth": "openclaw_mcporter_ha_auth_ok",
                   "last_run": "openclaw_mcporter_check_last_run_timestamp_seconds"},
        "errors_log": "/var/lib/openclaw/.openclaw/logs/gateway-vm.err.log",
        "errors_grammar": "openclaw",
        "incidents_json": "/var/lib/openclaw-self-heal/incidents.json",
        "selfheal_textfile": f"{TF}/openclaw_self_heal.prom",
        "selfheal_metric_prefix": "openclaw_self_heal",
        "invm_checks": [
            {"label": "trader /api/schwab/status", "kind": "curl",
             "url": "https://trader.vulcan.lan/api/schwab/status"},
            {"label": "trader requests-TLS", "kind": "requests_tls",
             "url": "https://trader.vulcan.lan/api/schwab/status"}],
        "verdict_fail_if_zero": [("openclaw_mcporter_ha_auth_ok", "HA auth failing")],
        "errors_fail_threshold": 20,
    },
    "hermes": {
        "agent": "hermes", "display_name": "Hermes",
        "env_prefix": "HERMES_REPORT", "report_header": "X-Hermes-Report",
        "default_from": "hermes-health@vulcan.lan",
        "live_textfiles": [f"{TF}/hermes_health.prom", f"{TF}/hermes_e2e_chat.prom",
                           f"{TF}/hermes_self_heal.prom"],
        # Authoritative inventory = nix services.hermes-agent.mcpServers.
        # SearXNG is the native web backend, NOT an MCP server.
        "expected_servers": (
            "vane", "home-assistant", "stock-trader", "email-contacts",
            "perplexity", "org-db"),
        # Hermes VM has no mcporter CLI; MCP loads inside the agent.
        "mcp_servers_mode": "config_inventory",
        "server_ok_metric": None,
        "mcp_aggregate": {"sse": "hermes_mcp_sse_open_ok",
                          "ask": "hermes_mcp_ask_hermes_ok",
                          "ask_s": "hermes_mcp_ask_hermes_seconds"},
        "host_blind_servers": frozenset(),
        "gateway": None,  # NousResearch agent: no plugin gateway → n/a
        "units": ["microvm@hermes.service", "hermes-mcp.service",
                  "hermes-self-heal.service"],
        "probe_families": [{"label": "Hermes e2e chat",
                            "ok": "hermes_e2e_chat_ok",
                            "dur": "hermes_e2e_chat_duration_seconds"},
                           {"label": "OpenClaw→Hermes bridge smoke",
                            "ok": "openclaw_hermes_smoke_ok",
                            "dur": "openclaw_hermes_smoke_duration_seconds"}],
        "discord": {"mode": "log",
                    "log": "/var/lib/hermes/.hermes/logs/gateway.log",
                    "heartbeat_age_metric": "hermes_discord_heartbeat_age_seconds"},
        "ha_mcp": {"mode": "na_pointer"},
        "errors_log": "/var/lib/hermes/.hermes/logs/errors.log",
        "errors_grammar": "hermes",
        "incidents_json": "/var/lib/hermes-self-heal/incidents.json",
        "selfheal_textfile": f"{TF}/hermes_self_heal.prom",
        "selfheal_metric_prefix": "hermes_self_heal",
        "invm_checks": [
            {"label": "/v1/capabilities", "kind": "curl",
             "url": "http://localhost:8080/v1/capabilities"},
            {"label": "trader /api/schwab/status", "kind": "curl",
             "url": "https://trader.vulcan.lan/api/schwab/status"},
            {"label": "trader requests-TLS", "kind": "requests_tls",
             "url": "https://trader.vulcan.lan/api/schwab/status"}],
        "verdict_fail_if_zero": [("hermes_api_server_ok", "api_server down"),
                                 ("hermes_mcp_sse_open_ok", "hermes-mcp SSE down"),
                                 ("hermes_mcp_ask_hermes_ok", "ask_hermes round-trip failing")],
        "errors_fail_threshold": 50,
    },
}


def get_profile(name: str) -> dict:
    p = PROFILES.get(name)
    if p is None:
        sys.stderr.write(f"unknown agent: {name!r} (expected: {sorted(PROFILES)})\n")
        raise SystemExit(2)
    return p


# ---------------------------------------------------------------------------
# Collect — gather every section's raw data into one dict
# ---------------------------------------------------------------------------

def collect(profile: dict) -> dict:
    """Gather all section data; any single failure degrades to None/empty."""
    global PROMETHEUS_URL
    prefix = profile["env_prefix"]
    PROMETHEUS_URL = os.getenv(f"{prefix}_PROMETHEUS_URL", PROMETHEUS_URL)
    ssh_key = os.getenv(f"{prefix}_SSH_KEY")
    ssh_target = os.getenv(f"{prefix}_SSH_TARGET")
    now = dt.datetime.now()

    live = parse_prom_textfiles(profile["live_textfiles"])
    live_selfheal = parse_prom_textfile(profile["selfheal_textfile"])

    # Section 2 — MCP servers
    servers: dict[str, dict] = {}
    if profile.get("mcp_servers_mode") == "mcporter":
        servers = run_mcporter_list(prefix, profile.get("mcporter_home", "/var/lib/openclaw"))
        vm_live = run_mcporter_list_via_ssh(ssh_key, ssh_target, prefix)
        for name in profile.get("host_blind_servers", frozenset()):
            servers.pop(name, None)
            if name in vm_live:
                servers[name] = vm_live[name]

    # Section 4 — uptime
    uptime = {u: systemd_uptime(u) for u in profile["units"]}

    # Section 5 — probe families
    probes = []
    for fam in profile["probe_families"]:
        summ = probe_summary_24h(fam["ok"], fam["dur"])
        summ["label"] = fam["label"]
        probes.append(summ)

    # Section 6 — discord
    discord: dict = {}
    dprof = profile["discord"]
    if dprof["mode"] == "log":
        discord = {
            "counts": parse_gateway_log(dprof["log"], 24, now),
            "latest": most_recent_per_type(dprof["log"], now),
        }

    # Section 8 — errors
    errors = parse_errors_log(profile["errors_log"], profile["errors_grammar"], 24, now)

    # Section 9 — incidents
    incidents = parse_incidents(profile["incidents_json"], now)

    # Section 10 — in-VM corroboration
    invm = ssh_probe(ssh_key, ssh_target, profile["invm_checks"])

    return {
        "host": os.uname().nodename,
        "now": now,
        "live": live,
        "live_selfheal": live_selfheal,
        "servers": servers,
        "uptime": uptime,
        "probes": probes,
        "discord": discord,
        "errors": errors,
        "incidents": incidents,
        "invm": invm,
    }


# ---------------------------------------------------------------------------
# Verdict + section renderers
# ---------------------------------------------------------------------------

def _trader_state(invm: dict) -> tuple[bool, bool]:
    """Return (probed, failed) for the trader checks within the in-VM results."""
    if invm.get("skipped", True):
        return (False, False)
    results = invm.get("results", {})
    curl = next((v for k, v in results.items()
                 if "trader" in k.lower() and "tls" not in k.lower()), None)
    tls = next((v for k, v in results.items()
                if "trader" in k.lower() and "tls" in k.lower()), None)
    probed = curl is not None or tls is not None
    # Only definitive bad signals count as failure (NOPY/None = unavailable).
    failed = (
        (curl is not None and curl != "200")
        or (tls in ("FAIL", "ERR"))
    )
    return (probed, failed)


def _compute_issues(profile: dict, data: dict) -> list[str]:
    issues: list[str] = []
    live = data["live"]
    for metric, label in profile["verdict_fail_if_zero"]:
        if live.get(metric, 1) == 0:
            issues.append(label)
    # microVM (first unit) not active
    first_unit = profile["units"][0]
    state = data["uptime"].get(first_unit, {}).get("active")
    if state not in ("active", None, "unknown"):
        issues.append(f"{first_unit} state: {state}")
    # structurally-invalid MCP servers (openclaw)
    bad = [n for n, ok in _server_ok_map(live, profile.get("server_ok_metric")).items()
           if ok != 1]
    if bad:
        issues.append(f"{len(bad)} MCP server(s) structurally invalid")
    # errors over threshold
    if data["errors"].get("errors_total", 0) > profile["errors_fail_threshold"]:
        issues.append(f"{data['errors']['errors_total']} errors in 24h")
    # trader unreachable from VM
    _, trader_failed = _trader_state(data["invm"])
    if trader_failed:
        issues.append("stock-trader unreachable from VM")
    # stuck self-heal incidents
    if data["incidents"]["stuck_alerts"]:
        issues.append(f"{len(data['incidents']['stuck_alerts'])} stuck incidents")
    return issues


def _section(header: str) -> list[str]:
    return [header, SECTION_RULE]


def render_live_metrics(profile, data) -> list[str]:
    lines = _section("Live metrics")
    live = data["live"]
    if not live:
        lines.append(_na("no live textfile gauges found"))
    else:
        for k, v in sorted(live.items()):
            lines.append(f"  {k:50} {v}")
    return lines


def render_mcp_servers(profile, data) -> list[str]:
    lines = _section("MCP servers")
    mode = profile.get("mcp_servers_mode")
    if mode == "config_inventory":
        servers = profile["expected_servers"]
        lines.append(f"  {'Server':<28} {'Struct':<10} {'Live':<6} Status")
        lines.append(f"  {'-' * 28} {'-' * 10} {'-' * 6} {'-' * 24}")
        for name in servers:
            lines.append(f"  {name:<28} {'configured':<10} {'—':<6} (configured in nix)")
        agg = profile.get("mcp_aggregate", {})
        live = data["live"]
        sse = _ok(live.get(agg.get("sse")))
        ask = _ok(live.get(agg.get("ask")))
        ask_s = live.get(agg.get("ask_s"))
        ask_s_str = f" ({ask_s:.1f}s round-trip)" if isinstance(ask_s, (int, float)) else ""
        lines.append(f"  MCP layer: sse_open={sse}  ask_hermes={ask}{ask_s_str}")
        lines.append("  (per-server tool counts n/a — Hermes loads MCP via the "
                     "agent, no mcporter CLI; aggregate liveness above)")
        return lines

    # mcporter mode (OpenClaw)
    live = data["live"]
    servers = data["servers"]
    server_ok = _server_ok_map(live, profile.get("server_ok_metric"))
    expected = sorted(server_ok.keys()) or list(profile["expected_servers"])
    all_names = sorted(set(expected) | set(servers.keys()))
    blind = profile.get("host_blind_servers", frozenset())
    lines.append(f"  {'Server':<28} {'Struct':<7} {'Live':<6} Status")
    lines.append(f"  {'-' * 28} {'-' * 7} {'-' * 6} {'-' * 26}")
    for name in all_names:
        struct = "OK" if server_ok.get(name) == 1 else ("?" if name not in server_ok else "FAIL")
        info = servers.get(name)
        if name in blind and info is None:
            live_count, status = "n/a", "(skipped from host context)"
        elif info is None:
            live_count, status = "?", "(not seen in mcporter list)"
        else:
            live_count = (str(info["tool_count"]) if info["tool_count"] is not None else "—")
            status = info["status"]
        lines.append(f"  {name:<28} {struct:<7} {live_count:<6} {status}")
    return lines


def render_gateway(profile, data) -> list[str]:
    lines = _section("Gateway + plugins")
    gw = profile.get("gateway")
    if gw is None:
        n = len(profile.get("expected_servers") or ())
        detail = (f"NousResearch agent has no plugin gateway; "
                  f"{n} MCP servers loaded" if n else
                  "NousResearch agent has no plugin gateway; MCP server count unavailable")
        lines.append(_na(detail, kind="not applicable"))
        return lines
    live = data["live"]
    ready_age = live.get(gw["ready_age"])
    plugins_total = live.get(gw["plugins_total"])
    init_fails = live.get(gw["init_fails"])
    if ready_age is not None:
        lines.append(f"  last [gateway] ready age: {_age_str(ready_age)}")
    else:
        lines.append("  last [gateway] ready age: ?")
    lines.append(f"  plugins loaded:           {int(plugins_total) if plugins_total is not None else '?'}")
    chan_prefix = gw["channels"]
    chans = sorted(
        c
        for k in live
        if k.startswith(chan_prefix + "{") and live[k] == 1.0
        and (c := _label(k, "channel"))
    )
    if chans:
        lines.append(f"  channels present:         {', '.join(chans)}")
    lines.append(f"  plugin init failures:     {int(init_fails) if init_fails is not None else '?'}")
    return lines


def render_uptime(profile, data) -> list[str]:
    lines = _section("microVM + sidecars uptime")
    for unit in profile["units"]:
        u = data["uptime"].get(unit, {})
        short = unit.replace(".service", "")
        lines.append(
            f"  {short:<22} active={str(u.get('active', '?')):8} "
            f"since={str(u.get('since') or '-'):27} restarts={u.get('n_restarts')}"
        )
    return lines


def render_probe_summary(profile, data) -> list[str]:
    lines = _section("24h probe summary (Prometheus)")
    if not data["probes"]:
        lines.append(_na("no probe families configured"))
        return lines
    for pr in data["probes"]:
        lines.append(f"  {pr['label']}:")
        if pr["available"]:
            lines.append(f"    Success ratio: {pr['success_ratio'] * 100:.1f}% over 24h")
            lines.append(f"    Latency p50:   {pr['p50_seconds']:.2f}s")
            lines.append(f"    Latency p95:   {pr['p95_seconds']:.2f}s")
        else:
            lines.append("    " + _na("Prometheus unreachable or no data").strip())
    return lines


def render_discord(profile, data) -> list[str]:
    lines = _section("Discord activity (last 24h)")
    dprof = profile["discord"]
    if dprof["mode"] == "metrics":
        live = data["live"]
        connected = live.get(dprof["connected"])
        age = live.get(dprof["last_ready_age"])
        conn_str = "yes" if connected == 1.0 else ("no" if connected == 0.0 else "?")
        lines.append(f"  WebSocket connected:   {conn_str}")
        if age is not None:
            lines.append(f"  last ready event age:  {_age_str(age)}")
        else:
            lines.append("  last ready event age:  ?")
        return lines
    # log mode (Hermes)
    counts = data["discord"].get("counts") or {t: 0 for t in EVENT_KEYWORDS}
    latest = data["discord"].get("latest") or {}
    for etype, count in counts.items():
        last = latest.get(etype)
        last_str = last.isoformat() if last else "-"
        lines.append(f"  {etype:10} count={count:4}  most recent={last_str}")
    hb_metric = dprof.get("heartbeat_age_metric")
    hb = data["live"].get(hb_metric) if hb_metric else None
    if hb is not None:
        lines.append(f"  heartbeat-ACK age:    {_age_str(hb)}")
    return lines


def render_ha_mcp(profile, data) -> list[str]:
    lines = _section("Home Assistant MCP")
    ha = profile["ha_mcp"]
    if ha["mode"] == "na_pointer":
        n = len(profile.get("expected_servers") or ())
        lines.append(_na(
            f"Hermes has no dedicated HA-MCP probe; home-assistant is one of "
            f"{n} configured MCP servers (see MCP servers above); MCP liveness "
            f"via ask_hermes round-trip", kind="not applicable"))
        return lines
    live = data["live"]
    lines.append(f"  token present:          {_ok(live.get(ha['token']))}")
    lines.append(f"  endpoint reachable:     {_ok(live.get(ha['reachable']))}")
    lines.append(f"  bearer token accepted:  {_ok(live.get(ha['auth']))}")
    lr = live.get(ha.get("last_run"))
    if lr:
        try:
            lr_dt = dt.datetime.fromtimestamp(lr, dt.timezone.utc).astimezone()
            age_min = (dt.datetime.now().astimezone() - lr_dt).total_seconds() / 60
            lines.append(f"  last check:             {lr_dt:%Y-%m-%d %H:%M %Z} ({age_min:.0f}m ago)")
        except (OSError, ValueError, OverflowError):
            pass
    return lines


def render_errors(profile, data) -> list[str]:
    errors = data["errors"]
    lines = _section(f"Errors digest (last 24h, total={errors.get('total', 0)})")
    if not errors.get("available"):
        lines.append("  err log not found")
        return lines
    if errors.get("total", 0) == 0:
        lines.append("  (no errors) — quiet window")
        return lines
    lines.append(
        f"  Real errors: {errors.get('errors_total', 0)}    "
        f"Benign warnings (filtered): {errors.get('warnings_total', 0)}"
    )
    if errors["patterns"]:
        lines.append("  Top error patterns:")
        for e in errors["patterns"]:
            lines.append(f"    {e['count']:>4}  {e['pattern'][:80]}")
    else:
        lines.append("  No real errors. (Only known config warnings.)")
    if errors.get("warnings"):
        lines.append("  Top benign warning patterns (info only):")
        for w in errors["warnings"]:
            lines.append(f"    {w['count']:>4}  {w['pattern'][:80]}")
    return lines


def render_selfheal(profile, data) -> list[str]:
    lines = _section("Self-heal incidents (last 24h)")
    inc = data["incidents"]
    lines.append(f"  active:        {inc['active']}")
    lines.append(f"  resolved 24h:  {inc['resolved_24h']}")
    if inc["stuck_alerts"]:
        lines.append("  STUCK alerts:  " + ", ".join(inc["stuck_alerts"]))
    sh = data["live_selfheal"]
    prefix = profile["selfheal_metric_prefix"]
    hb = sh.get(f"{prefix}_last_heartbeat_seconds")
    if hb:
        try:
            age = dt.datetime.now().timestamp() - hb
            lines.append(f"  daemon heartbeat age: {_age_str(max(0.0, age))}")
        except (OverflowError, ValueError):
            pass
    attempts = sorted(
        (a, int(v))
        for k, v in sh.items()
        if k.startswith(prefix + "_attempts_total{") and (a := _label(k, "action"))
    )
    nonzero = [(a, c) for a, c in attempts if c]
    if nonzero:
        lines.append("  remediation attempts (lifetime): "
                     + ", ".join(f"{a}={c}" for a, c in nonzero))
    return lines


def render_invm(profile, data) -> list[str]:
    lines = _section("In-VM corroboration")
    invm = data["invm"]
    if invm.get("skipped"):
        lines.append(_na(invm.get("reason", "probe skipped")))
        return lines
    if invm.get("reason"):
        lines.append(_na(invm["reason"]))
        return lines
    results = invm.get("results", {})
    if not results:
        lines.append(_na("probe returned no results"))
        return lines
    for label, val in results.items():
        kind = "HTTP" if (val or "").isdigit() else ""
        lines.append(f"  {label:<28} {kind} {val}".rstrip())
    return lines


SECTION_RENDERERS = [
    render_live_metrics,
    render_mcp_servers,
    render_gateway,
    render_uptime,
    render_probe_summary,
    render_discord,
    render_ha_mcp,
    render_errors,
    render_selfheal,
    render_invm,
]


def render(profile: dict, data: dict) -> tuple[str, str]:
    """Return (subject, body) for the email."""
    issues = _compute_issues(profile, data)
    verdict = "FAIL" if issues else "PASS"
    if issues:
        summary = issues[0]
    elif data["incidents"]["active"]:
        # Self-heal is actively remediating: not a FAIL, but not "all healthy".
        n = data["incidents"]["active"]
        summary = f"{n} active self-heal incident{'s' if n != 1 else ''}"
    else:
        summary = "all healthy"

    host = data["host"]
    now = data["now"]
    date_str = now.strftime("%Y-%m-%d")
    subject = f"[{profile['agent']}-nightly] {host} {date_str} - {summary}"

    lines: list[str] = []
    lines.append(f"{profile['display_name']} health report — {host} — "
                 f"{now.isoformat(timespec='seconds')}")
    lines.append("=" * 76)
    lines.append("")
    lines.append(f"Headline: {verdict} — {summary}")
    if data["incidents"]["stuck_alerts"]:
        lines.append("  STUCK INCIDENTS: " + ", ".join(data["incidents"]["stuck_alerts"]))
    for i in issues:
        lines.append(f"  - {i}")
    lines.append("")

    for renderer in SECTION_RENDERERS:
        lines.extend(renderer(profile, data))
        lines.append("")

    lines.append("--")
    lines.append(f"Sent by agent-health-report.service (--agent {profile['agent']})")
    return subject, "\n".join(lines)


# ---------------------------------------------------------------------------
# Delivery
# ---------------------------------------------------------------------------

def _build_message(subject: str, body: str, sender: str, recipient: str,
                   header_tag: str) -> bytes:
    """RFC 822 message with 8bit text/plain UTF-8 (preserves em-dash/`=`)."""
    headers = (
        f"Subject: {subject}\r\n"
        f"From: {sender}\r\n"
        f"To: {recipient}\r\n"
        "Auto-Submitted: auto-generated\r\n"
        f"{header_tag}: nightly\r\n"
        "MIME-Version: 1.0\r\n"
        'Content-Type: text/plain; charset="utf-8"\r\n'
        "Content-Transfer-Encoding: 8bit\r\n"
        "\r\n"
    )
    return headers.encode("ascii") + body.encode("utf-8")


def deliver(subject: str, body: str, sender: str, recipient: str,
            sendmail: str, header_tag: str, dry_run: bool) -> int:
    raw = _build_message(subject, body, sender, recipient, header_tag)
    if dry_run:
        sys.stdout.write(raw.decode("utf-8"))
        sys.stdout.write("\n")
        return 0
    if not os.path.isfile(sendmail):
        sys.stderr.write(f"sendmail not found at {sendmail}\n")
        return 2
    try:
        proc = subprocess.run(
            [sendmail, "-i", "-B", "8BITMIME", "-f", sender, recipient],
            input=raw, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        sys.stderr.write(f"sendmail failed: {exc}\n")
        return 3
    return proc.returncode


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Unified agent health report")
    parser.add_argument("--agent", required=True, choices=sorted(PROFILES),
                        help="which agent profile to render")
    args = parser.parse_args(argv)

    profile = get_profile(args.agent)
    prefix = profile["env_prefix"]
    recipient = os.getenv(f"{prefix}_TO", "johnw@vulcan.lan")
    sender = os.getenv(f"{prefix}_FROM", profile["default_from"])
    sendmail = os.getenv(f"{prefix}_SENDMAIL", "/run/wrappers/bin/sendmail")
    dry_run = bool(os.getenv(f"{prefix}_DRY_RUN"))

    data = collect(profile)
    subject, body = render(profile, data)
    return deliver(subject, body, sender, recipient, sendmail,
                   profile["report_header"], dry_run)


if __name__ == "__main__":
    sys.exit(main())
