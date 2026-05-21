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
  8. Optional in-VM SSH probe

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
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}).*\[gateway\.platforms\.discord\]\s+(?P<rest>.*)$"
)
# NOTE: "reconnect" must be checked before "connect" in the alternation order
# so that a line like "reconnect (resume ok)" is counted as reconnect, not
# connect. Python's `\b` already prevents `\bconnect\b` from matching inside
# `reconnect` (word boundary between two word chars doesn't exist), but the
# dict iteration order below is the operative safeguard if the regex ever
# changes.
EVENT_KEYWORDS = {
    "reconnect": re.compile(r"\breconnect\b"),
    "connect":   re.compile(r"\bWS connect\b|\bconnect\b"),
    "inbound":   re.compile(r"\binbound\b"),
    "outbound":  re.compile(r"\boutbound\b"),
    "error":     re.compile(r"\berror\b|\bheartbeat\b.*\bdelayed\b"),
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
