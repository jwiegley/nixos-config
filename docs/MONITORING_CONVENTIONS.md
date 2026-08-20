# Monitoring authoring conventions

Rules for writing a Prometheus / Loki / vmalert alert rule on vulcan. Every claim was measured
live on 2026-07-29/30 and names the file that enforces it, so you can re-verify rather than
trust this page. If a line here disagrees with the code, the code wins — fix this page.

## 1. Prove the metric exists before you write the rule

Mandatory first query, always this shape:

    count(last_over_time(<metric>[30d]))

Never a bare instant selector. Three verdicts, all real:

- **DEAD** — 0 over 30 d. The rule can never fire and will sit at `health=ok` forever.
- **CONDITIONAL** — non-zero over 30 d, 0 right now. Normal and correct for error counters,
  `state="failed"` matchers, and condition-gated textfile metrics. Live proof:
  `git_workspace_repo_age_seconds` = **51 series over 30 d, 0 at an instant** — per-repo series
  exist only while a repo is stale. An instant query would have called this dead.
- **LIVE** — non-zero now.

A bare comparison against a not-yet-existing metric stays inert until it appears; that is the
house convention for a rule landing before its producer.

## 2. Know which TSDB your rule reads

- `modules/monitoring/alerts/*.yaml` → Prometheus, `http://127.0.0.1:9090`
- `modules/monitoring/loki-rules/*.yaml` → Loki ruler, `http://127.0.0.1:3100` (30 d retention,
  `services/loki.nix:83`)
- `modules/monitoring/vm-alerts/*.yaml` → **VictoriaMetrics**, read endpoint
  `http://127.0.0.1:8428/api/v1/query` (vmalert `-datasource.url`) — 258 metric names, HA telemetry.

A query against Prometheus proves nothing about a `vm-alerts/` rule. Verify against the TSDB
the rule will actually be evaluated on.

## 3. `for:` is bounded by the phenomenon and nothing else — the old dwell budget is retired

There used to be an external cap. A second scheduler (the Nagios↔Prometheus mirror, removed
2026-07-31; Nagios itself 2026-08-19) approximated each rule's `for:` as check retries, which
clamped effective dwell at **38 min for critical / 95 min for warning-info** and could page
ahead of Prometheus on a long-dwell rule. That is why older write-ups — and older commit
messages — say "keep `for:` ≤ 35 min on critical, ≤ 90 min on warning/info". Nothing enforces
that any more, and no rule needs remediating for having breached it (24 did: 4 critical at
`for: 1h`, 20 warning/info up to `for: 3d`).

**Prometheus's `for:` is now the only dwell that exists, and it is authoritative.** Size it to
the phenomenon: long enough that a normal transient cannot fire it, short enough that the
condition still matters when the page arrives.

The one rule that survives the budget's retirement: **never shorten a dwell to satisfy something
other than the phenomenon.** A dwell cut to fit an external constraint trades a false-negative
problem for a false-positive one, which is the disease the rest of this page warns about. If a
rule legitimately needs `for: 1h` — `BlackboxICMPIoTDeviceDown` does, because brief trueness
across many series is normal there — give it `for: 1h`.

## 4. Every threshold ships with its measured over-threshold fraction

One range query per new threshold, over the longest window available, recorded in the commit or
a comment. "Longest available" is a measured date, not retention, and it differs per TSDB —
both are configured `100y`, so the binding limit is when data starts:

| TSDB | Data starts | Age on 2026-07-30 | How measured |
|---|---|---|---|
| Prometheus `:9090` | **2026-01-10** | ~202 d | `count(up)` is empty at 2026-01-09T12:00 and 88 at 2026-01-10T12:00; `count(ALERTS)` also answers from 2026-01-10 |
| VictoriaMetrics `:8428` (HA) | **2025-11-11** | ~261 d | `min(tfirst_over_time({__name__="°F_value"}[1000d]))` = 2025-11-11T10:33, identical for `%_value` and `W_value` |

`ALERTS` therefore backtests to 2026-01-10, not to the 2026-03-08 (~144 d) an earlier write-up
of this page claimed. Note `tfirst_over_time` is MetricsQL only — Prometheus rejects it
(`unknown function`); there, bracket the start with a `query_range` at `step=86400`.

Corollary — **size a seasonal threshold from the whole record, never a convenient window.**
The pool water-temperature series `°F_value{entity_id="water_sensor_1"}` holds **29,003 samples
from 2025-11-11**. A 14-day window is 5% of that record and a 90-day window ending in July lies
entirely inside the warm season — so both encode summer as normal, and a threshold fitted to
either fires all winter or never fires. The rule exists because this sensor family was mis-sized
twice on the record — first from 14 days, then from 90, both against the longer history that was
already there. Fit against the full record, and state in the commit which window you used.

Corollary — **never threshold the growth rate of a saturating stock.** `delta(<snapshot
residue>[7d]) > 100 GiB` was TRUE for 30 consecutive days of normal June operation and FALSE
through the entire five-day incident it was meant to catch: residue growth measures retention
ladder fill, not input rate.

