#!/usr/bin/env python3
"""Tier-3 Nagios <-> Prometheus mirror divergence reconciler.

Compares the HARD state of every `PROM-MIRROR <alertname>` Nagios service
(written by the tier-2 generator into /var/lib/nagios/status.dat) against the
firing alert sets of the three rulers (Prometheus, the Loki ruler, vmalert),
and emits a textfile-collector .prom describing where the two stacks disagree.

Two directions of divergence:

  nagios_only: a mirror service is HARD WARNING/CRITICAL but no ruler has the
    matching alertname FIRING OR PENDING. The ruler-side rule is likely
    dead/broken (the 2026-06-09 class of 123 rules that could never fire). Nagios
    re-evaluates the same expression through its own scheduler, so it still trips.
    "Or pending" matters: a pending alert means the ruler's expression IS true and
    only its for:-timer has yet to elapse, so the two stacks agree. Before
    2026-07-29 this counted only "firing", which made every Prometheus restart --
    i.e. every nixos-rebuild -- manufacture a burst of false nagios_only for the
    duration of each long-dwell rule's for:. A dead rule never reaches pending
    either, so dead-rule detection is unaffected.

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
  - Any ruler API unreachable -> that datasource's alert set is unknown, so
    we cannot assert ruler_only for it; we treat it as "skip" rather than
    divergence and still exit 0 with success=1. Only an unreadable status.dat
    sets success=0. As of 2026-07-29 the SAME suppression applies to nagios_only.
    It previously did not, despite this paragraph: the union was built from
    reachable rulers only and any_ruler_up was computed and then discarded, so
    one fetch timeout would have reported every HARD WARNING mirror as diverged.
    An unreachable ruler now suppresses nagios_only for that run, logs to stderr,
    and is reported via nagios_mirror_rulers_unreachable.
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

# The matching /rules endpoint for each ruler, used to prove a rule was actually
# EVALUATED before we accuse it of not firing. See fetch_evaluated().
RULER_RULE_ENDPOINTS = {
    ds: url.rsplit("/alerts", 1)[0] + "/rules" for ds, url in RULER_ENDPOINTS.items()
}

# Prometheus renders "never evaluated" as the zero time.
NEVER_EVALUATED = "0001-01-01T00:00:00Z"

# Comparison exclusions (spec section 2.4 / 4). Watchdog fires by design; the
# nagios.yaml rules check "is Nagios up" and are owned by the Prometheus side.
#
# The three NagiosMirror* names were ADDED 2026-07-29 and are exactly as circular as the
# nagios.yaml six: this reconciler's own output is what makes NagiosMirrorDivergence fire,
# so when that alert's mirror service goes HARD WARNING it lands back in nagios_only and
# increments the very gauge that produced it. Measured on 2026-07-29 it appeared in 21 of
# 145 five-minute steps, feeding its own alert. Excluding them here does NOT stop tier 2
# from creating their mirror services -- Nagios still checks them independently and still
# pages on its own -- it only removes them from the rule-vs-rule comparison.
EXCLUDED_ALERTNAMES = {
    "Watchdog",
    "NagiosServiceDown",
    "NagiosWebInterfaceUnreachable",
    "NagiosServicesCritical",
    "NagiosHostsDown",
    "NagiosResultsStale",
    "NagiosStatusExporterFailed",
    "NagiosMirrorDivergence",
    "NagiosMirrorReconcilerStale",
    "NagiosMirrorReconcilerFailed",
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


def fetch_active(url):
    """GET <url>/api/v1/alerts -> {"firing": {name: severity}, "active": {names}} or None.

    Two sets, because the two divergence directions need different questions
    answered:

      "firing" (state == firing only) answers "is the ruler PAGING for this?" and
        is what ruler_only compares against a HARD OK mirror.

      "active" (state == firing OR pending) answers "does the ruler's expression
        currently HOLD?" and is what nagios_only compares against a HARD
        WARNING/CRITICAL mirror. A pending alert means the expression is true and
        only the for:-timer has yet to elapse -- the two stacks AGREE about the
        world, so counting it as divergence is wrong. This distinction is the
        2026-07-29 fix: every nixos-rebuild restarts Prometheus, which resets all
        for:-timers, so long-dwell alerts drop to pending for their whole dwell
        while Nagios -- which keeps its own state across the restart -- stays HARD
        WARNING. That produced 34-50 minute nagios_only waves after each of the
        day's several rebuilds, and the diverged names were exactly the long-dwell
        rules (ServiceChronicallyUnavailable for:1h, ProbeTargetChronicallyFailing
        for:1h, AideChangesDetected for:1h, GiteaPushMirrorFailing for:2h). Note a
        genuinely DEAD rule never reaches pending either, so dead-rule detection
        -- the whole point of this reconciler -- is preserved.

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
    active = set()
    for a in alerts:
        if not isinstance(a, dict):
            continue
        state = a.get("state")
        if state not in ("firing", "pending"):
            continue
        labels = a.get("labels") or {}
        name = labels.get("alertname")
        if not name:
            continue
        active.add(name)
        if state != "firing":
            continue
        sev = labels.get("severity", "")
        # If an alertname fires at multiple severities, a non-info severity
        # wins (info is the only one that exempts ruler_only).
        if name not in firing or firing[name] == "info":
            firing[name] = sev
    return {"firing": firing, "active": active}


