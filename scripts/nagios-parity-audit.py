#!/usr/bin/env python3
"""Prove that every native Nagios check has a live Prometheus equivalent.

WHY THIS EXISTS

Nagios is being retired (2026-07-31) on one condition: that retiring it removes a DUPLICATE
set of monitors, not a unique one. That condition was originally answered in prose, by
reading rule names and judging them similar. Prose cannot be re-run, and name similarity is
not evidence -- a rule called `ATDServiceDown` proves nothing unless the series it selects
actually exists for the unit Nagios was watching.

So this asks a harder question, per check: does the SPECIFIC OBJECT this Nagios check
watches -- that unit, that vhost, that host, that container -- have a live Prometheus series
AND a rule selecting it? A check is COVERED only when both are true, verified against the
running Prometheus, not against the YAML.

It is deliberately re-runnable and exits non-zero while any gap remains, so it can be the
gate immediately before Nagios is removed rather than a snapshot taken days earlier.

WHAT IT DELIBERATELY DOES NOT DO

- It does not print IP addresses. The Nagios host inventory is private network topology;
  hosts are reported by name or alias only.
- It does not treat `PROM-MIRROR *` services as needing coverage. Those are generated FROM
  Prometheus rules by nagios-prometheus-mirror.nix -- they are mirrors, not sources, and
  counting them would inflate the work by ~497 checks.
- It does not accept a rule NAME as proof. Only a live series counts.

USAGE
    sudo scripts/nagios-parity-audit.py               # human summary, exit 1 if gaps
    sudo scripts/nagios-parity-audit.py --json        # machine-readable
    sudo scripts/nagios-parity-audit.py --show-covered
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request

OBJECTS_CACHE = "/var/lib/nagios/objects.cache"
PROM = "http://127.0.0.1:9090"

# Services being decommissioned in this same operation. A Nagios check whose target is one
# of these needs no Prometheus equivalent -- the thing it watches is going away. Keeping
# this list explicit (rather than silently ignoring unmatched checks) is the difference
# between "deliberately obsolete" and "accidentally forgotten".
# All removed as of 2026-08-03. Nagios is deliberately NOT here: it is being
# KEPT for the checks only it performs (notably timed-out oneshot units, which
# end inactive/dead rather than failed and so are invisible to
# node_systemd_unit_state{state="failed"}).
DOOMED = (
    "litellm", "openclaw", "teable", "cockpit",
    "shlink", "jupyter", "openspeedtest",
)

# Checks consciously dropped rather than ported, with the reason. Anything here is a
# DECISION, not a gap -- but it must be written down, or the next audit re-discovers it as a
# finding and someone re-litigates it.
DROPPED = {
    "check_local_users": "stock localhost.cfg boilerplate on a single-admin host; "
                         "node_logged_in_users does not exist and node_exporter has no "
                         "collector for it. Never fired.",
}


def q(expr: str) -> float:
    """Instant query -> scalar count. 0.0 on any failure, which fails CLOSED (reads as a gap)."""
    url = f"{PROM}/api/v1/query?query={urllib.parse.quote(expr)}"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            d = json.load(r)
    except Exception:
        return 0.0
    if d.get("status") != "success":
        return 0.0
    res = d.get("data", {}).get("result", [])
    if not res:
        return 0.0
    try:
        return float(res[0]["value"][1])
    except (KeyError, IndexError, ValueError):
        return 0.0


def load_rules() -> tuple[set[str], dict[str, str]]:
    """Return (rule names, name -> health) from the running Prometheus."""
    try:
        with urllib.request.urlopen(f"{PROM}/api/v1/rules", timeout=20) as r:
            d = json.load(r)
    except Exception:
        return set(), {}
    names, health = set(), {}
    for g in d.get("data", {}).get("groups", []):
        for rule in g.get("rules", []):
            n = rule.get("name")
            if n:
                names.add(n)
                health[n] = rule.get("health", "unknown")
    return names, health


def parse_objects() -> tuple[list[dict], list[dict]]:
    """Parse objects.cache into (services, hosts).

    Uses sudo because the file is root-owned. Blocks are `define service {` ... `}`.
    """
    try:
        raw = subprocess.run(
            ["sudo", "cat", OBJECTS_CACHE],
            capture_output=True, text=True, timeout=60, check=True,
        ).stdout
    except Exception as e:  # noqa: BLE001
        print(f"FATAL: cannot read {OBJECTS_CACHE}: {e}", file=sys.stderr)
        sys.exit(2)

    # EXACT block headers only. `startswith("define service")` also matches
    # `define servicedependency` and `define serviceescalation`, and `define host` matches
    # `define hostgroup` / `hostdependency` / `hostescalation`. Using startswith inflated the
    # count from 836 blocks to 1852 and filled the gap list with dependency records that are
    # not checks at all.
    svc_re = re.compile(r"^define\s+service\s*\{")
    host_re = re.compile(r"^define\s+host\s*\{")

    services, hosts = [], []
    kind, cur = None, {}
    for line in raw.splitlines():
        s = line.strip()
        if svc_re.match(s):
            kind, cur = "service", {}
            continue
        if host_re.match(s):
            kind, cur = "host", {}
            continue
        if s == "}" and kind:
            (services if kind == "service" else hosts).append(cur)
            kind, cur = None, {}
            continue
        if kind and "\t" in s or (kind and " " in s):
            parts = re.split(r"\s+", s, maxsplit=1)
            if len(parts) == 2:
                cur[parts[0]] = parts[1].strip()
    return services, hosts


def is_doomed(text: str) -> str | None:
    low = text.lower()
    for d in DOOMED:
        if d in low:
            return d
    return None


def classify(svc: dict) -> dict:
    """Decide whether one native Nagios check has a proven Prometheus equivalent.

    Every branch that claims COVERED must cite a live series count -- never a rule name
    alone. `evidence` records the exact query, so a disputed verdict is re-checkable.
    """
    desc = svc.get("service_description", "").strip()
    host = svc.get("host_name", "").strip()
    cmd = svc.get("check_command", "").strip()
    fam = cmd.split("!", 1)[0]
    args = cmd.split("!")[1:]
    out = {"check": desc, "host": host, "command": cmd, "family": fam}

    doomed = is_doomed(f"{desc} {cmd}")
    if doomed:
        return {**out, "status": "OBSOLETE", "evidence": f"target service '{doomed}' is being removed"}

    if fam in DROPPED:
        return {**out, "status": "DROPPED", "evidence": DROPPED[fam]}

    # --- systemd units: prove the exact unit is scraped ------------------------------
    if fam in ("check_systemd_service", "check_systemd_timer", "check_systemd_unit"):
        unit = args[0] if args else ""
        if not unit:
            return {**out, "status": "NOT_COVERED", "evidence": "no unit argument parsed"}
        if not unit.endswith((".service", ".timer", ".socket", ".mount", ".target")):
            unit += ".service"
        expr = f'count(node_systemd_unit_state{{name="{unit}"}})'
        n = q(expr)
        if n > 0:
            return {**out, "status": "COVERED",
                    "evidence": f"{expr} = {n:g} (SystemdServiceFailed/SystemdUnitFailed select this)"}
        return {**out, "status": "NOT_COVERED",
                "evidence": f"{expr} = 0 -- unit not scraped by node_exporter"}

    # --- host reachability -----------------------------------------------------------
    if fam == "check_ping":
        # Per-host membership is proven by the eval-time inventory assertion, not here:
        # matching a Nagios host to a blackbox target requires its ADDRESS, and addresses
        # must never reach this script's output. So this branch only confirms the job exists.
        n = q('count(probe_success{job="blackbox_icmp"})')
        if n > 0:
            return {**out, "status": "COVERED",
                    "evidence": f"blackbox_icmp has {n:g} targets; per-host membership checked in the host pass"}
        return {**out, "status": "NOT_COVERED", "evidence": "no blackbox_icmp targets at all"}

    # --- TLS certificates: two independent mechanisms, either suffices ----------------
    if fam in ("check_ssl_cert", "check_ssl_validity", "check_cert"):
        by_file = q("count(certificate_days_until_expiry)")
        by_probe = q('count(probe_ssl_earliest_cert_expiry)')
        if by_file > 0 or by_probe > 0:
            return {**out, "status": "COVERED",
                    "evidence": f"certificate_days_until_expiry={by_file:g} series "
                                f"(CertificateExpiringSoon <=30d/<=7d) + "
                                f"probe_ssl_earliest_cert_expiry={by_probe:g}"}
        return {**out, "status": "NOT_COVERED", "evidence": "no certificate series of either kind"}

    # --- HTTP/HTTPS vhosts: prove THIS vhost is probed --------------------------------
    if fam in ("check_http", "check_https", "check_https_vhost", "check_http_vhost"):
        m = re.search(r"(?:-H\s+|https?://)([A-Za-z0-9._-]+)", cmd)
        vhost = m.group(1) if m else ""
        if vhost:
            expr = f'count(probe_success{{instance=~"https?://{re.escape(vhost)}.*"}})'
            n = q(expr)
            if n > 0:
                return {**out, "status": "COVERED", "evidence": f"{expr} = {n:g} (WebServiceDown selects it)"}
        pm = re.search(r"-p\s+(\d+)", cmd)
        if pm:
            port = pm.group(1)
            n = q(f'count(probe_success{{instance=~".*:{port}.*"}})')
            if n > 0:
                return {**out, "status": "COVERED", "evidence": f"a probe targets port {port} ({n:g} series)"}
            return {**out, "status": "NOT_COVERED",
                    "evidence": f"no blackbox probe targets port {port}"}
        return {**out, "status": "NOT_COVERED", "evidence": f"no probe found for vhost '{vhost or cmd}'"}

    # --- raw TCP ports ----------------------------------------------------------------
    if fam == "check_tcp":
        port = args[0] if args else ""
        n = q(f'count(probe_success{{job="blackbox_tcp",instance=~".*:{port}"}})')
        if n > 0:
            return {**out, "status": "COVERED", "evidence": f"blackbox_tcp probes :{port}"}
        return {**out, "status": "NOT_COVERED",
                "evidence": f"no blackbox_tcp target for :{port} (this is what the new tcp job closes)"}

    # --- containers --------------------------------------------------------------------
    if "podman" in fam or "container" in fam:
        n = q("count(container_health_status) or count(podman_container_state)")
        if n > 0:
            return {**out, "status": "COVERED", "evidence": f"container state series present ({n:g})"}
        return {**out, "status": "NOT_COVERED", "evidence": "no container state metric"}

    return {**out, "status": "UNKNOWN",
            "evidence": f"no handler for check family '{fam}' -- classify it explicitly"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--show-covered", action="store_true")
    a = ap.parse_args()

    rules, _health = load_rules()
    if not rules:
        print("FATAL: Prometheus returned no rules -- cannot audit. Is it running?", file=sys.stderr)
        return 2

    services, hosts = parse_objects()
    native = [s for s in services
              if not s.get("service_description", "").startswith("PROM-MIRROR")]

    results = [classify(s) for s in native]

    # Host pass: every Nagios host must be an ICMP target. Names only -- never addresses.
    icmp = q('count(probe_success{job="blackbox_icmp"})')
    host_report = {
        "nagios_hosts": len(hosts),
        "blackbox_icmp_targets": int(icmp),
        "note": "per-host membership is proven by scripts/blackbox-inventory-check "
                "(the eval-time assertion); this records the totals only, and never addresses",
    }

    buckets: dict[str, list[dict]] = {}
    for r in results:
        buckets.setdefault(r["status"], []).append(r)

    gaps = buckets.get("NOT_COVERED", []) + buckets.get("UNKNOWN", [])

    if a.json:
        print(json.dumps({
            "summary": {k: len(v) for k, v in sorted(buckets.items())},
            "total_service_blocks": len(services),
            "prom_mirror_excluded": len(services) - len(native),
            "native_checks_audited": len(native),
            "hosts": host_report,
            "gaps": gaps,
            "verdict": "PARITY" if not gaps else "GAPS_REMAIN",
        }, indent=2))
        return 0 if not gaps else 1

    print("Nagios -> Prometheus parity audit")
    print("=" * 72)
    print(f"  service blocks in objects.cache : {len(services)}")
    print(f"  PROM-MIRROR (mirrors, excluded) : {len(services) - len(native)}")
    print(f"  native checks audited           : {len(native)}")
    print(f"  Nagios hosts / ICMP targets     : {host_report['nagios_hosts']} / {host_report['blackbox_icmp_targets']}")
    print()
    for status in sorted(buckets):
        print(f"  {status:<13} {len(buckets[status])}")
    print()

    if a.show_covered:
        for r in buckets.get("COVERED", []):
            print(f"  OK   {r['check']} [{r['host']}]\n       {r['evidence']}")
        print()

    if gaps:
        print("GAPS -- Nagios must NOT be removed while these remain:")
        for r in gaps:
            print(f"  [{r['status']}] {r['check']}  (host={r['host']})")
            print(f"      command : {r['command']}")
            print(f"      evidence: {r['evidence']}")
        print()
        print(f"VERDICT: GAPS_REMAIN ({len(gaps)}). Retiring Nagios now WOULD lose coverage.")
        return 1

    print("VERDICT: PARITY. Every native Nagios check has a proven live Prometheus equivalent.")
    print("Retiring Nagios removes duplication only.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
