#!/usr/bin/env python3
"""Nightly OpenClaw health report → email to johnw@vulcan.lan.

Aggregates four signals:
  1. MCP server structural status from prometheus textfile metrics.
  2. Live `mcporter list` output for tool counts and reachability.
  3. Gateway uptime, last [gateway] ready, and plugin load status.
  4. Last-24h error counts from gateway-vm.err.log (top patterns).

Composes a plain-text email with ASCII tables and pipes it to sendmail.
Designed to run as root from a systemd timer at 06:00 daily.

Inputs:
  /var/lib/prometheus-node-exporter-textfiles/openclaw_mcporter.prom
  /var/lib/openclaw/.openclaw/.mcporter/mcporter.json
  /var/lib/openclaw/.openclaw/logs/gateway-vm.log
  /var/lib/openclaw/.openclaw/logs/gateway-vm.err.log
  systemctl show microvm@openclaw.service

Environment overrides:
  OPENCLAW_REPORT_TO          recipient (default: johnw@vulcan.lan)
  OPENCLAW_REPORT_FROM        sender   (default: openclaw-health@vulcan.lan)
  OPENCLAW_REPORT_SENDMAIL    sendmail path (default: /run/wrappers/bin/sendmail)
  OPENCLAW_REPORT_MCPORTER    mcporter binary (default: looked up via PATH)
  OPENCLAW_REPORT_CA_BUNDLE   CA bundle for live mcporter list (default:
                              /etc/ssl/certs/ca-certificates.crt + Vulcan root)
  OPENCLAW_REPORT_DRY_RUN     if set non-empty, print to stdout instead of mailing
"""

from __future__ import annotations

import collections
import datetime as dt
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

TEXTFILE = pathlib.Path(
    "/var/lib/prometheus-node-exporter-textfiles/openclaw_mcporter.prom"
)
MCPORTER_JSON = pathlib.Path(
    "/var/lib/openclaw/.openclaw/.mcporter/mcporter.json"
)
GATEWAY_LOG = pathlib.Path("/var/lib/openclaw/.openclaw/logs/gateway-vm.log")
GATEWAY_ERR = pathlib.Path("/var/lib/openclaw/.openclaw/logs/gateway-vm.err.log")
VULCAN_CA = pathlib.Path("/etc/nixos/certs/vulcan-root-ca.crt")
SYSTEM_CA = pathlib.Path("/etc/ssl/certs/ca-certificates.crt")

RECIPIENT = os.getenv("OPENCLAW_REPORT_TO", "johnw@vulcan.lan")
SENDER = os.getenv("OPENCLAW_REPORT_FROM", "openclaw-health@vulcan.lan")
SENDMAIL = os.getenv("OPENCLAW_REPORT_SENDMAIL", "/run/wrappers/bin/sendmail")
DRY_RUN = bool(os.getenv("OPENCLAW_REPORT_DRY_RUN"))

# Servers we never expect to be reachable from the host's mcporter context
# (they need state that only exists inside the VM, e.g. OAuth keys mounted
# at /run/openclaw-secrets that live in the microvm secrets staging dir).
HOST_BLIND_SERVERS = frozenset(
    {
        "google-calendar-personal",
        "google-calendar-work",
        "drafts",  # remote SSE on hera; flaky from host
        "home-assistant",  # bridge needs in-VM token mount
    }
)


# ---------------------------------------------------------------------------
# Source 1: textfile metrics
# ---------------------------------------------------------------------------


