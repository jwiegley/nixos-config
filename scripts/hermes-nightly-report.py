#!/usr/bin/env python3
"""Nightly Hermes health report → email to johnw@vulcan.lan.

See docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md §7.

Aggregates 8 signal sources:
  1. Headline verdict (hermes_health.prom snapshot)
  2. Live metrics table
  3. microVM + hermes-mcp uptime via `systemctl show`
  4. 24h smoke probe history via Prometheus HTTP API
  5. Discord gateway activity (gateway.log tail)
  6. Errors digest (errors.log tail, redacted)
  7. Self-heal incidents (incidents.json last 24h)
  8. Optional in-VM SSH probe (api_server + stock-trader reachability/TLS)

Composes a plain-text email with ASCII tables and pipes it to sendmail.
Designed to run as root from a systemd timer at 06:15 daily.

Environment overrides:
  HERMES_REPORT_TO          recipient (default: johnw@vulcan.lan)
  HERMES_REPORT_FROM        sender (default: hermes-health@vulcan.lan)
  HERMES_REPORT_SENDMAIL    sendmail path (default: /run/wrappers/bin/sendmail)
  HERMES_REPORT_DRY_RUN     if non-empty, print to stdout instead of mailing
  HERMES_REPORT_SSH_KEY     path to ssh key for in-VM probe
  HERMES_REPORT_SSH_TARGET  e.g. hermes@10.99.1.2
  HERMES_REPORT_PROMETHEUS_URL  default http://127.0.0.1:9090
"""
from __future__ import annotations

import collections
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

TEXTFILE = pathlib.Path(
    "/var/lib/prometheus-node-exporter-textfiles/hermes_health.prom"
)
SMOKE_TEXTFILE = pathlib.Path(
    "/var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom"
)
GATEWAY_LOG = pathlib.Path("/var/lib/hermes/.hermes/logs/gateway.log")
ERRORS_LOG = pathlib.Path("/var/lib/hermes/.hermes/logs/errors.log")
INCIDENTS_JSON = pathlib.Path("/var/lib/hermes-self-heal/incidents.json")

RECIPIENT = os.getenv("HERMES_REPORT_TO", "johnw@vulcan.lan")
SENDER = os.getenv("HERMES_REPORT_FROM", "hermes-health@vulcan.lan")
SENDMAIL = os.getenv("HERMES_REPORT_SENDMAIL", "/run/wrappers/bin/sendmail")
DRY_RUN = bool(os.getenv("HERMES_REPORT_DRY_RUN"))
PROMETHEUS_URL = os.getenv("HERMES_REPORT_PROMETHEUS_URL", "http://127.0.0.1:9090")
SSH_KEY = os.getenv("HERMES_REPORT_SSH_KEY")
SSH_TARGET = os.getenv("HERMES_REPORT_SSH_TARGET", "hermes@10.99.1.2")

# Reuse the redact patterns from the self-heal daemon — same secret shapes.
REDACT_PATTERNS = [
    re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-or-v1-[A-Za-z0-9_-]{20,}"),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    re.compile(r"(?i)(token|password|api[_-]?key)=[^\s&\"]+"),
]


def redact(s: str) -> str:
    for p in REDACT_PATTERNS:
        s = p.sub("[REDACTED]", s)
    return s


def parse_textfile(path: pathlib.Path = TEXTFILE) -> dict[str, float]:
    """Return the gauges from a hermes_health.prom-shaped file."""
    out: dict[str, float] = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        k, _, v = line.rpartition(" ")
        try:
            out[k] = float(v)
        except ValueError:
            pass
    return out


