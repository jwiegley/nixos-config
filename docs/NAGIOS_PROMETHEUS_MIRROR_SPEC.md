# Nagios ⇄ Prometheus Reverse Mirror — Design Spec

**Status:** **implemented and live** (verified 2026-07-27) — all seven files in
the §7 manifest exist, tiers 1–2 are imported at `hosts/vulcan/default.nix:168-169`
and tier 3 at `modules/monitoring/services/default.nix:28`. Live figures on
2026-07-27: 483 `PROM-MIRROR` services in `status.dat` (480 rule mirrors + the 3
per-datasource API health checks) out of 830 Nagios services total;
`nagios_mirror_divergence_total` = 0 in both directions and
`nagios_mirror_reconciler_success` = 1. The design below is the as-built
description; the counts inside it are the 2026-06-10 recon snapshot, not today's.
Original operator directive 2026-06-10: "I want there to be 100% duplication.
Each is a check and validation of the other."
**Companion:** docs/MONITORING_DEFERRED_SPECS.md (#nagios-topology-decision),
memory `feedback_nagios_prometheus_duplication`.

## 1. TL;DR

Prometheus-side coverage of Nagios already exists (the status.dat bridge). This
project closes the reverse direction: **every Prometheus, Loki, and
VictoriaMetrics alert rule gets a Nagios service check, generated at build
time from the same rule files** — so the duplication is 100% *by construction*
and can never drift. Three tiers:

- **Tier 2 (the bulk, ~422 checks):** a generic `check_prom_rule` plugin
  re-evaluates each rule's expression through Nagios's own scheduler,
  severity mapping, and notification path. This is an independent *alerting
  pipeline* over the same data: it would have caught the 2026-06-09
  dead-rules class (123 rules that could never fire) on day one, and it
  catches a wedged Prometheus ruler, broken Alertmanager routing, or a
  silently-failing rule file.
- **Tier 1 (independent measurement, ~95 checks):** for the highest-value
  classes Nagios measures *without* touching any Prometheus API: file-age
  staleness of every textfile-collector output, `systemctl is-active` for the
  units Prometheus watches but Nagios doesn't, and `check_http` for the
  ~29 nginx vhosts only blackbox probes today.
- **Tier 3 (divergence detection, 1 exporter + 2 rules):** a 5-minute
  reconciler comparing Nagios mirror hard-states against the three rulers'
  firing sets, alerting on sustained disagreement in either direction. This
  is the actual "each validates the other" payoff: a rule firing in one
  stack but not the other is itself an alert.

Inventory (recon 2026-06-10): 484 alert rules across 62 files — 449 in
`modules/monitoring/alerts/` (Prometheus), 29 in `modules/monitoring/loki-rules/`
(Loki ruler), 6 in `modules/monitoring/vm-alerts/` (vmalert on the VM TSDB).
422 mirror, 55 already independently checked by Nagios, 7 excluded.

## 2. Tier 2 — the rule mirror (generator + plugin)

### 2.1 Generation (build time, zero drift)

New module `modules/monitoring/services/nagios-prometheus-mirror.nix`:

1. `builtins.readDir` over the three rule directories (mirroring
   `alerting.nix`'s auto-discovery — a NEW rule file is mirrored
   automatically on the next rebuild).
2. Each YAML is converted to JSON in a tiny `pkgs.runCommand` using
   `remarshal` (or `yq-go`), then `builtins.fromJSON (builtins.readFile …)`
   (import-from-derivation). IFD is acceptable here: the repo builds locally,
   and `services.nagios.validateConfig = true` already runs build-time
   machinery. **Fallback if IFD ever becomes a problem:** a checked-in
   generated JSON + a drift assertion; noted, not implemented.
3. For every rule: emit one `define service` block + one `pkgs.writeText`
   **query file** holding the expr verbatim (multi-line block scalars — 79
   rules — work untouched; query files sidestep all Nagios `$ARG$`/shell
   escaping). Exprs contain no secrets (they are public repo content) so
   nix-store world-readability is fine.
4. All mirror services attach to `host_name vulcan`, servicegroup
   `prometheus-mirror`, `service_description "PROM-MIRROR <alertname>"`
   (de-duplicated with a `-2` suffix on alertname collisions).
5. Appended via `services.nagios.objectDefs = [ blob ]` — the existing
   satellite-module pattern; nixpkgs merges list options, and the build-time
   `nagios -v` validation fails the rebuild on any malformed generated object.

### 2.2 The plugin

`scripts/check_prom_rule.py` (wrapped with `pkgs.writers.writePython3Bin`,
house pattern):

```
check_prom_rule --datasource {prometheus|loki|vm} --query-file <store path>
                --severity {critical|warning|info} [--retry-on-refused]
```

- Endpoints: prometheus `127.0.0.1:9090/api/v1/query`, loki
  `127.0.0.1:3100/loki/api/v1/query` (instant LogQL; `count_over_time`
  instant queries return a vector), vm `127.0.0.1:8428/api/v1/query`
  (PromQL-compatible).
- Non-empty result vector ⇒ the condition holds: `critical → CRITICAL(2)`,
  `warning → WARNING(1)`, `info → OK(0)` with output
  `"INFO condition active (visibility only): N series"` — the 16
  info-severity rules never page, matching the Prometheus side.
- Empty result ⇒ `OK`. HTTP/parse failure ⇒ `UNKNOWN(3)` after **one 5s
  retry** on connection-refused (rides out a ruler restart during a switch).
- Output is **series counts only** — never label values (no leak vector).

### 2.3 Severity, `for:`, and load mapping

- Service template by severity: `critical → standard-service` (5 min
  interval), `warning|info → low-priority-service` (15 min). We deliberately
  do NOT use the 2-min `critical-service` template: 422 mirrors must respect
  the host's single check worker (`check_workers=1`, a deliberate ARM64
  SEGV workaround). Expected added load ≈ 1.2–1.8 checks/s peak × ~100 ms
  per local HTTP query ⇒ <25% of the worker; watch
  `nagios_stale_results_total` after rollout.
