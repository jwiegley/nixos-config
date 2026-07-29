# vulcan — Remediation Plan for the 2026-07-28 Health Audit

**Author:** sequencing agent · **Date:** 2026-07-28 · **Status:** PLAN ONLY — nothing in this document has been applied.

**Live-verification stance.** Every PromQL/LogQL expression in this plan was executed against the live
Prometheus (`:9090`) or Loki (`:3100`) at plan time, or was executed by the cluster design agent and
re-checked here. Where an expression could not be run because the metric does not exist yet, it is
marked **UNVERIFIED (metric absent by design)** and the plan states what must be observed before the
rule ships. Two design claims were **corrected** during this pass and are called out inline:
`zfs_dataset_used_by_children_bytes` does not exist today (so the naive amplification proxy is
contaminated by 6 parent datasets), and `api_errors_total` **does** exist over a 30-day window (so
triage M-09's "delete" verdict is reversed).

---

## 1. Executive summary

vulcan is not broken; vulcan is **unobservable in the ways that matter**. The audit found 116 issues,
but they collapse into one shape: *a component fails, every layer above it reports success, and the
only trace is somewhere nobody looks.* The three archetypes are (a) the PostgreSQL backup dataset
holding **1,736.7 GiB of snapshots against 40.3 GiB of live data** (43.1×, verified) and driving the
pool toward the 80% knee with no alert on amplification; (b) the flume weekly cross-check hitting a
real SQL error and **still exiting 0**, so its `$SERVICE_RESULT`-driven alert can never fire; (c) the
Gitea→GitHub push mirror failing **every single day for 10 days** while three units reported success,
recorded only as an HTTP 500 in an nginx log. Underneath those sit ~40 alert rules that are
structurally incapable of firing, a daily health report that never queries `ALERTS` (so four
multi-hour criticals — copyparty 22.6 h, UnexpectedWildcardListener 24.7 h, NagiosMirrorDivergence
21.75 h, a 47-restart openclaw storm — went unread), and 414 emails/week of chronic noise that would
have buried them anyway.

This plan lands in **7 phases, 76 items**. Phase 1 stops the storage bleed *before* Phase 3 adds the
metrics that measure it. Phase 2 repairs or deletes every rule proven unfireable — including three
that adversarial review showed the triage got **wrong** (deleting them would have destroyed live
coverage). Phase 3 closes the three archetypes with detectors backtested against the actual incidents.
Phase 4 rewrites the daily report (`scripts/log-summarizer.py`) so alert history, invariant checks and
rule-liveness are deterministic sections that an LLM cannot suppress. Phase 5 cuts notification volume
by an estimated **~55%** by resolving two standing conditions rather than by muting anything real.
Phase 6 adds coverage for the subsystems nobody was watching (UPS behind an automated `poweroff`, Home
Assistant's entire log stream, per-cgroup memory, sudo). Phase 7 is backup integrity and hygiene.
Where an adversary proved a proposed fix could not work — the `if ! ( … )` restic isolation that
*silently masks* failures, the tmpfiles glob janitor that deletes nothing, the `staging` dataset with
`mountpoint=legacy` that would silently dump onto the root NVMe, the dead-rule sentinel that goes
`health=err` on its own labels — the plan carries the **corrected** form and says so.

---

## 2. What was already fixed on 2026-07-28 (do not re-plan)

| # | Change | Verified state | Residue this plan must handle |
|---|---|---|---|
| 1 | **Discord-token-shaped test fixtures removed** from tracked files (commit `8762657d`), pushed. | Fixtures gone from the working tree. | **Root problem untouched.** The token is still in git *history*; the Gitea repo is **public** and served it for ~69 days; the GitHub mirror is still blocked (144 × `GITHUB PUSH PROTECTION` per 2 days). → decisions **D1** (rotate) and **D2** (history). Detection → **M-01**. |
| 2 | **`/etc/nixos` added to the restic `Backups` B2 job** via `extraPaths` (`modules/storage/backups.nix:213`). | Broader than reported: `secrets/` and `nagios/` live *under* `/etc/nixos` on disk and no path component collides with `backupExcludes`, so the SOPS store and private network topology now reach B2 encrypted. | Materially reduces D2's urgency. The git-*history* mirror is what remains. |
| 3 | **`WebServiceDown` excludes `job="blackbox_https_public"`** (commit `9d4ad5b6`). | Confirmed live in `/api/v1/rules`: `job!="blackbox_https_public"`, `for: 60`. | **REGRESSION.** `PublicEdgeDown` (`for: 10m`) now solely owns that job, and the longest recorded public-edge outage is **3.8 min** — verified it reached `pending` 11 times and never fired during the 07-28 incident. Its own annotation says "more than 5 minutes". → **M-17R**. Note `HostUnreachable` still matches those 2 targets (`job=~"blackbox_.*"`, no exclusion) and **did** fire critical on both, so the commit halved the emails without removing critical paging. |
| 4 | **`usb-storage.quirks=1e91:a4a7:u`** UAS-disable mitigation **is applied and active** (in `/proc/cmdline`; all four disks bound to `usb-storage`; `uas` at refcount 0). | Applied — project memory still says "offered, not applied". | Two of the five UAS Loki patterns are now **dead by construction**. → **D-14/S-05R** (BOT-mode vocabulary), **A-03** (memory correction). |
| 5 | **hermes microVM runs on 1 vCPU deliberately** — `vcpu=4` was tried and reverted with rationale at `hermes-vm.nix:357-370`. | Confirmed. | Memory still calls it "staged, needs switch". → **A-03**. |
| 6 | **`aide-update.service` IS wired and DOES run** — triggered post-rebuild by `system.activationScripts.aide-post-rebuild` via `systemd-run --on-active=60` (`aide.nix:318-325`); 14,184 journal lines/7 d; `aide.db` mtime today. | The audit's "wired to nothing" claim is **REFUTED**. | Only the `aide-metrics` / `aide-check` ordering race is real (metrics exits 00:00:15, check exits 00:01:48 — 93 s early). → **M-20R**. |
| 7 | **`ee03dd75` deliberately disabled the two Schwab token alerts**, with the cost stated in the commit message. | Confirmed; agent `schwab-alert-disable` active this session. | → decision **D3** and **A-U1s**. |
| 8 | **`ServiceStuckActivating` needs no change** — already `for: 900s`, which a 60 s oneshot cannot satisfy, and already excludes known long-activating units. | The audit's own verifier marked this REFUTED. | None. |
| 9 | **`technitium_dns_status = 0` is the SUCCESS code** (the shipped dashboard maps 0 → green). | No exporter defect. | Genuine residue is `technitium_dns_update_available` pinned at `-1`. → **M-10R**. |
| 10 | **The 10 s ICMP ceiling on `iot`/`iot-noping`/`iot-quiet` is deliberate** (`blackbox-monitoring.nix:633-644`, long-timeout module, `scrape_timeout` raised to 12 s). The 3 permanently-silent Nests are registered non-responders, correctly excluded. | Confirmed. | Do not "fix". |
| 11 | **`ImmichAPIHighMemoryUsage` is NOT dead** — `process_memory_usage{job="immich-api"}` returns 1 series; `otel_scope_version` is a `without()` label. | Confirmed. | Excluded from the dead-rule work. |

**Two corrections to the audit's own alert-fatigue arithmetic**, which change the remedy:

* The **1,958 webhook notifications/7 d are NOT flapper-driven** — they are the by-design Watchdog
  dead-man heartbeat (`watchdog-deadman` receiver, `repeat_interval=4m` → ~11.7 posts/h). Only the
  **405–414 emails** are real notification volume. Do not "fix" the webhook count.
* The "~430 discrete 5-minute firing episodes" mechanism is **wrong**. `changes(aide_changes_detected[7d]) = 6`
  — the gauge does not flap. The `ALERTS` sample counts (AideChangesDetected 272,
  ConfigFileChangedOutsideDeploy 393) × the 15-minute group interval reproduce **68 h and 98 h of
  SUSTAINED firing**, matching `avg_over_time` of 0.426 and 0.600 exactly. The remedy is therefore to
  **resolve the two standing conditions** (M-20R, M-21), not to adjust dwell.

---

## 3. Phase plan

Ordering rule: **(a) stop active data loss/growth → (b) restore broken detection → (c) add new
detection → (d) hygiene**, with the hard constraint that *items which shrink data ship before items
that measure it* (Phase 1 before Phase 3), so the new gauges are not calibrated against a
pathological baseline.

| Phase | Title | Items | Gate |
|---|---|---|---|
| 1 | Stop the storage bleed | 4 | Rebuild; one full dump cycle; snapshot delta collapses |
| 2 | Restore broken detection (dead-rule sweep) | 19 | Rebuild; 534 → ~512 rules, 0 `health=err`, every repaired selector non-empty |
| 3 | Close the three archetypes | 7 | Rebuild; each new metric present; each new rule `health=ok`; fault-injection |
| 4 | Daily-report redesign | 9 | Manual generator run; section diff; email delivery confirmed |
| 5 | Alert fatigue: routing + standing conditions | 4 | 7-day `alertmanager_notifications_total` re-measure |
| 6 | New coverage for unmonitored subsystems | 17 | Rebuild; per-job Loki deadman; new exporters scraped |
| 7 | Backup integrity + hygiene | 16 | Restic negative test; permission audit; `systemctl --failed` empty |

**Effort totals:** **trivial 34 · small 33 · medium 9 · large 0 · 76 items.** There is no "large" item
left: the two that were sized large (C-05R, M-91R) were re-scoped after measurement — HA's error-shaped log
volume is ~40 lines/day, and the HA availability exporter is one SELECT in the textfile pattern this repo already
uses ~15 times.

**Not shipped as designed:** **14** items carry a `REVISED` tag because adversarial review proved the original
form could not work (or would silently make things worse); **6** were moved out of scope with the reason recorded
in §9. Nothing broken was quietly kept.

---

### PHASE 1 — Stop the storage bleed

*Goal: stop the PostgreSQL backup dataset regenerating ~600 GB/month of unshared snapshot residue, and
stop the litellm table that drives it, **before** Phase 3 adds the gauges that measure both.*

**Why first:** `tank` is at 70% CAP growing +1.098 TB/30 d; the 80% ZFS performance knee is ~2.9
months out. `tank/Backups/PostgreSQL` alone is **1,736.7 GiB of snapshots on 40.3 GiB of live data**
(verified via the exporter's own `usedbysnapshots` property, see S-01R). Calibrating a growth alert
against this baseline would encode the pathology as normal.

---

#### S-02R — Make the already-configured LiteLLM spend-log retention actually elapse
`REVISED — adopted adversary revision (interval 6h→1h + restart-independent timer + missing observable)`

| Field | Value |
|---|---|
| **Files** | `modules/services/litellm-settings.nix` (lines 1281-1282); new timer in `modules/containers/litellm-quadlet.nix` or a sibling module |
| **Change** | (a) `maximum_spend_logs_retention_interval = "7d"` → `"1h"`. (b) Add a **restart-independent** `systemd.timers.litellm-spendlogs-retention` (daily) running a bounded batched `DELETE` as the postgres role, so retention no longer depends on container uptime at all. (c) Emit `litellm_spendlogs_rows_past_retention` and `litellm_spendlogs_oldest_row_age_seconds` from that timer (the observable, see D-05R). |
| **Exact code** | `maximum_spend_logs_retention_interval = "1h";` — and the sweep SQL: `DELETE FROM "LiteLLM_SpendLogs" WHERE "startTime" < now() - interval '90 days' AND id IN (SELECT id FROM "LiteLLM_SpendLogs" WHERE "startTime" < now() - interval '90 days' LIMIT 20000);` in a loop with a row-count check. |
| **Verification** | `sudo journalctl _UID=948 --since '-8h' \| grep -iE 'spend.?log\|retention\|cleanup'` — **NOT** `journalctl --user -u litellm`, which returns **zero lines over 14 days** (verified; the rootless quadlet's output lands in the *system* journal under `_UID=948`, 28,078 lines/3 d). Then `psql -d litellm -tAc 'SELECT min("startTime") FROM "LiteLLM_SpendLogs"'` must advance past 2025-10-29. |
| **Backtest** | Not a detector. Mechanism verified: table holds **217,939 rows, oldest 2025-10-29 = 273 days**, so the 90 d sweep has demonstrably *never* run. `update-containers.timer` LastTrigger 2026-07-28 00:17:20, container `ActiveEnterTimestamp` 15:11:11 — uptime never approaches 7 days. Zero retention/cleanup matches in 14 days of logs. Also verified: at 6 h the sweep still misses on any day with two restarts <6 h apart (rebuild + nightly), which is why the timer is mandatory, not optional. |
| **Rollback** | Revert the two settings lines; disable the timer. No data is recoverable once deleted — see decision **D5** before the first sweep. |
| **Effort / Risk** | small / medium — first sweep deletes ~57.5 k rows carrying ~17 GiB of TOAST in one pass; run it manually in dated batches first, and expect heavy WAL inside the 02:00 dump window. |
| **Note** | `store_prompts_in_spend_logs = true` (`litellm-settings.nix:1280`) means the 55 GB is **prompt bodies**, not accounting rows — 273 days of prompt text on a host whose CLAUDE.md documents pasted-secret incidents. This is a **privacy** control as much as a disk one. Surface to the user before answering **D5**. |

---

#### S-03R — Make litellm shut down cleanly
`REVISED — adversary FALSIFIED the mechanism; the original two edits were a no-op`

| Field | Value |
|---|---|
| **Files** | `modules/users/home-manager/litellm.nix` / `modules/containers/litellm-quadlet.nix` (`containerConfig` + `serviceConfig`) |
| **Change** | The audit's premise — "inherits `TimeoutStopUSec=1min30s`, burns 90 s, then SIGKILL" — is **false**. The journal says `StopSignal SIGTERM failed to stop container litellm in 10 seconds, resorting to SIGKILL` at 15:11:10, i.e. **podman's own `--stop-timeout` default of 10 s**, not systemd's 90 s. The generated `.container` contains only `TimeoutStartSec=900` — no `StopTimeout`, no `StopSignal`. So `TimeoutStopSec = "30"` would change **nothing** (30 > podman's 10). Correct fix: set the knob podman honours — `containerConfig.stopSignal = "SIGINT"; containerConfig.stopTimeout = 45;` (quadlet-nix maps these to `StopSignal=`/`StopTimeout=`, `container.nix:652/660`) and `serviceConfig.TimeoutStopSec = "90"` so systemd never preempts podman's 45 s drain. |
| **Exact code** | `containerConfig = { … stopSignal = "SIGINT"; stopTimeout = 45; }; serviceConfig.TimeoutStopSec = "90";` |
| **Verification** | `grep -E 'StopTimeout\|StopSignal' /var/lib/containers/litellm/.config/containers/systemd/litellm.container` must show both; then time one restart and confirm the journal **no longer** contains `resorting to SIGKILL`. |
| **Backtest** | Restart-correlated 502s reproduced from raw nginx lines: **14 × 502 on `/v1/responses` in 15:11:07–15:11:23**, straddling the 15:11:10 SIGKILL. 24 h scan in 10-minute buckets returns three clusters (07-27 20:00 = 24, 07-28 00:20 = 10, 07-28 15:20 = 14). `sum(count_over_time({job="nginx-access", status=~"5.."}[24h]))` = **54** (verified live). |
| **Rollback** | Remove the three settings. |
| **Effort / Risk** | small / medium — a too-short drain truncates streaming requests (`streaming_request_timeout` is 300 s); 45 s is chosen above the p99 non-streaming request and below systemd's 90 s. |
| **Residual** | A **startup** 502 window exists independently: `TimeoutStartSec=900` and the container was still emitting `register_model` warnings 13 s *after* the kill. A perfect drain still leaves a non-zero per-restart 502 floor. This invalidates any "clean drain ⇒ ~0 502s" premise — see **S-06** in §9 (out of scope until the residual is measured). |

---

#### B-11 — Stop rewriting the 79 GB litellm dump file in full every night
| Field | Value |
|---|---|
| **Files** | `modules/services/postgresql-backup.nix:164` |
| **Change** | Add `--inplace --no-whole-file` to the publish rsync so unchanged blocks are reused instead of a whole-file rewrite that allocates fresh blocks for the next snapshot to pin. **Plus** a completion sentinel (see below) — `--inplace` means the hourly autosnap can now capture a *torn* file inside the live mirror, which today cannot happen because the mirror is always temp+rename atomic. |
| **Exact code** | `rsync -a --delete --checksum --inplace --no-whole-file --exclude=/.staging …`; then `rm -f "$backupDir/mirror-complete.stamp"` **before** rsync and `date +%s > "$backupDir/mirror-complete.stamp"` **after** success; emit `pg_dump_mirror_complete` (1 iff the stamp exists and is newer than the newest mtime under `db/`) from `pgDumpMetricsScript`. |
| **Verification** | `zfs get -Hp -o value recordsize,compression tank/Backups/PostgreSQL` (128K/zstd, confirmed); after one cycle `zfs list -t snapshot -o name,used -r tank/Backups/PostgreSQL \| tail -3` — the newest daily's `used` must fall from ~25 GiB toward single-digit GiB. Then `pg_dump_mirror_complete == 1`. |
| **Backtest** | Not a detector. `delta(zfs_dataset_used_bytes{name="tank/Backups/PostgreSQL"}[7d])` = **+114.9 GiB** against `delta(zfs_pool_allocated_bytes[7d])` = +70.1 GiB — this one dataset's growth exceeds the whole pool's net growth. Per-snapshot `used` climbed 18.6 G (07-17) → 25.5 G (07-27). |
| **Rollback** | Drop the two rsync flags. |
| **Effort / Risk** | small / medium — `--inplace` cannot reuse a destination block at a *later* offset, so append-mostly tables (the 79 GB `LiteLLM_SpendLogs` `.dat`) win big while UPDATE-heavy/post-VACUUM tables degrade toward whole-file. Runtime must be **re-measured** against `TimeoutStartSec=2h`: `--checksum` already forces a full read of both trees (38 min today, 14 of it the litellm `.dat`); `--no-whole-file` adds a block-checksum pass over every *differing* file. |
| **Doc** | Add to the module header: *"never restore from a snapshot in which `mirror-complete.stamp` is absent or older than the files in `db/`."* |

---

#### B-12R — Give pg_dump a dedicated staging dataset
`REVISED — adopted adversary revision: mountpoint=legacy would have silently dumped onto the root NVMe`

| Field | Value |
|---|---|
| **Files** | `modules/services/postgresql-backup.nix`; one-off `zfs create` |
| **Change** | Move the `.staging` directory off `tank/Backups/PostgreSQL` so in-progress dumps are never captured by that dataset's hourly/daily snapshots. **Create with the house convention — inherited mountpoint, NOT `mountpoint=legacy`.** All 20+ siblings under `tank/Backups` use inherited mountpoints and are mounted; with `legacy` the dataset never mounts, `bindTankPath`'s deliberate `nofail` silently drops the bind, and staging lands on the **root ext4 NVMe** — the exact failure the item exists to prevent. Worse, the design's original verification (`zfs list -t snapshot -r …-staging` prints "no datasets available") **passes in that broken state**. |
| **Exact code** | `sudo zfs create tank/Backups/PostgreSQL-staging` then `sudo zfs set com.sun:auto-snapshot=false tank/Backups/PostgreSQL-staging` (or a sanoid child section with `autosnap=no; autoprune=no`, which is proven to work on this host: `tank/Downloads` is an explicit child under a `recursive=true; process_children_only=true` parent and honours its own `use_template=active` — 7 dailies/3 monthlies vs tank/Home's 30/10). Fail-loud guard as the **first** action of the backup script: `${pkgs.util-linux}/bin/mountpoint -q "$staging" \|\| { log "FATAL: staging is not the ZFS dataset — refusing to dump onto /"; exit 1; }` |
| **Verification** | `findmnt -no FSTYPE,SOURCE /var/lib/postgresql-backup-staging` **must** return `zfs tank/Backups/PostgreSQL-staging`; `zfs get -Hp -o value used tank/Backups/PostgreSQL-staging` must be tens of GiB *during* a run and near zero after. |
| **Backtest** | Not a detector. The transient doubling is visible today: the 2026-07-28 09:19 hourly has `refer=69.5G` against a current dataset size of 40.3G. |
| **Rollback** | Point staging back at the old path; `zfs destroy` the (empty) dataset. |
| **Effort / Risk** | small / low |
| **Do NOT** | add `RequiresMountsFor` on the staging path — `bindTankModule.nix:23-36` documents that `RequiresMountsFor` is exactly what silently dropped these binds across the 2026-06-02 reboots. Do **not** use `ConditionPathIsMountPoint` *instead of* the guard: a failed Condition marks the unit **skipped/successful**, i.e. silent. |

**PHASE 1 GATE**
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
findmnt -no FSTYPE,SOURCE /var/lib/postgresql-backup-staging          # zfs tank/Backups/PostgreSQL-staging
grep -cE 'StopTimeout|StopSignal' /var/lib/containers/litellm/.config/containers/systemd/litellm.container  # 2
# wait for one 02:00 cycle, then:
zfs list -t snapshot -o name,used -r tank/Backups/PostgreSQL | tail -3   # newest daily used << 18 GiB
sudo journalctl _UID=948 --since '-26h' | grep -icE 'spend.?log|retention'  # > 0
psql -d litellm -tAc 'SELECT min("startTime") FROM "LiteLLM_SpendLogs"'     # > 2025-10-29
```

---

### PHASE 2 — Restore broken detection (the dead-rule sweep)

*Goal: every one of the 534 loaded rules is either capable of firing against the live TSDB, or
deliberately deleted with the reason recorded in-repo. Ship as one batch, one rebuild.*

**Baseline (verified live):** 91 groups, **534 rules**, all `health=ok` — which is exactly why the
defect is invisible: *a selector that matches nothing evaluates cleanly forever.* Expected post-phase:
**~512 rules**, still 0 `health=err`.

**Three triage verdicts are REVERSED here by adversarial review. Do not follow the triage:**
1. **M-09** said delete 3 DNS rules because `count(api_errors_total)` = NO_DATA. Verified:
   `count(last_over_time(api_errors_total[30d]))` = **1 series** (`error_type="network"`, last value 7).
   The metric is lazily emitted. **Deleting them destroys live coverage.** → repair thresholds instead.
2. **M-27** said delete `Aria2ExporterStale`/`GrafanaLoginFailureBurst` wholesale; the grafana one is a
   pure **rename** to a live metric (`grafana_authn_authn_failed_authentication_total`, verified 1 series).
3. **M-10** proposed inverting `TechnitiumUpdateAvailable` to `== -1`. Verified
   `count_over_time((technitium_dns_update_available != -1)[30d:1h])` = **0 samples** — the gauge has
   *never* left −1. Inverting it ships a rule engineered to fire **forever**, which is functionally as
   dead as silence and feeds the fatigue problem. **Delete instead.**

---

#### M-12 / AP-01 — De-duplicate `health-checks.yaml` (19 rule instances evaluated twice)
* **Files** `modules/monitoring/services/health-check-exporters.nix:292-294`
* **Change** Delete the explicit `../../monitoring/alerts/health-checks.yaml` append to
  `services.prometheus.ruleFiles`. `modules/monitoring/services/alerting.nix:23` already globs the whole
  directory. Verified: the same two groups (`certificate_alerts` 7 rules, `health_check_alerts` 12 rules)
  appear under two distinct store paths.
* **Verification** `REVISED — the design's check was factually wrong and would read as a failed fix.`
  Do **not** assert "19 unique names". `health-checks.yaml` legitimately declares
  `MbsyncNotRunRecently` **three times** inside one group (lines 69, 80, 91) → 6 instances today, 3 after.
  Use a **multiset diff**:
  ```bash
  before=$(curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[]|select(.name=="certificate_alerts" or .name=="health_check_alerts")|.name as $g|.rules[]|"\($g)|\(.name)"' | sort | uniq -c)
  # after switch, each count must be exactly halved; total instances 38 -> 19
  ```
* **Backtest** UNTESTABLE — Alertmanager dedupes identical labelsets, so this has never produced a symptom.
* **Rollback** Restore the line. **Effort/Risk** trivial / low.
* **Follow-up filed** The 3× `MbsyncNotRunRecently` is a latent defect of its own: if any two ever resolve
  to the same labelset, Prometheus raises *"vector contains metrics with the same labelset"* and the whole
  group goes `health=err`. Collapse into one rule with an account label.

#### M-13 / AP-14 — De-duplicate the Alertmanager registration
* **Files** `modules/monitoring/services/prometheus-server.nix:46`
* **Change** Delete that registration; keep `modules/services/alertmanager.nix:452`.
  **Adversary caveat resolved:** the deleted copy is the *guarded* one
  (`lib.mkIf config.services.prometheus.alertmanager.enable`). I verified `alertmanager.nix:9-10` sets
  `services.prometheus.alertmanager = { enable = true; … }` **in the same module**, so the guard is moot
  and deleting the guarded copy is safe.
* **Verification** `curl -s localhost:9090/api/v1/alertmanagers | jq '.data.activeAlertmanagers'` must list
  `http://localhost:9093/api/v2/alerts` **exactly once** (it lists it twice today, 0 dropped) and the URL
  must be **byte-identical** to today's.
* **Backtest** UNTESTABLE (latent). **Rollback** restore. **Effort/Risk** trivial / low.

#### M-03 / AP-02 — Delete the dead `backup_alerts` rule group
* **Files** `modules/storage/backup-monitoring.nix:32-70`
* **Change** Delete the `pkgs.writeText "backup-alerts.yml"` group (3 rules). Keep the `backup-alert@`
  template, the per-job `OnFailure` wiring and the tmpfiles entries — **B-01 and B-02R depend on them**.
* **Verification** `count(systemd_unit_state)` → NO_DATA and
  `count(systemd_service_last_trigger_timestamp_seconds)` → NO_DATA (both **verified**), while
  `count(node_systemd_unit_state)` = **3055** (verified). Surviving coverage proven to *fire*:
  `count(backup_service_failed)` = 9 series, and `ResticNoRecentSnapshot` fired across 8 repositories
  over 30 d (146–336 samples each).
* **Backtest** UNTESTABLE — the rules could never fire.
* **Rollback** restore the block. **Effort/Risk** trivial / low.
* **Record in the commit** `BackupServiceFailed` remains **double-declared** (health-checks.yaml on
  `backup_service_failed`, for=300; systemd.yaml on `node_systemd_unit_state`, for=60). Alertmanager
  groups by alertname, so one email cannot distinguish them and one silence covers both. Rename the
  systemd.yaml variant to `ResticServiceUnitFailed` in the same change. Same for `BackupTimerInactive`.
  Also: this group was **never mirrored to Nagios** (the generator globs `modules/monitoring/{alerts,loki-rules,vm-alerts}/*.yaml`),
  so no `PROM-MIRROR` service disappears.

#### M-04 — Fix the `job="blackbox-https"` hyphen typo in 5 rules
* **Files** `modules/monitoring/services/jupyterlab-alerts.nix`, `modules/monitoring/services/aria2-alerts.nix:~94`
* **Change** `job="blackbox-https"` → `job="blackbox_https_local"` in `Aria2WebUiDown`,
  `JupyterLabHttpsDown`, `JupyterLabCertificateExpiringSoon`, `JupyterLabCertificateExpired`,
  `JupyterLabSlowResponses`.
* **Exact expr (verified 1 series each)**
  `probe_success{job="blackbox_https_local", instance="https://jupyter.vulcan.lan"} == 0`
  `probe_success{job="blackbox_https_local", instance="https://aria.vulcan.lan"} == 0`
* **Verification** `count(last_over_time(probe_success{job="blackbox-https"}[30d]))` = **0** (verified);
  after the fix each selector must return 1.
* **Backtest** UNTESTABLE — both endpoints have been up; the rules were blind for their whole life.
  Record `avg_over_time(probe_success{instance="https://aria.vulcan.lan"}[30d])` in the commit so the
  record shows whether there was anything to catch.
* **Rollback** revert. **Effort/Risk** trivial / low.
* **Note (not introduced here)** `Aria2StuckQueue`/`Aria2SlowDownloads` use a bare `and` between two
  different metric names, relying on identical label sets. It holds today (same exporter instance) but
  will silently return zero series if the aria2 exporter ever adds a distinguishing label.

#### M-05 / M-06 / M-07 — jupyterlab: repair 2, **delete 3** (not 4)
`REVISED — adopted adversary revision: 3 of the 8 "restored" rules are strict subsets of live host-wide rules`
* **Files** `modules/monitoring/services/jupyterlab-alerts.nix`
* **Keep + repair (5 rules total in this group after the change):**
  * `JupyterLabServiceDown` → `node_systemd_unit_state{name="jupyterlab.service",state="active"} == 0`
    — **genuinely additive**: a cleanly stopped or masked unit is neither failed nor activating and no
    generic rule covers it. (Verified `node_systemd_unit_state{name="jupyterlab.service"}` = **5 series**.)
  * `JupyterLabHttpsDown`, the two cert rules (M-04), and `JupyterLabSlowResponses` on
    `probe_duration_seconds` — **not** `probe_http_duration_seconds`, which returns **5 phase series**
    (resolve/connect/processing/tls/transfer) and would compare each phase against the 5 s threshold.
    Verified `probe_duration_seconds{instance="https://jupyter.vulcan.lan"}` = 1 series, 0.0232 s.
* **Delete (with a comment naming the parent so nobody re-adds them):**
  * `JupyterLabServiceFailed` ⊂ `SystemdServiceFailed` (`node_systemd_unit_state{name=~".*\\.service",state="failed"} == 1`, for=60 — fired on 15 distinct units over 30 d).
  * `JupyterLabKernelIssue` ⊂ `ServiceStuckActivating` (for=900, fired on 6 units over 30 d).
  * `JupyterLabFrequentRestarts` ⊂ `ServiceRestartLooping` (`increase(node_systemd_service_restart_total{…}[30m]) > 3`, for=300). The proposed jupyterlab variant used a **lower** threshold (`>2`), making it the noisier of the pair, and `node_systemd_service_restart_total` **does reset** (3 units decreased in the last 7 d), so `increase()` re-adds the pre-reset value — observed spikes already reach **2.009**, exactly at the proposed bar.
  * `JupyterLabHighMemoryUsage` — **delete, no re-point possible.** Verified the `systemd_unit` label never exists on `process_resident_memory_bytes`, and a full census of `{__name__=~".*memory.*(current|high|max).*"}` returns only `process_virtual_memory_max_bytes`, `microvm_memory_current_bytes`, `redis_memory_max_bytes`, `grafana_*`. Covered prospectively by **M-92R**.
* **Backtest** UNTESTABLE — jupyterlab has had zero incidents in 30 d (restart counter max 0, `probe_success`=1 throughout, cert 337 days out).
* **Effort/Risk** trivial / low.

#### M-08 + M-U1 — Fix the 7 Technitium DNS ratio rules (vector matching + gauge semantics)
* **Files** `modules/monitoring/alerts/dns.yaml:106,117,128,139,151,163,175`
* **Change** `sum()` strips all labels, so one-to-one matching finds nothing — **verified: the as-written
  expression returns 0 series.** Also drop `rate()`: these are Technitium **rolling-hour gauges** that move
  down (sampled 370, 392, 317, 386, 361, 401, 343, 413, 415, 415, 377), so `rate()` misreads every decrease
  as a counter reset. The raw ratio *is* the last-hour ratio.
* **Exact expr (verified returns 1 series, value 0.0)**
  ```promql
  sum by(instance,job)(technitium_dns_request_result_count{result="server_failure"})
    / on(instance,job) group_left
  sum by(instance,job)(technitium_dns_request_result_count)
  ```
  with a volume guard `and on(instance,job) sum by(instance,job)(technitium_dns_request_result_count) > 250`
  (raised from the design's 200; the observed hourly denominator floor is **315**).
* **Thresholds — REVISED, see decision D6.** Live values already breach two as-written: refused **4.23%**
  vs a 2% threshold, cache-hit **58.99%** vs a 0.7 floor. Measured 7-day maxima:
  server_failure **0.0304**, refused **0.0524**, nx_domain **0.3217** (verified independently at plan time),
  cached min **0.4278**. Recommended retune: server_failure > 0.05, refused > 0.10, **nx_domain > 0.50**
  (the design's 0.40 sits only 1.24× above the observed max — raised to 1.55×), cached < 0.35,
  and `for: 15m`.
* **Verification** each of the 7 must return ≥1 series after the change and
  `count_over_time((<expr>)[7d:5m])` must be **0** (a *noise* check, not a backtest — there is no DNS
  incident in the window).
* **Backtest** UNTESTABLE for detection; honestly labelled.
* **Rollback** revert. **Effort/Risk** small / low.
* **Same-commit companion** `TechnitiumDNSMetricsFrozen` in the same file uses
  `sum(rate(technitium_dns_request_result_count[15m])) == 0` — it works, but for the *wrong* reason, and
  contradicts the new "never wrap these in `rate()`" comment. Either rewrite as
  `changes(sum(technitium_dns_request_result_count)[15m]) == 0` or add an explicit exemption comment.

#### M-09R — **Reverse the triage:** repair, do not delete, the 3 DnsQueryExporter rules
`REVERSED — deleting these would have destroyed live coverage`
* **Files** `modules/monitoring/alerts/dns.yaml:203,251,263`
* **Change** Old thresholds are provably unfireable: `max_over_time(rate(api_errors_total[5m])[30d:5m])`
  = **0.02266/s** against thresholds of 0.05 and 0.1 (2.2× and 4.4× short). Switch to
  `increase(...[1h]) > 5`, which **fires**: `max_over_time(increase(api_errors_total[1h])[30d:1h])` =
  **9.038** (re-verified at plan time).
* **Exact expr** — partition the space so one burst does not produce three alerts:
  * `DnsQueryExporterNetworkErrors`: `increase(api_errors_total{error_type="network"}[1h]) > 5 and on(instance,job) count_over_time(api_errors_total[1h]) > 6`
  * `DnsQueryExporterTimeouts`: same with `error_type="timeout"`
  * `DnsQueryExporterHighAPIErrorRate` (catch-all): `sum by(instance,job)(increase(api_errors_total{error_type!="network",error_type!="timeout"}[1h])) > 5`
  The `count_over_time > 6` guard suppresses `increase()` extrapolation across the exporter restart at
  2026-07-27 19:55:26, where an `[1h]` window can hold as few as one or two samples.
* **Verification** `count(last_over_time(api_errors_total[30d]))` = **1** (verified). Measured FP exposure
  after the change: 19 of 8,363 five-minute samples over 30 d = **0.23%**.
* **Backtest** **YES** — one real 95-minute error episode in the window would have fired at `for: 5m`.
* **Rollback** revert. **Effort/Risk** small / low.
* **Keep verbatim** a group comment explaining that Counter children are lazily created, so
  `count(metric)` at an instant is **not** evidence of a dead rule. This is the most valuable text in the change.

#### M-10R — **Delete** `TechnitiumUpdateAvailable`; file the exporter defect separately
`REVISED — do not ship the ==-1 inversion`
* **Files** `modules/monitoring/alerts/dns.yaml`
* **Change** Delete. Verified `technitium_dns_update_available` = **−1** and
  `count_over_time((technitium_dns_update_available != -1)[30d:1h])` = **0 samples** — the `== 1` branch
  is unreachable. The proposed `== -1` inversion would enter firing 24 h after deploy and **never
  resolve**, becoming a permanent Alertmanager entry (and a permanently non-OK Nagios mirror service).
  File the real defect — `technitium-dns-monitoring.nix` never populates the update-check path — as its
  own work item.
* **Backtest** the `== 1` form could not have fired at any point in 30 d (verified).
* **Effort/Risk** trivial / low.

#### M-11R — `ResticRepositorySizeGrowing`: `rate()` → `delta()`, **6 h window**, zero-guard
`REVISED — [6h] not [1d] (bounds the 72-h latch), plus the collector-zero guard`
* **Files** `modules/monitoring/alerts/storage.yaml:263-264`
* **Change** The live expr demands ~927 TB/day (`rate()` returns bytes **per second**); verified it returns
  **0 series**. `increase()` is also wrong — max over 1 d is **322.9 GB**, a counter-reset artifact on a
  non-monotonic gauge — while `delta()` gives a sane **3.87 GiB** (verified at plan time).
* **Exact expr**
  ```promql
  delta(restic_repo_size_bytes{repository!=""}[6h]) > 10*1024*1024*1024
    and min_over_time(restic_repo_size_bytes{repository!=""}[6h]) > 0
  ```
  `for: 1h`, `severity: warning`.
* **Why [6h]** I measured `max_over_time(delta(restic_repo_size_bytes{repository="Home"}[6h])[14d:1h])` =
  **26.29 GiB** — identical to the `[24h]` figure (26.27 GiB), so the 07-17 Home step is fully captured at
  6 h **and the alert clears within 6 h of growth stopping** instead of latching for 72 h/month (the `[1d]`
  form was true for 863 of 8,640 five-minute steps over 30 d = 10% of the month, as one contiguous ~72-hour
  episode).
* **Why the zero-guard** `restic-metrics` writes `restic_repo_size_bytes=0` when a repo read fails.
  Verified `count(min_over_time(restic_repo_size_bytes{repository!=""}[30d]) == 0)` = **0** today only
  because the check+prune cycle takes 6 m 42 s against a 6 h collector period (~2% overlap). **B-01
  stretches that to 1–3 h = 17–50% overlap every Monday**, at which point a 0-then-recover pair makes
  `delta` = +full repo size. **This guard must land before B-01.**
* **Backtest** **YES** — three episodes on Home, each ≥18 h continuous: 13.69 GiB (07-17/18), 26.27 GiB
  (07-21/22), 15.01 GiB (07-23/24). Next-highest repo max is Photos 3.87 GiB, so precision is clean.
* **Rollback** revert. **Effort/Risk** trivial / low.
* **Better fix, same commit if cheap** Have `restic-metrics` **omit** the series (or retain the previous
  value) on a failed read instead of writing 0, and emit
  `restic_metrics_repo_read_failed{repository=…}`. That single writer change removes the FP surface from
  **M-11R, ResticNoSnapshots and ResticRepoSizeShrunk** at once.

#### M-27R — Repair 1, delete 4 zero-series rules
* **Files** `modules/monitoring/alerts/{application-services,stock-trader}.yaml`, aria2/vdirsyncer alert modules
* **REPAIR — `GrafanaLoginFailureBurst`** (pure rename): `grafana_authn_authn_failed_login_total` is absent;
  `grafana_authn_authn_failed_authentication_total` exists (**verified 1 series**). Ship with `for: 15m`
  and `severity: info` for a one-month burn-in — the counter has been flat at **0 for 30 days**, so the
  `>5/15m` threshold is calibrated against nothing, and the metric counts *every* failed auth path
  (API tokens, anonymous, basic, proxy), not interactive logins. Say so in the annotation.
* **DELETE** `Aria2HighErrorRate` (`aria2_error_downloads` absent; do **not** re-point at
  `aria2_stopped_downloads`, which includes normal completions), `Aria2ExporterStale`
  (`Aria2ServiceDown` on `up{job="aria2"}` already covers it), `StockTraderChatErrorRate`
  (`stock_trader_chat_errors_total` absent; `StockTraderQuotesUnavailable` covers the quote path),
  `VdirsyncerSlowSync` (no duration metric; `vdirsyncer_sync_healthy` + `vdirsyncer_last_sync_timestamp`
  are already alerted).
* **Verification** each deleted name absent from `/api/v1/rules`; the grafana selector returns 1 series.
* **Effort/Risk** small / low. Leave comments naming the live metric names so the rules are not re-added.

#### M-16 — Fix the `host_group="dns"` relabel regex
* **Files** `modules/services/blackbox-monitoring.nix:613`
* **Change** The regex still matches a retired Google-DNS set and omits Quad9 entirely. **Verified:
  `count(probe_success{host_group="dns"})` = 2** — only `1.0.0.1` and `208.67.222.222`; `1.1.1.1`,
  `9.9.9.9`, `149.112.112.112`, `208.67.220.220` carry **no** `host_group`. Extend to the actual six.
* **Two consequences, both observed** (i) those four fall back into the always-on critical
  `HostUnreachable`, which **did** fire on 9.9.9.9 during today's WAN blip — the exact ~20-email failure
  mode `network.yaml:19-25` documents as fixed; (ii) `DNSResolversDown` computes `count(down)==count(all)`
  over **2 of 6** resolvers, so it can reach critical while four resolvers answer normally.
* **Verification** `count(probe_success{host_group="dns"})` must return **6**.
* **Effort/Risk** trivial / low.

#### M-17R — Fix the `PublicEdgeDown` regression from `9d4ad5b6`
`REVISED — the design's PublicEdgeDegraded backtest was a data-gap artifact; that half is dropped`
* **Files** `modules/monitoring/alerts/network.yaml:165-173`
* **Change (ship)** (a) Add `job!="blackbox_https_public"` to `HostUnreachable` — verified the current
  selector matches **71** series and the exclusion drops it to **69**, exactly the 2 public targets, which
  *did* fire critical (46 and 36 samples/30 d). This finishes what `9d4ad5b6` started. (b) Correct
  `PublicEdgeDown`'s annotation from "more than 5 minutes" to match its actual `for: 10m`.
* **Change (DROP)** The proposed `PublicEdgeDegraded` on `avg_over_time(probe_success[6h]) < 0.9`. The
  design's supporting number (0.6579) is **exactly 25/38** — a window holding 38 samples instead of 360,
  produced by a **332-minute scrape gap on 2026-07-03**. Under normal density the 07-03 outage gives
  avg ≈ 0.96, *above* the bar. Measured exposure: 58 of 4,320 ten-minute steps over 30 d have <300 samples
  in the 6 h window. Any `avg_over_time` availability rule without a density guard is a **data-gap
  detector**. If the oscillating shape must be covered later, use the gap-guarded absolute form:
  `count_over_time((probe_success{job="blackbox_https_public"} == 0)[6h:1m]) > 30 and on(instance,job) count_over_time(probe_success{job="blackbox_https_public"}[6h]) > 330`
  — and state honestly that at `>30` it catches **neither** 07-03 (13–15 zero-minutes) **nor** 07-28
  (11 and 9): it is a new detector for a shape that has not yet occurred.
* **Correction to the audit** `PublicEdgeDown` is **not** unfireable — it reached `firing` for 17 and 19
  samples over 30 d. It is *dwell-mismatched*, not dead.
* **Effort/Risk** trivial / low.

#### R-12R — **Delete** `GitWorkspaceImportantRepoStale`, do not repair it
`REVISED — the design mis-diagnosed a label-VALUE error as a label-NAME error`
* **Files** `modules/monitoring/services/git-workspace-alerts.nix:115` (**not** `modules/monitoring/alerts/application-services.yaml`)
* **Change** Delete. The design claimed the metric is labelled `alias` not `repository`; live
  `/api/v1/series` shows **both**, with `repository` carrying **51 distinct values** and `alias` carrying
  exactly one (`vulcan`, the host alias). The real defect is the matcher **value**: repository values look
  like `github/DeepSpec/InteractionTrees`, and a regex over `.*(jwiegley|nixos|config).*` returns **zero**
  — no jwiegley-owned or nixos-config repo is tracked by this exporter at all. Switching to `alias` (the
  design's fix) would select **all 51 repos** and page 51 series on the first multi-day sync outage.
* **Why delete rather than repair** (i) no tracked repository matches any "important" anchor; (ii) the
  metric measures *fetch recency* (all 51 uniformly 0.5 d), so it can only express sync failure — already
  covered by five live siblings (`GitWorkspaceSyncStale`, `GitWorkspaceManyStaleRepos`,
  `GitWorkspaceCriticallyManyStaleRepos`, `GitWorkspaceMultipleReposFailed`, `GitWorkspaceManyReposFailed`);
  (iii) the per-repo series is **conditionally emitted** (51 series over 30 d, 0 at an instant, while
  `git_workspace.prom` is 14 min fresh and `git_workspace_stale_repos_total`=0), so any per-repo rule will
  oscillate in and out of R-03's dead-selector detector forever.
* **Effort/Risk** trivial / low.

#### AP-06R — Widen the cert-expiry job selector, but scope the **critical** to certs this host mints
* **Files** `modules/monitoring/alerts/certificates.yaml`
* **Change** `job="blackbox_https"` (1 external target) → `job=~"blackbox_https.*"` for the **7-day
  WARNING** (46 targets: local 41, auth 2, public 2, external 1 — verified). Keep the **1-day CRITICAL**
  scoped to `job=~"blackbox_https_(local|auth)"`.
* **Why the scope** The 2 public targets are Cloudflare-fronted; `min_over_time(…[30d])` shows a served
  cert only ~3.6 days ahead vs 62.58 days now, i.e. a rotation already occurred on Cloudflare's schedule.
  A critical page this host cannot remediate is the exact unactionable class `9d4ad5b6` was written to
  remove three hours before this plan.
* **FP trap checked and does NOT apply** A failed TLS handshake normally yields expiry=0, making
  `0 - time() < 7d` fire critical on every probe failure. Verified
  `count(min_over_time(probe_ssl_earliest_cert_expiry{job=~"blackbox_https.*"}[30d]) == 0)` = **0**, and
  during the 07-28 flap the cert metric's sample count (352, 356) was strictly *lower* than
  `probe_success`'s (359, 360) — blackbox **omits** the series rather than zeroing it.
* **Backtest** UNTESTABLE — min remaining life is 54.4 days; 0 samples under 7 d in 30 d.
* **Effort/Risk** trivial / low.

#### AP-12 — Move `ring-chime-office.lan` from `iot-noping` to `iot`
* **Files** `modules/services/blackbox-monitoring.nix` (**re-read immediately before editing** — mtime is
  2026-07-27 12:56 but a target removal landed ~15:04 today, so line numbers 505/526-529/536 may have moved)
* **Change** It currently carries `host_group="iot-noping"` (defining property: 0% ICMP response) while
  `probe_success` returns **1**. Measured at 1-minute resolution over 30 days: **143 total zero-minutes,
  max 24 in any 70-minute window** — so a contiguous 60-minute zero run never occurred and
  `BlackboxICMPIoTDeviceDown` (`for: 1h`) will not fire spuriously. Use these figures in the commit, not
  the design's coarser step-300 numbers (25 min / 115 zero-minutes).
* **Grants** only `BlackboxICMPIoTDeviceDown`; `host_group="iot"` is in `HostUnreachable`'s exclusion list.
* **Effort/Risk** trivial / none. **Keep** the NO-ALERT INVENTORY comment — it is the durable part.

#### AP-13R — Retune, don't delete, `SystemdJournalHighErrorRate`
`REVISED — the triage's premise (stale matcher, rule is empty) is REFUTED; deleting loses the diffuse-multi-unit shape`
* **Files** `modules/monitoring/loki-rules/systemd-errors.yaml`
* **Change** Raise the threshold from `> 10` to `> 60`; **keep** the `unit!="user@948.service"` exclusion.
  Measured against live Loki over 7 d at step 600: the deployed expression returns **max 17.0** (so it
  *was* capable of firing), and **removing** the 948 exclusion raises max to **91.0**, which would create
  new firing — the exact inverse of the triage's claim.
* **Why not delete** The per-unit sibling `SystemdServicePersistentErrors` catches one noisy unit; the
  whole-host aggregate catches a **diffuse** increase spread across many units each below the bar (twelve
  units × nine lines = 108, which fires nothing after deletion). Record in the commit that the 7-day max
  is 17 and that `>60` is deliberately above any plausible sum of sub-threshold per-unit noise.
* **Loki gotcha** the `L+` symlink in `modules/services/loki.nix:125` must stay (10 symlinks at 122-133,
  verified). Editing a rule (not a group) keeps `post-reboot-validation.sh`'s "Loki ruler ≥10 rule groups"
  assertion passing.
* **Effort/Risk** trivial / low.

#### M-28 — Update `SystemdJournalHighErrorRate`'s stale unit exclusion (folded into AP-13R)
Superseded by AP-13R. The triage's factual basis (948 is now quiet, top emitters are user@928 and
matter-server) is correct, but the *action* it implies (drop the exclusion) is refuted above.
**No separate change.** Add a comment recording the measured emitter distribution.

#### C-04R — Make the 5 `*_last_success` alerts immune to fast-retry scrape aliasing
* **Files** `modules/monitoring/alerts/{flume-data,database,dns,node-red-safety}.yaml` (5 rules:
  `FlumeSyncFailed`, `FlumeCrossCheckFailed`, `PgDumpFailed`, `TechnitiumBackupFailed`, `NodeRedBackupFailed`)
* **Change** `<metric> == 0` → `min_over_time(<metric>[1h]) == 0`.
* **Exact expr** `min_over_time(flume_weekly_cross_check_last_success[1h]) == 0`, `for: 5m`.
* **Backtest** **YES** — the raw gauge over 2026-07-27T19:30→21:00 at step 15 s returns 359 samples with
  **exactly one zero at 19:36:00**; the `min_over_time` form over 19:00→22:00 at step 60 s returns **60
  consecutive firing samples** (19:36→20:35), so `for: 5m` is satisfied at 19:41. All five alertnames have
  **never fired** in 7 d.
* **Honest scoping** The triage over-claimed. `Restart=no`, `OnFailure=` empty, cadence weekly/daily → an
  *unattended* failure leaves the gauge at 0 for 24 h–5 d, which the old `for: 10m` already satisfied. The
  19:36 re-run was a **manual** `systemctl start` 19 s after the failure. So this closes a narrow hole
  (operator retries inside the dwell), not "the silent-failure class". Also: `PgDumpFailed`,
  `TechnitiumBackupFailed`, `NodeRedBackupFailed` are **already** `for: 5m` — dropping the dwell is a no-op
  for 3 of 5.
* **Residual, carried to Phase 3** `scrape_interval` is 15 s and the 07-27 zero survived exactly one scrape
  because the retry landed at +19 s. A retry at +10 s writes 1 before any scrape sees 0, and
  `min_over_time` sees nothing either. The structural fix is a monotonic counter
  (`flume_*_failures_total`, `pg_dump_failures_total`, …) with `increase(X[6h]) > 0` — see **D-09/D-10**.
* **Effort/Risk** trivial / none.

#### B-13 — Raise `ResticNoRecentSnapshot` from 30 h to 36 h
* **Files** `modules/monitoring/alerts/storage.yaml`
* **Change** `108000` → `129600` (harmonises with `BackupNotRunRecently` in `health-checks.yaml:38`, which
  already uses 129600 on an independent metric).
* **Backtest** **YES (removes false pages).** Verified
  `max_over_time((time() - restic_last_snapshot_timestamp_seconds{repository!=""})[7d:1h])/3600` per repo:
  **Home 30.17 h, Public 29.83, Backups 29.50, Video 29.50, Photos 29.33**, doc 26.50, Audio 26.83,
  Databases 26.16, src 25.83. **Five of nine repos came within 40 minutes of the threshold in one week.**
  The true worst-case bound (24 h + 6 h `OnUnitActiveSec` + 10 min `RandomizedDelaySec` + ~11 min runtime
  ≈ 30.35 h) is **above** the configured 30 h, so the old threshold is structurally guaranteed to graze.
  At `> 129600` the same query returns **zero** series (21,002 s = 5.8 h of margin).
* **Cost** Detection of a genuinely skipped daily slips from T+30 h to T+36 h (T+42 h observed, given the
  ~6 h collector cadence). Acceptable only because three independent paths cover it:
  `BackupNotRunRecently` (9 live series), each job's `OnFailure=backup-alert@%n`, and `ResticMetricsStale`.
* **Better end-state (same commit)** Drop `restic-metrics`' `RandomizedDelaySec` 10 min → 2 min or shorten
  `OnUnitActiveSec` 6 h → 3 h; that cuts the worst-case lag term from ~6.35 h to ~3.05 h and would let the
  threshold return to 30 h with real margin.
* **Effort/Risk** trivial / none.

**PHASE 2 GATE**
```bash
sudo nixos-rebuild build --flake '.#vulcan' --show-trace
/nix/store/iinff711bp4hsw0xbk27mas9xh2mrl9a-prometheus-3.7.2-cli/bin/promtool check rules modules/monitoring/alerts/*.yaml
sudo nixos-rebuild switch --flake '.#vulcan'
curl -s localhost:9090/api/v1/rules | jq '[.data.groups[].rules[]]|length'                    # ~512
curl -s localhost:9090/api/v1/rules | jq '[.data.groups[].rules[]|select(.health!="ok")]|length' # 0
curl -s localhost:9090/api/v1/alertmanagers | jq '.data.activeAlertmanagers|length'           # 1
# every repaired selector must be non-empty:
for s in 'probe_success{job="blackbox_https_local",instance="https://jupyter.vulcan.lan"}' \
         'node_systemd_unit_state{name="jupyterlab.service"}' \
         'last_over_time(api_errors_total[30d])' \
         'grafana_authn_authn_failed_authentication_total' \
         'probe_success{host_group="dns"}'; do
  printf '%s -> ' "$s"; curl -sG --data-urlencode "query=count($s)" localhost:9090/api/v1/query | jq -r '.data.result[0].value[1] // "EMPTY"'
done   # expect 1, 5, 1, 1, 6
```

---

### PHASE 3 — Close the three archetypes

*Goal: each of the user's three named silent failures gets a detector that is backtested against the
actual incident, plus the generalisation that makes the **class** detectable.*

---

#### M-01 / D-01 — Loki alert on Gitea push-mirror sync failures  *(archetype (c) — the log-side detector)*
| Field | Value |
|---|---|
| **Files** | new `modules/monitoring/loki-rules/gitea-mirror.yaml` **+ an `L+` symlink line in `modules/services/loki.nix`** (rules are **not** auto-discovered; 10 existing symlinks at lines 122-133) |
| **Exact expr** | `sum by (path) (count_over_time({job="nginx-access", status=~"5.."} \|= "push_mirrors-sync" [26h])) >= 1` — `for: 5m`, `severity: warning` |
| **Backtest** | **YES.** `sum(count_over_time({job="nginx-access", status="500"} \|= "push_mirrors-sync" [7d]))` = **7** at plan time (verified) — exactly the 7 daily failures in the retained window. The same expression body over 9 d at step 21600 is non-zero at **37/37 steps**. Status distribution on that path over 7 d is `{200: 1330, 500: 7}`, so the else-branch is unambiguous. Loki retention is 720 h, so the whole failure run is in-window. |
| **Revisions adopted** | `status=~"5.."` not `status="500"` (a total Gitea outage yields 502/504 from nginx, which the `500`-only form would miss); `sum by (path)` so the annotation names the failing repo; `severity: warning` + `for: 5m` rather than `critical`/`for: 0` — a critical page that **cannot clear for 26 h** will get silenced, and it will look broken *during* remediation. State the 26 h clear latency in the annotation text. |
| **Verification** | `curl -s localhost:3100/prometheus/api/v1/rules \| jq '.data.groups[]\|select(.file\|test("gitea-mirror"))'` → 1 group, `health=ok`. |
| **Rollback** | Delete the file + symlink. |
| **Effort / Risk** | trivial / low |
| **Fragility to record in-file** | The rule depends on the sync going through nginx. `giteaUrl` defaults to `https://gitea.vulcan.lan` (module line 228) but is an **option** — pointing it at `localhost:3000` silently deletes the only log-side detector, with no rule-health signal. **D-09 is the producer-side primary; this is the cross-check.** |

#### D-09 — Make the push-mirror script itself fail loudly and emit a metric  *(archetype (c) — the producer-side detector)*
| Field | Value |
|---|---|
| **Files** | the push-mirror sync script in `modules/services/gitea.nix` (~line 283/372, `User=root`) |
| **Change** | The loop is `while read -r repo; do … done <<< "$repos"` — a **here-string**, not a pipe, so it runs in the current shell and a `failed=$((failed+1))` increment persists (the existing `synced` counter proves this). Add a failure tally, emit a textfile gauge, `exit 1` on failures. |
| **Exact code** | ```bash
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST … || true)   # ← || true is MANDATORY
case "$code" in 2??) synced=$((synced+1));; *) failed=$((failed+1)); echo "MIRROR FAIL $repo http=$code";; esac
``` plus `trap emit_metrics EXIT` where `emit_metrics` writes `gitea_push_mirror_sync_failures`, `gitea_push_mirror_last_run_timestamp_seconds` and `gitea_push_mirror_run_incomplete` to a **fixed** temp name (`gitea_push_mirror.prom.tmp`) then `mv`. |
| **Adversary bug fixed** | The design's rewrite dropped `curl -f` in favour of `-o /dev/null -w '%{http_code}'` **without** `\|\| true`. Under `set -euo pipefail` (injected by `pkgs.writeShellApplication`), a connection-level failure makes curl exit non-zero with `code=000`, the command substitution fails, and **`set -e` aborts the run mid-loop** — the `.prom` write never happens, the previous file's values stay frozen, and the silent failure is reintroduced one layer up. *Total Gitea outage — the worst case — is precisely the case that breaks it.* The `trap … EXIT` makes an aborted run publish `gitea_push_mirror_run_incomplete 1`, which is itself a finding. |
| **Alert** | `gitea_push_mirror_sync_failures > 0` (for: 10m) and `gitea_push_mirror_run_incomplete > 0`. Add `\|gitea_push_mirror` to `TextfileCollectorStaleDaily`'s regex at `meta-monitoring.yaml:337` (93600 s, daily cadence matches). |
| **Backtest** | **YES.** Ground truth: 7 d = `{200:1330, 500:7}`, 1–2 failures on **every** one of the last 10 days → `failed>=1` and `exit 1` on every run. |
| **Naming** | `gitea_push_mirror_sync_failures` is a per-run **gauge**, not a counter — no `_total` suffix, so nobody applies `rate()`. |
| **Rollback** | Revert the script; delete the two rules. **Effort / Risk** small / low. |
| **Housekeeping** | The textfile dir already holds 7 leaked `.prom.<pid>` files (see B-03R), proving the copied tmp+mv pattern leaks on abort. Use the fixed tmp name. |

#### D-10 / C-04b — Make the flume weekly cross-check report degraded steps  *(archetype (b))*
| Field | Value |
|---|---|
| **Files** | `scripts/flume-data/flume_data/cross_check.py` (**note the path — it is a module inside a packaged distribution with its own `pyproject.toml`, not `scripts/flume-data/cross_check.py`**); `modules/services/flume-data.nix` |
| **The real defect** | `run()` returns 0 unconditionally (line 681) and four broad `except Exception` handlers (lines 136, 253, 282, 441 — 441 annotated *"broad on purpose"*) substitute fallbacks, three of which return `0.0` into a category comparison where **"absent" becomes indistinguishable from "agrees"**. That is a false negative in the check's own output, which no exit-code fix can reach. |
| **Correction to the triage** | `FlumeCrossCheckFailed` is **not** structurally unfireable. `count_over_time(ALERTS{alertname="FlumeCrossCheckFailed"}[90d])` = **773 firing samples**, one 6.0 h episode on **2026-06-15** — because `ExecStopPost=+…flume-data-metrics … $SERVICE_RESULT` tracks the **unit** result, which correctly went to 0 when the unit failed. The accurate claim is the narrower *"this check reports unit-level failure and cannot report internal step failure."* Any test asserting `last_success` is pinned to 1 will fail. |
| **Change** | Split reporting into **DATA** and **DELIVERY** tiers. `cross_check.py` writes an atomic JSON sidecar `/var/lib/flume-data/cross_check_result.json` = `{items_checked, data_steps_degraded, delivery_steps_degraded, failed_steps:[…]}`; the existing `flume-data-metrics` ExecStopPost reads it and emits `flume_cross_check_items_checked`, `flume_cross_check_data_steps_degraded`, `flume_cross_check_delivery_steps_degraded`, `flume_cross_check_last_completion_timestamp_seconds`. **DATA-tier degradation must NOT force a non-zero exit** (the degrade-don't-abort contract at `cross_check.py:447+` is deliberate and correct). |
| **HARD BLOCKER the design missed** | `systemctl show flume-data-weekly` reports `ProtectSystem=strict` with `ReadWritePaths=/var/lib/flume-data /var/lib/postfix/queue`. `/var/lib/prometheus-node-exporter-textfiles` is **not** in that list, so any direct write fails **EROFS regardless of the 1777 mode** — the design's justification reasons about POSIX permissions and ignores the mount namespace. (The sibling daily `flume-data` unit has `ProtectSystem=no`, which is why the pattern looked safe.) **Add `/var/lib/prometheus-node-exporter-textfiles` to `ReadWritePaths` and verify with `systemctl show flume-data-weekly -p ReadWritePaths` after the switch, ahead of any fault injection.** |
| **Exact exprs** | `flume_cross_check_data_steps_degraded > 0` (for: 10m, warning) — **instantaneous, not `max_over_time([8d])`**: on a weekly gauge an 8-day window latches one bad run for a full week and cannot resolve after the next clean run. Safe only because the emitter writes **0 on a clean run unconditionally**. Plus `time() - flume_cross_check_last_completion_timestamp_seconds > 8*86400` (weekly cadence + slack) — **the design omitted this**, and without it a run that dies before the emitter leaves the counters frozen at last-good and every new rule stays quiet. |
| **Backtest** | UNVERIFIED (metrics absent by design). Validate by **fault injection**: temporarily raise one handler's exception and confirm `data_steps_degraded` ≥ 1 and the rule fires. |
| **Rebuild caveat** | The code does **not** run from the repo: `Environment=PYTHONPATH=/nix/store/…-flume-data`, `ExecStart=…/bin/python -m flume_data cross-check --days 7`. Edits require `nixos-rebuild switch`; add *"verify the deployed store path changed"* (`readlink` before/after) to the verification. |
| **Effort / Risk** | medium / low |
| **Unidentified producer, honestly flagged** | The `USING(date, start_time)` schema error the audit attributed to this check is **not in `/etc/nixos`** (repo-wide grep for SQL `USING` returns only `databases.nix` and a cert script), and Loki confirms **exactly 1** such error in 8 d. The producing query is unidentified; that attribution is **unproven**. This item detects the *degradation class* regardless. |

#### S-01R — ZFS snapshot-amplification metric + rule  *(archetype (a))*
`REVISED — the exporter property must be ADDED (metric name now verified by direct probe); rule 2 deleted`
| Field | Value |
|---|---|
| **Files** | `modules/monitoring/services/system-exporters.nix:71-75` (`services.prometheus.exporters.zfs`), `modules/monitoring/alerts/storage.yaml` |
| **Change** | Add `extraFlags = [ "--properties.dataset-filesystem=available,logicalused,quota,referenced,used,usedbydataset,usedbysnapshots,usedbychildren,written" ];` |
| **Metric names — VERIFIED by direct probe** | I ran `zfs_exporter-2.3.10` on a spare port with those properties. The emitted names are **`zfs_dataset_used_by_snapshot_bytes`** (singular) and **`zfs_dataset_used_by_children_bytes`**. For `tank/Backups/PostgreSQL`: `used_by_snapshot=1.8647e12` (1736.7 GiB), `used_by_dataset=40.3 GiB`, `used_by_children=0`. Plumbing confirmed safe: `systemctl cat prometheus-zfs-exporter` shows ExecStart ending with `--web.listen-address`, `--web.telemetry-path`, then an **empty interpolation slot** — `extraFlags` is supported and currently unset, so no duplicate-flag risk. |
| **CORRECTION to both designs** | Neither `usedbysnapshots` nor `usedbychildren` exists today, so the proxy `used - usedbydataset` is **contaminated by children**. I ran the guarded proxy live and it returns **7 series** (`tank`, `tank/Backups`, `tank/Models`, …) — *not* the claimed 1. With the **real** property the same guard selects **exactly 1 of 59 datasets**: `tank/Backups/PostgreSQL` (1736.7 GiB residue / 40.3 GiB data / ratio 43.13). Runners-up are correctly declined: tank/Home 697.3/163.8 (4.26), Models/Llama.cpp 654.6/5949.0, Photos 653.6/379.8, Video 461.6/304.1, work/positron 297.1/212.0. |
| **Exact expr (rule 1 — SHIP, severity `info`)** | ```promql
(zfs_dataset_used_by_snapshot_bytes{type="filesystem"} > 300*1024*1024*1024)
  and ((zfs_dataset_used_by_snapshot_bytes{type="filesystem"}
        / clamp_min(zfs_dataset_used_by_dataset_bytes{type="filesystem"}, 1)) > 5)
``` `for: 6h` → **change to `for: 90m`** so the Nagios mirror's clamped `max_check_attempts` (20 → HARD at ~100 min) stays inside the Prometheus dwell instead of producing ~4.3 h of `nagios_only` divergence per episode. |
| **Rule 2 — DELETE, do not ship** | `delta(residue[7d]) > 100 GiB` was measured over 30 days: **continuously TRUE 06-11 → 07-11** (100.7 … 273.2 GiB — ~30 consecutive days of firing during entirely normal operation) and **FALSE through the whole incident** (07-19 39.3, 07-24 **9.4**, 07-27 18.6 GiB). It fired for a month when nothing was wrong and was silent through the five-day 130× regime change, because residue is a **stock** that saturates once the 12-monthly ladder is populated. |
| **The true onset detector (SHIP as a separate 15-min collector)** | Emit per dataset the **newest daily snapshot's** `used` and `referenced` (`zfs list -Hp -t snapshot -o name,used,referenced -s creation`) as `zfs_newest_daily_snapshot_used_bytes` / `_refer_bytes`, and alert on `used / clamp_min(refer,1) > 0.5 and refer > 10*1024^3` for 24 h. Today that ratio is **~0.98** for tank/Backups/PostgreSQL (25.5 G used / 26.0 G refer) versus **~0.28** for the post-fix TechnitiumDNS control case — and it **drops to near zero the first night B-11 lands**, so it is a genuine onset detector that self-resolves on repair instead of standing for 30 days. |
| **Collector-hazard revision (mandatory)** | Do **not** put `zfs list` into the existing `zfs-pool-health-exporter`, which runs `zpool status` every **2 minutes** and produces `zfs_pool_suspended` — the critical UAS-cascade detector. `zfs list` can block indefinitely on a hung USB bridge; a hang would stale the pool-suspension gauge during exactly the failure it exists to catch (`TextfileCollectorStaleFast` gives up to an hour blind). Use a **separate 15-minute collector**, `TimeoutStartSec=60`, its own `.prom` filename added to the **`TextfileCollectorStaleFast` allowlist regex** (currently `(asymmetric_routing\|nodered_safety\|container_health\|zfs_pool_health\|nagios_status)\.prom`), and `mktemp`+`trap` from day one. |
| **Backtest** | **YES (rule 1).** Exact-proxy `query_range` of the ratio over 30 d at step 21600 returns **120/120 steps above 10** (min 43.13, max 81.69, declining 76.45 on 06-28 → 43.13 today) with the residue 1425–1737 GiB at every step — it would have been firing continuously for the entire retained window. Backtest of the onset detector: UNVERIFIED (metric absent), but the 0.98-vs-0.28 contrast is measured from live `zfs list`. |
| **Rollback** | Remove `extraFlags` (exporter restarts — a scrape gap can trip `TargetDown`, `up==0` for:5m, on a slow switch); delete the rules. |
| **Effort / Risk** | medium / low. Cardinality +118 series against 4,049 metric names; the `dataset-filesystem` collector duration is 0.0197 s. |
| **Owner warning** | Rule 1 will fire on day one and keep firing ~30 days while the old ladder drains. **A detector for a condition with no owner and no remediation step becomes wallpaper within two weeks.** It is `severity: info` precisely for that reason, and it must ship alongside Phase 1 (already landed) plus decision **D7** (destroy the four legacy monthlies) so it has a path to resolving. |

#### D-11 — pg_dump completeness: prove the dump covers every live database
| Field | Value |
|---|---|
| **Files** | `modules/services/postgresql-backup.nix` |
| **Change** | Emit `pg_dump_database_dirs` (count of mirror dirs) and `pg_dump_databases_live` (count of connectable non-template databases) and alert on inequality. Today all three independent counts agree at **27** (verified: `ls -1 /var/lib/postgresql-backup/db \| wc -l`, `SELECT count(*) FROM pg_database WHERE datallowconn AND datname NOT IN ('template0','template1')`, `find … -name toc.dat \| wc -l`). Existing coverage is a **byte floor and nothing else** (`pg_dump_size_bytes`), and the module's own comment at lines 49-56 already concedes *"a green systemd exit is NOT proof of a complete dump."* |
| **Privilege revision (mandatory)** | The design assumed the `+`-prefixed `ExecStopPost` can `sudo -u postgres psql`. `systemctl show postgresql-backup` reports `NoNewPrivileges=yes`, and I verified root **cannot** reach Postgres as the postgres role without setuid (`psql -U postgres -h /run/postgresql` → *"Peer authentication failed"*). Whether `+` clears `NoNewPrivileges` for that command is **unverified**, and the design's `\|\| echo 0` fallback combined with its own `and pg_dump_databases_live > 0` guard makes the failure **invisible** — a broken psql call silently converts a completeness check into a permanently-quiet rule. **Sidestep it:** have the backup script — which already runs as `User=postgres` and already enumerates the databases it is about to dump — write the count to `/var/lib/postgresql-backup/.dbcount`, and have the root ExecStopPost emitter read that file. More correct as well as safer: the count then comes from the same session that did the enumeration. |
| **Exact expr** | `pg_dump_database_dirs != pg_dump_databases_live and pg_dump_databases_live_valid == 1` — an explicit **validity flag**, not a `> 0` guard, so a failed count is a *firing* condition rather than a suppressed one. `for: 26h` (rides out one dump cycle; also resolves the C-U1 ordering question without sequencing). |
| **Backtest** | UNVERIFIED (metrics absent). Correctly quiet today — all three counts = 27. |
| **Known limit to record** | Both counters are computed in the same ExecStopPost, so they are always mutually consistent *as of dump time*: the rule catches a dump that **lost** a database, never drift between dumps. `pg_dump.prom` is already in the `TextfileCollectorStaleDaily` allowlist (`meta-monitoring.yaml:337`), which is what covers the emitter never running. |
| **Effort / Risk** | small / low |

#### D-05R — `litellm_spendlogs_oldest_row_age_seconds`: express the retention invariant on **data age**, not growth rate
`REVISED — the design's delta-based rule is disproved by a 200-day backtest`
| Field | Value |
|---|---|
| **Files** | the S-02R retention timer (same oneshot), `modules/monitoring/alerts/litellm.yaml` |
| **Why the design's rule fails** | `delta(pg_database_size_bytes{datname="litellm"}[7d]) > 5 GiB` was backtested over **200 daily steps**: true on only **5** (2.5%), first crossing **2026-07-24 — four days ago**. Monthly maxima of `delta[7d]`: 2026-01 +0.00, 02 +0.00, 03 +0.00, 04 +3.24, 05 +3.24, 06 +3.94, **07 +36.96 GiB**. The database accumulated its entire 55 GB and its full 273-day backlog **below this threshold**; over the 30 days ending 07-22 the weekly delta ran 0.7–1.6 GiB, a third to a fifth of the bar. A growth-rate threshold high enough to ignore normal churn is also high enough to ignore 1.4 GiB/week of unbounded accumulation. |
| **Exact code** | `psql -d litellm -tAc 'SELECT extract(epoch from now()-min("startTime")) FROM "LiteLLM_SpendLogs"'` → textfile gauge, atomic tmp+mv. |
| **Exact expr** | `litellm_spendlogs_oldest_row_age_seconds > 90*86400*1.15` (= 103 days) |
| **Backtest** | **YES, decisively.** Today it reads **273 days** against a 103-day threshold — it fires immediately, would have fired **every single day for the last 6+ months**, is completely independent of traffic volume, and self-resolves the moment the sweep genuinely elapses. This is the real regression test for S-02R. |
| **Note on the S-02R success criterion** | A plain `DELETE` returns pages to Postgres's free-space map, **not to the OS**, so `pg_database_size_bytes` will **not** shrink. Only this age gauge (and D5's VACUUM FULL/repack) proves the fix. |
| **Generalise** | Template the table/column so any other retention-bounded store gets the same invariant for free. |
| **Effort / Risk** | small / low |

#### S-10 — `pg_database_size_bytes` 24-hour growth anomaly  *(the volume-anomaly companion, kept)*
| Field | Value |
|---|---|
| **Files** | `modules/monitoring/alerts/database.yaml` |
| **Exact expr** | `delta(pg_database_size_bytes[24h]) > 2*1024*1024*1024`, `for: 30m`, warning |
| **Backtest** | **YES — the strongest new rule in the plan.** Hourly resolution across the real incident: crosses 2 GiB at **2026-07-24 11:00** (2.160 GiB) and rises monotonically 12:00 (2.438), 13:00 (2.721), 14:00 (3.110) — so `for: 30m` is satisfied on the first two consecutive evaluations and it **pages on 2026-07-24, four days before the audit ran and ~15 h after the 07-23 20:00 onset**. (5 GiB would have waited until 07-24 21:00; 10 GiB until 07-27 15:00.) Current value re-verified at plan time: **13.21 GiB/24 h**. |
| **FP margin** | `topk(6, max_over_time(delta(pg_database_size_bytes[24h])[14d:1h]))` = litellm **16.63**, mailarchiver 0.0194, flume-data 0.0139, nodered_events 0.0057, hass 0.0025, openproject 0.0018 GiB — an **857× gap** to the runner-up. |
| **Flap profile (state honestly)** | The condition held 93 of 169 hours over 7 d and dips below 2 GiB mid-window (07-25 17:00 = 1.757, 07-26 01:00 = 0.736), so expect **2–4 fire/resolve cycles**, not one. |
| **Post-restart check** | Prometheus restarted 20:03:43Z today and the 21:00Z/22:00Z samples are continuous with the pre-restart series — `delta()`'s bounded extrapolation produces **no** post-restart spike here. |
| **Nagios mirror** | `for: 30m` → `max_check_attempts = 1+ceil(30/5) = 7` → HARD at ~35 min vs Prometheus 30 min: inside `NagiosMirrorDivergence`'s 30 min tolerance. **The only new rule in the plan that is mirror-consistent by construction.** |
| **Annotation** | Note that a database **RESTORE** also produces a legitimate large positive delta, so the first runbook step is "check for a restore before hunting a runaway consumer". |
| **Effort / Risk** | trivial / low |

**PHASE 3 GATE**
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
systemctl show flume-data-weekly -p ReadWritePaths | grep -q prometheus-node-exporter-textfiles || echo "FAIL: EROFS blocker not fixed"
for m in zfs_dataset_used_by_snapshot_bytes zfs_dataset_used_by_children_bytes \
         gitea_push_mirror_sync_failures flume_cross_check_data_steps_degraded \
         pg_dump_database_dirs litellm_spendlogs_oldest_row_age_seconds; do
  printf '%-46s ' "$m"; curl -sG --data-urlencode "query=count($m)" localhost:9090/api/v1/query | jq -r '.data.result[0].value[1] // "ABSENT"'
done
curl -s localhost:9090/api/v1/rules | jq '[.data.groups[].rules[]|select(.health!="ok")]|length'  # 0
curl -s localhost:3100/prometheus/api/v1/rules | jq '[.data.groups[]]|length'                     # >= 11
# fault injection: raise one cross_check.py handler, run the unit, assert the gauge and the alert
```

---

### PHASE 4 — Daily-report redesign

*Goal: make the four multi-hour criticals nobody noticed impossible to miss, and stop the LLM narrative
from contradicting the facts underneath it. See §6 for the full section layout.*

**The generator (found, verified):** `scripts/log-summarizer.py` — **898 lines**, invoked by the
`analyze-logs` wrapper at `modules/services/monitoring.nix:91-107` (which reads the LiteLLM key from
`/run/secrets/litellm-vulcan-lan-logwatch`), wired into logwatch at `:112-118` as
`analyze-logs --quiet 2>/dev/null || true`, and registered as the customService `ai-log-summary`
(title *"AI-Powered System Log Analysis"*) at `:134-140`. `logwatch.timer` OnCalendar 04:00; current
run time **3 m 54 s**. `services.logwatch.customServices` (`:134-174`) is a list of **10 independent
named sections**, of which `ai-log-summary` is only one — the others (zpool, database-sizes, restic,
certificate-validation, systemctl-failed) are plain scripts. **New deterministic sections belong there,
not inside the LLM path.**

#### R-01 — Section A: 7-day alert history  *(the single highest-value item in the plan)*
* **Files** new `scripts/system_health_report.py` + a customService entry in `modules/services/monitoring.nix`
* **Exact expr** `sum by (alertname,severity) (count_over_time(ALERTS{alertstate="firing"}[7d]))`
* **Backtest** **YES.** Returns **36 series / 36 distinct alertnames in 4 ms** (verified at plan time:
  `count(count by (alertname)(count_over_time(ALERTS{alertstate="firing"}[7d])))` = **36**) — Watchdog
  20150 samples (167.9 h, confirming 30 s sampling), NagiosServicesCritical 17790 (148.2 h),
  ExposedImageFixableHighCVE 10071, SchwabTokenExpiringSoon/Critical 8905 each, HostUnreachable 7994, and
  **CopypartyDown at 2709 samples = 22.6 h** — reproducing the exact outage the audit says nobody saw.
  The copyparty window merges to **one** episode at any tolerance (1354 samples, gap histogram
  `{60s:1353}`, span 22.55 h).
* **Episode merging — adaptive tolerance required.** A fixed tolerance cannot serve both: the group-interval
  histogram is `{60:231, 30:199, 300:55, 15:41, 900:6, 3600:2}`. ConfigFileChangedOutsideDeploy has real
  gaps of `[(60,1572),(660,390)]` → 393 episodes/26.2 h at tol 120–300 but **3 episodes/97.7 h** at tol ≥660.
  Use `tolerance = group_interval + 300 + step`.
* **Duration convention — state it in the header** (the design left it implicit and it inflates short-episode
  alerts by up to `step × episodes`): `firing_h = merged span + one evaluation interval per episode`. Emit
  **both** `raw_span_h` and `firing_h`.
* **Longest single window — one query, no shell run-walking:** `max_over_time((time() - ALERTS_FOR_STATE)[7d:60s])`
  per alertname. (`query_range` of ALERTS at step 60 over 7 d returns 1.14 MB in 12 ms, so the range approach
  is affordable but the run-merging logic is not worth writing.)
* **Self-blinding hazard** R-09R's `keep_firing_for` rewrites the very series this section counts: merging
  OpenClawHttpHealthDown at tol 900 collapses **41 episodes/1.47 h into 4 episodes/8.23 h**. Section A would
  stop saying "flapping 41×" and start saying "sustained 3.75 h". **Mitigation:** count flap episodes from the
  **underlying signal** (`up`/`probe_success`/the rule's own expr), not from `ALERTS`; minimum viable version
  stores the pre-R-09R episode counts as a JSON baseline so the report can show `episodes(alert)=4, episodes(signal)=41`.
* **Regression test** a synthetic series with a genuine **400 s resolve gap** on a 60 s-interval rule must
  report **2** episodes, not 1 — that is the direction the tolerance formula can get wrong.
* **Effort / Risk** medium / low

#### R-04R — Section B: deterministic health invariants
* **Files** same generator
* **Six invariants**, each rendering `PASS` / `FAIL` / **`NOT CHECKED`** (never silently absent):
  * **B1 snapshot amplification** — `zfs_dataset_used_by_snapshot_bytes / zfs_dataset_used_by_dataset_bytes`,
    topk. **Backtest YES:** the exact-proxy ratio over 30 d at step 6 h returns 120 points, min **44.13**,
    max **82.69**, **zero** below 10× — a >10× invariant would have been breached at every sample for
    30 consecutive days, i.e. archetype (a) with a **30-day head start**.
    **Do NOT emit this as an alertable gauge with a static threshold** — see S-01R; report it with the
    annotation *"known-elevated since 2026-06, tracking down from 83×"* since fa3026e and bf1ce08 are
    visibly working (77 → 44 over the window). Replace the guard `usedbydataset > 1 GiB` (a magic constant
    that silently *drops* a dataset instead of reporting it) with an explicit denominator-validity test
    rendering `NOT CHECKED`.
  * **B2** pg_dump completeness (D-11 counters).
  * **B3 Gitea mirror** — `SELECT count(*), sum((last_error<>'')::int) FROM push_mirror` style, credential-free
    column list. **Reproduced exactly: aggregate `12 \| 1 \| 3`; per-mirror `nixos-config \| 1 \| t \| 19661`
    plus 11 rows with `errored=f`.** Key insight: `lag_h=1` (fresh) **while** `errored=t`, so every
    last-update-based check is structurally blind and only the boolean carries signal. Wrap the psql call so
    any failure renders `NOT CHECKED` with the exception class — never a non-zero exit.
  * **B4 chronic availability** — `1 - avg_over_time(probe_success[7d])`, 8 series (verified).
    **TRANSCRIPTION ERROR TO FIX:** the design's table lists *"TL-WPA8630 0.0018"*. Live,
    `1 - avg_over_time(probe_success{instance="TL-WPA8630.lan"}[7d])` = **0.9982**, i.e. 99.82% **UNAVAILABLE**;
    nest-upstairs 0.9719 likewise. Label the column **availability = `avg_over_time`**, not unavailability, to
    stop the inversion recurring, and classify `>0.9 unavailable` as **DEAD / NOT-MONITORED** (candidates for
    removal from blackbox targets) separately from 0.01–0.5 **CHRONIC** (august-lock 0.0999, traeger 0.0812,
    openclaw 0.0583, hubspace 0.0195). Include `avg_over_time(up[7d]) < 0.98` here — verified it returns
    **exactly 1 series, copyparty 0.8651** — because as an *alert* it would fire 100% of the week for 7 days
    after any outage >3.36 h, which is how it gets silenced.
  * **B5** restic per-repo snapshot age and size delta.
  * **B6 HA/VictoriaMetrics sensor liveness** — source the entity names from the **vmalert rules** at `:8880`
    (3 groups / 6 rules, selectors `gal_value{entity_id="water_pool_autofill_total"}`,
    `ppm_value{entity_id="intellichlor_1_salt"}`, `W_value{…}`, `{__name__=~".+_value"}`) rather than
    hardcoding, since VictoriaMetrics has 306 `__name__` values with **zero** autofill/openuv matches.
* **Effort / Risk** medium / low

#### R-02 — Section D: the check-coverage ledger (five-state)
* **Change** For every periodic check on the host render one of **VERIFIED / DEGRADED / VACUOUS / NOT CHECKED /
  FAILED**. Census confirmed by reading the live textfiles: `flume_cross_check.prom` holds exactly 2 series
  (`_last_success`, `_last_run_timestamp_seconds`); `flume_sync.prom` the same shape; `local-backup.prom` only
  `local_backup_last_success_timestamp`; `pg_dump.prom` last_run/last_success/size_bytes. 61 textfiles,
  `node_textfile_scrape_error` = 0.
* **Accuracy fix** the rootCause must say *"reports unit-level failure, cannot report internal step failure"* and
  **cite the 2026-06-15 episode** (see D-10). The 30-day backtest window the design proposed (`06-28…07-28`,
  flat 1) starts **13 days after the counterexample**; use 90 d and assert *"exactly one failure episode despite
  N application errors throughout"* — a **stronger** argument for the third leg, not a weaker one.
* **Do NOT ship `HealthCheckVacuousSuccess` yet.** As a bare `or`-chain over metrics that do not exist it
  evaluates to the empty vector — silent, at `health=ok`, i.e. the exact class R-03 will then flag as dead. Add
  it **in the same commit as D-10's metrics**, written with `absent()` guards so a check that stops emitting
  `items_checked` is NOT_CHECKED-**and-alertable** rather than quiet.
* **Anti-drift** derive the ledger table from the emitting modules (one Nix attrset consumed by both the `.prom`
  writer and a generated JSON) rather than duplicating check names/intervals — otherwise it is a second source
  of truth, which is the docs-truth failure R-11R exists to fix.
* **Also render each `SERVICE_GROUPS` entry** as VERIFIED / NOT CHECKED based on `LoadState` (see R-11R).
* **Effort / Risk** medium / low

#### R-03R — Section C: dead-alert-selector sentinel
`REVISED — three-way verdict, own timer, and a promtool-proven label fix`
* **Files** new `modules/monitoring/services/rule-liveness-exporter.nix`; own timer at 03:30
* **Mechanism (validated)** `/api/v1/parse_query` is live on Prometheus 3.7.2 with no feature flag. The 30-day
  `__name__` window returns **4,153 names** and passes the acceptance test: `api_errors_total` **PRESENT**
  (the critical negative test) while `systemd_unit_state`, `aria2_error_downloads` and
  `grafana_authn_authn_failed_login_total` are **ABSENT**. Do **not** widen the window — unbounded returns
  4,272 names, so 119 exist only outside it; retention is 100 y, so 30 d is a deliberate choice.
* **MANDATORY label fix** Emit the label as **`rule`, not `alertname`.** Prometheus overwrites a sample's
  `alertname` with the rule's own name, so every dead-rule series in the same group referencing the same
  metric collapses to an identical labelset. Proven with `promtool 3.7.2 test rules` on three input series:
  `FAILED: vector contains metrics with the same labelset after applying alert labels`. This is today's exact
  ground truth (`jupyterlab_alerts` has 3 rules on `systemd_unit_state`; `backup_alerts` has 2). **Insidiously,
  the annotation `{{ $labels.alertname }}` renders correctly in a dry run** (annotation templating uses the
  sample's labels, pre-overwrite), so the bug only surfaces as `health=err` in production — which then breaks
  `scripts/post-reboot-validation.sh:402` (*"Prometheus rules: 0 health=err"*).
* **Three-way verdict, not binary** — this removes most of the false-positive surface without a large allowlist:
  * **DEAD** — metric name has zero series over 30 d (the M-03 class). *Alertable.*
  * **MISMATCHED** — metric name has series but the full selector matches none (the M-04 / R-12R class).
    *Alertable, and the most actionable.*
  * **CONDITIONAL** — selector empty now but non-empty at some point in 30 d, or a known error/state counter.
    *Reported, not alertable.* This class is **systematic on this host**: `git_workspace_repo_age_seconds` has
    51 series over 30 d, **0** at an instant, 0 of 37 steps over 3 h, while its textfile is 14 min fresh and
    `git_workspace_stale_repos_total`=0 — per-repo series exist only when repos are stale. Every error counter,
    every `state="failed"` matcher and every condition-gated textfile metric has this shape.
* **Coverage boundary, stated in the module comment** This detects the missing-metric-**NAME** subclass plus
  (with MISMATCHED) empty base selectors — roughly **half** of the 2026-07-28 findings. It does **not** catch
  unit/operator errors (`rate()` on a gauge) or unreachable thresholds. **A clean report does NOT mean there
  are no dead rules.**
* **Add the cheap third check** compare each rule's threshold against `max_over_time`/`min_over_time` of its
  metric over 30 d. Mechanical, one query per rule, and it would have caught **M-11R** (10.7 GB/s vs a max of
  3.7 MB/s), **M-09R** (>0.1/s vs 0.0227/s) and six of M-08's seven thresholds automatically.
* **Escaping rationale — the design's version is half wrong.** Backtick form returns 1445; raw
  `'.*\.service'` in double quotes returns HTTP 400 *"unknown escape sequence U+002E"*; **escaped**
  `'.*\\.service'` also returns **1445 successfully**. The rule is *"backslashes must be escaped in
  double-quoted PromQL strings; backticks avoid the need."* Never hardcode a count in the negative control
  (the design's 1436 is already stale — it is 1445 today); assert *HTTP 400 for the raw form and equal
  non-zero counts for backtick vs escaped*.
* **Extractor FP** with the proposed regex, `and` in `… and on (instance,job) …` matches and would emit a
  bogus `metric="and"` — and **M-08's seven repaired exprs are full of `and on`**, so the two items collide on
  day one. The keyword/function subtraction list must be complete.
* **Decouple from logwatch** own timer at 03:30 writing the gauge plus a JSON the report reads, so the 04:00
  email never waits on ~1,000 queries (measured ~4 min) and a slow sweep cannot delay delivery. The proposed
  rules-API-hash cache **misses exactly on the days someone changed rules** (every `nixos-rebuild switch`),
  i.e. when it matters most.
* **Loki is out of scope for this exporter** — it reads Prometheus's `/api/v1/rules` only; `promtool` cannot
  check Loki rule files either. Say so in the comment, or add the Loki ruler's `/prometheus/api/v1/rules` as a
  second source.
* **Ship threshold above baseline** `PrometheusDeadAlertSelectors > 24` (24 non-allowlisted today) or gate the
  rule behind Phase 2, so it does not debut in a firing state. Depends on `TextfileCollectorStaleDaily` for the
  frozen-verdict case — state that as a dependency, do not assume it.
* **Effort / Risk** medium / medium

#### R-05R — Wisdom-file (suppression surface) control
`REVISED — the design leaves the motivating case still suppressed, and has no migration path`
* **Files** `scripts/log-summarizer.py` (`WISDOM_FILENAME = "known-conditions.prompt"` at :24, delimiter :25,
  split at :344-345, load at :663-666), `history_dir/known-conditions.prompt`
* **State** 33,555 bytes / 278 lines / **266 undated entries**, mtime Jul 28 04:02. (The design's
  *"113 backticked"* is not reproducible as stated: `grep -c` for backticks returns **58**; 93 lines contain
  asterisks; 116 contain either.)
* **(a) MIGRATION — the sharpest defect.** `WISDOM_EXPIRY_DAYS=90` and "keep newest N=120" key on a
  `# first-seen=YYYY-MM-DD hits=N` marker that **zero existing entries carry**. Behaviour is undefined: treat
  undated as expired → all 266 suppressions vanish at once and the 07-29 report is unreadable, burying the
  three real bugs; treat undated as never-expiring → both the expiry and the cap are **inert** against the
  entire corpus (266 > 120, no ordering key). **Fix:** on first run rewrite the file stamping every entry with
  `first-seen=<file mtime date>`, apply the pollution gate **and** the denylist to the existing corpus at that
  moment (dropping ~141 + 24), and print before/after counts in the trailer. One announced, reviewable event.
* **(b) FIX SUPPRESSOR (1) — without this the whole cluster misses its own proof case.** `load_recent()` feeds
  14 prior reports under the instruction at **:423-431**: *"If an issue has already been reported in previous
  reports and appears to be a recurring, known condition, omit it from today's report entirely."* The
  flume-data error was reported 07-28, so from 07-29 it is omitted on that basis alone, with the wisdom file
  never consulted. Replace with *"summarise recurring conditions in one line with a count and first-seen date,
  never omit"*, or gate the dedup instruction on the denylist.
* **(c)** Raise the pollution gate's upper bound from 200 to ~400 chars (20 existing lines exceed 200, max 592)
  and route reject logging to a **file**, not stderr — R-07R pipes stderr into the email.
* **(d)** Emit `wisdom_entries_total` and `wisdom_denylist_rejects_total` as gauges with a rule on the cap, so
  regrowth is alertable rather than only visible in prose. The file grew unreviewed to 266 entries with 116
  polluted lines over ~5 months; one paragraph in one email is too weak a control.
* **(e)** The retention split yields nothing for 90 days — only **15** `.log` files exist (07-14…07-28).
* **Effort / Risk** small / medium

#### R-06R — Stop the narrative contradicting the facts
* **Files** `scripts/log-summarizer.py:407-410, 423-431, 520-527, 540-595`
* **Change** (a) Replace the hardcoded `"SYSTEM STATUS: All systems operating normally"` (:527) and
  `status = "HEALTHY"` (:587→:595) with a verdict **derived from Section A's critical count**. (b) Retitle the
  fallback field to `JOURNALD SEVERITY ROLLUP` (note: this changes text logwatch users may grep — decide the
  string once and share it with R-08R's delivery check via a single Nix let-binding). (c) Add `--max-ai-seconds`
  — currently `self.timeout = 7200` (:306) against a 3 m 54 s run — implemented as a **per-attempt** urllib
  timeout **and** a wall-clock budget across retries, with the deterministic sections asserted flushed before
  the AI call starts.
* **MECHANICAL consistency check, not a prompt instruction.** The design addresses "nothing forces the narrative
  to be consistent with the facts" with… an instruction to the model. Instead: after the narrative returns, if
  Section A reports >0 criticals in 7 d **and** the narrative matches
  `/(none|no critical|all systems|operating normally|HEALTHY)/i`, **replace it with the fallback text and set
  `health_report_ai_narrative_ok = 0`.** That converts an instruction into an invariant and gives R-08R's rule 4
  something real to measure.
* **Also needed** an explicit **application-error section** sourced from Loki, or (c) has nothing to protect —
  the flume schema error reaches **no** section today (see §5, Pattern 6). Cheap: `{job="postgresql"} |= "does not exist"`
  returns 7 over 7 d, and Loki holds ~30 days.
* **Effort / Risk** small / low

#### R-07R — Wire the deterministic report into logwatch
* **Files** `modules/services/monitoring.nix:112-118, 134-140`
* **Change** Add a customService that runs the new generator **before** `ai-log-summary`, and pass its JSON to
  `analyze-logs --facts-json`. `logwatch.service` is `Type=oneshot` with `PrivateTmp=yes` (verified), so a
  `mktemp` facts file is per-run private and safe.
* **SECURITY — do not simply remove `2>/dev/null`.** `analyze-logs` runs with a live LiteLLM API key in its
  environment (:305 reads it; :492-493 builds `Authorization: Bearer …`) and there are 20+ stderr print sites
  including `API connection error: {e}` (:514) and raw journalctl error text (:173/211/228). Per CLAUDE.md's
  OUTPUT CHECK, replace the redirect with an **inline redacting filter in the same command**:
  ```bash
  analyze-logs --quiet --facts-json "$facts" \
    2> >(sed -E 's/(Bearer|[Aa]uthorization|api[_-]?key|token)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g' >&2) || true
  ```
* **Atomicity** have the generator write its JSON with `.tmp` + `os.replace`, and have `analyze-logs` treat an
  unparseable facts file as **absent**, not fatal.
* **Fail-loud, not fail-silent** `pkgs.writeShellApplication` injects `set -euo pipefail`, so a Prometheus
  outage would abort the section and print **nothing** — reproducing this plan's own defect inside its fix.
  Wrap each curl: `out=$(curl … ) || { echo 'PROMETHEUS UNREACHABLE — no alert history available'; exit 0; }`.
* **promtool is NOT on PATH** (verified: `which promtool` → not found; it exists only at
  `/nix/store/iinff711bp4hsw0xbk27mas9xh2mrl9a-prometheus-3.7.2-cli/bin/promtool`). Every verification step in
  this plan that uses promtool must use the absolute store path or `nix run nixpkgs#prometheus -- check rules`.
  Consider adding `pkgs.prometheus` to the dev toolchain.
* **Effort / Risk** small / low

#### R-08R — Self-monitoring for the report
`REVISED — two of the four proposed rules were silent exactly when the exporter is missing`
* **Files** `modules/monitoring/alerts/meta-monitoring.yaml`
* **Rule 1 (evaluable today, verified)** `node_systemd_timer_last_trigger_seconds{name="logwatch.timer"}` exists
  = 1785236400 (= 04:00 today, matching `LastTriggerUSec`). At `> 30*3600` it returns EMPTY (correct healthy
  negative); at `> 10*3600` it returns 1 series value **41177** — so selector, arithmetic and comparison all
  work. **Add `for: 30m` and a zero-guard:** `node_systemd_timer_last_trigger_seconds{name="logwatch.timer"} > 0
  and (time() - …) > 30*3600`, with a **separate** rule for `==0`/absent so a first deploy reports *"never run"*
  rather than *"stale by 56 years"*. (14 timers fleet-wide already satisfy `>30 h`.)
* **Rule 2 (live)** `node_systemd_unit_state{name="logwatch.service",state="failed"} == 1` — 5 live series
  (type=oneshot), so unlike the M-03 class this selector is real.
* **Rules 3 & 4 — MANDATORY `absent()` guards.** I evaluated rule 3 verbatim while `health_report_*` does not
  exist: it returns **EMPTY**, and `absent(health_report_last_run_timestamp_seconds)` returns **1**. So as
  designed, the rules that monitor the new exporter are **silent precisely when the exporter is missing** — the
  vacuous-evaluation defect R-03R exists to detect, reproduced inside the plan's own self-monitoring. Write:
  `absent(health_report_last_run_timestamp_seconds) or (time() - health_report_last_run_timestamp_seconds) > 30*3600 or health_report_last_success == 0 or health_report_sections_rendered < 4`.
* **Rule 5 — NEW: prove DELIVERY, not generation.** All four proposed rules test *"did the generator run"*.
  None tests arrival. logwatch runs `--output mail` to `johnw@vulcan.lan`; a postfix/dovecot LMTP rejection
  yields timer=triggered, unit=success, fresh metrics, sections≥4 and **zero email** — archetype (b) at the top
  of the stack the plan is building. Cheapest honest version: a `doveadm`-based textfile exporter counting
  messages matching the report's subject in INBOX in the last 30 h → `health_report_last_delivered_timestamp_seconds`.
* **Routing** give rule 4 `severity: warning`, or exempt `health_report_*` from R-09R's info null-route — otherwise
  a sibling item in the same plan makes it unnotifiable.
* **Cardinality safe** only **106** named timers are currently exposed (the 1,328 in `/api/v1/series` are
  historical pre-relabel transients), so this does not reopen the 1047→94 incident.
* **Effort / Risk** small / medium

#### R-11R — Write `docs/DAILY_HEALTH_REPORT.md`
* **Change** Document the generator, the wisdom mechanism, retention, and coverage. **Two corrections the design
  would otherwise enshrine:**
  * **Coverage is 12 units, not 17 or 19.** `SERVICE_GROUPS` (`log-summarizer.py:29-38`) declares **17** unit
    names across 8 groups, and **five do not exist** — `systemctl show -p LoadState` returns `not-found` for
    **redis, hass, smbd, nmbd, nfs-server**. So **Samba and NFS are entirely uncovered** while both the code and
    the current doc claim otherwise. Enumerate all three sets (declared / resolving / not-found), name Samba and
    NFS explicitly as a KNOWN GAP with the proving command — better, **fix `SERVICE_GROUPS` in the same change**.
  * **Retention figures.** Prometheus is `storage.tsdb.retention.time=100y` with `ALERTS` back to **2026-03-31
    (~119 d)** — *not* a 7-day bound, so month-over-month statements like *"copyparty availability has been under
    90% for six weeks"* are queryable **today** with no new state file. Loki holds **~30 days**, not ~8 (postgres
    line counts: 14,848 at 8 d, 28,052 at 15 d, 55,340 at 30 d, plateau 55,359 at 60 d).
* **Self-checks must be shape assertions, not exact counts** (`wc -l` ≤ `WISDOM_MAX_ENTRIES + header`), or the
  doc's own verification fails the day after it ships.
* **Make the `SERVICE_GROUPS`-vs-doc agreement a test, not a convention.** Add the doc to the comment-audit pass.
* **Effort / Risk** small / low

**PHASE 4 GATE**
```bash
sudo -u root /run/current-system/sw/bin/analyze-logs --quiet --dry-run | head -80   # sections A-D present
curl -sG --data-urlencode 'query=health_report_sections_rendered' localhost:9090/api/v1/query | jq -r '.data.result[0].value[1]'  # >= 4
curl -sG --data-urlencode 'query=prometheus_dead_alert_selectors' localhost:9090/api/v1/query | jq -r '.data.result[0].value[1]'
# next morning: confirm the 04:00 mail arrived AND that Section A lists CopypartyDown-class history
doveadm search -u johnw mailbox INBOX since 1d subject 'System Health Report' | wc -l   # >= 1
```

---

### PHASE 5 — Alert fatigue: resolve the standing conditions, then route

*Goal: cut the 405–414 emails/week without muting anything real. **Resolve first, route second.***

#### M-21 — Stop `config_file_drift{file="secrets.yaml"}` standing at 1 for 60% of every week
* **Files** `scripts/config-drift-exporter.py`, its module
* **Change** `secrets.yaml` is a **separate flake-input repo** that legitimately changes without a deploy, so a
  deploy-timestamp comparison can never be right for it. Either exclude it, or key it off the secrets repo's own
  git state (`git -C /etc/nixos/secrets rev-parse HEAD` vs the HEAD recorded at last switch).
* **Backtest** `avg_over_time(config_file_drift{file=~".*secrets.*"}[7d])` = **0.600** (verified), while all six
  other tracked files are **0.000**. `ConfigFileChangedOutsideDeploy` contributed **393 ALERTS samples × 15 min
  group interval ≈ 98 h of sustained firing** — the single largest email source.
* **Effort / Risk** small / low

#### M-20R — Order `aide-metrics` After `aide-check`
`REVISED — delete the redundant timer, but KEEP the wantedBy mkForce`
* **Files** `modules/security/aide.nix:112-119` (delete `systemd.timers.aide-metrics`)
* **Change** `aide-metrics.nix:96` already declares `after = [ "aide-check.service" ]` and `:106` already sets
  aide-check's `ExecStartPost` to the metrics script — so the ordering *is* declared and the redundant
  `OnCalendar=daily` timer is what races it. Verified today: **aide-metrics exited 00:00:15, aide-check exited
  00:01:48** — metrics finishes **93 s before** the check it reports on, so the gauge is systematically one day
  stale. Deleting the timer leaves the ExecStartPost path as the sole trigger.
* **KEEP `systemd.services.aide-metrics.wantedBy = lib.mkForce [ ]` at :129.** The design calls it "now-pointless
  defensive"; the in-file comment at :125 says it exists to undo a default. If any other definition supplies a
  `wantedBy`, removing the `mkForce` lets the unit start **at boot against a stale database** — a milder version
  of the bug being fixed, for no benefit.
* **Staleness stays covered** after the timer is gone: `config-drift.yaml:102`
  (`time() - aide_last_check_timestamp_seconds > 2*86400`) and `security.yaml:39`
  (`aide_database_age_seconds > 172800`).
* **Verification** `systemctl show aide-metrics -p WantedBy -p After` — WantedBy empty, `aide-check.service`
  listed; `systemctl list-timers 'aide*'` shows only `aide-check.timer`.
* **Contribution** `AideChangesDetected` = 272 ALERTS samples ≈ **68 h of sustained firing**
  (`changes(aide_changes_detected[7d])` = **6** — it does not flap, it stands).
* **Effort / Risk** trivial / low

#### R-09R — Routing and dwell
`REVISED — the inhibit rule is REJECTED; it manufactures the plan's own archetype`
* **(a) `keep_firing_for` — ship narrowly, behind a test.** `promtool 3.7.2` accepts it and `/api/v1/rules`
  reports it per-rule (currently 0 for `OpenClawHttpHealthDown`). Real inter-flap gaps are **720 s (34×) and
  780 s (3×)**, so start at **`keep_firing_for: 10m`** — above the measured 780 s max gap, below the self-heal
  daemon's `RESOLVED_RETENTION_S=3600` with margin — not the design's 15 m.
  **Gate on a self-heal integration test.** Both chosen alertnames (`OpenClawDiscordWsDown`,
  `OpenClawHttpHealthDown`) are self-heal triggers mapped to `restart_microvm` at `daemon.py:246-247`, which the
  design never mentions. The coupling is *probably* survivable — incidents resolve via the daemon's own
  `probe_clear` (:550) not the resolved webhook, repeat firing webhooks are skipped for non-`in_progress`
  incidents (:473), and `RESOLVED_RETENTION_S` exceeds the dwell — but that rests on **three internals nobody
  examined**, alongside a circuit breaker and a 600 s VM-uptime warmup gate in the same path. Replay
  firing→resolved→firing-within-15m through `handle_alertmanager_payload` and assert **no second
  `restart_microvm` and no circuit-breaker trip.**
  Also note the R-01 self-blinding interaction (flap signal erased from `ALERTS`).
* **(b) info routing — re-severity FOUR rules first, then null-route the rest.** Of 21 info rules, a blanket
  null route would silence: **`HostUnexpectedReboot`** (category=system — on a host whose CLAUDE.md says only the
  user ever reboots, this is a genuine anomaly), **`ContainerCVEScanFailed`** and **`ContainerCVEDBStale`** (a
  failed *scan* is a coverage failure, i.e. the vacuous-check class R-02 exists to surface), and
  **`MicroVMStateShareExporterStale`** (monitoring-meta) — plus **R-08R's own rule 4**. Promote those four to
  `warning`, **then** null-route the remaining 17. Same volume win, no new blind spot.
  Validated with `amtool 0.29.0`: `check-config` SUCCESS; `config routes test severity=info` → digest-only;
  `severity=critical` → default-receiver. Confirmed no info rule carries `service=openclaw/hermes/drafts-mcp`,
  so self-heal routing is **not** affected.
* **(c) inhibit rule — REJECT the general form.** The design's
  `source severity=critical → target severity=warning, equal:[instance,job]` is **strictly worse than the no-op
  it replaces**. Measured blast radius: on `(instance=localhost:9100, job=node)` — the node-exporter target
  carrying nearly every textfile-derived alert — **8 critical alertnames would suppress 11 unrelated warning
  alertnames** (AideChangesDetected, ConfigFileChangedOutsideDeploy, LiteLLMSlowResponse, NagiosHostsDown,
  NagiosServicesCritical, OpenClawChannelPluginMissing, **ResticNoRecentSnapshot**, SchwabTokenExpiringSoon,
  ServiceStuckActivating, UnexpectedWildcardListener, LitellmSlowResponse). `SchwabTokenExpiryCritical` fired
  **148.87 h of the last 168 h**, so for **89% of the week** a stale brokerage token would have blanket-suppressed
  ResticNoRecentSnapshot and NagiosServicesCritical. 17 warning alertnames are suppressible across 6
  instance/job pairs, and 3 alertnames fire with `job=""` (Alertmanager treats both-absent labels as equal,
  widening the match further). **This manufactures the exact archetype the plan exists to fix.**
  **Ship only the targeted rule:** `source_match {alertname: CopypartyDown} → target_match {alertname: TargetDown}, equal: [instance, job]`
  — precise, backtested (both fired **22.58 h** on the same instance+job), zero collateral.
* **(d) `group_by` +instance — DEFER**, exactly as the design proposed. Measure
  `increase(alertmanager_notifications_total{integration="email"}[7d])` for a week against the 36/day baseline first.
* **Backtest / volumes (verified)** email **406.01** and webhook **1979.05** over 7 d; `[1d]` = 36.01. Root route
  `group_by` lacks `instance`, `group_interval=10m`, `repeat_interval=24h`; the openclaw route is 5 m / 4 h.
* **Effort / Risk** small / medium

#### A-98R — matter-server subscription churn: report it, don't page it
`REVISED — the proposed threshold sits BELOW the condition's own normal floor`
* **Files** `modules/monitoring/loki-rules/systemd-errors.yaml` (or a new file + `L+` symlink)
* **Measured** `sum(count_over_time({job="systemd-journal", unit="matter-server.service"} |~ "Subscription Liveness timeout|CASESession timed out" [6h]))` = **265** at plan time (design measured 294). Window sweep:
  `[1h]`=23, `[3h]`=71, `[6h]`=284, `[12h]`=706, `[24h]`=1554. The observed **hourly floor is 21–23**, i.e.
  **126–138 per 6 h — above the proposed 120 threshold.** The churn is chronic and flat, not an event, so the
  rule would be **firing permanently from deploy**, forever, because A-92 classifies the remedy as unscheduled
  mesh work.
* **Ship instead** either (a) a **step-change** detector — 6 h count > 2× the trailing 7 d baseline — or
  (b) an absolute threshold **above the observed ceiling**: `> 600` per 6 h (24 h = 1554 implies ~390/6 h), which
  means *"materially worse than the known-bad baseline"*. Route the **known-bad chronic state to the daily
  report**, not to email. State the current baseline (265/6 h, floor ~126) **in the annotation** so a future
  reader can tell "firing" from "worse".
* **Routing check** `severity: warning` keeps it off the phone — verified only `match = { severity = "critical" }`
  reaches the `iphone-notifier` receiver (repeat_interval 4 h, continue=true).
* **Registration** loki-rules are **not** auto-discovered — `L+` symlink required in `modules/services/loki.nix`.
* **Effort / Risk** trivial / medium

**PHASE 5 GATE** — measured one week after the switch:
```bash
curl -sG --data-urlencode 'query=increase(alertmanager_notifications_total{integration="email"}[7d])' localhost:9090/api/v1/query
curl -sG --data-urlencode 'query=avg_over_time(config_file_drift{file=~".*secrets.*"}[7d])' localhost:9090/api/v1/query  # -> 0
curl -sG --data-urlencode 'query=avg_over_time(aide_changes_detected[7d])' localhost:9090/api/v1/query                    # -> ~0
amtool config routes test severity=info      # digest/null
amtool config routes test severity=critical  # default-receiver
```

---

### PHASE 6 — New coverage for unmonitored subsystems

*Goal: the places nobody was looking. Ordered so prerequisites (C-05R, the Loki deadman) precede consumers.*

#### C-05R — Dedicated promtail scrape for `home-assistant.service` and `node-red.service`
`REVISED — keep ONE priority-drop stage; reclassified large → small`
* **Files** `modules/services/promtail.nix` (pattern already used 3×: sshd `:186-193`, postgresql `:237-246`, vm-egress `:292-305`)
* **The blindness** verified exactly: `sum(count_over_time({job="systemd-journal",unit="home-assistant.service"}[24h]))` → **NO DATA**; node-red → **NO DATA**; matter-server → 4,777. HA's journal priority histogram over 7 d is `{6: 7650, 5: 2}` — **100% of HA's output is priority 6** and therefore dropped by the `[5-7]` filter at `:174-181`. Loki's 11 job values (verified) contain no HA stream.
* **Volume** only **281 lines/7 d** match `\b(ERROR|CRITICAL|FATAL|Traceback|Exception)\b` (~40/day), and **76 TypeError lines since 2026-07-25** (the design said 33; the journal says 76).
* **REVISION 1 — keep a priority-7 drop.** The design says *"no pipeline filter is needed and none should be added."* That is the one risky call: setting `logger: default: debug` in HA (a routine debugging action this repo's own memory records doing) is a 100–1000× volume jump into an unrate-limited stream. Drop **priority 7 only**, preserving 3–6 so every line A-96R/A-97R need still lands.
* **REVISION 2 — the capacity premise is FALSE, so the Y-01 dependency is void.** `systemctl show loki`:
  `MemoryCurrent=657,670,144` (627 MiB) against `MemoryHigh=2,147,483,648` — **30.6%, not 96%**. Peak RSS over
  7 d is 589 MiB, up 25 days, `NRestarts=0`. Verify with `systemctl show loki -p MemoryCurrent -p MemoryHigh`
  rather than the audit's figure. (`MemoryPeak` = 2,150,694,912 *does* marginally exceed `MemoryHigh`, which is
  why a rate limit is still prudent — but it is not a blocker.)
* **REVISION 3 — do NOT include `user@[0-9]+\.service` in the first cut.** That selector is uid-scoped across
  **16 lingering container users**, not unit-scoped, and is the one branch that could genuinely swamp the stream.
  Add matter-server / node-red / others only after each one's own 7-day error-shaped count is measured the same way.
* **Verification** `curl -s localhost:3100/loki/api/v1/label/job/values | grep ha-nodered`
* **Effort / Risk** small / low

#### NEW — Per-job Loki ingestion deadman *(the prerequisite nobody specified)*
* **Why** A-96R, A-97R, A-98R, S-05R and M-14R all depend on Loki streams existing. If a relabel regex is wrong,
  promtail is degraded, or a unit is renamed, the streams silently return no data and every dependent rule
  evaluates **quiet-and-green** — indistinguishable from health. This is the same defect class the whole plan
  is about, one layer up.
* **Change** For each configured Loki job (`ha-nodered`, `sudo`, `kernel`, `sshd`, `postgresql`, `vm-egress`,
  `nginx-access`), a rule of the form
  `sum(count_over_time({job="<j>"}[6h])) == 0` (or `absent_over_time`), tuned per job's expected floor. This also
  **retro-protects the three previously-fixed scrapes**.
* **Effort / Risk** small / low

#### A-96R — HA `climate.set_temperature` TypeError detector
`REVISED — both proposed thresholds are miscalibrated and produce FALSE NEGATIVES on the very fault`
* **Files** new `modules/monitoring/loki-rules/home-assistant.yaml` + `L+` symlink
* **Measured from the journal (same source promtail reads).** Per-day TypeErrors: 07-25 **11**, 07-26 **12**,
  07-27 **10**, 07-28 **3**. The design never built the **hourly** histogram; events cluster in small bursts with
  a **max of 6/hour** (07-25T01=6, 07-25T02=2, 07-26T12=4, 07-27T00-05=1/2/2/2/1, 07-28T14=3).
* **Why the design fails** Rule (1) `>3 per 6h` fires in only ~4 of 16 six-hour windows, and today's single
  cluster is **exactly 3 — not >3**, so the design's own claim that it "is still exceeded today" is
  arithmetically wrong. Rule (2) `>5 per 1h` is crossed **once in 96 hours**. Worse, `Error executing service`
  returns counts **identical** to the TypeError on all four days (11/11, 12/12, 10/10, 3/3), so it is not a
  wider net at all on current data.
* **Ship instead**
  * `sum(count_over_time({job="ha-nodered",unit="home-assistant.service"} |= "unsupported operand type(s) for -: 'float' and 'NoneType'" [6h])) > 0`, `for: 15m` — **this fault should never occur at all**; a single occurrence means a setpoint was silently dropped. Fires on all 17 observed cluster-hours instead of 4 of 16 windows.
  * Re-scope the class-level net to `count_over_time({…} |= "Error executing service" [24h]) > 5` and **re-derive
    the threshold after 7 days of real HA data**, at which point it will start matching non-TypeError failures the
    journal window cannot show today.
* **Backtest** cannot be evaluated in Loki until C-05R lands; validated against the journal.
* **Effort / Risk** trivial / low

#### A-97R — Node-RED Pool-tab / OpenUV chain detector
* **Files** same new Loki rule file
* **Ship** `sum(count_over_time({job="ha-nodered",unit="node-red.service"} |= "OpenUV forecast missing or too short" [24h])) > 0`, `for: 5m`. **Well-calibrated:** counts are 07-25 **0**, 07-26 **2**, 07-27 **2**, 07-28 **1** — crosses on 3 of 4 retained days, and `>0` is insensitive to burst size.
* **REVISE the companion** `HaRestFetchTimeouts` at `>2 per 6h` would essentially never fire — HA openuv-tagged error lines run at **1–2 per DAY** (~0.5/6 h). Use `|= "Timeout while fetching data" [24h] > 2`, `for: 15m`.
* **Known shape** the `[24h]` window means the alert stays firing a full day and re-fires each morning — ~1 email/day while the upstream sensor is broken, acceptable, but it cannot distinguish "failed once" from "failing daily". Narrow to `[6h]` if per-incident resolve/refire is wanted.
* **Effort / Risk** trivial / low

#### M-23R — UPS/NUT monitoring
`REVISED — the battery rule as designed pages falsely on every recovery`
* **Files** `modules/monitoring/services/` (new), `docs/ports.txt` (**register 9199 — required by CLAUDE.md**), new alert file
* **Verified gap is total** `count({__name__=~"nut_.*|network_ups_.*"})` → **ZERO SERIES** (re-verified at plan
  time); a scan of all 534 rules for ups/nut/network_ups/battery returns **none**; 9199 absent from
  `docs/ports.txt` and nothing listening. NUT itself is live (`upsd`+`upsmon`, UPS `apc` = APC Back-UPS RS 1000MS,
  status OL / charge 100 / runtime 2601 s / load 15) behind an automated `systemctl poweroff` path
  (`nut.nix:107` service, `:117` timer, `:49-51` logger-then-poweroff).
* **Not from scratch** `services.prometheus.exporters.nut` exists in nixpkgs 25.11 (`nutServer`/`nutVariables`/
  `listenAddress` confirmed) and `pkgs.nut-exporter` is 3.2.2.
* **Rules — pin exact series names by curling `:9199/metrics` FIRST** (the names below are the expected shape,
  **UNVERIFIED until the exporter runs**):
  * `UpsOnBattery`: `network_ups_tools_ups_status{flag="OB"} == 1`, **`for: 2m`** (not 1 m — the UPS exists to absorb sub-minute utility blips).
  * `UpsBatteryLow`: **must be gated on actually being on battery** — `network_ups_tools_battery_charge < 60 and on() network_ups_tools_ups_status{flag="OB"} == 1`, or better key off the hardware's own `flag="LB"`. The design's charge-only form pages **critical** (→ `iphone-notifier`, repeat 4 h) for the tens of minutes of *normal recharging* after any power event — i.e. right after the operator has already dealt with it. Keep 60 above `nut.nix`'s 50% poweroff so the page still precedes the shutdown.
  * `UpsRuntimeLow`, `UpsExporterDown` (`up{job="nut"} == 0`).
* **Missing rule the design omitted** `up{job="nut"}==0` catches a dead exporter but **not** upsd losing
  communication with the UPS while the exporter serves stale or zero values. Add staleness/`absent()` checks on
  the `network_ups_tools_*` series themselves plus a driver-state check.
* **Effort / Risk** medium / low

#### M-24R — Alert on the automated poweroff path
`REVISED — the design's rule cannot deliver, and its second matcher never matches`
* **Files** `modules/services/nut.nix:49-51`; new Loki rule
* **Two defects in the design** (i) `nut-low-battery-poweroff` is the syslog **tag**, not message text, and the
  message says *"initiating poweroff"*, not *"powering off"* — the design's second branch would never match.
  (The first branch *does* match, but only because the main journal scrape sets `json = true` (`promtail.nix:~122`)
  so the Loki line is the whole entry serialised as JSON including `SYSLOG_IDENTIFIER` — a fragile coupling worth
  a comment: flip `json` to false and the rule silently stops matching.) (ii) **Fatal:** `nut.nix:51` is
  `exec "$SYSTEMCTL" poweroff`. promtail, Loki, the ruler and Alertmanager all run on the host being powered off;
  the line must be batched, ingested, evaluated on the group interval, grouped (`group_wait`) and handed to
  Postfix **while systemd is SIGTERMing all of them.** The design's own positive test
  (`logger -p daemon.warning 'nut-low-battery-poweroff TEST'`) passes forever precisely *because* nothing is
  shutting down.
* **Ship instead** (a) **notify synchronously from the script, before the poweroff** — insert a blocking
  best-effort notification between the logger line and the `exec`: a `curl --max-time 5` to the existing
  Healthchecks/watchdog ping URL (already a SOPS secret + `LoadCredential`) and/or the iPhone push path.
  (b) Write `nut_low_battery_poweroff_timestamp_seconds` as a **textfile gauge before the exec** and alert on
  `time() - nut_low_battery_poweroff_timestamp_seconds < 86400` — a timestamp survives arbitrary downtime and is
  immune to both log retention and the shutdown race. (c) Keep a Loki rule as the durable forensic record, but
  **widen the window to `[24h]`** (the design's `[1h]` is relative to *evaluation* time, so if the host stays
  down longer than an hour — the only scenario this rule exists for — the line is already too old post-boot and
  the rule **never fires**) and match the MESSAGE text as well as the tag.
* **Also add** a rule for the opposite silent failure: the poll script exiting as a no-op because `upsd` is
  unreachable — which is how the shutdown protection dies quietly.
* **Effort / Risk** small / low

#### M-14R — Make `SudoAuthFailures` fireable
`REVISED — the sshd template's keep-rule matches ZERO sudo lines, and the unit label is a cardinality bomb`
* **Files** `modules/services/promtail.nix`, `modules/monitoring/loki-rules/auth-security.yaml`
* **Verified dead** `/var/log/sudo.log` is 0 bytes; `grep -c logfile /etc/sudoers` = 0; **2,120 sudo journal
  entries in 24 h, 2,119 at priority 5** (one at 1), all dropped by `[5-7]`; Loki's 11 job values contain no
  `sudo`. Volume over 7 d is 3,550 lines (~507/day) — negligible ingest.
* **CORRECTION — load-bearing.** A 24 h census of `SYSLOG_IDENTIFIER=sudo` shows units
  `{user@1000.service: 2092, session-915033.scope: 26, hermes-self-heal.service: 2}` — **there is no
  `sudo.service`.** Copying the sshd template's `__journal__systemd_unit` keep-rule (regex `"sshd\\.service"`)
  matches **exactly zero** lines and would ship a rule that looks deployed and detects nothing. Use
  `__journal_syslog_identifier` with regex `"sudo"`, `action=keep`, **no priority-drop stage**.
* **CARDINALITY — the 1047→94 timer class.** Do **not** carry the `unit` relabel: values include
  `session-NNNNNN.scope` with a monotonically increasing counter (already at 915033) — **33 distinct session
  scopes in 7 days ≈ 37 new Loki streams/week, unbounded and never reclaimed.** Either drop the `unit` label for
  this job, or normalise with a replace stage collapsing `session-[0-9]+\.scope` → `session.scope`. Keep
  host/job/priority/syslog_identifier/process only.
* **Threshold** re-measure the baseline over 7 d **after** the stream exists, before trusting `>3 per 15m` —
  `user@1000.service` is where interactive (and agent) sudo lands, so three password prompts will page.
* **Context** `logwatch` already has a `{ name = "sudo"; }` section (`monitoring.nix:145`), so what is missing is
  **real-time alerting**, not visibility.
* **Verification** `curl -s localhost:3100/loki/api/v1/label/job/values | grep sudo`
* **Effort / Risk** small / low

#### D-14 / S-05R — BOT-mode USB failure vocabulary
`REVISED — do not rely on priority surviving the filter; guarantee ingestion`
* **Files** `modules/services/promtail.nix` (new kernel scrape), `modules/monitoring/loki-rules/uas-enclosure.yaml` (+ existing `L+`)
* **Why** The `usb-storage.quirks=1e91:a4a7:u` mitigation is applied (verified in `/proc/cmdline`; `lsmod` shows
  `uas 65536 0`), so `uas_eh_abort` and `scsi host N uas` are **impossible by construction**, and two more
  patterns are KERN_INFO and dropped. Only `err -108` and `sd[a-d].*ESHUTDOWN` remain live — **2 of 5**.
* **The design's load-bearing claim is UNVERIFIED** — *"all of which are priority 3 and therefore survive the
  filter"* is asserted, not measured, and cannot be measured: `journalctl --list-boots` only reaches back to
  2026-07-02 and **none of the four strings has ever appeared**. If even one is emitted at KERN_INFO the promtail
  drop eats it and the rule ships dead on arrival — precisely how the two already-dead KERN_INFO patterns got
  that way.
* **Ship instead** a dedicated **no-priority-drop** promtail scrape keyed on `__journal_syslog_identifier="kernel"`
  with a content filter on `usb-storage|scsi host[0-9]+|rejecting I/O|Synchronize Cache`, exactly the C-05R
  pattern. Volume is trivial and it makes the priority question **irrelevant instead of assumed**. Then scope the
  rule to that job — the design's bare `{job="systemd-journal"}` drops the file's deliberate
  `syslog_identifier="kernel"` anchoring (which exists so routine keyboard/phone replug events do not match) and
  costs ~380 MB / 5.3 s per 7-day evaluation.
* **Threshold** `> 3 in 10m` is a **guess** — the baseline is unmeasurable because the failure has not recurred
  (the proposed LogQL over `[7d]` returns an empty vector, scanning 379,988,464 bytes / 102,883 lines in 5.34 s;
  a raw journal grep for all four strings returns 0 at any priority). On the host's most dangerous failure mode,
  **too high is the expensive direction** — start at `> 0 in 10m`, `severity: warning`, and raise only if noise appears.
* **Effort / Risk** small / low

#### M-15R — Chronic **flapping** availability (the alert), chronic **level** (the report)
`REVISED — the avg-only form fires 100% of the week on two rules; split by shape`
* **Files** `modules/monitoring/alerts/network.yaml`
* **Two distinct shapes, two different homes:**
  * **Long single outage** (copyparty 22.6 h) — **already paged** (`CopypartyDown` fired 2,709 samples;
    `TargetDown` too). The failure was that nobody *read* it. → fixed by **R-01**, not by a new alert. The
    guarded `up` form was **already firing before** the 07-23 outage began (06:00Z 0.8988 … 20:00Z 0.8216) and is
    **still** firing 5 days later — it fires 337/336 steps = **100% of the week**.
  * **Flapping below the dwell** (august-lock-garage-door at 90%) — **never pages**. → the new rule.
* **Exact expr — SHIP (verified: returns exactly 1 series, `august-lock-garage-door.lan`)**
  ```promql
  changes(probe_success{host_group!~"iot-noping|iot-quiet"}[7d]) > 100
    and avg_over_time(probe_success{host_group!~"iot-noping|iot-quiet"}[7d]) < 0.98
  ```
  `for: 30m`, `severity: warning`. The exclusion is what makes it clean: `topk(6, changes(probe_success[7d]))` is
  traeger-grill **2744** (`iot-quiet`, deliberate), **august-lock-garage-door 2056** (`iot`, the genuine fault),
  nest-upstairs 1038 (`iot-noping`, registered non-responder), tesla-wall-connector 158, august-lock-side-door
  124, ring-chime-office 90.
* **`up`-side equivalent verified quiet:** `changes(up[7d]) > 10 and avg_over_time(up[7d]) < 0.98` returns
  **0 series** (openproject has 14 changes but ≥0.98 availability), so it is a prospective detector with **no
  day-one noise** — ship it too, `severity: info`.
* **Dead-series guard is NOT sufficient over a window** — the design's `present_over_time[15m]` guard is a
  point-in-time property presented as a general one: **TL-WPA8630.lan fired for a full 24 h** and
  august-lock-side-door for 16 h while their removed series were still inside the window. The `changes()`
  requirement incidentally fixes this (a removed target stops changing), but add an explicit removed-target
  exclusion list anyway.
* **Exclude** `job="blackbox_openclaw"` (dedicated coverage; `HostUnreachable` 2,330 samples/7 d).
* **Chronic *level* goes in the report** — B4 in R-04R, where a 7-day tail is a feature rather than 168 h of paging.
* **Effort / Risk** small / low

#### M-18 — Public-edge probes for the 2 unmonitored tunnelled hostnames
`count by (job)(probe_success)` shows `blackbox_https_public` has exactly **2** targets (verified) while
`cloudflare-tunnels.nix` declares four ingress hostnames. Both unmonitored names work today (gitea 200, shlink
404). The module's `valid_status_codes` already accepts 404, so this needs **no module change** and does not
create a permissive probe. *trivial / low.*

#### M-19 — Add `memory-mcp.vulcan.lan` to `blackbox_https_auth`
A genuine standalone nginx vhost (`modules/containers/memory-vault-quadlet.nix:118`) with its own certificate and
a Nagios cert check but **no HTTP availability probe**. Returns 404 at `/`, which `blackbox_https_auth` already
accepts — one-line target addition. *trivial / low.*

#### M-22 — Labelled per-listener series from `port-drift-exporter`
`avg_over_time(port_drift_unexpected_wildcard_listeners[7d])` = **0.294** (verified) — non-zero 29% of the week,
including one unbroken **24.7-hour critical** on 07-21/22. The exporter records only a **count**, so what bound
the wildcard is unrecoverable after the fact (see M-93 in §9). Emit port/process labels alongside the count so the
next occurrence is diagnosable. *small / low.*

#### A-01 — Make `openclaw-self-heal` emit structured log lines like `hermes-self-heal`
The daemon has emitted **ZERO** journal lines in 5 days of uptime with `StandardOutput=journal` and
`LogLevelMax=-1`, while `hermes-self-heal` — same design — logs a startup banner and a line per remediation. So
this is the daemon, not journald retention. Consequence: **74 lifetime `restart_microvm` actions** and the
47-restart 10-hour storm on 07-23 left **no diagnosable trace**, and `incidents.json` is frozen at 07-23 11:59
while the heartbeat gauge ticks. This makes the **next** storm reconstructable; 07-23 is forensically closed
(A-93, §9). *small / low.*

#### M-92R — Per-cgroup memory exporter
`REVISED — the burst-only rule misses the chronic case, and the peak rule latches forever`
* **Verified gap is total** a census of `{__name__=~".*memory.*(current|high|max).*"}` returns only
  `process_virtual_memory_max_bytes`, `microvm_memory_current_bytes`, `redis_memory_max_bytes`, `grafana_*`;
  node_exporter's systemd collector exposes no `MemoryCurrent`/`MemoryHigh`. Inputs are present and root-readable:
  `/sys/fs/cgroup/system.slice/<unit>/{memory.current,high,max,peak,events,swap.current,pressure}`. Resolve the
  cgroup path from `systemctl show -p ControlGroup`, not a hardcoded `system.slice`. Counts and bytes only — no PII.
* **Chronic tier is MANDATORY.** The design rejected proximity alerting on a claimed *"0 events over a clean 30-second
  window"*. **I could not reproduce that zero:** three samples 20 s apart on postgresql's `memory.events` read
  `high = 3866038, 3866039, 3866041` — a continuous **~0.05 events/sec** trickle sustained at **99.7–99.8% of
  `memory.high`**. The truth is **both**: a permanent low-rate reclaim floor **plus** large bursts (+178,537 in
  8 minutes). So `rate(cgroup_memory_high_events_total[15m]) > 10` catches only the bursts and leaves the chronic
  case — the whole reason Y-01 exists — with **no detector**. Emit
  `cgroup_memory_pressure_full_avg300_ratio` (from `memory.pressure`, verified readable) and alert on sustained
  non-zero full-pressure (e.g. `> 1 for 30m`), the canonical cgroup-v2 "stalled on memory" signal.
* **Drop the peak rule as designed.** `memory.peak` is **monotonic for the life of the cgroup** — it resets only
  on restart, so `peak > high for: 1h` works exactly once (right after the switch restarts the units) and is a
  permanently-firing info alert thereafter. Use `max_over_time(cgroup_memory_current_bytes[6h]) > cgroup_memory_high_bytes`
  (windowed, self-clearing), or emit peak as a dashboard series only.
* **Hard-code the unit list** (5 units × 6 series = 30) with a comment **forbidding a glob** — that is the 1047→94 shape.
* *small / medium.*

#### Y-01 — Raise `MemoryHigh`/`MemoryMax` for postgresql, loki, home-assistant
* **Files** `modules/core/memory-limits.nix`
* **Measured** postgresql `MemoryCurrent=3,751,444,480` vs `MemoryHigh=3,758,096,384` = **99.8%**,
  `MemoryPeak=3,786,473,472`, `MemorySwapCurrent=124,223,488`, `memory.events high=3,679,581` over 25 days,
  `pgscan_direct:pgscan_kswapd` **11:1** (reclaim happening synchronously inside postgres's allocation path).
  loki `MemoryPeak=2,150,694,912` **exceeds** `MemoryHigh=2,147,483,648`. home-assistant `MemoryPeak=1,611,841,536`
  exceeds its own `MemoryHigh=1,610,612,736` with **436 MB** in cgroup swap. `oom_kill=0` everywhere.
* **Headroom question answered:** total RAM **62 G with 35 G available**, so the proposed Max sum
  (pg 6 G + loki 3 G + HA 2.5 G = **11.5 G**) is comfortable.
* **Write the CORRECTED characterisation into the module comment** — *"sustained 99.8% of memory.high with a
  continuous ~0.05 events/sec reclaim floor **and** periodic bursts of ~10⁵ events, measured 2026-07-28"* — because
  that distinction is load-bearing for M-92R's rule design.
* **Acceptance** the event **floor** should drop toward zero, not merely the bursts shrink. If the floor persists at
  the new ceiling, postgres's working set is genuinely larger than 5 G and `shared_buffers`/`work_mem` should be
  examined rather than raising the cgroup again.
* *small / low.*

#### M-91R — Home Assistant entity-availability exporter
* **Verified gap is total** `count({__name__=~"hass.*|homeassistant.*"})` → **NO_DATA** (re-verified); a full
  `__name__` census of VictoriaMetrics (306 names) contains nothing matching `entity` or `unavail`. So "163
  entities dark >24 h" is currently **unrepresentable**.
* **Counts only** — HA `entity_id`s leak device and household detail. Emit aggregate + per-domain counts.
* **QUERY COST — measure before scheduling.** The proposed `DISTINCT ON (entity_id) … ORDER BY entity_id,
  last_updated_ts DESC` over the full `states` table is a full scan plus sort unless a matching index exists, and
  it would run against the postgres instance measured at 99.8% of `memory.high` with 124 MB already swapped —
  i.e. it could **worsen the condition Y-01 is relieving**. Run `EXPLAIN (ANALYZE, BUFFERS)` once by hand and
  **record the timing in the module comment**. Default to **15 minutes**, not 5, and set a `statement_timeout`.
  If the plan is a full scan, rewrite with a LATERAL join:
  `FROM states_meta m CROSS JOIN LATERAL (SELECT state,last_updated_ts FROM states s WHERE s.metadata_id=m.metadata_id ORDER BY s.last_updated_ts DESC LIMIT 1) x`
  — one giant sort becomes per-entity index lookups. Use the existing read-only role, not the superuser.
* **Ship with NO alert** (not a disabled-by-threshold alert) until **A-U2 / decision D9** resolves the debris:
  ~37 of the 163 are orphaned `calendar.*_2` / `sensor.water_*_gated_gpm_2` twins plus superseded flume-window
  sensors, so a threshold set against today's 163 would encode known-dead entities as normal.
* **Add the recorder-freshness guard** — if the recorder stops writing, these counts **freeze** and a frozen
  number reads as healthy. Emit `max(last_updated_ts)` age alongside.
* *medium / medium.*

#### A-U1s — Schwab: alert on the truthful input, never on the lying gauge  *(gated on decision D3)*
* **Exact expr (verified FIRING today)** `(schwab_refresh_token_expiry_timestamp_seconds - time()) < 0`,
  `for: 1h`, `severity: warning`. Value at plan time: **−34.22 days**.
* **Non-flapping proven, not asserted** `changes(schwab_refresh_token_expiry_timestamp_seconds[7d])` = **0**,
  versus `changes(stock_trader_data_source_up{source="schwab"}[24h])` = **8** and
  `avg_over_time(…[24h])` = **0.9746** — the up-gauge reads UP 97% of the time while the source has been dead 34
  days, which is plausibly the flapping that got the old alert disabled in `ee03dd75`.
* **Add the absent-arm** `or absent(schwab_refresh_token_expiry_timestamp_seconds)` at `for: 1h` — otherwise a
  `< 0` comparison over an empty vector silently yields nothing and the alert **resolves and looks healthy at
  the exact moment monitoring dies**.
* **Optional 3-day lead tier** — re-auth needs browser OAuth on hera and only the user can do it, so lead time is
  the difference between a scheduled re-auth and another 34-day outage.
* Annotations: **timestamps and day-counts only**, never any OAuth value.
* *trivial / none.*

**PHASE 6 GATE**
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
curl -s localhost:3100/loki/api/v1/label/job/values | jq -r '.data[]'      # must now include ha-nodered, sudo, kernel
curl -sG --data-urlencode 'query=count({__name__=~"network_ups_tools_.*"})' localhost:9090/api/v1/query
grep -q '^9199 ' docs/ports.txt || echo "FAIL: port 9199 not registered"
for m in cgroup_memory_pressure_full_avg300_ratio hass_entities_unavailable_total nut_low_battery_poweroff_timestamp_seconds; do
  printf '%-46s ' "$m"; curl -sG --data-urlencode "query=count($m)" localhost:9090/api/v1/query | jq -r '.data.result[0].value[1] // "ABSENT"'
done
curl -s localhost:3100/prometheus/api/v1/rules | jq '[.data.groups[].rules[]|select(.health!="ok")]|length'  # 0
```

---

### PHASE 7 — Backup integrity and hygiene

*Ordering inside the phase is load-bearing: **M-11R's zero-guard → B-02R → B-01**. Shipping B-01 on top of an
uncorrected B-02R would add bit-rot detection and simultaneously silence it.*

#### B-02R — Stop one bad repo skipping the integrity check for every later repo
`REVISED — the design's idiom is ACTIVELY HARMFUL; I ran it and it converts a loud failure into a silent success`
* **Files** `modules/lib/resticOperations.nix:17-35`
* **The design's proposal fails, empirically.** `if ! ( unlock||true; check; prune; repair snapshots ); then …`
  inside a `writeShellApplication` (`set -euo pipefail`): **bash ignores errexit inside a compound command in a
  condition context, and that suppression propagates into subshells.** Running the exact structure with repo a's
  check failing printed `CHECK a FAILS`, then **`PRUNE a RAN`** and **`REPAIR a RAN`**, then processed b, and
  **exited 0** — the `!!! a failed` branch never executed and `$failed` stayed empty. Two compounding bugs:
  prune/repair still run after a failed check, and the subshell's status is that of the **last** command
  (`repair snapshots`), so a failing check is **masked by a succeeding repair**. Net effect: today's loud failure
  (unit fails → `OnFailure=backup-alert@restic-check.service` → `restic_integrity_check_success=0` →
  `ResticIntegrityCheckFailed` pages) becomes a **silent success with `restic_integrity_check_success=1`.**
  I also tested the two natural repairs — adding `set -e` inside the subshell, and using the subshell as the left
  operand of `||` — and **both produced identical broken output and exit 0.**
* **The one form that works (verified: printed `!!! a failed (rc=1)`, SKIPPED a's prune, still processed b, exited 1):**
  ```bash
  rc=0; failed=""
  for fileset in ${attrNameList backups} ; do
    set +e
    ( set -e
      /run/current-system/sw/bin/restic-"$fileset" unlock || true
      /run/current-system/sw/bin/restic-"$fileset" --retry-lock=1h check "$@"
      /run/current-system/sw/bin/restic-"$fileset" --retry-lock=1h prune
      /run/current-system/sw/bin/restic-"$fileset" --retry-lock=1h repair snapshots
    ); s=$?
    set -e
    if [ "$s" -ne 0 ]; then echo "!!! $fileset FAILED (rc=$s)"; failed="$failed $fileset"; rc=1; fi
  done
  if [ -n "$failed" ]; then echo "FAILED REPOS:$failed"; fi
  exit $rc
  ```
  (Alternative: run the per-repo body as a separate process — `if bash -c '…'` — whose own errexit cannot be
  suppressed by the parent's condition context.) Note the trailing `[ -n … ] && echo` form must be `if/fi`;
  under errexit it would exit 1 on the empty case were `exit $rc` not immediately after.
* **The per-repo gauge must ship WITH its writer or not at all.** The design pairs a new alert
  `restic_integrity_check_repo_success == 0` with **no specified writer** — as filed it would ship a brand-new
  permanently-dead rule (the exact defect M-03 deletes three of) and be auto-mirrored into Nagios, producing the
  `nagios_only` asymmetry the reconciler exists to catch. Either specify the writer concretely (in-loop textfile
  append with `mktemp`+`trap`, one line per repo, then `chmod 644`) **in the same commit**, or drop the alert.
* **Verification (negative test, all three properties)** add a bogus tenth fileset and assert: later repos are
  still visited; the `FAILED REPOS` line names the bad one; **and** the unit reports `Result=failure` with
  `restic_integrity_check_success=0`.
* **Effort / Risk** small / medium

#### B-01 — Add `--read-data-subset` to the weekly restic integrity check
* **Files** `modules/lib/resticOperations.nix`, `modules/storage/backups.nix` (timer)
* **Change** Add `--read-data-subset=2%` (restic 0.18.1 accepts `x%`/`x.y%`/size suffixes — verified via
  `restic help check`). Today's check is **metadata-only** — 9 repos, ~1.47 TB, in **6 m 42 s** — so offsite
  bit-rot in B2 is undetectable. De-herd to **06:30** (verified clear: the last scheduled job before it is
  restic-backups-Video at 05:30:11–05:30:18, seven seconds; Photos at 04:40). `restic-check.timer` is
  Mon-00:00 (LAST 2026-07-27, NEXT 2026-08-03), so the de-herd rationale holds.
* **Cost** ~30 GB of B2 egress per week (2% of 1.47 TB) — see decision **D10**.
* **Add `RuntimeMaxSec=4h`** — the unit is `Type=simple`, so `TimeoutStartSec=1m30s` does not bound it and
  **nothing else does either.** A B2 slowdown could leave the check holding exclusive locks into the next
  night's 02:10–05:30 herd, whose jobs carry only `--retry-lock=5m` and would then fail. A killed check reports
  failure through the existing `OnFailure` path — the correct outcome.
* **Make it backtestable** emit `restic_check_read_data_subset_percent` and a per-repo pass/fail gauge from the
  same `ExecStopPost` that already writes `restic_integrity_check_success` — otherwise the next incident is as
  un-backtestable as this one (there is no read-data history because no read-data pass has ever run).
* **HARD DEPENDENCY** land **M-11R's zero-guard (or the restic-metrics writer fix) first.** Stretching the check
  from 6 m 42 s to 1–3 h raises the probability of overlapping the 6 h `--no-lock` metrics collector from ~2% to
  **17–50% every Monday**; a failed `stats` write of 0 then produces a spurious M-11R page of up to +220 GiB
  **and** a CRITICAL `ResticNoSnapshots` that stays 0 for up to 6 h. (I verified `restic-metrics` uses
  `--no-lock` on all four read-only calls, so it does **not** deadlock against the exclusive lock — that
  hypothesis was wrong; the hazard is the failed-read zero.)
* **Effort / Risk** small / medium

#### B-U1 — Off-site (B2) coverage for the three excluded backup sets  *(gated on decision D8)*
* **Files** `modules/storage/backups.nix:134-145` (`backupExcludes`)
* **Phase A — do as TWO SEPARATE NIGHTS, not one, and kick off MANUALLY at a daytime hour with the enclosure
  under no other load.** TechnitiumDNS (158 MiB) alone first to prove the path, then Machines (307 GB) on its own
  night. The 03:30 `Backups` timer sits **20 minutes** before Home (03:50), then Public (04:10), Photos (04:40),
  Video (05:30) — a multi-hour first upload overlaps all of them. Different repos means different locks, so there
  is no lock failure, but B2 bandwidth, compression CPU **and USB read load on the enclosure whose documented
  failure mode is load-induced (2026-06-02)** all stack. **This is the one risk in the plan that can take the
  pool offline.** Watch `journalctl -k` for `uas_eh_abort` / `err -108` during that first upload and abort if any appear.
* **Pre-silence** M-11R and `ResticRepoSizeShrunk` for `repository="Backups"` for 14 days, dated:
  `min_over_time(restic_repo_size_bytes{repository="Backups"}[30d])` = **300.64 GiB**, so adding Machines roughly
  **doubles the repo in one night** — a delta 30× the new 10 GiB threshold.
* **Phase B (PostgreSQL) is gated on Phase 1 + decision D5** — do not upload a 33 GB uncompressed litellm dump
  nightly. Confirm `restic-Backups cat config` shows repo version 2 (0.18.1 defaults to v2/compression=auto).
* **Verified premise** the repo named `Databases` holds **DEVONthink data**, not the dumps
  (`restic-Databases --no-lock ls latest` → `/tank/Databases/AI.dtBase2/…`), so PostgreSQL, TechnitiumDNS and
  `Machines/Vulcan/{etc,home,var}` are genuinely single-copy on the enclosure.
* **Effort / Risk** medium / medium

#### C-01R — Dovecot key-backup permissions
`REVISED — the recurrence rationale is FALSIFIED, and one of the two chmods can break IMAP`
* **Verified artifact (metadata only)** `/var/lib/dovecot-certs/imap.vulcan.lan.key.bak.20250924-161750` is
  `-rw-r----- johnw users`, 1704 bytes, beside a correct `-rw------- root:dovecot2` live key of the same size.
  `getent group users` → `users:x:100:` (empty), so the **group** half is unreachable; the **owner** half is not —
  anything running as johnw can read a copy of the live IMAP TLS private key with no sudo.
* **FALSIFIED premise** the design says *"bare `cp` does not preserve mode… that is exactly how a 0600 root key
  became a 0640 johnw file, and it will happen again."* I tested `cp` at five umasks (000/002/022/027/077): a 0600
  source produced a **0600** destination in **every** case; a 0640 source produced 0640. GNU `cp` creates the
  destination with the **source's** mode; umask does not widen it. And the copy is **johnw-owned**, so the script
  ran as johnw — who could not have read a 0600 root:dovecot2 key at all. The 0640 file is **historical residue**
  from a period when the live key was itself group-readable (since closed at the source), **not** an active
  recurrence mechanism.
* **Ship** (a) `shred -u` the `.bak` — correct and safe, the live key is present and healthy.
  (b) **Do NOT blind-chmod `/var/lib/dovecot/users` to `600 root:root`** — it is Dovecot's passwd-file auth
  database; if the auth worker drops privileges, 600 root:root breaks **every IMAP login**, discovered only at
  next login. First read the effective uid of the dovecot auth process, then set the **minimum** it needs — most
  likely `chown root:dovecot2` + `chmod 640` — from Nix so it survives, and **verify an actual IMAP login**, not
  just `systemctl status dovecot`. (c) Still switch the generators to `install -m 600 -o root -g root`, described
  as **hardening**, not as fixing a live recurrence.
* **Effort / Risk** trivial / medium *(the risk is entirely in (b))*

#### C-02R — Retention for PostgreSQL TLS key backups
* **Verified** exactly **13** `server.key.bak.<date>` files in `/var/lib/postgresql/certs` (one per monthly
  renewal back to 2025-09-23) — the triage's 13, not the audit's 14 — plus the live key; **all 14 are mode 600**
  (3 postgres:postgres, 10 root:root). Generators are `certs/postgresql-cert-renew.sh:132,133` and
  `certs/create-web-certificate.sh:65`; `certs/renew-certificate.sh` has **no** matching line, so the triage's
  attribution is corrected.
* **Change** keep-3 retention (`ls -1t server.key.bak.* | tail -n +4 | xargs -r shred -u`) — the glob is
  `server.key.bak.*` so the **live** `server.key` cannot be matched — plus the same for `server.crt.bak.*`, plus
  `install -m 600 -o root -g root` in both generators.
* **Justify as blast-radius reduction**, not via the falsified cp-widening claim: each file is a full copy of a
  recently-live TLS private key retained forever, one directory over from where the permission mistake already
  happened.
* **Safer one-off** `install -m 600 -o root -g root` the 10 condemned keys into a single 0600 root-only tarball,
  confirm PostgreSQL TLS still serves (`SHOW ssl;` **plus** a real `sslmode=require` connect), then shred the
  tarball after a confirmation period.
* **Effort / Risk** small / low

#### C-03R — Fix OpenProject's unwritable `/tmp`
* **Verified cause** `modules/users/home-manager/openproject.nix:101` mounts
  `/var/lib/containers/openproject/tmp:/tmp:Z` while `openproject-quadlet.nix:109` creates it
  `d … 0755 openproject openproject`. Under rootless userns the host owner maps to **container root**, so the
  image's app uid cannot write. Live symptom: **18 `is not writable: /tmp` lines in 7 d**.
* **1777 is SAFE — verified, and the design did not check this:** the parent
  `/var/lib/containers/openproject` is `drwx------ openproject:openproject`, so a world-writable child is fully
  gated from other host users. These are standard `/tmp` semantics, not a sensitive-file relaxation.
* **Also clear the stale contents once** — the dir holds **228 entries written by container-root** while the app
  uid could not write. After the mode change the app uid can create *new* files, but a named subdirectory like
  `/tmp/cache` owned by container-root at 0755 still rejects app-uid writes, while `Dir.tmpdir`'s top-level probe
  passes and the warning count drops to 0 — **a false all-clear.** Stop the container and
  `sudo find /var/lib/containers/openproject/tmp -mindepth 1 -delete`.
* **Regression detector** C-05R covers **system** units only; openproject logs to the **openproject user
  manager** journal (`user@928`), so it stays uncovered. Either extend the scrape or assert the mode from a tiny
  textfile check — the design's functional test (trigger a PDF export in the UI) is manual and will not be repeated.
* **Effort / Risk** trivial / low

#### B-03R — Textfile-collector temp-file leaks
`REVISED — the tmpfiles janitor is a VERIFIED NO-OP, and the obvious alternative deletes live metrics`
* **Verified inert today** node_exporter globs only `*.prom`; `node_textfile_scrape_error` = 0 on all three
  scraped instances. Seven orphans, not four: `restic.prom` ×4, `litellm.prom` ×2, `microvm_state_share.prom` ×1.
  Plus `/var/lib/node_exporter/textfile_collector/` holding two 2025 `.prom` files nothing reads.
* **The proposed janitor does nothing.** I tested `systemd-tmpfiles` against a sandbox: with the item's rule shape
  and the most aggressive possible age (0), `e <dir>/*.prom.* - - - 0 -` deleted **NOTHING** on either `--clean`
  or `--remove` — age-based cleanup applies to the *contents of a directory*, not to a glob of regular files.
  The obvious alternative `e <dir> 1777 - - 0 -` deleted **EVERY file including the live `litellm.prom` and
  `restic_check.prom`** — on the real host that would delete `restic_check.prom`, written only **once a week** by
  restic-check's ExecStopPost, blinding `ResticIntegrityCheckFailed` and `ResticIntegrityCheckStale`. That is a
  data-loss pattern of exactly the class CLAUDE.md forbids in this directory. Only `r <dir>/*.prom.*` behaved
  correctly (removed the orphan, left the live files).
* **Ship** (a) `mktemp`+`trap` in the writers — the real fix; (b) because `trap` does not run on SIGKILL, one line
  at the top of **one** existing collector:
  `find /var/lib/prometheus-node-exporter-textfiles -maxdepth 1 -name '*.prom.*' -mtime +2 -delete`;
  (c) **the missing detection** — have that same `find` emit `node_textfile_temp_leak_count` and alert on
  `> 0 for: 6h`. That is what turns *"a collector was SIGKILLed mid-write"* from an archaeology finding into a
  signal (`node_textfile_scrape_error` is structurally **always** 0 for this, because a stranded
  `*.prom.<pid>` is not a `*.prom`). Leave the existing `z … 1777 prometheus prometheus -` line untouched.
* **Effort / Risk** trivial / low

#### B-04 — Delete the 10 KB placeholder Home Assistant backup from 2025-10-15
It inflates `home_assistant_backup_count` to 4 and sits at **10,240 bytes**, just above
`HomeAssistantBackupSizeTooSmall`'s <5000 floor, so it can never trip the guard it would otherwise trip. The three
real backups are ~105 MB each; latest age 8.3 h. *trivial / low.*

#### B-05R — Make `zpool-trim`'s permanent no-op explicit
`Result=success` / `ExecMainStatus=0` while the journal contains only *"cannot trim: no devices in pool support
trim operations"* — all four members are `(trim unsupported)` spinning disks behind a USB bridge. Timer is live
(LAST Mon 2026-07-27 02:50:29, NEXT 2026-08-03 00:49:52) and **nothing monitors it** (grep of
`modules/monitoring/alerts/` for `zpool.trim|zpool_trim|freeing` → no matches), so no rule and no Nagios mirror
service disappears. Set `services.zfs.trim.enable = false` **with the rationale comment on the option itself**
(it is global to the module — if tank ever gains an SSD special/log/cache vdev, trim silently stays off).
Marginal bonus: one less Monday I/O burst on the bridge. `fstrim.timer` for the NVMe root is a separate unit and
is unaffected. *trivial / low.*

#### S-04 — Enable `nix.optimise.automatic`
Verified **zero** nix-optimise timers among 106 enabled timers and an empty `ExecMainExitTimestamp` — store
hard-link dedup has **never** been performed. `nix.gc` is configured and healthy (`base.nix:64`). No pressure
today at 30% root usage. Note optimise is deliberately disabled inside the two microVM guests. *trivial / low.*

#### Y-02 — Clean up 45 not-found unit references
`sops-nix.service` and `sops-install-secrets.service` both have `LoadState=not-found`, so the `After=`/`Wants=`
that **15 services** declare on them are silent no-ops — systemd resolves `Wants=` on missing units without
complaint (0 *"Cannot add dependency job"* warnings in 7 d). Determine the real unit name sops-nix generates and
point the ordering at it; delete the 8 stale `podman-*` names and the same class at **user** level in 4 rootless
managers (memory-vault, openspeedtest, vane, opnsense-exporter). *small / low.*

#### Y-03 — Fix the two phantom unescaped device units
`sys-subsystem-net-devices-br-openclaw.device` and `sys-subsystem-net-devices-hermes-br0.device` resolve to wrong
sysfs paths (the hyphen parses as a path separator) alongside their correctly `\x2d`-escaped counterparts.
**Verified inert today** — `WantedBy`, `RequiredBy`, `BoundBy` and `ConsistsOf` all empty — but a future
`BindsTo` on the phantom name would silently never bind. *trivial / low.*

#### X-03 — Raise Alertmanager's log level off `warn`
`sum(alertmanager_notifications_failed_total)` = **8** on webhook, `journalctl` for the unit returns **1 line for
the whole run**, and ExecStart carries `--log.level warn` — so **which receiver failed is permanently
unrecoverable.** Delivery is healthy now; the next failure will be equally opaque. *trivial / low.*

#### A-02 — Fix the self-contradicting `hermes-vm.nix` comment
`alerts/hermes.yaml:48-50` is `for: 5m` **plus** a 600 s uptime warmup gate, while `hermes-vm.nix:365-367` claims
the fix was *"widening HermesApiServerDown to `for: 15m`"*. The same file's comment at `:44-47` **correctly**
describes the gate, so the file contradicts itself. Acting on the wrong comment (setting `for: 15m` **on top of**
the existing gate) would create a **~25-minute blind spot**. *trivial / low.*

#### A-03 — Compress MEMORY.md under its limit and correct two stale entries
**58,266 bytes against a 24.4 KB limit**, so the loader reports *"Only part of it was loaded"* — which
**demonstrably produced false premises during this very audit**. Two entries are now wrong:
`project_tank_uas_enclosure_failure` still says the `usb-storage.quirks` mitigation was *"offered, not applied"*
when it **is applied and active** (this is the host's most dangerous known failure mode, and the staleness
directly caused the S-05R blind spot), and `project_hermes_self_heal` still says `microvm.vcpu=4` is *"staged,
needs switch"* when it was tried and **reverted** with rationale at `hermes-vm.nix:357-370`. Keep index entries to
one line under ~200 chars; move detail into topic files. *small / low.*

#### Y-U1 — 14 leaked `nix-daemon --stdio` processes  *(gated on decision D12)*
* **Measured (worse than the audit)** 36 logind sessions, **19 active / 17 closing**; **17** `nix-daemon --stdio`
  matches (audit said 13–14); 29 nix-daemon processes total; **178,976 KB (~174 MB)** aggregate RSS. Oldest
  closing session 2026-07-11 (17 days). No exhaustion risk (997 procs vs `pid_max` 4194304).
* **HAZARD the design underweights** `nix-daemon --stdio` is the **daemon side of a live nix client connection**.
  A session logind has marked `State=closing` can still contain a daemon serving an active client — an in-progress
  `nixos-rebuild`, a flake eval, an agent's nix query — and `terminate-session` kills the scope, **aborting that
  build**. A 6-hour age filter reduces but does not eliminate this: a long `nixos-rebuild switch` plausibly
  outlives 6 h of wall time in a session opened earlier.
* **Ship** age filter **plus** an activity guard (skip if any process in the scope has an established socket or
  recent CPU time) **plus** a rebuild interlock, and run one full cycle in **log-only** mode, diffing the
  would-terminate list against `loginctl list-sessions` and any tmux/screen sessions before enabling termination.
* **Emit both** a level gauge `logind_closing_sessions` and a terminated **counter**, so the leak **rate** is
  visible. Acceptance is *"stays low a week later"*, not the one-off RSS drop.
* **Reject** `services.logind.killUserProcesses = true` as the default remedy — it kills tmux/screen/nohup on
  logout, a real behavioural change for an interactive user.
* *small / medium.*

**PHASE 7 GATE**
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
# B-02R negative test (add a bogus tenth fileset first):
sudo systemctl start restic-check.service; systemctl show restic-check -p Result   # Result=failure
curl -sG --data-urlencode 'query=restic_integrity_check_success' localhost:9090/api/v1/query   # 0
# permissions (metadata only — NEVER cat these):
sudo ls -la /var/lib/dovecot-certs/ | grep -c 'bak'            # 0
sudo ls -1 /var/lib/postgresql/certs/server.key.bak.* | wc -l  # <= 3
sudo -u dovecot true && doveadm search -u johnw mailbox INBOX all >/dev/null && echo "IMAP auth OK"
ls -1 /var/lib/prometheus-node-exporter-textfiles/*.prom.* 2>/dev/null | wc -l    # 0
systemctl --failed | tail -3
```

---

## 5. The silent-failure detection architecture

The 116 findings are not 116 problems. They are **six patterns**. The user named three instances; the
architecture below is designed so the *pattern* becomes detectable, not just the instance. Each pattern
carries the backtest that proves the new detector would have caught the real event.

---

### Pattern 1 — **Execution ≠ outcome**: a unit exits 0 while its work failed
> *"Green systemd exit is not proof of a complete dump."* — `postgresql-backup.nix:49-56`, already in-repo.

**Archetypes caught: (b) flume, (c) gitea mirror.**

The fleet has exactly **5** `*_last_success` metrics, and **all 5 are defined as `$SERVICE_RESULT == success`** —
they measure *the unit exited*, not *the work happened*. The fix is a **work floor**: every producer emits a
count of what it actually did, and the alert fires on the count, not on the exit code.

| Detector | Expr | Backtest |
|---|---|---|
| **M-01/D-01** gitea mirror (log side) | `sum by (path)(count_over_time({job="nginx-access", status=~"5.."} \|= "push_mirrors-sync"[26h])) >= 1` | **YES.** 7-day count = **7** (verified live) = exactly the 7 daily failures; non-zero at **37/37** six-hourly steps over 9 d. Status distribution `{200:1330, 500:7}`. |
| **D-09** gitea mirror (producer side) | `gitea_push_mirror_sync_failures > 0`, `gitea_push_mirror_run_incomplete > 0` | **YES.** 1–2 failures on **every** one of the last 10 days → `failed>=1` and `exit 1` on every run. |
| **D-10** flume degraded steps | `flume_cross_check_data_steps_degraded > 0` | UNVERIFIED (metric absent) — validate by fault injection. **Correction:** `FlumeCrossCheckFailed` **has** fired (773 samples/90 d, one 6.0 h episode 2026-06-15) because it tracks the *unit* result; the gap is **internal step** failure. |
| **D-11** pg_dump completeness | `pg_dump_database_dirs != pg_dump_databases_live and pg_dump_databases_live_valid == 1` | Correctly quiet — three independent counts all = **27** (verified). |
| **C-04R** retry-aliasing | `min_over_time(<last_success>[1h]) == 0` | **YES.** The 07-27 zero survived **exactly one** 15 s scrape; the `min_over_time` form returns **60 consecutive firing samples** 19:36→20:35. |

**The generalisation the plan institutionalises:** any service that declares a `*_last_success` metric **must**
also declare a work-floor counter in the same commit, and any new `.prom` **must** ship with a
last-completion-timestamp age rule in the same commit (D-10 explicitly adds
`time() - flume_cross_check_last_completion_timestamp_seconds > 8*86400`, which the original design omitted).
**Residual, stated honestly:** this converts **4 producers** out of the fleet. There is no shared helper and no
lint, so the next backup/sync/report job can ship the same shape — see §9, *"execution-vs-outcome convention"*.

---

### Pattern 2 — **Absent selector = eternal silence**: a rule that matches nothing is `health=ok` forever
**Archetype caught: the meta-failure that hid everything else.** 534 rules, **all** `health=ok`, ~40 of them
incapable of firing.

The class has four sub-shapes, and the plan's own findings show which are detectable mechanically:

| Sub-shape | Example (verified) | Detected by |
|---|---|---|
| Metric **name** absent | `count(systemd_unit_state)` = 0 vs `node_systemd_unit_state` = **3055** | **R-03R** verdict `DEAD` |
| Selector empty, name exists | `count(last_over_time(probe_success{job="blackbox-https"}[30d]))` = **0** (live job is `blackbox_https_local`, 41 targets) | **R-03R** verdict `MISMATCHED` |
| Wrong **operator/unit** | `rate(restic_repo_size_bytes[1d]) > 10 GiB` demands **927 TB/day**; `rate()` on a Technitium rolling-hour **gauge** | **R-03R** third check (threshold vs `max_over_time`/`min_over_time` over 30 d) |
| Unreachable **threshold** | `rate(api_errors_total[5m]) > 0.1` vs observed max **0.02266/s** | same third check |
| Vector-matching failure | bare `sum()` strips labels → 7 Technitium ratio rules return **0 series** (verified) | **M-08** fix; R-03R `MISMATCHED` |

**The trap R-03R must avoid, proven with `promtool`:** emitting the offending rule's name under the label
`alertname` makes Prometheus overwrite it with the sentinel's own name, collapsing same-group same-metric series
into one labelset → `FAILED: vector contains metrics with the same labelset after applying alert labels`, i.e.
`health=err`, which then trips `post-reboot-validation.sh:402`. **Use the label `rule`.** And the annotation
renders *correctly* in a dry run, so this only surfaces in production.

**The counter-trap: CONDITIONAL emission.** `git_workspace_repo_age_seconds` has **51 series over 30 d, 0 at an
instant, 0 of 37 steps over 3 h**, while its textfile is 14 min fresh — per-repo series exist only when repos are
stale. Every error counter, every `state="failed"` matcher and every condition-gated textfile metric has this
shape. A binary dead/alive verdict either pages permanently or grows a hand-maintained exception list; the
**three-way verdict** is what makes the sentinel survivable.

---

### Pattern 3 — **Stock vs. flow**: a ratio invariant catches what a level threshold cannot
**Archetype caught: (a) PostgreSQL backup amplification.**

The pool has capacity rules at **>80%** and **>90%**. It is at **70%**. Those rules are correct and useless here:
the fault is not *"the pool is full"*, it is *"one dataset is storing 43× more history than data."* A **ratio**
expresses that; a level cannot.

| Detector | Expr | Backtest |
|---|---|---|
| **S-01R** amplification (info) | `zfs_dataset_used_by_snapshot_bytes > 300 GiB and (… / clamp_min(used_by_dataset,1)) > 5` | **YES, with a 30-day head start.** Exact-proxy ratio over 30 d at step 6 h: **120/120 steps above 10**, min **43.13**, max **82.69**, residue 1425–1737 GiB at every step. **Selectivity verified by direct exporter probe: exactly 1 of 59 datasets.** |
| **S-01R** onset (the marginal-cost metric) | `newest_daily_snapshot_used / clamp_min(refer,1) > 0.5 and refer > 10 GiB` | Live contrast **0.98** (tank/Backups/PostgreSQL) vs **0.28** (post-fix TechnitiumDNS control). Drops to near zero **the first night B-11 lands** → a true onset detector that self-resolves on repair. |
| **S-10** database growth | `delta(pg_database_size_bytes[24h]) > 2 GiB` | **YES — pages 2026-07-24**, four days before the audit and ~15 h after onset. 857× FP margin to the runner-up. |
| **D-05R** retention invariant | `litellm_spendlogs_oldest_row_age_seconds > 103 days` | **YES.** Reads **273 days** today; would have fired **every day for 6+ months**, independent of traffic volume. |

**Two rules were DELETED from this pattern because a range backtest disproved them**, and this is the most
important methodological lesson in the plan:

* `delta(snapshot_residue[7d]) > 100 GiB` — **TRUE for 30 consecutive days in June** during normal operation and
  **FALSE through the entire five-day incident** (07-24 = 9.4 GiB). Residue is a **stock** that saturates once
  the retention ladder is populated; its growth measures ladder fill, not input rate.
* `delta(pg_database_size_bytes[7d]) > 5 GiB` as the *retention* invariant — true on **5 of 200 daily steps**,
  first crossing **four days ago**. The database accumulated its entire 55 GB **below** this threshold.

**Convention this plan adopts:** *every new threshold must carry its measured over-threshold fraction across the
longest available window.* One query per rule. It broke four items in this very plan.

---

### Pattern 4 — **The instant is not the week**: history must be a first-class query
**Archetype caught: the second critical finding — 36 alerts fired, 12 critical, while state showed 2.**

All seven audit domains sampled `Alertmanager active=true`, got `{Watchdog, ExposedImageFixableHighCVE}`, and
reasoned from it. **Four multi-hour criticals were invisible to that method** while sitting in the TSDB the whole
time.

`count(count by (alertname)(count_over_time(ALERTS{alertstate="firing"}[7d])))` = **36** — verified, in 4 ms.
`CopypartyDown` = 2,709 samples = **22.6 h**, one contiguous episode.

**And the data goes back further than anyone believed:** Prometheus is `storage.tsdb.retention.time=100y` with
`ALERTS` reaching **2026-03-31 (~119 days)**. Month-over-month statements are queryable **today**, with no new
state file. Loki holds **~30 days**, not ~8.

Fixes: **R-01** (Section A, with adaptive episode-merge tolerance `group_interval + 300 + step` and a stated
duration convention), and **B4** in **R-04R** for chronic level. Deliberately **not** an alert — see §7.

---

### Pattern 5 — **The lying metric**: fresh, well-formed, and wrong
**Archetype caught: nothing the user named — which is the point. This one has no natural discoverer.**

| Instance | Evidence | Response |
|---|---|---|
| `stock_trader_data_source_up{source="schwab"}` | Reads **1** while the source has been dead **34.2 days**; `avg_over_time[24h]` = **0.9746**, `changes[24h]` = **8**. Root cause is in the app's own docstring: `_pinger_tick` sets 1.0 whenever `refresh_if_needed()` does not raise, but that **short-circuits with no network call** while the access token is clock-fresh, overwriting the honest 0 that `probe_sources()` wrote. | **A-U1s** alerts on `schwab_refresh_token_expiry_timestamp_seconds` instead: `changes[7d]` = **0**, monotone, cannot flap. **A-94** (§9) is the upstream fix. **Mechanically** drop or shadow the lying series (metric_relabel or a recording rule) so the misleading one is not the most discoverable — and repoint the Grafana panels, which currently render Schwab as healthy. |
| Frozen textfile gauges | A stale `.prom` serves its last value **indefinitely**; `node_textfile_scrape_error` = 0 and structurally always will be for a stranded `*.prom.<pid>`. | Every new `.prom` in this plan ships with an age rule **in the same commit**; **B-03R** adds `node_textfile_temp_leak_count`. |
| `technitium_dns_update_available` | Pinned at **−1** for 30 d; the rule tests `== 1`. | **M-10R** deletes it. Inverting to `== -1` would trade eternal silence for eternal firing — *functionally the same failure.* |
| `aide_changes_detected` | 1 for 42.5% of the week, but `changes(…[7d])` = **6** — it **stands**, it does not flap. A file-integrity monitor that is right 57% of the time is a noise source, not a control. | **M-20R** removes the racing timer so the gauge reports today's check, not yesterday's. |

---

### Pattern 6 — **Invisible substrate**: the data never reaches the query plane at all
**Archetypes caught: the ones no rule could ever have expressed.**

This is the largest and least glamorous pattern. No amount of rule-writing helps when the signal is filtered,
un-exported, or emitted by a technology nobody enumerated.

| Blind spot | Proof | Fix |
|---|---|---|
| **Home Assistant's entire log stream** | Priority histogram over 7 d = `{6: 7650, 5: 2}` — **100% priority 6**, dropped by promtail's `[5-7]` filter. `count_over_time({unit="home-assistant.service"}[24h])` → **NO DATA**. 76 TypeErrors and a 17-day-dead integration were unreachable by *any* Loki rule. | **C-05R** (+ priority-7 drop retained), **A-96R**, **A-97R** |
| **sudo — the only privilege-escalation detector** | 2,120 entries/24 h, **2,119 at priority 5**; `/var/log/sudo.log` is 0 bytes; `grep -c logfile /etc/sudoers` = 0; Loki has **no `sudo` job**. And there is **no `sudo.service`** — the sshd-template keep-rule would match **zero** lines. | **M-14R** (identifier-keyed, `unit` label dropped for cardinality) |
| **UPS behind an automated `systemctl poweroff`** | `count({__name__=~"nut_.*\|network_ups_.*"})` = **ZERO SERIES**; **0 of 534 rules** mention it. The poweroff leaves exactly one `logger` line — and promtail/Loki/Alertmanager are all **on the host being powered off**. | **M-23R** (exporter + rules), **M-24R** (synchronous pre-shutdown notify + timestamp gauge, **not** a post-hoc Loki rule alone) |
| **Per-cgroup memory** | Census of `{__name__=~".*memory.*(current\|high\|max).*"}` returns 4 unrelated names. Postgres pinned at **99.8%** of `memory.high` with a **continuous ~0.05 events/sec** reclaim floor could throttle indefinitely with nothing firing. | **M-92R** (+ `memory.pressure` chronic tier), **Y-01** |
| **HA entity availability** | `count({__name__=~"hass.*\|homeassistant.*"})` → **NO_DATA** in Prometheus; VictoriaMetrics' 306 names contain nothing matching `entity`/`unavail`. 163 entities dark >24 h is **unrepresentable**. | **M-91R** (counts only, LATERAL join, 15 min) |
| **BOT-mode USB vocabulary** | The UAS mitigation makes 2 of 5 patterns **impossible by construction**; 2 more are KERN_INFO and dropped. Only `err -108` and `sd[a-d].*ESHUTDOWN` survive. And *"they're priority 3"* is **unverifiable** — none of the four new strings has ever appeared in the retained journal. | **D-14/S-05R** — a dedicated kernel scrape makes the priority question **irrelevant instead of assumed** |
| **copyparty under `systemd-nspawn`** | A **third** virtualisation technology no domain enumerated. `systemctl show` returns an empty `ActiveEnterTimestamp`; its journal held **1 line** across a 22.6 h outage. | Out of scope (**A-95**, §9). **M-15R** + R-01 catch it from the outside, which is the cheap correct win. |
| **Loki stream existence itself** | If a relabel regex is wrong, dependent rules evaluate **quiet-and-green**. | **NEW: per-job ingestion deadman** (Phase 6) — the prerequisite no design specified |

---

## 6. Daily-report redesign

**Generator:** `scripts/log-summarizer.py` (898 lines) → wrapper `analyze-logs`
(`modules/services/monitoring.nix:91-107`) → logwatch customService `ai-log-summary`, title
**"AI-Powered System Log Analysis"** (`:134-140`). `logwatch.timer` OnCalendar **04:00**; current run **3 m 54 s**;
`Type=oneshot`, `PrivateTmp=yes`.

**Design principle:** `services.logwatch.customServices` is a list of **10 independent named sections**, of which
the LLM path is only one — the other nine (zpool, database-sizes, restic, certificate-validation,
systemctl-failed, sudo, …) are plain scripts. **Everything deterministic goes in a new sibling section, not
inside the LLM path.** The LLM's job becomes *narration of verified facts*, not *discovery*.

```
┌─ NEW customService: system-health-report  (scripts/system_health_report.py, runs FIRST) ────────┐
│                                                                                                  │
│  SECTION A — 7-DAY ALERT HISTORY                                    [R-01]  ← highest value      │
│    · per alertname: severity | episodes | firing_h | raw_span_h | longest_window                 │
│      expr: sum by (alertname,severity)(count_over_time(ALERTS{alertstate="firing"}[7d]))         │
│      longest: max_over_time((time() - ALERTS_FOR_STATE)[7d:60s])                                 │
│      episode merge tolerance = group_interval + 300 + step   (adaptive; fixed cannot serve both) │
│      duration convention printed in the header: firing_h = span + 1 interval per episode         │
│    · NEW 4th table: alertnames whose 7d count CHANGED vs the prior week  ← surfaces the NEW      │
│    · flap episodes counted from the UNDERLYING signal, not ALERTS (R-09R's keep_firing_for       │
│      rewrites ALERTS and would erase the flap evidence that justified it)                        │
│                                                                                                  │
│  SECTION B — DETERMINISTIC HEALTH INVARIANTS  (PASS / FAIL / NOT CHECKED)          [R-04R]       │
│    B1 zfs snapshot amplification (topk, annotated "known-elevated, tracking down from 83x")      │
│    B2 pg_dump completeness (dirs vs live)                                                        │
│    B3 gitea push_mirror errored-boolean  ← lag_h=1 while errored=t: only the BOOLEAN has signal  │
│    B4 chronic availability — column labelled AVAILABILITY, not unavailability                    │
│         DEAD/NOT-MONITORED (>0.9 unavail) listed separately from CHRONIC (0.01-0.5)              │
│    B5 restic per-repo snapshot age + size delta                                                  │
│    B6 HA/VM sensor liveness — entity names sourced from the vmalert rules at :8880               │
│                                                                                                  │
│  SECTION C — RULE LIVENESS                                                          [R-03R]     │
│    DEAD / MISMATCHED / CONDITIONAL counts + the DEAD and MISMATCHED lists                        │
│    (computed by a SEPARATE 03:30 timer writing JSON — the email never waits on ~1000 queries)    │
│    + NEW row: Nagios mirror divergence episodes in 7d (a green mirror is NOT "no dead rules")    │
│                                                                                                  │
│  SECTION D — CHECK-COVERAGE LEDGER                                                  [R-02]      │
│    every periodic check: VERIFIED | DEGRADED | VACUOUS | NOT CHECKED | FAILED                    │
│    + every SERVICE_GROUPS entry rendered by LoadState  ← exposes redis/hass/smbd/nmbd/nfs-server │
│                                                                                                  │
│  SECTION E — APPLICATION ERRORS FROM LOKI                                    [R-06R, NEW]       │
│    the flume schema error reaches NO other section; without E, R-06R(c) protects nothing         │
│    e.g. {job="postgresql"} |= "does not exist"  → 7 over 7d, and Loki holds ~30 days             │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
              │ facts JSON (atomic .tmp + os.replace; unparseable ⇒ ABSENT, never fatal)
              ▼
┌─ EXISTING customService: ai-log-summary  (log-summarizer.py --facts-json …)          [R-06R,R-07R]┐
│  · narrates the verified facts; MUST NOT contradict them                                          │
│  · MECHANICAL post-check: if Section A criticals > 0 AND narrative matches                        │
│      /(none|no critical|all systems|operating normally|HEALTHY)/i                                 │
│    → replace with fallback text and set health_report_ai_narrative_ok = 0                         │
│  · hardcoded "SYSTEM STATUS: All systems operating normally" (:527) and status="HEALTHY" (:587)   │
│    DELETED — verdict derived from Section A                                                       │
│  · --max-ai-seconds (per-attempt urllib timeout + wall-clock budget); today self.timeout = 7200   │
│  · stderr redaction INLINE in the same command (a live LiteLLM key is in the environment)         │
└───────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Suppression surface (R-05R).** Two independent suppressors exist and the design only disarmed one:
1. `load_recent()` feeds 14 prior reports under **`:423-431`** — *"omit it from today's report entirely"*. **This
   is the one that kills the motivating case**: the flume error was reported 07-28, so from 07-29 it is a "known
   recurring condition" and is dropped without the wisdom file ever being consulted. **Must be replaced** with
   *"summarise in one line with a count and first-seen date, never omit."*
2. `known-conditions.prompt` — 33,555 bytes / 266 **undated** entries, of which only ~125 would pass the new
   pollution gate. Migration must **stamp every surviving entry** with `first-seen=<mtime>` on first run and apply
   the gate + denylist to the existing corpus **at that moment**, printing before/after counts. Otherwise the
   90-day expiry and 120-entry cap are either inert (266 > 120, no ordering key) or unsuppress everything at once.
   Emit `wisdom_entries_total` / `wisdom_denylist_rejects_total` as gauges.

**Self-monitoring (R-08R)** — 5 rules: timer fired (`for: 30m` + zero-guard), unit not failed, **metrics fresh
with `absent()` guards** (without them the rules are silent exactly when the exporter is missing — verified: the
verbatim expression returns EMPTY today while `absent(...)` returns 1), narrative-ok, and **delivery proven** via
a `doveadm` count of the report subject in INBOX in the last 30 h. Generation ≠ arrival.

---

## 7. Alert-fatigue plan

**Baseline (verified):** `sum by (integration)(increase(alertmanager_notifications_total[7d]))` = **email 406.01,
webhook 1979.05**; `[1d]` = 36.01 email/day. Root route `group_by` lacks `instance`, `group_interval=10m`,
`repeat_interval=24h`; openclaw route 5 m / 4 h; only `severity=critical` reaches `iphone-notifier` (4 h,
`continue=true`).

**Correction first:** the **1,979 webhooks are the by-design Watchdog dead-man** (`repeat_interval=4m` →
~11.7/h). They are not noise and must not be "fixed". **Only the ~406 emails are real volume.**

**Strategy: resolve the standing conditions, then route. Never inhibit broadly.**

| # | Action | Mechanism | Expected email delta / 7 d |
|---|---|---|---|
| 1 | **M-21** — stop `config_file_drift{file="secrets.yaml"}` | `avg_over_time[7d]` = **0.600**; 393 ALERTS samples × 15 min ≈ **98 h sustained firing**. All six other tracked files are **0.000**. | **−140 to −170** |
| 2 | **M-20R** — stop `aide_changes_detected` standing at 1 | `avg_over_time` = 0.426; 272 samples ≈ **68 h sustained**. `changes[7d]` = **6** — it stands, it does not flap, so this is a *resolve*, not a dwell tweak. | **−90 to −120** |
| 3 | **R-09R(b)** — re-severity 4 misfiled info rules, **then** null-route the remaining 17 | Validated with `amtool 0.29.0`: `config routes test severity=info` → digest-only. Promote `HostUnexpectedReboot`, `ContainerCVEScanFailed`, `ContainerCVEDBStale`, `MicroVMStateShareExporterStale` (+ exempt `health_report_*`) to warning first. | **−25 to −40** |
| 4 | **R-09R(a)** — `keep_firing_for: 10m` on 2 openclaw rules | Real inter-flap gaps 720 s (34×) / 780 s (3×) → 41 episodes collapse to ~4. **Gated on a self-heal replay test** (both alertnames map to `restart_microvm` at `daemon.py:246-247`). | **−15 to −25** |
| 5 | **R-09R(c)** — **only** the targeted inhibit `CopypartyDown → TargetDown`, `equal:[instance,job]` | Backtested: both fired **22.58 h** on the same instance+job. | **−5 to −10** |
| 6 | **A-98R, S-01R, M-11R, S-10** — new rules routed to match their shape | matter churn → **report**, not email; snapshot amplification `severity: info`; M-11R bounded to `[6h]` (was 72 h/month latched at `[1d]`); S-10 expects 2–4 fire/resolve cycles. | **+15 to +30** |
| | **Net** | | **≈ −230 (−55%)**, from ~406 to **~175/week** |

**Rejected, with the measurement that rejects it.** The general inhibit
`source severity=critical → target severity=warning, equal:[instance,job]` **manufactures this plan's own
archetype**. On `(instance=localhost:9100, job=node)` — the target carrying nearly every textfile-derived alert —
**8 critical alertnames would suppress 11 unrelated warnings**, including **`ResticNoRecentSnapshot`** and
`NagiosServicesCritical`. `SchwabTokenExpiryCritical` fired **148.87 h of the last 168 h**, so for **89% of the
week** a stale brokerage token would have blanket-suppressed the backup alerts. 17 warning alertnames are
suppressible across 6 instance/job pairs, and 3 alertnames fire with `job=""` (Alertmanager treats both-absent
labels as equal). **Do not ship it.**

**The unmeasured dimension, filed:** nothing tracks notifications-per-week **as a metric with a budget**, so there
is no signal that the detection architecture has crossed from useful into ignored — which is the failure mode that
renders every other item moot. Add `increase(alertmanager_notifications_total{integration="email"}[7d])` to
Section A of the daily report with an explicit budget line.

**A related shape the plan must not create:** a chronically-**firing** rule is functionally as dead as a silent
one, because it gets silenced. Live evidence: `HostUnreachable` accumulated **110,296 firing samples over 30 d**
on a single LAN target (~19 days continuously firing); `ServiceStuckActivating` 2,957 on zimit-job-runner. Three
proposed items were demoted or deleted for exactly this reason (S-01R rule 2, M-10R's inversion, D-03/M-15R's
`up`-side avg form).

---

## 8. Decisions needed from you

Nothing in this section is actioned without your answer. Each carries my recommendation and why.

---

**D1 — Rotate the Discord bot token that GitHub's scanner found in `nixos-config` history.**
The Gitea repo is **public** and served this token for ~69 days; GitHub push-protection has rejected the mirror
on it **144 times per 2 days**. Removing the fixtures (`8762657d`) did not remove it from history.
* (a) **Rotate now** in the Discord developer portal, update the SOPS secret, rebuild — treat the old value as burned
* (b) Rotate **and** purge the blobs from history (pairs with D2-a)
* (c) Confirm the token is already dead/unused and take no action
* (d) Leave as-is and accept the exposure

**→ Recommend (a), today, independent of D2.** A token that sat in a public repo for 69 days is compromised
whether or not the mirror is ever fixed; rotation is cheap and does not require the history rewrite. (b) only if
you also want D2-a. This is the single highest-urgency item in the whole plan.

---

**D2 — Restore a working off-site path for the nixos-config git history.**
10/10 push attempts returned HTTP 500; the mirror is **678 commits behind since 2026-05-05**. Urgency is already
**reduced**: `/etc/nixos` (including `secrets/` and `nagios/`) now reaches B2 encrypted via `extraPaths`. What
remains is the *git history* mirror.
* (a) Rewrite history to purge the flagged blobs (destructive; rewrites 678+ commits of shared history)
* (b) Push a fresh orphan/squashed branch or a new GitHub repo so only clean history goes off-site
* (c) Give `secrets/` and `nagios/` real off-host git remotes and leave the GitHub mirror broken
* (d) Accept B2 as the sole off-site path and **disable** the GitHub push mirror so it stops failing silently

**→ Recommend (b).** It restores off-site history without rewriting 678 commits of shared history, and it costs
one afternoon. If you pick (d), you must still land **M-01/D-09** — a *deliberately* disabled mirror and a
*silently broken* one must not look the same, and today they do.

---

**D3 — Schwab OAuth re-auth, and what to alert on afterwards.**
The refresh token expired **2026-06-24 (34.2 days ago)**; re-auth requires browser OAuth on hera per the
documented runbook, which only you can do. `ee03dd75` deliberately removed both token alerts.
* (a) **Re-auth now**, then enable a single expiry-only alert on `schwab_refresh_token_expiry_timestamp_seconds`
* (b) Re-auth now and leave it unalerted, as `ee03dd75` chose
* (c) Retire the Schwab data source entirely and rely on alpha_vantage
* (d) Leave expired; the app serves quotes from alpha_vantage today

**→ Recommend (a) with A-U1s.** The reason `ee03dd75` disabled the old alerts was flapping, and I can now show
*why*: the old input `stock_trader_data_source_up{source="schwab"}` has `changes[24h] = 8` and reads UP **97.5%**
of the time while dead. The new input has **`changes[7d] = 0`** — monotone, cannot flap. Add the absent-arm.

---

**D4 — UPS battery: 3.96 years old, never self-tested, behind an automated poweroff.**
`battery.mfr.date` = 2022/08/13, at the top of APC's 3–5 year window; `ups.test.result` = *"No test initiated"*,
so the 43-minute runtime figure is an **unvalidated vendor estimate**. A self-test is a **state change** (it drops
the host to battery).
* (a) Order a replacement battery now without testing
* (b) Run a self-test first (accepting the brief transfer to battery) and decide on the result
* (c) Schedule a recurring self-test timer and defer replacement
* (d) Accept the risk; current state is OL / 100% / 15% load

**→ Recommend (a) + (c), and explicitly NOT (b) alone.** This is cross-domain: `tank` lives in a USB enclosure
whose documented failure mode (2026-06-02) is a bridge hang, and **unclean power is the classic trigger**. A
4-year-old untested battery is the cheapest single point of failure to remove. Do M-23R **first** so you can
actually watch the self-test.

---

**D5 — Reclaim the 55 GB `LiteLLM_SpendLogs` bloat.**
**217,939 rows, oldest 2025-10-29 = 273 days**; 55 GB of a 56 GB database; a single 83.5 GB `.dat` taking 14 of
the 38 backup minutes. S-02R stops the growth; it does **not** reclaim what is there — a plain `DELETE` returns
pages to the free-space map, **not to the OS**.
* (a) Let the fixed retention sweep drain it gradually (no lock, slow, snapshots keep pinning)
* (b) `DELETE` past-cutoff rows then `VACUUM FULL`/`pg_repack` in a maintenance window (exclusive lock, needs ~55 GB free)
* (c) `TRUNCATE` the table entirely (fastest, loses all spend history)
* (d) Also set `store_prompts_in_spend_logs = false` to cut future row width

**→ Recommend (b) via the new-table + swap route, plus (d).** CTAS the keep-window into a new table and swap:
that turns an hours-long `ACCESS EXCLUSIVE` into a **seconds-long** one and removes the interaction with
`LitellmBackendDown` and any self-heal action targeting litellm. **New information that should weigh on your
answer: `store_prompts_in_spend_logs = true`, so the 55 GB is 273 days of prompt BODIES** — on a host whose
CLAUDE.md documents pasted-secret incidents. This is a privacy control as much as a disk one, which argues
against (a).
*Prerequisites:* `zfs snapshot tank/Backups/PostgreSQL@pre-repack`; confirm free space on the PG tablespace
(the design asserts 1.1 T free — **verify, do not assume**); **silence `PostgreSQLDumpSizeShrunk`
(`database.yaml:95`, `pg_dump_size_bytes < 0.5 * avg_over_time(…[14d])`) and its Nagios mirror for 14 dated
days** — the dump collapsing far below half its trailing average is exactly what "the fix worked" looks like, and
it would page for a fortnight.

---

**D6 — Technitium DNS ratio thresholds, once M-08 makes the rules evaluable.**
The 7 rules have **never** been able to evaluate. Live values already breach two as-written: refused **4.23%** vs
a 2% threshold, cache-hit **58.99%** vs a 0.7 floor.
* (a) Fix expressions **and** retune thresholds to home-LAN-appropriate values in the same change
* (b) Fix expressions as-is and let them fire so the real values get triaged
* (c) Fix only server-failure/recursion (genuine faults) and delete the refused/cache-hit ratio rules

**→ Recommend (a)** with the measured 7-day maxima: server_failure 0.0304, refused 0.0524, nx_domain 0.3217,
cached min 0.4278. Set server_failure > 0.05, refused > 0.10, **nx_domain > 0.50** (1.55× over max — the design's
0.40 was only 1.24×), cached < 0.35, volume guard > 250 (observed floor 315), `for: 15m`. (b) creates two chronic
alerts on day one, which is how this family gets ignored again. Note honestly: these are rolling-**hour** gauges,
so time-to-page for a real degradation is 30–75 min and the alert latches up to an hour past recovery.

---

**D7 — Destroy the 739 GiB of legacy pre-fix PostgreSQL backup snapshots.**
Four monthlies (2026-02/03/04/05) pin **185.5 G, 181.5 G, 185.8 G, 186.2 G** with `refer == used`, i.e. wholly
unshared full copies of the old dated-tarball layout. Verified with `zfs destroy -nv` on the range: exactly those
four, *"would reclaim 739G"*. The 9-monthly ladder holds them ~nine more months. **Irreversible, and there is no
B2 copy.**
* (a) Destroy all four now and reclaim ~739 GiB
* (b) Destroy the two oldest only (2026-02 + 2026-03, ~367 GiB), keep 04/05 as a restore floor
* (c) Let the ladder age them out and accept the capacity pressure
* (d) Widen the pool / move a different dataset instead

**→ Recommend (b), and do it LAST among the capacity items.** The pool is at **70%, not 80%** — there is no
urgency that justifies destroying every Feb–May restore point with no off-site copy. **Sequencing matters:** a
−739 GiB step swamps `delta(zfs_pool_allocated_bytes[30d])` (currently +1.1 TB) and would blind any
runway-style rule for a **full month** — precisely the month you are still bringing the dump under control. If
you want the level rule, its denominator must be the *worst recent* rate
(`max_over_time(delta(…[7d])[30d:1h])/7`), not a net 30-day average.

---

**D8 — Off-site (B2) coverage for PostgreSQL dumps, TechnitiumDNS and the Machines mirror.**
`backupExcludes` = `[Assembly Contracts Git Images Machines PostgreSQL TechnitiumDNS GoogleDrive OneDrive]`.
Verified from both config and B2 that the repo named `Databases` holds **DEVONthink data**, not these dumps.
* (a) Un-exclude all three (uploads a 33 GB uncompressed litellm dump nightly — do D5 first)
* (b) Un-exclude only **TechnitiumDNS (158 MiB) and Machines (307 GB)**; leave PG local-only
* (c) Fix D5 first to shrink the PG dump, then revisit
* (d) Accept the enclosure as the sole copy

**→ Recommend (b) now, then (c) for PostgreSQL.** **Cost:** B2 storage for ~307 GB plus the first-upload egress;
ongoing delta is small. **Operational warning:** run the two as **separate manual daytime uploads**, not via the
03:30 timer — that slot sits 20 minutes before four more backup jobs, and B2 bandwidth + compression CPU + USB
read load stacking on the enclosure is **the one risk in this plan that can take the pool offline**. Watch
`journalctl -k` for `uas_eh_abort`/`err -108` and abort if any appear. Pre-silence M-11R and
`ResticRepoSizeShrunk` for `repository="Backups"` for 14 days — adding Machines roughly **doubles** a 300.64 GiB
repo in one night.

---

**D9 — 163 Home Assistant entities stuck unavailable >24 h.**
26 are the genuinely-dead **mail_and_packages** integration (all 26 dark for 17 days while the config entry still
reports `loaded`); ~37 more are known benign debris (27 orphaned `calendar.*_2` twins, 10
`sensor.water_*_gated_gpm_2` twins) plus superseded flume window sensors from the documented w15→w5 retune.
* (a) Reload/reconfigure mail_and_packages **and** delete the orphaned `_2` and superseded entities
* (b) Delete the debris only; leave mail_and_packages dark (parcel tracking stays gone)
* (c) Remove the mail_and_packages integration entirely
* (d) Accept the pile as-is

**→ Recommend (a).** **The debris is what makes the real outage invisible** — and it is the prerequisite for
M-91R being interpretable. A threshold set against today's 163 would encode 37+ known-dead twins as normal.
M-91R ships with **no alert** until this is answered.

---

**D10 — Weekly restic `--read-data-subset=2%` (recurring B2 egress).**
The weekly check is **metadata-only** today (9 repos, ~1.47 TB, 6 m 42 s), so offsite bit-rot in B2 is
**undetectable**. 2% of 1.47 TB ≈ **~30 GB of B2 egress per week** (~120 GB/month).
* (a) Ship at 2% weekly
* (b) Ship at 1% weekly, or 2% monthly
* (c) Skip; accept that bit-rot is undetectable

**→ Recommend (a)**, with `RuntimeMaxSec=4h` and the 06:30 de-herd, **and only after M-11R's zero-guard and
B-02R's corrected loop land** — B-01 raises the metrics-collector overlap probability from ~2% to 17–50% every
Monday, and on an uncorrected B-02R a read-data failure would be **masked by the following `repair snapshots`**.
That pairing (add bit-rot detection, simultaneously silence it) is the worst outcome available.

---

**D11 — `nixos-apple-silicon` is 222 days stale; home-manager is 66.7 days stale.**
`nixos-apple-silicon` (f94f449677, 2025-12-18) supplies linux-asahi, GPU/peripheral drivers, vendor firmware and
m1n1 — **every hardware-specific component** — against an 8.3-day nixpkgs. Nothing is failing today; both are
reboot-risky and **no reboot happens without you**.
* (a) Bump `nixos-apple-silicon` with a reboot window, paired with `scripts/post-reboot-validation.sh`
* (b) Bump home-manager only (no reboot needed) and defer the platform bump
* (c) Bump both in one window
* (d) Defer both and re-evaluate when the nixpkgs-unstable pin is re-floated (~2026-08-10)

**→ Recommend (b) now, (a) in a scheduled window after this plan's phases land.** Do not mix a 222-day platform
bump with 77 monitoring changes — you would lose the ability to attribute any regression. `post-reboot-validation.sh`
(600 lines, 21 PASS/0 FAIL at last cold boot) is the right gate for (a).

---

**D12 — 17 abandoned logind sessions holding ~174 MB.**
17 sessions in `State=closing` (oldest 2026-07-11), **17** `nix-daemon --stdio` parents, ~174 MB permanently
pinned on a host where three services are simultaneously throttling against memory limits.
* (a) Terminate the stale closing sessions now (one-off, reclaims ~174 MB)
* (b) `services.logind.killUserProcesses = true` (kills tmux/screen/nohup on logout — real behavioural change)
* (c) Add a periodic sweep terminating `State=closing` sessions older than N hours
* (d) Accept it; restart nix-daemon opportunistically

**→ Recommend (c) with guards, after one log-only cycle.** **Not (b).** The hazard the designs understate:
`nix-daemon --stdio` is the daemon side of a **live client connection**, and a `closing` session can still be
serving an in-progress `nixos-rebuild` — a 6-hour age filter does not rule that out. Add an activity guard and a
rebuild interlock, and emit the leak **rate** so this stops being rediscovered by every audit.

---

**D13 — Paging policy: which `info` alerts may go to a digest-only receiver?**
R-09R nulls 17 of 21 info rules after promoting four. This is a policy call, not a technical one.
* (a) Promote the four named (`HostUnexpectedReboot`, `ContainerCVEScanFailed`, `ContainerCVEDBStale`,
  `MicroVMStateShareExporterStale`) + exempt `health_report_*`, then null-route the remaining 17
* (b) Null-route all 21 info rules
* (c) Leave info routing unchanged

**→ Recommend (a).** (b) re-creates meta-monitoring blind spots: a failed CVE *scan* is a coverage failure, and
on a host whose CLAUDE.md says only you ever reboot, an unexpected reboot is a genuine anomaly.

---

**D14 — Drop the stray empty `litellm.public` database?**
`pg_database` contains a database literally named `litellm.public` (7,670 kB, **0 tables**) alongside `litellm`
(56 GB); grep across all of `/etc/nixos` finds **zero** references. The name shape says a schema-qualified
identifier was passed where a bare database name was expected.
* (a) Drop it now (it is empty)  · (b) Identify the client whose connection string created it first, then drop
  · (c) Leave it; the cost is one empty dump directory

**→ Recommend (b) then (a).** It is harmless but the nightly `pg_dump` mirrors it forever, and **some client may
believe it is writing there.** D-11's completeness check will count it as a live database, so resolve it before
that rule's baseline is set.

---

**D15 — `notebook.vulcan.lan` is served but its certificate has no matching SAN.**
`jupyterlab.nix:320` declares the serverAlias, internal DNS resolves it, nginx serves it — but the presented cert
is `CN=jupyter.vulcan.lan` with **only** `DNS:jupyter.vulcan.lan` in its SAN list, so HTTPS fails for any
verifying client. `blackbox-monitoring.nix:883-885` deliberately omits it because *"jupyter is covered"* — but
**the difference between the two names is exactly the certificate**, so probing jupyter proves nothing.
* (a) Add `notebook.vulcan.lan` to the cert SAN and add a blackbox probe  · (b) Drop the serverAlias so the
  broken name stops resolving to a served vhost  · (c) Leave it; nothing uses the alias

**→ Recommend (b)** unless you actually use the alias — it is the smaller change and removes a name that cannot
work rather than adding machinery to keep it working.

---

**D16 — Root NVMe wear/media monitoring and periodic SMART self-tests.**
`smartctl_exporter` serves only sda-sdd, so **nvme0n1 — backing `/` and `/nix/store` — has no automated SMART
coverage**, and `SmartNVMeMediaErrors` is a knowingly dead rule. `smartd` is not installed; each tank drive's
self-test log holds exactly **one** burn-in record from ~30,000 hours ago.
* (a) Add nvme0n1 to `smartctl_exporter` and revive the NVMe media-error rule
* (b) Enable `smartd` with a periodic short/long self-test schedule for all five devices
* (c) Both  · (d) Keep manual-inspection-only; the monthly ZFS scrub is the stronger integrity check for tank

**→ Recommend (c), but as ONE collector, not two items.** Critical caveat: I enumerated the exporter's entire
metric surface and **it emits no `self_test` series of any kind** — a *failed* self-test would reach only
`smartd`'s unmonitored mail to root. So (b) alone schedules media exercise whose **outcome is unobservable** —
the same "active but not functioning" shape as `zpool-trim`. If you take (c), the collector must parse
`smartctl -l selftest -j` for all five devices and emit `smart_selftest_last_status` / `_last_lifetime_hours` /
`_age_hours`, plus a `SmartdDown` rule. Also: `smartctl_device_error_log_count` is **live for all four tank
drives and referenced by zero rules** — free coverage. Threshold correction: `available_spare < 100` would page
on the *first spare block ever consumed*; use `< 95`, or emit the device's own threshold and compare.

---

**D17 — 82 retained system generations against a 10-entry `/boot` limit.**
`nix.gc` is automatic and healthy, `/boot` correctly bounded at 10, but `/nix/var/nix/profiles` holds **82**
system generations (oldest 2026-06-26) — the GC window keeps ~32 days of closures. Root is at 30% of 1.7 T.
* (a) Tighten `nix.gc` to a shorter retention (e.g. 14 d)  · (b) Leave as-is; disk is ample and rollback depth is
  valuable  · (c) Prune to a specific generation count once, keep the current policy

**→ Recommend (b).** With a 222-day platform bump pending (D11), deep rollback capability is worth more than
disk that is not scarce.

---

**D18 — Configure or delete the 4 Discord round-trip canary rules.**
`HermesDiscordCanaryDown/Stale` and `OpenClawDiscordCanaryDown/Stale` reference `hermes_discord_canary_*` /
`openclaw_discord_canary_*`, **none of which exist**. Verified why: `modules/monitoring/services/discord-canary.nix`
is imported at `hosts/vulcan/default.nix:139` but `services.discordCanary.probes` is `{}` — no probe was ever
declared. (The similarly-named `openclaw_canary_parse_ok` that *does* exist comes from a different exporter and
measures a ready-line parse, not a round trip.)
* (a) Configure the two probes (needs channelId, targetUserId and a bot token in SOPS per
  `docs/DISCORD_CANARY_SETUP.md`)  · (b) **Delete the 4 rules** and rely on existing heartbeat/ws-connected
  coverage  · (c) Keep one direction only (OpenClaw → Hermes)

**→ Recommend (b).** Existing heartbeat and `discord_ws_connected` coverage is live and adequate; (a) requires a
new bot token in SOPS, which given D1 is not the week to add one. If you pick (b), it should ride in **Phase 2**.

---

## 9. Explicitly out of scope

Each of these is real. Each is excluded for a stated reason, with what it would take to pull it in.

### 9.1 Fixes that live in someone else's code

**A-91 — HA: every `climate.set_temperature` on `climate.upstairs` raises TypeError**
33+ failures over 3 days (07-25 = 11, 07-26 = 12, 07-27 = 10, 07-28 = 3) at
`homeassistant/components/nest/climate.py:317` — `abs(high_temp - self.target_temperature_high)` where
`target_temperature_high` is `None` because the Nest is not in a `heat_cool` mode. **Setpoints are silently never
applied.** The caller passes `target_temp_high == target_temp_low == temperature` (a zero-width range) and is
almost certainly `versatile_thermostat`, which logs its own *"Requested state for unknown entity_id:
climate.upstairs"* 8 times.
*Why out:* the fix is in third-party code (HA's nest component and/or VTherm) **or** in a VTherm reconfiguration
that lives in HA's `.storage`, not in this repo.
*To pull in:* first **prove the emitter** — enable VTherm debug logging for one cycle and tie a `ServiceCall`
context id to it (the registry inference narrows but does not prove causation; acting on the wrong integration
means reconfiguring the wrong thing and concluding the fix failed). Then prefer the pattern this household
already proved on 2026-05-28 (`project_office_hvac_eco_restore`): `climate.set_preset_mode 'none'` to exit Eco,
**then** write a single `temperature`. Reject a local overlay patch — permanent rebase burden for a
caller-triggered path. Snapshot `core.config_entries` (root-only, never displayed) first.
*Detection ships anyway:* **A-96R** (with the corrected `>0` threshold — the design's `>3/6h` would **not** fire
on today's 3-event cluster).

**A-94 — the lying `stock_trader_data_source_up` gauge**
Reads **1** while the source has been dead 34.2 days (`avg_over_time[24h]` = 0.9746, 8 transitions/day). Root
cause is documented in the app's own docstring. *Why out:* `pkgs/stock-trader.nix` takes `src` from a **separate
flake input** — this is an upstream change in another repo.
*In-repo alternative ships:* **A-U1s**. *Also do:* `grep -rl stock_trader_data_source_up` across the dashboard
definitions and repoint the panels — a dashboard that says "healthy" is the same silent-failure class.

**Y-91 — 6 quadlet units reporting `UnitFileState=bad`**
`/etc/systemd/system/<x>.service` → a quadlet-service-symlinks store path → `/run/systemd/generator/<x>.service`.
`find -xtype l` returns nothing, so **no link actually dangles**; all 6 units are active with `Result=success` and
nothing on this host consumes `UnitFileState`. *Why out:* removing the double indirection is an upstream
`quadlet-nix` change.

### 9.2 New capabilities, not config fixes

**A-92 — matter-server: 5 Matter nodes in continuous subscription churn**
16,211 err-priority lines in 13 h, ~5,394 genuine CHIP errors, flat at ~210 events/hour for **every hour of the
last 24**, against 5,160 *"Re-Subscription succeeded"* — a self-sustaining loop. `<Node:24>` dominates at 6,490
events vs ~1,000 each for four others. Unit reports active/running/`Result=success`/`NRestarts=0` throughout.
*Why out:* converging this needs Matter/Thread mesh diagnosis and probably device or border-router changes.
*Detection ships as a report row, not a page* (**A-98R**) — the proposed 120/6 h threshold sits **below the
observed floor** of 126–138/6 h, so it would be permanently firing. Use `> 600/6h` or a baseline-relative form.
*Most valuable finding here, and it belongs in the repo as a comment:* `SystemdJournalHighErrorRate` is quiet
**by exclusion** — `systemd-errors.yaml:14-15` strips `CHIP_ERROR` and *"Subscription failed with CHIP"*. **A
green journal-error rule must never be read as "Matter is healthy."** Write that next to the exclusion, not only
in a memory file. *If you do re-commission Node:24:* `/var/lib/matter-server` holds the fabric credentials —
copy it first or every paired device needs re-pairing.

**A-95 — copyparty has no usable unit/journal visibility**
Runs under `systemd-nspawn`, a **third** virtualisation technology no domain enumerated. `systemctl show` returns
an empty `ActiveEnterTimestamp`; its journal held **1 line** across a 22.6 h outage. Every unit-state and
journal-grep method this fleet relies on returns nothing useful. *Why out:* making it observable means changing
how it is run, or building an nspawn-aware collector — a new capability.
*Cheap correct win ships:* **M-15R** catches it from the outside; **R-01** makes the 22.6 h visible.

**M-91-adjacent / M-92-adjacent** — both *were* pulled in (M-91R, M-92R) after re-scoping from "needs a
framework" to "one textfile collector". Retained here only to note the re-scope was deliberate.

### 9.3 Forensically closed — the data no longer exists

**A-93 — reconstruct the 2026-07-23 multi-service incident**
Four findings land on that day and joining them needs data that is gone: `CopypartyDown` critical 22.6 h with
**1 journal line for the whole day**; a **47-restart 10-hour openclaw storm** (verified hour-by-hour on
`openclaw_self_heal_attempts_total`) with an **empty unit journal**; `openclaw-self-heal` has emitted **zero**
lines for its entire life with `incidents.json` frozen at 11:59:44; and **`OpenClawSelfHealDown` itself fired** —
the remediator was down or restarting (`ActiveEnterTimestamp` 10:59:44) during the storm it was meant to converge.
*A-01 makes the next one reconstructable. This one is closed.*

**M-93 — what bound an unexpected wildcard listener for 24.7 hours on 07-21/22**
One unbroken 1,480-minute critical window; the gauge is non-zero 29% of the week (verified 0.294). The exporter
records **only a count**. *M-22 adds the labels going forward; the past event is unrecoverable.*

**M-94 — which alertname diverged during the 21.75-hour `NagiosMirrorDivergence` window**
The counter returning to 0 says only that it **reconciled**; the reconciler keeps no divergence detail.
*Structural point worth recording in-repo:* the mirror **cannot detect the dead-rule class at all** — Nagios
evaluates the same broken expression, gets no data, lands at OK/UNKNOWN, and the script skips UNKNOWN by design.
**A green mirror must never be read as "no dead rules."** R-03R's Section C adds a divergence-episode row so the
two systems stop being free to disagree silently.

### 9.4 Deferred designs the adversary broke and I did not repair

**S-06 — 502-burst regression detector on `/v1/responses`**
Would fire on **every** restart today (3 clusters in 24 h, all >5 per 10 min), and its gate — S-03R producing
"~0 residual" — is **invalid**: the startup window produces 502s independently of drain quality
(`TimeoutStartSec=900`, container still initialising 13 s after the kill). *To pull in:* land corrected S-03R,
measure the residual across **two** nightly cycles, then set the threshold above it and say so in the annotation
— or, if the residual is startup-dominated, alert on **502 duration past a restart** instead, which is what
actually distinguishes a broken drain from a normal cold start. Note `Nginx5xxBurst` (>30/2m) and
`NginxUpstreamFailureBurst` (>10/2m) are already tuned above restart blips with in-file rationale; do **not**
lower them.

**M-02 — generic nginx 5xx-rate Loki rule → CLOSED as already covered**
Verified at the Loki ruler API: group `nginx_web_errors` (file `nginx-web.yaml`) already contains
`Nginx5xxBurst`, `NginxUpstreamFailureBurst`, `NginxApplicationError500` and `NginxAuthFailureBurst`, all
`health=ok`. The push-mirror residue is **~1 failure/day**, so a 15-minute window can never exceed
`NginxApplicationError500`'s `> 2` floor — which is exactly why **M-01/D-01 uses a 26 h window**.
*Action: record the closure as a comment in `nginx-web.yaml` naming M-02 and the reason,* because this is a
negative finding and negative findings decay: those thresholds were tuned against a 2026-06-27 HA-restart storm
and a 2026-07-22 teable 500, and relaxing them later would silently change coverage this plan declares sufficient.

**D-02's openuv staleness rule — DROPPED**
`lag(openuv_forecast[…]) > 6h` is above threshold on **2,295 of 3,681 steps = 62.3% of the last 90 days** (73.7%
of the last 14 d), because `openuv_forecast` is a **push-on-change string** entity whose p95 inter-sample gap is
38.1 h. `pool-sensors.yaml`'s own header already excludes this class. *The three existing pool rules DO get their
idiom fixed* — `lag(X[Nd])` returns **NO_DATA once staleness exceeds N** (proved on a 245 h-stale series:
`lag[1d]`, `lag[3d]`, `lag[10d]` all NO_DATA, `lag[30d]` = 883,242 s), so `PoolWaterTempStale` would detect only
the band (6 h, 24 h] and then send a **RESOLVED notification at 24 h for a sensor that is more dead than ever**.
Use the monotone form `absent_over_time({entity_id="water_sensor_1", __name__=~".+_value"}[6h])` as the firing
condition and keep `lag(X[90d])` annotation-only. Raise intellichlor 72 h → **96 h** (1.25× the 90 d observed max
of 77.0 h; 72 h sits only 7% above it). *Node-RED Pool-tab liveness ships instead as **A-97R**.*

**D-03 — "alert has been firing >4h" meta-alert → moved to the daily report**
The final expression backtests correctly on copyparty (crosses 4 h around 11:00Z on 07-23, reads 22.6 h by
07-24T02:00). But over 7 days it is non-empty for **16 distinct alertnames, 900/1008 steps = 89.3% of the week**
even after excluding the Schwab rules. `NagiosServicesCritical` alone is 144.7 h — Nagios uses a **24 h
check_interval**, so a stale CRIT is frozen for a day *by design* and will exceed 4 h on essentially every
occurrence. The alertname-**denylist** is also the wrong architecture: it must be hand-extended for every future
chronic alert, which is the maintenance-decay failure mode this plan exists to fix. *If you ever want it as a
page, invert to **opt-in**: a `duration_watch="true"` label on the handful of rules where a long fire is genuinely
anomalous.* Duration reporting ships in **R-01**, which is the right cadence for "nobody noticed a 22 h critical"
and costs zero paging load.

### 9.5 Gaps this plan leaves open (named so they are not rediscovered)

1. **No restore verification.** B-01 adds pack-read verification (structure + hashes); **nothing ever proves a
   restored file equals the original.** A monthly oneshot restoring one file per repo and emitting
   `restic_restore_verify_success{repository}` is the missing bottom of the pyramid. B-U1's own text calls this
   *"the only test that matters"* and then leaves it manual.
2. **No route-and-receiver reachability check per rule.** A rule can be perfectly evaluable, correctly
   thresholded, and still deliver **nowhere**. `health=ok` + non-empty selector cannot see that.
3. **No scrape-gap awareness for windowed rules.** A **332-minute gap on 2026-07-03** silently corrupted one of
   this plan's own backtests by collapsing a 6 h denominator from 360 samples to 38. Nothing flags *"this
   target's window contains <80% of expected samples"* — a prerequisite for trusting any `avg_over_time`
   availability rule.
4. **Duplicate alert NAMES across files with different expressions.** After M-12/M-03 there are still **two live
   rules named `BackupServiceFailed`** with different exprs and dwells, and `MbsyncNotRunRecently` is declared
   **three times in one group**. Alertmanager groups by alertname: one email cannot distinguish them, one silence
   covers both.
5. **No shared execution-vs-outcome convention.** Four producers are converted; there is no helper, no lint, and
   no rule asserting that a service declaring `*_last_success` also declares a work floor. Archetype (b) will
   recur on the next backup/sync/report job written.
6. **The `USING(date, start_time)` producer is still unidentified.** Not in `/etc/nixos` (repo-wide grep for SQL
   `USING` hits only `databases.nix` and a cert script); Loki shows exactly **1** occurrence in 8 days. D-10
   detects the *class*; the specific query remains unfound. `pg_stat_statements` or `log_min_error_statement`
   would find it.
7. **ZFS snapshot retention itself is unchanged.** S-01R makes the 43× amplification *visible* and it will fire
   permanently; nothing in the plan changes sanoid retention (that is D7). **A detector for a condition with no
   owner becomes wallpaper within two weeks** — this is why S-01R is `severity: info` and why D7 matters.
8. **No off-host observer.** Alertmanager, Loki and promtail all run on the machine they report about (M-24R
   exposes this for the UPS case; it is fleet-wide). The Watchdog dead-man exists, but nothing tests that a
   critical generated in the **last 60 seconds before an unclean shutdown** actually leaves the host. One
   external or push-based confirmation path would cover M-24R, the UAS pool-loss cascade and D-15 simultaneously.
9. **`for:`-vs-Nagios-mirror skew is systemic.** The mirror approximates `for:` as
   `max_check_attempts = clamp(1 + ceil(for/retry), 1, 20)`, so with warning-severity `retry=5m` any rule with
   `for: > ~95 min` reaches HARD in the mirror **~4 hours before** Prometheus fires, while
   `NagiosMirrorDivergence` tolerates only 30 min. This plan keeps every new `for:` **≤ 90 min** for that reason;
   the general problem is undocumented.

---

## 10. Verification harness

Save as `scripts/verify-remediation-2026-07.sh`, in the style of `scripts/post-reboot-validation.sh` (600 lines,
`check "<name>"` helper, PASS/FAIL tally). Run after every phase; the phase's own checks must pass and **all
earlier phases must still pass**.

```bash
#!/usr/bin/env bash
# Verification harness for the 2026-07-28 remediation plan.
# READ-ONLY. Mirrors the check/PASS/FAIL style of scripts/post-reboot-validation.sh.
set -uo pipefail

PROM=http://localhost:9090
LOKI=http://localhost:3100
PROMTOOL=/nix/store/iinff711bp4hsw0xbk27mas9xh2mrl9a-prometheus-3.7.2-cli/bin/promtool  # NOT on PATH
PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
# scalar PromQL -> value, or the literal string EMPTY
pq(){ curl -sG --data-urlencode "query=$1" "$PROM/api/v1/query" \
      | jq -r '.data.result[0].value[1] // "EMPTY"'; }
# series count for a selector
pc(){ pq "count($1)"; }
lq(){ curl -sG --data-urlencode "query=$1" "$LOKI/loki/api/v1/query" \
      | jq -r '.data.result[0].value[1] // "EMPTY"'; }
chk(){ local n="$1" got="$2" want="$3"; [ "$got" = "$want" ] && ok "$n ($got)" || no "$n" "got=$got want=$want"; }
gt(){  local n="$1" got="$2" min="$3"
       if [ "$got" != "EMPTY" ] && awk "BEGIN{exit !($got > $min)}"; then ok "$n ($got)"; else no "$n" "got=$got want>$min"; fi; }

echo "=== PHASE 0 — invariants that must hold at all times ==="
chk "Prometheus rules: 0 health=err" \
    "$(curl -s $PROM/api/v1/rules | jq '[.data.groups[].rules[]|select(.health!="ok")]|length')" 0
gt  "Loki ruler rule groups >= 11" \
    "$(curl -s $LOKI/prometheus/api/v1/rules | jq '[.data.groups[]]|length')" 10
chk "systemd --failed is empty" "$(systemctl --failed --no-legend | wc -l)" 0
chk "Alertmanager registered exactly once" \
    "$(curl -s $PROM/api/v1/alertmanagers | jq '.data.activeAlertmanagers|length')" 1
gt  "Prometheus targets up" "$(pq 'count(up==1)')" 130

echo "=== PHASE 1 — storage bleed stopped ==="
chk "staging is the ZFS dataset (NOT root ext4)" \
    "$(findmnt -no FSTYPE,SOURCE /var/lib/postgresql-backup-staging 2>/dev/null)" \
    "zfs   tank/Backups/PostgreSQL-staging"
chk "litellm quadlet declares StopTimeout+StopSignal" \
    "$(grep -cE '^(StopTimeout|StopSignal)=' /var/lib/containers/litellm/.config/containers/systemd/litellm.container)" 2
# oldest spend-log row must be inside the retention window (D-05R; 103 days = 8899200s)
got=$(pq 'litellm_spendlogs_oldest_row_age_seconds')
if [ "$got" != EMPTY ] && awk "BEGIN{exit !($got < 8899200)}"; then ok "spend-log retention enforced ($got s)"
else no "spend-log retention enforced" "age=$got want<8899200 (was 273d)"; fi
# newest daily snapshot must no longer pin a near-full copy
gt  "mirror completeness sentinel" "$(pq 'pg_dump_mirror_complete')" 0.5

echo "=== PHASE 2 — dead rules repaired or deleted ==="
n=$(curl -s $PROM/api/v1/rules | jq '[.data.groups[].rules[]]|length')
if [ "$n" -lt 534 ] && [ "$n" -gt 490 ]; then ok "rule count reduced 534 -> $n"; else no "rule count" "got=$n want 490..533"; fi
chk "backup_alerts group deleted"  "$(curl -s $PROM/api/v1/rules | jq '[.data.groups[]|select(.name=="backup_alerts")]|length')" 0
chk "no rule still uses job=blackbox-https" \
    "$(curl -s $PROM/api/v1/rules | jq '[.data.groups[].rules[]|select(.query|test("blackbox-https"))]|length')" 0
chk "health-checks.yaml loaded once (38 instances -> 19)" \
    "$(curl -s $PROM/api/v1/rules | jq '[.data.groups[]|select(.name=="certificate_alerts" or .name=="health_check_alerts")|.rules[]]|length')" 19
for pair in \
  'probe_success{job="blackbox_https_local",instance="https://jupyter.vulcan.lan"}|1' \
  'node_systemd_unit_state{name="jupyterlab.service"}|5' \
  'last_over_time(api_errors_total[30d])|1' \
  'grafana_authn_authn_failed_authentication_total|1' \
  'probe_success{host_group="dns"}|6' ; do
  sel=${pair%|*}; want=${pair#*|}; chk "selector non-empty: ${sel:0:52}" "$(pc "$sel")" "$want"
done
chk "technitium ratio evaluates (corrected vector match)" \
    "$(pc 'sum by(instance,job)(technitium_dns_request_result_count{result="server_failure"}) / on(instance,job) group_left sum by(instance,job)(technitium_dns_request_result_count)')" 1
chk "TechnitiumUpdateAvailable deleted" \
    "$(curl -s $PROM/api/v1/rules | jq '[.data.groups[].rules[]|select(.name=="TechnitiumUpdateAvailable")]|length')" 0
chk "ResticRepositorySizeGrowing uses delta(...[6h]) not rate()" \
    "$(curl -s $PROM/api/v1/rules | jq -r '[.data.groups[].rules[]|select(.name=="ResticRepositorySizeGrowing")|.query|test("delta\\(.*\\[6h\\]\\)")]|all')" true
chk "ResticNoRecentSnapshot at 36h: 0 repos currently over" "$(pq 'count(max_over_time((time() - restic_last_snapshot_timestamp_seconds{repository!=""})[7d:1h]) > 129600)')" EMPTY

echo "=== PHASE 3 — archetype detectors present ==="
for m in zfs_dataset_used_by_snapshot_bytes zfs_dataset_used_by_children_bytes \
         gitea_push_mirror_sync_failures gitea_push_mirror_last_run_timestamp_seconds \
         flume_cross_check_data_steps_degraded flume_cross_check_last_completion_timestamp_seconds \
         pg_dump_database_dirs pg_dump_databases_live litellm_spendlogs_oldest_row_age_seconds ; do
  v=$(pc "$m"); [ "$v" != EMPTY ] && ok "metric present: $m ($v series)" || no "metric present: $m" "ABSENT"
done
# the amplification rule must select EXACTLY ONE dataset (verified 1 of 59 at plan time)
chk "amplification rule selectivity == 1" \
    "$(pq 'count((zfs_dataset_used_by_snapshot_bytes{type="filesystem"} > 300*1024*1024*1024) and ((zfs_dataset_used_by_snapshot_bytes{type="filesystem"} / clamp_min(zfs_dataset_used_by_dataset_bytes{type="filesystem"},1)) > 5))')" 1
chk "flume-data-weekly can write the textfile dir (EROFS blocker)" \
    "$(systemctl show flume-data-weekly -p ReadWritePaths --value | grep -c prometheus-node-exporter-textfiles)" 1
gt  "gitea mirror Loki rule loaded" \
    "$(curl -s $LOKI/prometheus/api/v1/rules | jq '[.data.groups[]|select(.file|test("gitea-mirror"))]|length')" 0
echo "  (info) gitea 500s last 7d: $(lq 'sum(count_over_time({job="nginx-access", status=~"5.."} |= "push_mirrors-sync" [7d]))')  # was 7 pre-fix; target 0"

echo "=== PHASE 4 — daily report ==="
for m in health_report_last_run_timestamp_seconds health_report_sections_rendered \
         health_report_ai_narrative_ok prometheus_dead_alert_selectors wisdom_entries_total ; do
  v=$(pq "$m"); [ "$v" != EMPTY ] && ok "report metric: $m = $v" || no "report metric: $m" "ABSENT"
done
gt  "report renders >= 5 sections" "$(pq 'health_report_sections_rendered')" 4
# the absent() guard must be present, or the self-monitoring is decorative
chk "R-08R rules carry absent() guards" \
    "$(curl -s $PROM/api/v1/rules | jq -r '[.data.groups[].rules[]|select(.name|test("HealthReport"))|.query|test("absent\\(")]|all')" true
# R-03R MUST label with `rule`, never `alertname` (promtool-proven health=err otherwise)
chk "dead-selector sentinel labels with rule=, not alertname=" \
    "$(curl -s $PROM/api/v1/rules | jq -r '[.data.groups[].rules[]|select(.name=="PrometheusRuleReferencesMissingMetric")|.query|test("alertname")]|any')" false
echo "  (manual) next morning: doveadm search -u johnw mailbox INBOX since 1d subject 'System Health Report' | wc -l  >= 1"
echo "  (manual) confirm Section A lists a CopypartyDown-class multi-hour window if one occurred"

echo "=== PHASE 5 — alert fatigue ==="
v=$(pq 'avg_over_time(config_file_drift{file=~".*secrets.*"}[7d])')
if [ "$v" != EMPTY ] && awk "BEGIN{exit !($v < 0.05)}"; then ok "secrets.yaml drift resolved ($v)"; else no "secrets.yaml drift resolved" "avg7d=$v want<0.05 (was 0.600)"; fi
chk "aide-metrics timer removed" "$(systemctl list-timers 'aide*' --all --no-legend | grep -c aide-metrics)" 0
chk "aide-metrics has no boot start path" "$(systemctl show aide-metrics -p WantedBy --value | wc -w)" 0
amtool config routes test severity=info     >/dev/null 2>&1 && ok "amtool: info route resolves"     || no "amtool: info route"
amtool config routes test severity=critical >/dev/null 2>&1 && ok "amtool: critical route resolves" || no "amtool: critical route"
echo "  (budget) email/7d: $(pq 'increase(alertmanager_notifications_total{integration="email"}[7d])')  # baseline 406, target <200"
echo "  (info)  webhook/7d: $(pq 'increase(alertmanager_notifications_total{integration="webhook"}[7d])')  # ~1979 BY DESIGN (Watchdog dead-man) — do not 'fix'"

echo "=== PHASE 6 — new coverage ==="
for j in ha-nodered sudo kernel; do
  curl -s $LOKI/loki/api/v1/label/job/values | jq -e --arg j "$j" '.data|index($j)' >/dev/null \
    && ok "Loki job present: $j" || no "Loki job present: $j" "missing"
done
# per-job ingestion deadman: a job that exists but ships nothing is the failure this catches
for j in ha-nodered sudo sshd postgresql nginx-access; do
  v=$(lq "sum(count_over_time({job=\"$j\"}[6h]))")
  [ "$v" != EMPTY ] && [ "$v" != 0 ] && ok "Loki ingesting: $j ($v lines/6h)" || no "Loki ingesting: $j" "0 lines/6h"
done
for m in network_ups_tools_battery_charge cgroup_memory_pressure_full_avg300_ratio \
         hass_entities_unavailable_total node_textfile_temp_leak_count ; do
  v=$(pc "$m"); [ "$v" != EMPTY ] && ok "metric present: $m" || no "metric present: $m" "ABSENT"
done
grep -q '^9199 ' /etc/nixos/docs/ports.txt && ok "port 9199 registered in docs/ports.txt" || no "port 9199 registered" "missing"
# M-15R must select exactly the garage lock (verified 1 series at plan time)
chk "chronic-flap rule selectivity == 1" \
    "$(pq 'count(changes(probe_success{host_group!~"iot-noping|iot-quiet"}[7d]) > 100 and avg_over_time(probe_success{host_group!~"iot-noping|iot-quiet"}[7d]) < 0.98)')" 1
chk "blackbox_https_public now has 4 targets" "$(pc 'probe_success{job="blackbox_https_public"}')" 4
gt  "openclaw-self-heal is logging" "$(journalctl -u openclaw-self-heal --since '-24h' --no-pager | wc -l)" 0

echo "=== PHASE 7 — backup integrity + hygiene ==="
chk "resticOperations uses the isolating set+e form" \
    "$(grep -c 'set +e' /etc/nixos/modules/lib/resticOperations.nix)" 1
grep -q 'read-data-subset' /etc/nixos/modules/lib/resticOperations.nix && ok "--read-data-subset present" || no "--read-data-subset present" "missing"
grep -q 'RuntimeMaxSec' /etc/nixos/modules/storage/backups.nix && ok "restic-check RuntimeMaxSec bound" || no "restic-check RuntimeMaxSec bound" "missing"
# permissions — METADATA ONLY. Never cat these files.
chk "no dovecot key .bak files"      "$(sudo ls -1 /var/lib/dovecot-certs/ 2>/dev/null | grep -c '\.bak')" 0
n=$(sudo ls -1 /var/lib/postgresql/certs/server.key.bak.* 2>/dev/null | wc -l)
[ "$n" -le 3 ] && ok "postgres key backups pruned to $n (<=3)" || no "postgres key backups pruned" "got=$n want<=3"
chk "no group/world-readable keys in cert dirs" \
    "$(sudo find /var/lib/dovecot-certs /var/lib/postgresql/certs -name '*.key*' \! -perm 600 2>/dev/null | wc -l)" 0
doveadm search -u johnw mailbox INBOX all >/dev/null 2>&1 && ok "IMAP auth still works after C-01R" || no "IMAP auth after C-01R" "LOGIN BROKEN — revert (b)"
chk "no leaked textfile temps" "$(ls -1 /var/lib/prometheus-node-exporter-textfiles/*.prom.* 2>/dev/null | wc -l)" 0
chk "openproject /tmp is 1777" "$(sudo stat -c '%a' /var/lib/containers/openproject/tmp)" 1777
chk "zpool-trim timer gone" "$(systemctl list-timers 'zpool-trim*' --all --no-legend | wc -l)" 0
gt  "nix-optimise timer exists" "$(systemctl list-timers 'nix-optimise*' --all --no-legend | wc -l)" 0
n=$(loginctl list-sessions --no-legend | wc -l); echo "  (info) logind sessions: $n  (17 were State=closing pre-fix)"
b=$(stat -c%s /home/johnw/.claude/projects/-etc-nixos/memory/MEMORY.md)
[ "$b" -lt 25000 ] && ok "MEMORY.md under limit ($b B)" || no "MEMORY.md under limit" "got=${b}B want<25000 (was 58266)"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ] || exit 1
```

**Also run, unchanged, after any reboot:** `scripts/post-reboot-validation.sh` (600 lines; asserts *"Prometheus
rules: 0 health=err"* at :402 and *"Loki ruler >=10 rule groups"* at :430 — both still satisfied by this plan,
since it deletes rules but no Loki **groups**).

**Static gates before every switch:**
```bash
nix flake check
sudo nixos-rebuild build --flake '.#vulcan' --show-trace
/nix/store/iinff711bp4hsw0xbk27mas9xh2mrl9a-prometheus-3.7.2-cli/bin/promtool check rules \
  modules/monitoring/alerts/*.yaml          # promtool is NOT on PATH — absolute path required
# Loki rule files cannot be promtool-checked; verify via the ruler API after the switch.
```