GATEWAY_TS_RE = re.compile(
    # Match BOTH the synthetic test fixture format
    #   "2026-05-20T03:14:22 [gateway.platforms.discord] foo"
    # AND the real production log format from Hermes
    #   "2026-05-20 23:35:31,438 INFO gateway.platforms.discord: foo"
    # The [T ] handles the date/time separator. The trailing [\]:] accepts
    # either `]` (bracketed fixture form) or `:` (real Python-logging form).
    r"^(?P<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}).*?"
    r"\[?gateway\.platforms\.discord(?:\]|:)\s*(?P<rest>.*)$"
)
# Hermes' Discord gateway log emits bracketed event labels:
#   2026-05-20 21:15:57,142 INFO gateway.platforms.discord: [Discord] Connected
# The real vocabulary is Connected / Registered / Skipping / Flushing /
# Disconnected (one per startup cycle, plus housekeeping). It does NOT log
# inbound/outbound message activity — that lives elsewhere in Hermes. The
# 5 categories below pick what's actually meaningful in this log.
#
# Order matters: more-specific keywords first so "Disconnected" is not
# bucketed as "Connected" by a permissive substring match. Python's `\b`
# word boundaries also help.
EVENT_KEYWORDS = {
    "disconnected": re.compile(r"\[Discord\]\s+(?:Safely\s+)?[Dd]isconnect(?:ed)?\b"),
    "connected":    re.compile(r"\[Discord\]\s+Connected\b"),
    "registered":   re.compile(r"\[Discord\]\s+Registered\b"),
    "flushing":     re.compile(r"\[Discord\]\s+Flushing\b"),
    "skipping":     re.compile(r"\[Discord\]\s+Skipping\b"),
}


def _iter_gateway_events(path, now, window_hours=24):
    """Yield (ts, event_type) for each line newer than now-window_hours."""
    if not path.is_file():
        return
    cutoff = now - dt.timedelta(hours=window_hours)
    for line in path.read_text().splitlines():
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


def parse_gateway_log(
    path: pathlib.Path = GATEWAY_LOG,
    window_hours: int = 24,
    now=None,
) -> dict[str, int]:
    """Count Discord events by type in the last `window_hours`."""
    now = now or dt.datetime.now()
    counts = {t: 0 for t in EVENT_KEYWORDS}
    for _ts, etype in _iter_gateway_events(path, now, window_hours):
        counts[etype] += 1
    return counts


def most_recent_per_type(
    path: pathlib.Path = GATEWAY_LOG,
    now=None,
) -> dict[str, dt.datetime]:
    now = now or dt.datetime.now()
    out: dict[str, dt.datetime] = {}
    for ts, etype in _iter_gateway_events(path, now):
        if etype not in out or ts > out[etype]:
            out[etype] = ts
    return out


ERRORS_TS_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\s+(?:ERROR|WARN)\s+(?P<msg>.*)$"
)


def parse_errors_log(
    path: pathlib.Path = ERRORS_LOG,
    window_hours: int = 24,
    now=None,
) -> dict:
    """Return {total, patterns: [{pattern, count}, ...]}, redacted.

    Buckets identical lines (after redaction) so secret variants don't
    fragment the count.
    """
    now = now or dt.datetime.now()
    if not path.is_file():
        return {"total": 0, "patterns": []}
    cutoff = now - dt.timedelta(hours=window_hours)
    bucket: collections.Counter = collections.Counter()
    total = 0
    for line in path.read_text().splitlines():
        m = ERRORS_TS_RE.match(line)
        if not m:
            continue
        try:
            ts = dt.datetime.fromisoformat(m.group("ts"))
        except ValueError:
            continue
        if ts < cutoff:
            continue
        total += 1
        msg = redact(m.group("msg").strip())
        bucket[msg] += 1
    top = [
        {"pattern": p, "count": c}
        for p, c in bucket.most_common(10)
    ]
    return {"total": total, "patterns": top}


def parse_incidents(path: pathlib.Path = INCIDENTS_JSON, now=None) -> dict:
    """Summarize self-heal incidents."""
    if not path.is_file():
        return {"active": 0, "resolved_24h": 0, "stuck_alerts": []}
    try:
        data = json.loads(path.read_text())
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
        if v.get("status") == "stuck"
        and v.get("alerts")
    ]
    resolved_24h = sum(
        1 for v in data.get("history", [])
        if v.get("status") == "resolved"
        and v.get("first_seen_ts", 0) >= cutoff_ts
    )
    return {"active": active, "resolved_24h": resolved_24h, "stuck_alerts": stuck_alerts}