- `for:` is approximated by soft states:
  `max_check_attempts = clamp(1 + ceil(for / retry_interval), 1, 20)` with
  the template's `retry_interval` (2 min). `for: 0m` ⇒ 1 attempt (immediate
  hard state). The approximation is documented per-service in a comment line.
- **Notification-storm guard:** one `"PROM-MIRROR <ds> API"` health check per
  datasource (`check_http` on 9090/3100/8428) plus a `define servicedependency`
  from every mirror in that datasource with
  `execution_failure_criteria u,c` / `notification_failure_criteria u,c,w` —
  when the ruler API is down, Nagios suppresses mirror checks/notifications
  instead of emitting 422 UNKNOWNs. The API-down condition itself pages (and
  is also independently covered by tier 1 / existing checks).

### 2.4 Exclusions (explicit list in the module)

- `Watchdog` (meta-monitoring.yaml) — fires-by-design dead-man; mirroring is
  meaningless.
- `ServiceStuckActivating` (systemd.yaml, added 2026-06-11) — un-mirrorable
  by instant sampling. The expr is a broad multi-series selector where
  short-lived `activating` blips are normal (a dozen frequent exporter
  oneshots each spend seconds-to-a-minute activating, many times an hour).
  The ruler's `for: 15m` requires ONE series continuously true; the mirror's
  max_check_attempts emulation only sees "some series true" at sparse 5-min
  instants, so a rotating cast of unrelated blips reads as one sustained
  condition. Observed 2026-06-11: two HARD WARNINGs (04:26, 06:31) on
  different exporters each sample — two ~45m `nagios_only` divergences —
  while the ruler stayed correctly silent; the one genuine 17-minute event
  (02:00 postgresql-backup) was missed to sampling phase. The general
  lesson: any rule whose expr matches MANY series where brief trueness is
  normal cannot be approximated by point sampling + retries; exclude it.