def parse_textfile() -> dict[str, Any]:
    """Return parsed gauges from the prometheus textfile.

    Shape:
        {
          "server_ok": {"home-assistant": 1, ...},
          "ha_auth_ok": 1, "ha_reachable": 1, "ha_token_present": 1,
          "last_run_ts": 1778289693.07,
        }
    """
    out: dict[str, Any] = {
        "server_ok": {},
        "ha_auth_ok": None,
        "ha_reachable": None,
        "ha_token_present": None,
        "last_run_ts": None,
        "available": False,
    }
    if not TEXTFILE.is_file():
        return out
    out["available"] = True
    try:
        text = TEXTFILE.read_text()
    except OSError:
        return out

    server_re = re.compile(
        r'^openclaw_mcporter_server_ok\{name="([^"]+)"\}\s+(\S+)'
    )
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        m = server_re.match(line)
        if m:
            try:
                out["server_ok"][m.group(1)] = int(float(m.group(2)))
            except ValueError:
                continue
            continue
        for key, prefix in (
            ("ha_auth_ok", "openclaw_mcporter_ha_auth_ok "),
            ("ha_reachable", "openclaw_mcporter_ha_endpoint_reachable "),
            ("ha_token_present", "openclaw_mcporter_ha_token_present "),
            ("last_run_ts", "openclaw_mcporter_check_last_run_timestamp_seconds "),
        ):
            if line.startswith(prefix):
                rest = line[len(prefix) :].strip()
                try:
                    out[key] = float(rest)
                except ValueError:
                    pass
    return out


# ---------------------------------------------------------------------------
# Source 2: live mcporter list
# ---------------------------------------------------------------------------


_MCPORTER_LIST_RE = re.compile(
    r"^- (?P<name>\S+) — (?P<desc>.*?) \((?P<status>[^)]+)\)$"
)


def _build_ca_bundle() -> str | None:
    """Concatenate system CA + Vulcan root into a temp file. Caller deletes."""
    if not SYSTEM_CA.is_file():
        return None
    fd, path = tempfile.mkstemp(prefix="openclaw-report-ca-", suffix=".crt")
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


def _find_mcporter() -> str | None:
    """Locate mcporter binary. Falls back to scanning the nix store."""
    explicit = os.getenv("OPENCLAW_REPORT_MCPORTER")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit
    found = shutil.which("mcporter")
    if found:
        return found
    # Fallback: pick the highest-versioned mcporter in /nix/store
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


