#!/usr/bin/env python3
"""Detect Prometheus alert rules that CANNOT FIRE, and rules that stopped evaluating.

WHY THIS EXISTS

Until 2026-07-31 the Nagios<->Prometheus mirror re-evaluated every Prometheus expression
through a SECOND, independent scheduler. That is what caught the 2026-06-09 defect where 123
rules could never fire -- the core mistake being a metric named `systemd_unit_state` when the
exporter actually publishes `node_systemd_unit_state`. A rule selecting a metric that does
not exist is not an error to Prometheus: the query is valid, it simply returns no series, the
rule sits `inactive` forever, and the dashboard is a wall of reassuring green.

Removing the mirror removed that detector. This replaces it without a second scheduler.

WHAT IT CHECKS

1. DEAD RULES -- for every alerting rule, extract the metric names its expression selects and
   assert each one has at least one series in the TSDB. A rule referencing a metric with zero
   series can never fire. This is the mirror's headline capability and the reason this script
   exists.
2. STALE EVALUATION -- a rule whose `lastEvaluation` has not advanced is not being run, e.g.
   its group is wedged behind a slow query. Prometheus reports health `ok` regardless.
3. HEALTH -- any rule Prometheus itself marks `err`.
4. GROUP OVERRUN -- a group whose evaluation duration exceeds its own interval is falling
   behind and will silently skip evaluations.

WHAT IT DELIBERATELY DOES NOT DO

- It does not flag a rule merely for being `inactive`. Almost every rule is inactive almost
  always; that is a healthy system, not a dead rule. Deadness is a claim about the METRIC not
  existing, never about the alert not currently firing.
- It does not run promtool. Syntax is already enforced at build time by the flake check;
  re-checking it at runtime would only catch a store path nobody deployed.

METRIC-NAME EXTRACTION is a heuristic and is documented as such in the output: PromQL has no
public parser in the stdlib, so identifiers are taken as metric names unless they are
followed by `(` (a function call), are a PromQL keyword, appear inside a label matcher, or
are a bare number/duration. False POSITIVES are avoided by ignoring anything unresolvable;
the failure mode is under-reporting, never inventing a dead rule.

USAGE
    prometheus-rule-audit.py                 # write the textfile metrics
    prometheus-rule-audit.py --stdout        # print instead, for humans
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
import re
import sys
import tempfile
import time
import urllib.parse
import urllib.request

PROM = os.environ.get("PROM_URL", "http://127.0.0.1:9090")
TEXTFILE_DIR = os.environ.get(
    "TEXTFILE_DIR", "/var/lib/prometheus-node-exporter-textfiles"
)
OUTPUT = os.path.join(TEXTFILE_DIR, "prometheus_rule_audit.prom")

# Evaluation older than this means the rule is not being run.
STALE_EVAL_SECONDS = 900

# PromQL keywords, functions and aggregation operators. Anything here is NOT a metric name.
# Kept deliberately generous: a missing entry produces a false "dead rule", which is the one
# outcome this script must never produce.
NOT_METRICS = {
    "and", "or", "unless", "by", "without", "on", "ignoring", "group_left", "group_right",
    "offset", "bool", "start", "end", "atan2", "inf", "nan",
    "abs", "absent", "absent_over_time", "ceil", "changes", "clamp", "clamp_max",
    "clamp_min", "day_of_month", "day_of_week", "day_of_year", "days_in_month", "delta",
    "deriv", "exp", "floor", "histogram_quantile", "histogram_count", "histogram_sum",
    "holt_winters", "hour", "idelta", "increase", "irate", "label_join", "label_replace",
    "ln", "log2", "log10", "minute", "month", "predict_linear", "rate", "resets", "round",
    "scalar", "sgn", "sort", "sort_desc", "sqrt", "time", "timestamp", "vector", "year",
    "avg_over_time", "min_over_time", "max_over_time", "sum_over_time", "count_over_time",
    "quantile_over_time", "stddev_over_time", "stdvar_over_time", "last_over_time",
    "present_over_time", "mad_over_time",
    "sum", "min", "max", "avg", "group", "stddev", "stdvar", "count", "count_values",
    "bottomk", "topk", "quantile", "limitk", "limit_ratio",
}

# Identifiers that look like metrics but are label VALUES or matcher names in practice.
LABEL_CONTEXT = re.compile(r'[{,]\s*[A-Za-z_][A-Za-z0-9_]*\s*(=~|!~|=|!=)')


def get(path: str, params: dict | None = None):
    url = f"{PROM}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def metric_names(expr: str) -> set[str]:
    """Best-effort extraction of the metric names an expression selects."""
    # Strip string literals first -- they can contain anything.
    cleaned = re.sub(r'"[^"]*"|\'[^\']*\'', '""', expr)
    # Strip the interior of label matchers so matcher NAMES are not read as metrics.
    cleaned = re.sub(r"\{[^{}]*\}", "{}", cleaned)
    # Strip range/subquery brackets. A SUBQUERY is written [1h:5m], and the `:5m` half
    # matches the metric-name pattern (a leading colon is legal in a recording-rule name),
    # so it was reported as a missing metric for DNSQueryRateSpike/Drop on the first run.
    cleaned = re.sub(r"\[[^\[\]]*\]", "", cleaned)
    # Strip the LABEL LISTS of grouping/matching modifiers. Without this, `by (job, instance)`
    # and `on(instance) group_left(vm)` yield `job`, `instance`, `vm`, `__name__` as
    # "metrics", every one of which has zero series -- which reported 66 healthy rules as
    # dead on the first run. The modifier keywords were already excluded; their ARGUMENTS
    # were not.
    cleaned = re.sub(
        r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)",
        r"\1()",
        cleaned,
    )

    out: set[str] = set()
    for m in re.finditer(r"\b([a-zA-Z_:][a-zA-Z0-9_:]*)\b", cleaned):
        name = m.group(1)
        if name in NOT_METRICS:
            continue
        # A following '(' means it is a function call, not a selector.
        tail = cleaned[m.end():].lstrip()
        if tail.startswith("("):
            continue
        # Durations like 5m / 1h30m are not metrics.
        if re.fullmatch(r"\d+[smhdwy]", name):
            continue
        out.add(name)
    return out


def parse_rfc3339(value: str) -> float | None:
    """Epoch seconds from Prometheus' lastEvaluation, or None if unparseable.

    Prometheus emits a LOCAL time with an explicit offset and NANOSECOND precision, e.g.
    `2026-07-31T15:24:55.894214582-07:00`. Two traps, both hit on the first run:
      - truncating to 19 chars discards the offset, so a UTC reading is wrong by the local
        offset and every rule reads as ~7h stale. All 508 were reported stale.
      - datetime.fromisoformat accepts at most 6 fractional digits, so the 9 digits here
        raise ValueError and the check silently degrades to "never stale".
    So: keep the offset, clamp the fraction to microseconds.
    """
    m = re.match(r"^(.*?T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$", value.strip())
    if not m:
        return None
    frac = (m.group(2) or "")[:7]          # '.' + up to 6 digits
    off = (m.group(3) or "")
    if off == "Z":
        off = "+00:00"
    try:
        return datetime.fromisoformat(f"{m.group(1)}{frac}{off}").timestamp()
    except ValueError:
        return None


def series_exists(metric: str, cache: dict[str, bool]) -> bool:
    if metric in cache:
        return cache[metric]
    try:
        d = get("/api/v1/query", {"query": f"count({metric})"})
        ok = bool(d.get("data", {}).get("result"))
    except Exception:
        # Unresolvable -> treat as EXISTS. Under-report rather than invent a dead rule.
        ok = True
    cache[metric] = ok
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdout", action="store_true")
    a = ap.parse_args()

    now = time.time()
    lines: list[str] = []
    dead: list[tuple[str, str, str]] = []
    stale: list[tuple[str, str]] = []
    errored: list[tuple[str, str]] = []
    overrun: list[tuple[str, float, float]] = []
    scrape_ok = 1

    try:
        rules = get("/api/v1/rules")
    except Exception as e:  # noqa: BLE001
        print(f"rule audit: cannot reach Prometheus at {PROM}: {e}", file=sys.stderr)
        scrape_ok = 0
        rules = {"data": {"groups": []}}

    # Prometheus uptime, used to suppress the warmup false positive above. If it cannot be
    # determined, `never_run` is never treated as stale -- fail quiet rather than page on
    # every restart.
    uptime: float | None = None
    try:
        # NOT prometheus_start_time_seconds -- that name has 0 series here (checked). The
        # process collector's series, scoped to the prometheus job, is the one that exists.
        d = get(
            "/api/v1/query",
            {"query": 'time() - process_start_time_seconds{job="prometheus"}'},
        )
        res = d.get("data", {}).get("result", [])
        if res:
            uptime = float(res[0]["value"][1])
    except Exception:
        uptime = None

    cache: dict[str, bool] = {}
    total = 0

    for g in rules.get("data", {}).get("groups", []):
        gname = g.get("name", "?")
        gfile = re.sub(r"^[a-z0-9]{32}-", "", os.path.basename(g.get("file", "?")))
        interval = float(g.get("interval", 0) or 0)
        duration = float(g.get("evaluationTime", 0) or 0)
        if interval and duration > interval:
            overrun.append((f"{gfile}/{gname}", duration, interval))

        for r in g.get("rules", []):
            if r.get("type") != "alerting":
                continue
            total += 1
            name = r.get("name", "?")

            if r.get("health") == "err":
                errored.append((name, gfile))

            # STALENESS IS RELATIVE TO THE GROUP'S OWN INTERVAL, and is suppressed during
            # warmup. Two false-positive modes, both hit on the first run:
            #
            #  - A group with interval=3600s is legitimately 59 minutes past its last
            #    evaluation. A flat 900s threshold calls every hourly group stale.
            #  - Immediately after a Prometheus restart a not-yet-ticked group reports
            #    lastEvaluation = 0001-01-01T00:00:00Z and evaluationTime = 0. That is
            #    "not run YET", not "stopped running". security_system_age (interval 3600s)
            #    was reported stale for exactly this reason, right after a switch.
            #
            # So: allow 3 missed intervals, floor at STALE_EVAL_SECONDS, and ignore the zero
            # timestamp until Prometheus itself has been up longer than two intervals.
            threshold = max(STALE_EVAL_SECONDS, 3 * interval) if interval else STALE_EVAL_SECONDS
            last = r.get("lastEvaluation")
            ts = parse_rfc3339(last) if last else None
            never_run = ts is not None and ts < 0  # 0001-01-01 predates the epoch
            if never_run:
                if uptime is not None and interval and uptime > 2 * interval:
                    stale.append((name, gfile))
            elif ts is not None and (now - ts) > threshold:
                stale.append((name, gfile))

            for metric in metric_names(r.get("query", "")):
                if not series_exists(metric, cache):
                    dead.append((name, gfile, metric))

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    # The label is `rule`, NOT `alertname`. An alerting rule applies its OWN alertname label
    # to every sample it selects, overwriting one of the same name on the metric. The three
    # DnsQueryExporter* entries differ only by that label, so they collapsed into a single
    # labelset and Prometheus marked the rule health=err:
    #   "vector contains metrics with the same labelset after applying alert labels"
    lines.append(
        "# HELP prometheus_rule_audit_dead_rule An alerting rule selecting a metric "
        "with zero series; it can never fire."
    )
    lines.append("# TYPE prometheus_rule_audit_dead_rule gauge")
    for name, gfile, metric in dead:
        lines.append(
            f'prometheus_rule_audit_dead_rule{{rule="{esc(name)}",file="{esc(gfile)}",missing_metric="{esc(metric)}"}} 1'
        )

    for metric_name, help_text, value in (
        ("prometheus_rule_audit_dead_rules_total", "Alerting rules that can never fire.", len(dead)),
        ("prometheus_rule_audit_stale_rules_total", "Alerting rules whose lastEvaluation has not advanced.", len(stale)),
        ("prometheus_rule_audit_error_rules_total", "Alerting rules Prometheus marks health=err.", len(errored)),
        ("prometheus_rule_audit_group_overrun_total", "Rule groups whose evaluation exceeds their interval.", len(overrun)),
        ("prometheus_rule_audit_rules_checked_total", "Alerting rules examined.", total),
        ("prometheus_rule_audit_up", "1 if the audit reached Prometheus and completed.", scrape_ok),
    ):
        lines.append(f"# HELP {metric_name} {help_text}")
        lines.append(f"# TYPE {metric_name} gauge")
        lines.append(f"{metric_name} {value}")

    lines.append("# HELP prometheus_rule_audit_last_run_timestamp_seconds Unix time of the last completed audit.")
    lines.append("# TYPE prometheus_rule_audit_last_run_timestamp_seconds gauge")
    lines.append(f"prometheus_rule_audit_last_run_timestamp_seconds {now:.0f}")

    body = "\n".join(lines) + "\n"

    if a.stdout:
        print(body, end="")
        for name, gfile, metric in dead:
            print(f"DEAD  {name} ({gfile}) -> missing metric: {metric}", file=sys.stderr)
        for name, gfile in stale:
            print(f"STALE {name} ({gfile})", file=sys.stderr)
        return 1 if (dead or errored) else 0

    # Atomic write: the node exporter must never read a half-written file.
    os.makedirs(TEXTFILE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=TEXTFILE_DIR, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        os.chmod(tmp, 0o644)
        os.replace(tmp, OUTPUT)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
