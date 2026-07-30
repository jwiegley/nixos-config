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

## 3. `for:` budget — the Nagios mirror caps out at 38 min (critical) / 95 min (warning)

`nagios-prometheus-mirror.nix:263-271` approximates each rule's `for:` as

    max_check_attempts = clamp(1 + ceil(for_minutes / retry_interval), 1, 20)

with `retry_interval` = **2 m for critical** (`standard-service`) and **5 m for warning/info**
(`low-priority-service`) — `:256-261`. Time to Nagios HARD state is `(mca - 1) × retry`, so the
clamp at 20 caps the mirror at **38 min for critical** and **95 min for warning/info**,
no matter how long `for:` is. Verified in the deployed cfg: `for: 30m → mca 16` (critical,
unclamped), `for: 1h → mca 13` (warning, unclamped), `for: 1h → mca 20` and `for: 3d → mca 20`
(both clamped).

**Budget: keep new `for:` ≤ 35 min on `severity: critical`, ≤ 90 min on warning/info.**

Consequence of exceeding it: mirror services in HARD CRITICAL are counted, with no PROM-MIRROR
exclusion, by `nagios-status-exporter.nix` into `nagios_services_critical_total`, and
`NagiosServicesCritical` (`alerts/nagios.yaml:42`, `for: 15m`, notifying) pages off that count.
A critical rule with `for: 2h` therefore pages via Nagios at ~53 min, an hour before Prometheus.
`check_prom_rule.py:164-170` maps critical → CRITICAL(2), warning → WARNING(1), info → OK(0), so
info-severity rules are exempt from this path.

Two measured corrections to older write-ups of this constraint:

- The blanket "≤ 90 min" figure is **only safe for warning/info**. Critical is capped at 38 min.
- The consequence is **not** a `NagiosMirrorDivergence` false alarm. Since 2026-07-29
  (`scripts/nagios-mirror-divergence.py:177-237`) a *pending* ruler alert counts as agreement,
  so a long `for:` no longer registers as `nagios_only`. The live consequence is the early
  Nagios page above, plus a mirror service showing non-OK for hours while Prometheus is quiet.

24 deployed mirrors already breach this (4 critical at `for: 1h`; 20 warning/info up to `for: 3d`,
which reaches HARD ~69 h early). Not fixed here — do not add more.

## 4. Every threshold ships with its measured over-threshold fraction

One range query per new threshold, over the longest window available, recorded in the commit or
a comment. Prometheus retention is `100y` and `ALERTS` reaches back to at least **2026-03-08**
(~144 d), so month-scale backtests are queryable today.

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

## The `for:` budget has a sanctioned escape hatch — use it instead of shortening a dwell

The dwell budget above exists because the Nagios mirror derives
`max_check_attempts = clamp(1 + ceil(for/retry), 1, 20)`. But a rule that legitimately needs a
long dwell must NOT be shortened to satisfy it — that trades a false-negative problem for a
false-positive one, which is the disease this page warns about elsewhere.

The supported answer is to exclude the rule from the mirror:

- `excludedAlertnames` — `modules/monitoring/services/nagios-prometheus-mirror.nix:131`
- `excludedFileKeys` — same file, `:136`
- both are applied by the `keptRules` filter at `:165-166`

An excluded rule keeps its Prometheus behaviour untouched and simply has no mirrored Nagios
service. The divergence checker skips excluded rules automatically (they are outside its
universe), so nothing else needs changing.

This is an established pattern, not a workaround: `Watchdog`, `ServiceStuckActivating` and
`BlackboxICMPIoTDeviceDown` are already excluded — and `BlackboxICMPIoTDeviceDown` is itself a
`for: 1h` rule, i.e. exactly the case the budget would otherwise forbid.
`docs/NAGIOS_PROMETHEUS_MIRROR_SPEC.md` §2.4 documents the mechanism and generalises the rule
for when to reach for it: any alert whose expr matches MANY series, where brief trueness is
normal, cannot be approximated by point sampling plus retries — exclude it rather than
distorting its dwell.

So the decision order is: (1) is the dwell genuinely needed? (2) if yes and it exceeds the
budget, exclude the alertname from the mirror. (3) Only shorten a dwell if the shorter value is
correct on its own merits.