## 5. Do not trust an average without counting the window's samples

Query `count_over_time(...)` alongside any `avg_over_time`. A **331-minute scrape gap on
2026-07-03** (1111 of 1440 expected 1-minute samples that day) silently corrupted a backtest by
collapsing a 6 h denominator. Nothing alerts on scrape-window completeness.

## 6. A transient can fall between rule evaluations

Scrape interval is 15 s; rule group intervals run 15 s / 30 s / 60 s / 300 s / 900 s / 3600 s.
A value that holds for one scrape is invisible to a 60 s+ group. For a success gauge that can
blip to 0, write `min_over_time(<metric>[1h]) == 0`, not `<metric> == 0`. A single-scrape zero
on a `*_last_success` was missed by the instant form and produced 60 consecutive firing samples
under `min_over_time`.

## 7. Alert names must be unique fleet-wide

Alertmanager groups and silences by `alertname`. Two rules sharing a name cannot be told apart
in one email and one silence covers both. Still live and unfixed: `CertificateExpiringSoon` and
`CertificateExpired` are each declared twice with **different exprs and different `for:`**
(`alerts/certificates.yaml` group `certificates` vs `alerts/health-checks.yaml` group
`certificate_alerts`). Check with

    grep -rhoP '^\s*-\s*alert:\s*\K\S+' modules/monitoring/{alerts,loki-rules,vm-alerts} \
      | sort | uniq -d

## 8. Never set `alertname` in a rule's `labels:`

Prometheus applies the rule's own name last, so a configured `alertname` is silently discarded —
and if `alertname` was the only label distinguishing the output series, they collapse and the
rule fails to evaluate. Reproduced with `promtool test rules`:

    rule: Sentinel, time: 0s, err: vector contains metrics with the same labelset
    after applying alert labels

That is `health=err`, which fails the `Prometheus rules: 0 health=err` check at
`scripts/post-reboot-validation.sh:402` (currently 0 err of 533 rules). If a rule needs to name
another rule, use the label **`rule`**. The annotation renders correctly in a dry run, so this
only surfaces in production.

## 9. Execution is not outcome

A `*_last_success` metric fed by `$SERVICE_RESULT == success` measures only *that the unit
exited*, not that the work happened. Whenever you add one, add in the **same commit**:

- a **work-floor counter** — a count of what the job actually produced — and alert on that, and
- for any new `.prom` textfile, a **last-completion-timestamp age rule**. A stale `.prom` serves
  its last value indefinitely and `node_textfile_scrape_error` stays 0, so staleness is
  otherwise undetectable.

No helper and no lint enforce this; it is on the author.

## 10. Do not "fix" a permanently-wrong metric by inverting it

A rule that can never fire and a rule that always fires are the same failure; delete the rule
and fix or drop the metric. Relatedly, an alert on a condition **with no owner** becomes
wallpaper within two weeks — that is why permanent-truth detectors are `severity: info`.

## 11. Two specific do-nots

- **Do not lower `Nginx5xxBurst` (>30 per 2 m) or `NginxUpstreamFailureBurst` (>10 per 2 m).**
  Both are deliberately tuned above the ~4000-502 websocket reconnect storm that every routine
  Home Assistant restart produces; the derivation lives in the code at
  `modules/monitoring/loki-rules/nginx-web.yaml:14-23,41-47`. Read it before retuning. Neither
  has fired in 30 d. Low-volume app 500s have their own lower-floor rule in the same file —
  extend that instead.
- **`restic_restore_verify_success` does not exist**, in Prometheus (0 series over 30 d) or
  anywhere in this repo outside prose. Restore verification is unimplemented: pack structure and
  hashes are verified, but nothing proves a restored file equals the original. Do not write a
  rule against that metric until something emits it.

## A rule is now evaluated exactly once — there is no second opinion

Until 2026-07-31 every rule in `modules/monitoring/{alerts,loki-rules,vm-alerts}/` was
re-evaluated by a second, independent scheduler, and a tier-3 reconciler alerted when the two
disagreed. Two consequences of that being gone are worth knowing when you author a rule:

- **A rule that cannot fire is now invisible to everything except a deliberate audit.** The
  second scheduler is what caught the 2026-06-09 class where 123 rules referenced metrics that
  did not exist. `systemd.services.prometheus-rule-audit`
  (`modules/monitoring/services/prometheus-rule-audit.nix`, source
  `scripts/prometheus-rule-audit.py`) replaces that capability hourly: it extracts the
  metric names each expr selects and asserts each has ≥1 series in the TSDB, plus stale
  evaluation, `health=err` and group-overrun checks. It is the only thing standing between a
  typo'd metric name and a wall of reassuring green — which is why §1 above is mandatory.
- **Nothing cross-checks the ruler's own liveness by re-deriving the answer.** That job falls
  to `Watchdog` (pipeline alive) and the post-reboot harness's rule-health check
  (`scripts/post-reboot-validation.sh`).