def prometheus_query(promql: str) -> float | None:
    """Query Prometheus' /api/v1/query and return the scalar value, or None on error."""
    url = f"{PROMETHEUS_URL}/api/v1/query?query={urllib.parse.quote(promql)}"
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


def smoke_summary_24h() -> dict:
    """Spec §7.2 section 4 — three Prometheus queries over the smoke gauge.

    Returns {success_ratio, p50_seconds, p95_seconds, available}.
    """
    success = prometheus_query("avg_over_time(openclaw_hermes_smoke_ok[24h])")
    p50 = prometheus_query("quantile_over_time(0.5, openclaw_hermes_smoke_duration_seconds[24h])")
    p95 = prometheus_query("quantile_over_time(0.95, openclaw_hermes_smoke_duration_seconds[24h])")
    return {
        "success_ratio": success,
        "p50_seconds": p50,
        "p95_seconds": p95,
        "available": all(v is not None for v in (success, p50, p95)),
    }


def systemd_uptime(unit: str) -> dict[str, Any]:
    """Return {active, since, n_restarts} via `systemctl show`."""
    try:
        out = subprocess.check_output(
            ["systemctl", "show", "-p", "ActiveState,ActiveEnterTimestamp,NRestarts", unit],
            text=True, timeout=10,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return {"active": "unknown", "since": None, "n_restarts": None}
    fields = dict(line.split("=", 1) for line in out.strip().splitlines() if "=" in line)
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


def in_vm_probe() -> dict[str, Any]:
    """Optional in-VM corroboration via SSH.

    Returns a dict with:
      skipped, reason       — whether the SSH probe ran at all
      http_code             — api_server /v1/capabilities HTTP code
      trader_curl_code      — https://trader.vulcan.lan/api/schwab/status code
                              via curl (system CA bundle path: proves the cert,
                              nginx, the stock-trader service, and the bridge
                              DNAT are all healthy)
      trader_requests_tls   — "OK"/"FAIL"/"ERR"/"NOPY": whether Python
                              `requests` (the library the stock-trader MCP
                              child uses) validates the Vulcan Step-CA cert
                              against the system bundle. Guards the certifi
                              trust path that broke on 2026-05-29 — see the
                              vulcanCaBundle note in hermes-vm.nix.

    All checks run in one SSH round-trip. The python3 interpreter is discovered
    from the Nix store at probe time so we never hardcode a store hash that
    changes on every VM rebuild.
    """
    blank = {
        "skipped": True,
        "reason": "no SSH key available",
        "http_code": None,
        "trader_curl_code": None,
        "trader_requests_tls": None,
    }
    if not SSH_KEY or not pathlib.Path(SSH_KEY).is_file():
        return blank

    remote = r'''set -u
cap=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost:8080/v1/capabilities 2>/dev/null || echo 000)
tcurl=$(curl -s -m 8 -o /dev/null -w '%{http_code}' https://trader.vulcan.lan/api/schwab/status 2>/dev/null || echo 000)
ttls=NOPY
for p in /nix/store/*-python3-*-env/bin/python3; do
  "$p" -c 'import requests' 2>/dev/null || continue
  ttls=$("$p" -c 'import requests
try:
    r = requests.get("https://trader.vulcan.lan/api/schwab/status", verify="/etc/ssl/certs/ca-certificates.crt", timeout=8)
    print("OK" if r.status_code == 200 else "FAIL")
except Exception:
    print("ERR")' 2>/dev/null || echo ERR)
  break
done
printf 'cap=%s\ntcurl=%s\nttls=%s\n' "$cap" "$tcurl" "$ttls"
'''
    try:
        out = subprocess.check_output(
            ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5",
             SSH_TARGET, remote],
            text=True, timeout=40, stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return {**blank, "reason": f"ssh probe failed: {type(e).__name__}"}

    fields = dict(
        line.split("=", 1) for line in out.strip().splitlines() if "=" in line
    )
    return {
        "skipped": False,
        "reason": None,
        "http_code": fields.get("cap"),
        "trader_curl_code": fields.get("tcurl"),
        "trader_requests_tls": fields.get("ttls"),
    }


def render_report(now: dt.datetime, metrics: dict, smoke: dict,
                  microvm_uptime: dict, mcp_uptime: dict,
                  gateway_counts: dict, gateway_latest: dict,
                  errors: dict, incidents: dict, ssh_probe: dict) -> tuple[str, str]:
    """Return (subject, body) for the email."""
    # stock-trader reachability is only a failure signal when the in-VM probe
    # actually ran AND returned a trader result. When the keys are absent (the
    # probe was skipped, or an older code path) we treat it as "not probed" so
    # a missing SSH key never flips the verdict to FAIL.
    trader_curl = ssh_probe.get("trader_curl_code")
    trader_tls = ssh_probe.get("trader_requests_tls")
    trader_probed = trader_curl is not None or trader_tls is not None
    trader_ok = trader_curl == "200" and trader_tls == "OK"
    trader_failed = (
        not ssh_probe.get("skipped", False) and trader_probed and not trader_ok
    )

    # Headline verdict
    fail = (
        metrics.get("hermes_api_server_ok", 1) == 0
        or metrics.get("hermes_mcp_sse_open_ok", 1) == 0
        or metrics.get("hermes_mcp_ask_hermes_ok", 1) == 0
        or trader_failed
    )
    verdict = "FAIL" if fail else "PASS"
    if incidents["stuck_alerts"]:
        verdict = "FAIL"
        summary = f"{len(incidents['stuck_alerts'])} stuck incidents"
    elif incidents["active"]:
        summary = f"{incidents['active']} active incidents"
    elif trader_failed:
        summary = "stock-trader unreachable from VM"
    elif errors["total"] > 50:
        summary = f"{errors['total']} errors in 24h"
    else:
        summary = "all healthy"

    hostname = os.uname().nodename
    date_str = now.strftime("%Y-%m-%d")
    # ASCII hyphen (not em-dash) so headers.encode("ascii") in _build_message
    # doesn't trip on the Subject. The body keeps unicode via 8bit CTE.
    subject = f"[hermes-nightly] {hostname} {date_str} - {summary}"

    lines = []
    lines.append(f"Hermes nightly report — {hostname} — {now.isoformat(timespec='seconds')}")
    lines.append("=" * 76)
    lines.append("")
    lines.append(f"Headline: {verdict} — {summary}")
    if incidents["stuck_alerts"]:
        lines.append("  STUCK INCIDENTS: " + ", ".join(incidents["stuck_alerts"]))
    lines.append("")

    lines.append("Live metrics")
    lines.append("-" * 76)
    for k, v in sorted(metrics.items()):
        lines.append(f"  {k:50} {v}")
    lines.append("")

    lines.append("microVM + hermes-mcp uptime")
    lines.append("-" * 76)
    lines.append(f"  microvm@hermes  active={microvm_uptime['active']:8} "
                 f"since={microvm_uptime['since'] or '-':25} restarts={microvm_uptime['n_restarts']}")
    lines.append(f"  hermes-mcp      active={mcp_uptime['active']:8} "
                 f"since={mcp_uptime['since'] or '-':25} restarts={mcp_uptime['n_restarts']}")
    lines.append("")

    lines.append("24h smoke probe summary (Prometheus)")
    lines.append("-" * 76)
    if smoke["available"]:
        lines.append(f"  Success ratio: {smoke['success_ratio']*100:.1f}% over 24h")
        lines.append(f"  Latency p50:   {smoke['p50_seconds']:.2f}s")
        lines.append(f"  Latency p95:   {smoke['p95_seconds']:.2f}s")
    else:
        lines.append("  (history unavailable: Prometheus unreachable)")
    lines.append("")

    lines.append("Discord activity (last 24h)")
    lines.append("-" * 76)
    for etype, count in gateway_counts.items():
        last = gateway_latest.get(etype)
        last_str = last.isoformat() if last else "-"
        lines.append(f"  {etype:10} count={count:4}  most recent={last_str}")
    lines.append("")

    lines.append(f"Errors digest (last 24h, total={errors['total']})")
    lines.append("-" * 76)
    if not errors["patterns"]:
        lines.append("  (no errors)")
    for entry in errors["patterns"]:
        lines.append(f"  {entry['count']:4}x  {entry['pattern'][:60]}")
    lines.append("")

    lines.append("Self-heal incidents (last 24h)")
    lines.append("-" * 76)
    lines.append(f"  active:        {incidents['active']}")
    lines.append(f"  resolved 24h:  {incidents['resolved_24h']}")
    if incidents["stuck_alerts"]:
        lines.append("  STUCK alerts:  " + ", ".join(incidents["stuck_alerts"]))
    lines.append("")

    lines.append("In-VM corroboration")
    lines.append("-" * 76)
    if ssh_probe["skipped"]:
        lines.append(f"  (probe skipped: {ssh_probe['reason']})")
    else:
        lines.append(f"  /v1/capabilities           HTTP {ssh_probe['http_code']}")
        if trader_curl is not None or trader_tls is not None:
            lines.append(f"  trader /api/schwab/status  HTTP {trader_curl}")
            lines.append(f"  trader requests-TLS        {trader_tls}")
    lines.append("")

    body = "\n".join(lines)
    return subject, body


def _build_message(subject: str, body: str) -> bytes:
    """Construct an RFC 822 message with 8bit text/plain UTF-8.

    EmailMessage's set_content() forces quoted-printable for utf-8 bodies,
    which mangles `=` and unicode (em dash, warning glyph) in the
    rendered email. Build the message manually so we can declare 8bit CTE.
    Mirrors the openclaw-nightly-report fix.
    """
    headers = (
        f"Subject: {subject}\r\n"
        f"From: {SENDER}\r\n"
        f"To: {RECIPIENT}\r\n"
        "Auto-Submitted: auto-generated\r\n"
        "X-Hermes-Report: nightly\r\n"
        "MIME-Version: 1.0\r\n"
        'Content-Type: text/plain; charset="utf-8"\r\n'
        "Content-Transfer-Encoding: 8bit\r\n"
        "\r\n"
    )
    return headers.encode("ascii") + body.encode("utf-8")


def deliver(subject: str, body: str) -> int:
    raw = _build_message(subject, body)
    if DRY_RUN:
        sys.stdout.write(raw.decode("utf-8"))
        sys.stdout.write("\n")
        return 0
    if not os.path.isfile(SENDMAIL):
        sys.stderr.write(f"sendmail not found at {SENDMAIL}\n")
        return 2
    try:
        proc = subprocess.run(
            [SENDMAIL, "-i", "-B", "8BITMIME", "-f", SENDER, RECIPIENT],
            input=raw,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        sys.stderr.write(f"sendmail failed: {exc}\n")
        return 3
    return proc.returncode


def main() -> int:
    # Resolve module-level path constants at call time so tests can
    # monkeypatch them (avoiding the default-arg early-binding trap).
    now = dt.datetime.now()
    metrics = parse_textfile(TEXTFILE)
    smoke = smoke_summary_24h()
    microvm_up = systemd_uptime("microvm@hermes.service")
    mcp_up = systemd_uptime("hermes-mcp.service")
    gw_counts = parse_gateway_log(GATEWAY_LOG, window_hours=24, now=now)
    gw_latest = most_recent_per_type(GATEWAY_LOG, now=now)
    errors = parse_errors_log(ERRORS_LOG, window_hours=24, now=now)
    incidents = parse_incidents(INCIDENTS_JSON, now=now)
    ssh = in_vm_probe()
    subject, body = render_report(
        now, metrics, smoke, microvm_up, mcp_up,
        gw_counts, gw_latest, errors, incidents, ssh,
    )
    return deliver(subject, body)


if __name__ == "__main__":
    sys.exit(main())
