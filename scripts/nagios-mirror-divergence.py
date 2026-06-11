#!/usr/bin/env python3
"""Tier-3 Nagios <-> Prometheus mirror divergence reconciler.

Compares the HARD state of every `PROM-MIRROR <alertname>` Nagios service
(written by the tier-2 generator into /var/lib/nagios/status.dat) against the
firing alert sets of the three rulers (Prometheus, the Loki ruler, vmalert),
and emits a textfile-collector .prom describing where the two stacks disagree.

Two directions of divergence:

  nagios_only: a mirror service is HARD WARNING/CRITICAL but no ruler is firing
    the matching alertname. The ruler-side rule is likely dead/broken (the
    2026-06-09 class of 123 rules that could never fire). Nagios re-evaluates
    the same expression through its own scheduler, so it still trips.

  ruler_only: a ruler is firing an alertname that HAS a mirror service, but
    that service is HARD OK. The Nagios mirror is broken.

Design constraints (see docs/NAGIOS_PROMETHEUS_MIRROR_SPEC.md section 4):
  - HARD states only (state_type=1, has_been_checked=1); soft states are
    transient retries and do not represent a real disagreement.
  - The three datasource-health checks ("PROM-MIRROR <ds> API") are not rule
    mirrors and are excluded from the comparison.
  - Mirrors in UNKNOWN are skipped: an UNKNOWN means the datasource API was
    unreachable when Nagios checked, which is a datasource outage, not a
    rule-vs-rule divergence.
  - Exclusions: "Watchdog" (fires by design) and the 6 nagios.yaml rules
    (circular). Alertnames with no mirror service are skipped (not yet
    deployed / deliberately excluded by tier 2).
  - info-severity asymmetry: tier-2 maps info-severity rules to OK by design,
    so an info mirror can never be HARD WARNING/CRITICAL and thus can never be
    detected as nagios_only. Conversely an info-severity ruler alert firing
    while its mirror sits at OK is EXPECTED, so ruler_only skips any firing
    alert whose ruler labels.severity == "info".
  - Any ruler API unreachable -> that datasource's firing set is unknown, so
    we cannot assert ruler_only for it; we treat it as "skip" rather than
    divergence and still exit 0 with success=1. Only an unreadable status.dat
    sets success=0.
  - Emits alertnames only (public repo content) -- never other label values.

Stdlib only. Runs as root via a 5-minute oneshot timer.
"""

import json
import os
import re
import sys
import time
import urllib.request

STATUS = "/var/lib/nagios/status.dat"
OUT = "/var/lib/prometheus-node-exporter-textfiles/nagios_mirror_divergence.prom"

MIRROR_PREFIX = "PROM-MIRROR "

# Datasource-health checks created by the tier-2 generator. These are
# check_http probes against the ruler APIs, NOT rule mirrors, so they must not
# participate in the rule-vs-rule comparison.
API_HEALTH_NAMES = {"prometheus API", "loki API", "vm API"}

# Rulers. Each is queried independently and is independently fallible.
RULER_ENDPOINTS = {
    "prometheus": "http://127.0.0.1:9090/api/v1/alerts",
    "loki": "http://127.0.0.1:3100/prometheus/api/v1/alerts",
    "vm": "http://127.0.0.1:8880/api/v1/alerts",
}

# Comparison exclusions (spec section 2.4 / 4). Watchdog fires by design; the
# nagios.yaml rules check "is Nagios up" and are owned by the Prometheus side.
EXCLUDED_ALERTNAMES = {
    "Watchdog",
    "NagiosServiceDown",
    "NagiosWebInterfaceUnreachable",
    "NagiosServicesCritical",
    "NagiosHostsDown",
    "NagiosResultsStale",
    "NagiosStatusExporterFailed",
}

# A trailing "-2"/"-3"/... dedupe suffix is appended by the tier-2 generator on
# alertname collisions. Strip it so the mirror name maps back to the rule name.
DEDUPE_SUFFIX_RE = re.compile(r"-\d+$")


def parse_blocks(text, name):
    header = name + " {"
    out = []
    cur = None
    for raw in text.splitlines():
        s = raw.strip()
        if s == header:
            cur = {}
        elif s == "}" and cur is not None:
            out.append(cur)
            cur = None
        elif cur is not None and "=" in s:
            k, _, v = s.partition("=")
            cur[k] = v
    return out


def alertname_from_description(desc):
    """PROM-MIRROR <alertname>[-N] -> <alertname> (or None if not a mirror)."""
    if not desc.startswith(MIRROR_PREFIX):
        return None
    rest = desc[len(MIRROR_PREFIX):]
    if rest in API_HEALTH_NAMES:
        return None
    return DEDUPE_SUFFIX_RE.sub("", rest)


def load_mirror_states(text):
    """Return (alertname -> best HARD nagios_state) plus the raw mirror count.

    nagios_state: 0 OK / 1 WARNING / 2 CRITICAL / 3 UNKNOWN. When the same
    alertname has multiple mirror services (it should not, but dedupe makes it
    possible), keep the most-severe HARD state with CRITICAL > WARNING >
    UNKNOWN > OK so a single broken mirror is not masked by an OK sibling.
    """
    # Severity ordering for collapsing duplicate alertnames.
    rank = {2: 3, 1: 2, 3: 1, 0: 0}
    states = {}
    mirror_count = 0
    for b in parse_blocks(text, "servicestatus"):
        desc = b.get("service_description", "")
        name = alertname_from_description(desc)
        if name is None:
            continue
        mirror_count += 1
        if b.get("has_been_checked") != "1":
            continue
        if b.get("state_type") != "1":  # hard states only
            continue
        try:
            st = int(b.get("current_state", ""))
        except ValueError:
            continue
        if st not in (0, 1, 2, 3):
            continue
        prev = states.get(name)
        if prev is None or rank[st] > rank[prev]:
            states[name] = st
    return states, mirror_count