def run_mcporter_list() -> dict[str, dict[str, Any]]:
    """Return {name: {"status": "...", "tool_count": N|None, "raw": "..."}}.

    Runs as the calling user (root in production). Earlier versions tried
    to drop privileges to ``openclaw`` via ``subprocess.run(user=...)``,
    but that proved fragile under the systemd sandbox: when /nix/store
    globbing for the binary failed silently the function returned an
    empty dict and the report rendered every server as "(not seen in
    mcporter list)" (caught in the 2026-05-09 06:02 nightly). Now we
    pin the binary via OPENCLAW_REPORT_MCPORTER and log every failure
    path to stderr so the next regression is visible in the journal.
    """
    out: dict[str, dict[str, Any]] = {}
    binary = _find_mcporter()
    if not binary:
        sys.stderr.write(
            "run_mcporter_list: could not locate mcporter; "
            "set OPENCLAW_REPORT_MCPORTER or add it to PATH\n"
        )
        return out
    if not MCPORTER_JSON.is_file():
        sys.stderr.write(
            f"run_mcporter_list: mcporter.json missing at {MCPORTER_JSON}\n"
        )
        return out

    ca_bundle = _build_ca_bundle()
    env = os.environ.copy()
    env["HOME"] = "/var/lib/openclaw"
    if ca_bundle:
        env["REQUESTS_CA_BUNDLE"] = ca_bundle
        env["NODE_EXTRA_CA_CERTS"] = ca_bundle
    env.setdefault("MCPORTER_LIST_TIMEOUT", "30000")

    try:
        proc = subprocess.run(
            [binary, "list"],
            cwd="/var/lib/openclaw",
            env=env,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except subprocess.TimeoutExpired:
        sys.stderr.write(
            "run_mcporter_list: mcporter list timed out after 180s\n"
        )
        if ca_bundle:
            try:
                os.unlink(ca_bundle)
            except OSError:
                pass
        return out
    except (OSError, ValueError) as exc:
        sys.stderr.write(
            f"run_mcporter_list: subprocess.run failed: {type(exc).__name__}: {exc}\n"
        )
        if ca_bundle:
            try:
                os.unlink(ca_bundle)
            except OSError:
                pass
        return out
    finally:
        if ca_bundle:
            try:
                os.unlink(ca_bundle)
            except OSError:
                pass

    if proc.returncode != 0:
        sys.stderr.write(
            f"run_mcporter_list: mcporter list exited {proc.returncode}: "
            f"{proc.stderr[:300]}\n"
        )

    matched = 0
    for line in proc.stdout.splitlines():
        m = _MCPORTER_LIST_RE.match(line)
        if not m:
            continue
        matched += 1
        name = m.group("name")
        status = m.group("status")
        tool_count: int | None = None
        tm = re.match(r"(\d+)\s+tools?", status)
        if tm:
            tool_count = int(tm.group(1))
        out[name] = {"status": status, "tool_count": tool_count, "raw": line}

    if matched == 0:
        # Helpful when the regex stops matching (e.g. mcporter changes
        # its list format). Show the first ~400 bytes so we can tell.
        sys.stderr.write(
            "run_mcporter_list: parsed 0 servers from mcporter output. "
            f"stdout head: {proc.stdout[:400]!r}\n"
        )
    return out


# ---------------------------------------------------------------------------
# Source 3: gateway log → uptime + plugins
# ---------------------------------------------------------------------------


def microvm_uptime() -> dict[str, Any]:
    """Read systemd state for microvm@openclaw.service."""
    out: dict[str, Any] = {"active_since": None, "active_state": "unknown"}
    try:
        proc = subprocess.run(
            [
                "systemctl",
                "show",
                "microvm@openclaw.service",
                "--property=ActiveState,ActiveEnterTimestamp,SubState",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return out
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key == "ActiveState":
            out["active_state"] = value
        elif key == "ActiveEnterTimestamp" and value:
            try:
                out["active_since"] = dt.datetime.strptime(
                    value, "%a %Y-%m-%d %H:%M:%S %Z"
                )
            except ValueError:
                # Some systemctl variants return without TZ tag
                try:
                    out["active_since"] = dt.datetime.strptime(
                        value, "%a %Y-%m-%d %H:%M:%S"
                    )
                except ValueError:
                    pass
        elif key == "SubState":
            out["sub_state"] = value
    return out


_GATEWAY_READY_RE = re.compile(
    r"^(?P<ts>\S+)\s+\[gateway\]\s+ready(?:\s+\((?P<plugins>[^;)]+)(?:;\s*[^)]*)?\))?"
)
_HTTP_LISTENING_RE = re.compile(
    r"^(?P<ts>\S+)\s+\[gateway\]\s+http server listening \((?P<n>\d+)\s+plugins?:\s+(?P<plugins>[^;)]+)"
)


def gateway_state() -> dict[str, Any]:
    """Find latest [gateway] ready and plugin list."""
    out: dict[str, Any] = {
        "last_ready_ts": None,
        "plugins": [],
        "log_age_s": None,
        "log_present": GATEWAY_LOG.is_file(),
    }
    if not GATEWAY_LOG.is_file():
        return out

    last_ready: str | None = None
    plugins: list[str] = []

    # Read tail (last 4000 lines) — the log has typing TTL noise from
    # before but [gateway] ready lines are sparse.
    try:
        with GATEWAY_LOG.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 256 * 1024))
            tail = f.read().decode("utf-8", errors="replace")
    except OSError:
        return out

    for line in tail.splitlines():
        m = _GATEWAY_READY_RE.match(line)
        if m:
            last_ready = m.group("ts")
            ps = m.group("plugins")
            if ps:
                plugins = [p.strip() for p in ps.split(",") if p.strip()]
            continue
        m = _HTTP_LISTENING_RE.match(line)
        if m:
            ps = m.group("plugins")
            plugins = [p.strip() for p in ps.split(",") if p.strip()]

    out["last_ready_ts"] = last_ready
    out["plugins"] = plugins
    if last_ready:
        try:
            ts = dt.datetime.fromisoformat(last_ready.replace("Z", "+00:00"))
            now = dt.datetime.now(dt.timezone.utc)
            out["log_age_s"] = (now - ts).total_seconds()
        except ValueError:
            pass
    return out


# ---------------------------------------------------------------------------
# Source 4: last-24h errors
# ---------------------------------------------------------------------------


_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T[\d:.+-]+)")