- `BlackboxICMPIoTDeviceDown` (network.yaml, added 2026-06-12) — same class
  as ServiceStuckActivating. The expr spans the sleepy Wi-Fi IoT fleet
  (host_group="iot", ~17 devices) probed by single-shot ICMP (5s at
  observation; 10s same-day via icmp_ping_iot — softens but cannot
  eliminate the class); power-save wakeup latency (ring-doorbell measured
  0% real loss yet 1.2s avg / 2.9s max RTT) makes per-instant blips
  routine, so at nearly every
  sample SOME device reads as down. The ruler's `for:` (10m when this was
  written; widened to `1h` in commit 2b02e8c, still 1h as of 2026-07-27)
  requires ONE
  device continuously down; the mirror latched HARD WARNING for hours on a
  rotating cast (13 distinct devices in 2h, ≥1 failing at every 10-min
  sample, observed 2026-06-12) while the ruler stayed correctly silent —
  chronic `nagios_only` divergence, surfacing two days after the IoT
  blackbox probes landed (eeeb3d5). Coverage retained: the live ruler rule
  plus the native Nagios PING services on the IoT fleet.
- All 6 rules in `nagios.yaml` — Nagios checking "is Nagios up" through its
  own scheduler is circular; the Prometheus side owns those.
- (That is the complete list — 9 rules. Everything else mirrors, including
  the 13 `absent()`-based dead-man rules, which evaluate correctly through
  the query API. Tier 3 needs no parallel list: an excluded rule has no
  mirror service, so it is outside the reconciler's universe in both
  directions by construction.)

## 3. Tier 1 — independent measurements

New module `modules/monitoring/services/nagios-tier1-mirror.nix` (separate
from tier 2 so the IFD machinery and the hand-curated lists don't mix):

1. **Textfile-collector freshness (~46 checks):** `check_file_age` (from
   `monitoring-plugins`) on every live `.prom` in
   `/var/lib/prometheus-node-exporter-textfiles/`, threshold = 3× the
   writer's cadence (floor 10 min; daily ⇒ 26 h; weekly CVE ⇒ 8 d;
   event-driven backup writers anchored to their OnCalendar; the two
   self-heal daemon files get a generous 2 h). This independently detects a
   dead collector even if Prometheus, its scrape, AND its staleness rules are
   all broken — pure cross-validation. The recon's collector/cadence table is
   baked into the module as data. **Excludes** the two orphaned files
   (`paperless.prom`, `paperless_ai.prom`, writers removed Nov 2025) — these
   are deleted at deploy time instead.
2. **systemd unit gap (~17 checks):** `check_systemd_service` (command
   already defined globally in nagios.nix — reused, not redefined) for the
   units Prometheus watches via `node_systemd_unit_state` that Nagios's 97
   covered units miss (recon list: prometheus-blackbox-exporter,
   NetworkManager, podman.socket, the restic-backups timers, budget-board-pod,
   etc.).
3. **nginx vhost gap (~29 checks):** `check_http -S --sni` against the local
   vhosts that only blackbox probes today (Prometheus probes 42+, Nagios 13).
   The vhost list is duplicated as plain data in the module with a
   keep-in-sync comment; tier 3 catches semantic drift, and the two auth-only
   vhosts reuse the existing auth pattern or are skipped with a comment.

Ownership note: `.prom` files are 0644 under a 0755 dir regardless of owning
user, so `check_file_age` works as the nagios user; no permission changes.

## 4. Tier 3 — divergence detection

New `modules/monitoring/services/nagios-mirror-divergence.nix` (pattern:
nagios-status-exporter — root oneshot + 5 min timer + textfile):

1. Parse `/var/lib/nagios/status.dat` for `PROM-MIRROR *` servicestatus
   blocks → alertname → hard state (soft states ignored).