def fetch_firing(url):
    """GET <url>/api/v1/alerts -> dict alertname -> severity for FIRING alerts.

    Independently fallible: returns None on any error (timeout, HTTP, parse) so
    the caller can treat the whole datasource as "unknown" rather than empty.
    The standard Prometheus alerts payload is data.alerts[] with .state,
    .labels.alertname, .labels.severity; the Loki ruler and vmalert both speak
    this shape on /api/v1/alerts.
    """
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        return None
    if not isinstance(payload, dict) or payload.get("status") != "success":
        return None
    data = payload.get("data") or {}
    alerts = data.get("alerts") or []
    firing = {}
    for a in alerts:
        if not isinstance(a, dict) or a.get("state") != "firing":
            continue
        labels = a.get("labels") or {}
        name = labels.get("alertname")
        if not name:
            continue
        sev = labels.get("severity", "")
        # If an alertname fires at multiple severities, a non-info severity
        # wins (info is the only one that exempts ruler_only).
        if name not in firing or firing[name] == "info":
            firing[name] = sev
    return firing


def main():
    now = int(time.time())
    success = 1

    try:
        with open(STATUS, "r", errors="replace") as fh:
            text = fh.read()
    except Exception:
        # An unreadable status.dat is the only hard failure: we cannot compare.
        success = 0
        text = None

    if text is not None:
        mirror_states, mirror_count = load_mirror_states(text)
    else:
        mirror_states, mirror_count = {}, 0

    # Fetch firing sets. Each datasource is independently fallible; a None means
    # "unknown firing set" and is excluded from ruler_only assertions.
    firing_by_ds = {ds: fetch_firing(url) for ds, url in RULER_ENDPOINTS.items()}

    # Union of all reachable rulers' firing alertnames -> severity. info wins
    # only if every contributing entry is info.
    firing_union = {}
    any_ruler_up = False
    for ds_firing in firing_by_ds.values():
        if ds_firing is None:
            continue
        any_ruler_up = True
        for name, sev in ds_firing.items():
            if name not in firing_union or firing_union[name] == "info":
                firing_union[name] = sev

    nagios_only = []
    ruler_only = []

    if text is not None:
        # nagios_only: mirror HARD WARNING/CRITICAL whose alertname is not in
        # any reachable ruler's firing set. (info mirrors map to OK by design
        # and thus never reach this branch.) UNKNOWN mirrors are skipped --
        # they mean the datasource API was down, not a divergence.
        for name, st in mirror_states.items():
            if name in EXCLUDED_ALERTNAMES:
                continue
            if st not in (1, 2):  # only WARNING/CRITICAL; OK/UNKNOWN skipped
                continue
            if name not in firing_union:
                nagios_only.append(name)

        # ruler_only: a firing alertname that HAS a mirror service which is
        # HARD OK. Skip names with no mirror (not deployed / excluded), skip
        # exclusions, and skip info-severity ruler alerts (expected to sit at
        # OK on the mirror side).
        for name, sev in firing_union.items():
            if name in EXCLUDED_ALERTNAMES:
                continue
            if sev == "info":
                continue
            st = mirror_states.get(name)
            if st is None:  # no mirror service for this alertname
                continue
            if st == 0:  # mirror is HARD OK while ruler fires -> mirror broken
                ruler_only.append(name)

    # any_ruler_up is informational; even with all rulers down we still emit a
    # valid file (success stays 1 unless status.dat was unreadable).
    _ = any_ruler_up

    nagios_only = sorted(set(nagios_only))
    ruler_only = sorted(set(ruler_only))

    lines = [
        "# HELP nagios_mirror_divergence_total Mirror services disagreeing with the ruler firing set, by direction",
        "# TYPE nagios_mirror_divergence_total gauge",
        'nagios_mirror_divergence_total{direction="nagios_only"} %d' % len(nagios_only),
        'nagios_mirror_divergence_total{direction="ruler_only"} %d' % len(ruler_only),
        "# HELP nagios_mirror_diverged_alert Individual diverged alertnames (alertname label only; up to 20 per direction)",
        "# TYPE nagios_mirror_diverged_alert gauge",
    ]
    # Alertnames only -- never other label values (no leak vector).
    for name in nagios_only[:20]:
        lines.append(
            'nagios_mirror_diverged_alert{direction="nagios_only",alertname="%s"} 1'
            % name
        )
    for name in ruler_only[:20]:
        lines.append(
            'nagios_mirror_diverged_alert{direction="ruler_only",alertname="%s"} 1'
            % name
        )
    lines += [
        "# HELP nagios_mirror_checks_total Number of PROM-MIRROR rule services seen in status.dat",
        "# TYPE nagios_mirror_checks_total gauge",
        "nagios_mirror_checks_total %d" % mirror_count,
        "# HELP nagios_mirror_reconciler_success Whether the last reconciler run read status.dat successfully (1) or not (0)",
        "# TYPE nagios_mirror_reconciler_success gauge",
        "nagios_mirror_reconciler_success %d" % success,
        "# HELP nagios_mirror_reconciler_timestamp_seconds Unix time of the last nagios-mirror-divergence reconciler run",
        "# TYPE nagios_mirror_reconciler_timestamp_seconds gauge",
        "nagios_mirror_reconciler_timestamp_seconds %d" % now,
        "",
    ]

    tmp = OUT + "." + str(os.getpid())
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)
    sys.exit(0)


if __name__ == "__main__":
    main()