def fetch_evaluated(url):
    """GET <url>/api/v1/rules -> {alertnames whose rule has been EVALUATED} or None.

    The third leg of the 2026-07-29 fix, and the one that actually did most of the
    work. Treating "pending" as agreement is necessary but not sufficient, because
    a rule the ruler has not yet evaluated even ONCE produces no entry in
    /api/v1/alerts at all -- neither firing nor pending -- so "not in the active
    set" is trivially true for it and nagios_only fires on nothing.

    That is not a rare edge: Prometheus staggers group evaluation across the
    configured interval, so for tens of seconds after every restart a large slice
    of the rule set is unevaluated. Measured immediately after the 2026-07-29
    switch, 77 seconds into the new process, 40 of 529 rules still reported
    health="unknown" with lastEvaluation="0001-01-01T00:00:00Z", among them the
    three that the fixed reconciler was still falsely reporting
    (AideChangesDetected, ProbeTargetChronicallyFailing,
    ServiceChronicallyUnavailable).

    So nagios_only now demands POSITIVE evidence that some ruler evaluated the
    rule and found its expression false. Absence of evidence -- rule unevaluated,
    rule absent, endpoint unreachable -- is never divergence. A genuinely dead
    rule is still caught: it evaluates fine and simply never matches, which is
    exactly the case this returns.

    Returns None on any error so the caller can distinguish "unknown" from empty.
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
    evaluated = set()
    for g in data.get("groups") or []:
        if not isinstance(g, dict):
            continue
        for r in g.get("rules") or []:
            if not isinstance(r, dict) or r.get("type") != "alerting":
                continue
            name = r.get("name")
            if not name:
                continue
            # An evaluated rule has a real timestamp and a health other than the
            # initial "unknown". Require both -- vmalert and the Loki ruler do not
            # render the zero time identically to Prometheus.
            last = r.get("lastEvaluation") or ""
            if not last or last.startswith("0001-01-01"):
                continue
            if r.get("health") == "unknown":
                continue
            evaluated.add(name)
    return evaluated


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

    # Fetch active/firing sets. Each datasource is independently fallible; a None
    # means "unknown" and suppresses the assertions that depend on knowing it.
    by_ds = {ds: fetch_active(url) for ds, url in RULER_ENDPOINTS.items()}
    rules_by_ds = {
        ds: fetch_evaluated(url) for ds, url in RULER_RULE_ENDPOINTS.items()
    }

    unreachable = sorted(
        ds
        for ds in RULER_ENDPOINTS
        if by_ds[ds] is None or rules_by_ds[ds] is None
    )

    # Alertnames some reachable ruler has actually evaluated at least once.
    evaluated_union = set()
    for ds_rules in rules_by_ds.values():
        if ds_rules is None:
            continue
        evaluated_union |= ds_rules
    if unreachable:
        # Previously this was entirely silent: a suppressed comparison left no
        # trace and was indistinguishable from a clean agreeing run.
        print(
            "nagios-mirror-divergence: ruler API unreachable (%s); nagios_only "
            "suppressed for this run" % ",".join(unreachable),
            file=sys.stderr,
        )

    # Union over reachable rulers. firing_union: name -> severity (info wins only
    # if every contributing entry is info). active_union: firing OR pending.
    firing_union = {}
    active_union = set()
    for ds_state in by_ds.values():
        if ds_state is None:
            continue
        active_union |= ds_state["active"]
        for name, sev in ds_state["firing"].items():
            if name not in firing_union or firing_union[name] == "info":
                firing_union[name] = sev

    nagios_only = []
    ruler_only = []
    unevaluated_skipped = 0

    if text is not None:
        # nagios_only: mirror HARD WARNING/CRITICAL whose alertname is not ACTIVE
        # (firing OR pending) on any ruler. (info mirrors map to OK by design and
        # thus never reach this branch.) UNKNOWN mirrors are skipped -- they mean
        # the datasource API was down, not a divergence.
        #
        # Guarded on ALL rulers being reachable. The module docstring has always
        # promised that an unreachable ruler is treated as "skip" rather than
        # divergence, but the code only ever implemented that for ruler_only: with
        # one ruler down, its alerts are absent from the union, so EVERY HARD
        # WARNING/CRITICAL mirror would be falsely reported as nagios_only.
        # any_ruler_up used to be computed and then explicitly discarded. This
        # was latent rather than active on 2026-07-29 (all three rulers answered
        # HTTP 200 throughout), but it is a real trap and it is now closed.
        if not unreachable:
            for name, st in mirror_states.items():
                if name in EXCLUDED_ALERTNAMES:
                    continue
                if st not in (1, 2):  # only WARNING/CRITICAL; OK/UNKNOWN skipped
                    continue
                # Require positive evidence the ruler evaluated this rule and found
                # it false. An unevaluated rule (every restart, for tens of
                # seconds) or one absent from the ruler entirely is not evidence of
                # a dead rule -- see fetch_evaluated().
                if name not in evaluated_union:
                    unevaluated_skipped += 1
                    continue
                if name not in active_union:
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
        # Makes the nagios_only suppression above observable instead of silent: a
        # nonzero value means this run could not assert nagios_only at all.
        "# HELP nagios_mirror_rulers_unreachable Ruler APIs that did not answer on the last reconciler run",
        "# TYPE nagios_mirror_rulers_unreachable gauge",
        "nagios_mirror_rulers_unreachable %d" % len(unreachable),
        # Mirrors held back purely because their rule was not evaluated yet. Non-zero
        # is normal for the first minute after a ruler restart and should return to 0;
        # a persistently non-zero value means a mirror exists for an alertname no
        # ruler is evaluating, i.e. tier 2 and the rule files have drifted apart.
        "# HELP nagios_mirror_unevaluated_mirrors Non-OK mirrors skipped because no ruler had evaluated their rule",
        "# TYPE nagios_mirror_unevaluated_mirrors gauge",
        "nagios_mirror_unevaluated_mirrors %d" % unevaluated_skipped,
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