# Known-benign warnings that systemd captures into err.log because they go
# to stderr. Filtering them out of the headline error count lets a real
# regression actually stand out instead of drowning in gateway noise.
_BENIGN_WARNING_PATTERNS = [
    re.compile(r"must declare contracts\.tools before registering"),
    re.compile(r"Gateway is binding to a non-loopback address"),
    re.compile(r"controlUi\.dangerouslyAllowHostHeaderOriginFallback"),
    re.compile(r"security warning: dangerous config flags enabled"),
    re.compile(r"Api key is used with unsecure connection"),
    # [diagnostic] lines are observability traces, not errors. They
    # show up in err.log because OpenClaw routes diagnostic output to
    # stderr. Treating them as errors masked real issues in the 2026-05-09
    # report, where 4 of 44 "errors" were liveness pings and stalled-
    # session traces.
    re.compile(r"\[diagnostic\] long-running session\b"),
    re.compile(r"\[diagnostic\] stalled session\b"),
    re.compile(r"\[diagnostic\] liveness warning\b"),
    # WhatsApp Web companion-link goes "app-silent" every ~2h; OpenClaw's
    # watchdog detects it and reconnects, which logs both a watchdog
    # timeout AND a 499 status close in lockstep. Upstream protocol
    # behavior, not actionable from NixOS.
    re.compile(r"\[whatsapp\] watchdog timeout\b"),
    re.compile(r"\[whatsapp\] Web connection closed\b"),
]


def _is_benign_warning(line: str) -> bool:
    return any(p.search(line) for p in _BENIGN_WARNING_PATTERNS)


def recent_errors(window_hours: int = 24) -> dict[str, Any]:
    """Count error log lines in the last window_hours; group top patterns.

    Splits results into ``errors`` (real problems) and ``warnings`` (known
    benign config noise from systemd capturing stderr — e.g. plugin-SDK
    contract warnings, intentional non-loopback bind, dangerous-flag
    advisories). The benign set is filtered by _BENIGN_WARNING_PATTERNS.
    """
    out: dict[str, Any] = {
        "available": False,
        "total_lines": 0,
        "errors_total": 0,
        "warnings_total": 0,
        "errors_by_pattern": [],
        "warnings_by_pattern": [],
        "window_hours": window_hours,
    }
    if not GATEWAY_ERR.is_file():
        return out
    out["available"] = True
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=window_hours)

    try:
        with GATEWAY_ERR.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 1024 * 1024))
            tail = f.read().decode("utf-8", errors="replace")
    except OSError:
        return out

    error_counts: collections.Counter[str] = collections.Counter()
    warning_counts: collections.Counter[str] = collections.Counter()

    for line in tail.splitlines():
        if not line.strip():
            continue
        m = _TS_RE.match(line)
        if m:
            try:
                ts = dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts < cutoff:
                continue
        else:
            # Lines without a timestamp (e.g. "Api key is used with unsecure
            # connection." printed by litellm SDK) — skip the time gate
            # rather than counting forever-old noise.
            continue
        out["total_lines"] += 1

        body = line[m.end():].strip() if m else line
        body = re.sub(r"\s*\(status=[^)]*\)\s*$", "", body)
        body = re.sub(r"\d+(?:\.\d+)?ms\b", "Nms", body)
        body = re.sub(r"\b\d{2,}\b", "N", body)
        pattern = body[:120]

        if _is_benign_warning(line):
            warning_counts[pattern] += 1
            out["warnings_total"] += 1
        else:
            error_counts[pattern] += 1
            out["errors_total"] += 1

    out["errors_by_pattern"] = error_counts.most_common(5)
    out["warnings_by_pattern"] = warning_counts.most_common(3)
    return out


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------