2. Fetch firing sets: Prometheus `/api/v1/alerts`, Loki ruler
   `/prometheus/api/v1/alerts`, vmalert `:8880/api/v1/alerts`.
3. Emit counts: `nagios_mirror_divergence_total{direction="nagios_only"}`
   (mirror hard-CRITICAL/WARNING but ruler not firing ⇒ **the ruler-side rule
   is broken/dead** — the 123-dead-rules class) and
   `{direction="ruler_only"}` (firing but mirror OK ⇒ the mirror is broken),
   plus `nagios_mirror_checks_total` and a parse-success gauge. Alertnames
   only (public), never label values.
4. Alert rules in `modules/monitoring/alerts/nagios-mirror.yaml`:
   `NagiosMirrorDivergence` (warning, `for: 30m` — state-machine timing skew
   between the stacks makes transient divergence NORMAL; only sustained
   disagreement is real) and `NagiosMirrorReconcilerStale`. (As built there is
   a third rule, `NagiosMirrorReconcilerFailed` —
   `modules/monitoring/alerts/nagios-mirror.yaml:17,40,53`.) Info-severity
   rules and the exclusions (§2.4) are skipped in the comparison. These rules
   are themselves auto-mirrored into Nagios by tier 2 — harmless, and means
   Nagios also sees the divergence.

## 5. Rollout & verification

1. Build (the build-time `nagios -v` validates all ~520 generated objects);
   switch reloads Nagios.
2. Verify: live service count ≈258 → ≈780 in status.dat; UI loads; the
   `prometheus-mirror` servicegroup paginates; no mass CRITICALs (expected
   mirror-firing set == current Prometheus firing set: Watchdog excluded, so
   ≈ ExposedImageFixableHighCVE which maps to OK/info);
   `nagios_mirror_divergence_total` == 0 within two cycles; check latency /
   `nagios_stale_results_total` stays 0.
3. Soak: the daily Nagios report truncates at 50 state changes — acceptable;
   the existing bridge (`nagios_services_critical_total`) now also carries
   mirror states into Alertmanager automatically, which is the intended
   recursion (a hard mirror CRITICAL pages through BOTH stacks).
4. Rollback: revert the three module imports; Nagios reloads with the old
   object set; nothing else is touched.

## 6. Security

- Plugin and reconciler query loopback APIs only, unauthenticated (existing
  posture); they emit counts and alertnames only — never label values, never
  log bodies, never query-result payloads.
- Generated query files land in the nix store (world-readable): rule exprs
  are already public repo content; nothing secret may ever be embedded in an
  alert expr (house rule, already true of all 484).
- No new listening ports; no new privileged users (reconciler runs as root
  like nagios-status-exporter, read-only against status.dat + loopback HTTP).
- The private `nagios/hosts.nix` is untouched; all new checks attach to
  `host_name vulcan`.

## 7. Effort & file manifest

| File | Role |
|---|---|
| `scripts/check_prom_rule.py` | tier-2 plugin (writePython3Bin) |
| `modules/monitoring/services/nagios-prometheus-mirror.nix` | tier-2 IFD generator (≈422 services + 3 API checks + dependencies + servicegroup) |
| `modules/monitoring/services/nagios-tier1-mirror.nix` | tier-1 file-age / systemd-gap / vhost-gap checks (≈95 services) |
| `modules/monitoring/services/nagios-mirror-divergence.nix` | tier-3 reconciler exporter |
| `scripts/nagios-mirror-divergence.py` | tier-3 parser/comparator |
| `modules/monitoring/alerts/nagios-mirror.yaml` | tier-3 alert rules (auto-discovered) |
| `hosts/vulcan/default.nix` | tier-1 + tier-2 imports (`:168-169`); as built, tier 3 is imported from `modules/monitoring/services/default.nix:28` instead |

Estimated: tier 2 ≈ 4 h, tier 1 ≈ 2 h, tier 3 ≈ 2 h, verify/soak ≈ 1 h.