def _ok(value: Any) -> str:
    if value is None:
        return "?"
    return "OK" if int(value) == 1 else "FAIL"


def _fmt_uptime(d: dt.timedelta) -> str:
    total = int(d.total_seconds())
    days, total = divmod(total, 86400)
    hours, total = divmod(total, 3600)
    mins, _ = divmod(total, 60)
    if days:
        return f"{days}d {hours}h {mins}m"
    if hours:
        return f"{hours}h {mins}m"
    return f"{mins}m"


def render_report(
    textfile: dict[str, Any],
    live: dict[str, dict[str, Any]],
    gateway: dict[str, Any],
    errors: dict[str, Any],
    uptime_info: dict[str, Any],
) -> tuple[str, str]:
    """Return (subject, body) for the email."""
    now_local = dt.datetime.now().astimezone()
    date_str = now_local.strftime("%Y-%m-%d %H:%M %Z")

    issues: list[str] = []
    server_ok = textfile.get("server_ok", {})
    expected = sorted(server_ok.keys()) or sorted(
        {
            "drafts",
            "email-contacts",
            "google-calendar-personal",
            "google-calendar-work",
            "home-assistant",
            "searxng",
            "stock-trader",
            "vane",
        }
    )
    bad_servers = [n for n, ok in server_ok.items() if ok != 1]
    if bad_servers:
        issues.append(f"{len(bad_servers)} MCP server(s) structurally invalid")
    if textfile.get("ha_auth_ok") not in (1, None) or textfile.get("ha_auth_ok") == 0:
        issues.append("HA auth failing")
    if uptime_info.get("active_state") != "active":
        issues.append(f"microvm state: {uptime_info.get('active_state')}")
    if errors.get("errors_total", 0) > 20:
        issues.append(
            f"{errors['errors_total']} non-warning errors in last 24h"
        )
    if not gateway.get("plugins"):
        issues.append("no plugins detected in recent gateway log")

    overall = "OK" if not issues else f"{len(issues)} issue(s)"
    subject = f"[OpenClaw] Daily Health {now_local:%Y-%m-%d} - {overall}"

    lines: list[str] = []
    lines.append("OpenClaw Daily Health Report")
    lines.append("============================")
    lines.append(f"Generated: {date_str}")
    lines.append(f"Overall:   {overall}")
    if issues:
        for i in issues:
            lines.append(f"  - {i}")
    lines.append("")

    # Section 1: MCP servers
    lines.append("MCP Servers")
    lines.append("-----------")
    lines.append(
        f"{'Server':<28} {'Struct':<7} {'Live':<8} Status"
    )
    lines.append(f"{'-' * 28} {'-' * 7} {'-' * 8} {'-' * 30}")
    for name in expected:
        struct = "OK" if server_ok.get(name) == 1 else (
            "?" if name not in server_ok else "FAIL"
        )
        live_info = live.get(name)
        # HOST_BLIND servers always show as skipped, regardless of what
        # mcporter list reports — they need in-VM state (HA token mount,
        # GCal OAuth, hera SSE) that isn't accessible from the host, so
        # an "offline" reading from here is misleading. Their actual
        # health comes from the textfile structural check + the HA
        # section below.
        if name in HOST_BLIND_SERVERS:
            live_count = "n/a"
            status = "(skipped from host context)"
        elif live_info is None:
            live_count = "?"
            status = "(not seen in mcporter list)"
        else:
            live_count = (
                str(live_info["tool_count"])
                if live_info["tool_count"] is not None
                else "—"
            )
            status = live_info["status"]
        lines.append(f"{name:<28} {struct:<7} {live_count:<8} {status}")
    lines.append("")

    # Section 2: Gateway
    lines.append("Gateway")
    lines.append("-------")
    if uptime_info.get("active_since"):
        try:
            since = uptime_info["active_since"].astimezone()
            now = dt.datetime.now().astimezone()
            uptime_str = _fmt_uptime(now - since)
            since_str = since.strftime("%Y-%m-%d %H:%M %Z")
        except (TypeError, ValueError):
            uptime_str = "unknown"
            since_str = "?"
    else:
        uptime_str = "unknown"
        since_str = "?"
    lines.append(f"  microvm@openclaw state: {uptime_info.get('active_state', '?')}")
    lines.append(f"  active since:           {since_str} (uptime {uptime_str})")
    lines.append(
        f"  last [gateway] ready:   {gateway.get('last_ready_ts') or 'not found'}"
    )
    if gateway.get("log_age_s") is not None:
        age_h = gateway["log_age_s"] / 3600
        lines.append(f"  ready age:              {age_h:.1f}h")
    plugins = gateway.get("plugins") or []
    plugin_str = ", ".join(plugins) if plugins else "(none parsed)"
    lines.append(f"  plugins loaded ({len(plugins)}):    {plugin_str}")
    lines.append("")

    # Section 3: HA
    lines.append("Home Assistant MCP")
    lines.append("------------------")
    lines.append(
        f"  token present:          {_ok(textfile.get('ha_token_present'))}"
    )
    lines.append(
        f"  endpoint reachable:     {_ok(textfile.get('ha_reachable'))}"
    )
    lines.append(
        f"  bearer token accepted:  {_ok(textfile.get('ha_auth_ok'))}"
    )
    lr = textfile.get("last_run_ts")
    if lr:
        try:
            lr_dt = dt.datetime.fromtimestamp(lr, dt.timezone.utc).astimezone()
            lr_age_min = (
                dt.datetime.now().astimezone() - lr_dt
            ).total_seconds() / 60
            lines.append(
                f"  last check:             {lr_dt:%Y-%m-%d %H:%M %Z} ({lr_age_min:.0f}m ago)"
            )
        except (OSError, ValueError):
            pass
    lines.append("")

    # Section 4: Errors
    lines.append(f"Recent Errors (last {errors.get('window_hours', 24)}h)")
    lines.append("---------------------------")
    if not errors.get("available"):
        lines.append("  err.log not found")
    elif errors.get("total_lines", 0) == 0:
        lines.append("  No log lines in window. Quiet night.")
    else:
        lines.append(
            f"  Real errors: {errors['errors_total']}    "
            f"Benign warnings (filtered): {errors['warnings_total']}"
        )
        if errors["errors_by_pattern"]:
            lines.append("  Top error patterns:")
            for pattern, count in errors["errors_by_pattern"]:
                lines.append(f"    {count:>4}  {pattern}")
        else:
            lines.append("  No real errors. (Only known config warnings.)")
        if errors["warnings_by_pattern"]:
            lines.append("")
            lines.append("  Top benign warning patterns (info only):")
            for pattern, count in errors["warnings_by_pattern"]:
                lines.append(f"    {count:>4}  {pattern}")
    lines.append("")
    lines.append("--")
    lines.append(
        "Sent by openclaw-nightly-report.service "
        "(/etc/nixos/scripts/openclaw-nightly-report.py)"
    )
    return subject, "\n".join(lines)


# ---------------------------------------------------------------------------
# Send
# ---------------------------------------------------------------------------


def _build_message(subject: str, body: str) -> bytes:
    """Construct an RFC 822 message with 8bit text/plain UTF-8.

    EmailMessage's set_content() forces quoted-printable for utf-8 bodies,
    which mangles ``=`` and unicode (em dash, warning glyph) in the
    rendered email. Build the message manually so we can declare 8bit CTE.
    """
    headers = (
        f"Subject: {subject}\r\n"
        f"From: {SENDER}\r\n"
        f"To: {RECIPIENT}\r\n"
        "Auto-Submitted: auto-generated\r\n"
        "X-Openclaw-Report: nightly\r\n"
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
    textfile = parse_textfile()
    live = run_mcporter_list()
    gateway = gateway_state()
    errors = recent_errors()
    uptime = microvm_uptime()
    subject, body = render_report(textfile, live, gateway, errors, uptime)
    return deliver(subject, body)


if __name__ == "__main__":
    sys.exit(main())
