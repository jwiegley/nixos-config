# Wiggum Handoff — vulcan remediation loop

**Started:** 2026-07-28 · **Mode:** `/wiggum` autonomous loop
**Frozen plan:** `docs/REMEDIATION_PLAN_2026-07-28.md` (76 items, 7 phases)
**Frozen decisions:** `docs/REMEDIATION_DECISIONS_2026-07-28.md` (18 decisions + 10 scope-creep, all resolved)
**Source audit:** `docs/HEALTH_AUDIT_2026-07-28.md` (116 findings)

> These three documents are READ-ONLY for the purpose of lowering the bar.
> Do not edit them to make a gate pass.

## Environment notes

- **Anvil MCP: ABSENT on this host.** Probed at loop start 2026-07-28; no `anvil`
  registration is present (a capability search returned unrelated tools). Using
  standard tools for the whole loop. Re-probe after any compaction.
- **No `doc/observations/`** directory exists, so the `partner-cleanup` step of each
  iteration is a no-op. Check anyway each cycle in case one appears.
- **Build lock protocol is mandatory** (`CLAUDE.md`): `sudo touch /etc/nixos/.nixos-build`
  before any build/switch, remove it after. If it already exists, wait up to 10 min
  polling every 10s; if still present, STOP and ask. Never delete another job's lock.
- **Flake reads from the git tree**: new files must be `git add`-ed before a rebuild
  will see them, or the build fails with "path ... does not exist".
- **Branch:** `main`, no Graphite stack. No remote push as part of the loop.

## Definition of Done (frozen)

Exit ONLY when all hold, with shown evidence:

1. Every in-scope item below is implemented or explicitly deferred with a reason.
2. `sudo nixos-rebuild build --flake '.#vulcan'` succeeds.
3. `promtool check rules --lint-fatal` passes (rc=0) on every changed file under
   `modules/monitoring/alerts/`. **The `--lint-fatal` flag is mandatory**: plain
   `promtool check rules` prints `FAILED: lint error` and still **exits 0**, so an
   exit-code check silently passes a file with duplicate rules. Verified: with
   `--lint-fatal` this repo's current `health-checks.yaml` returns **rc=3**. This
   raises the gate; it must not be relaxed back to the exit-0 form.
4. Live Prometheus reports **0 rules at `health=err`** across the whole rule set.
5. `systemctl --failed` is empty after the final switch.
6. Every new alert rule is backtested or has its firing behaviour measured against the
   live TSDB — no rule ships whose ability to fire is unverified. Record the evidence.
7. Both self-heal test suites pass (openclaw 45, hermes 86).
8. The last work commit has passed a `fess` audit by a separate evaluator subagent.
9. Branch rebased cleanly onto its base locally.

No parity target was given, so DoD = every objective of the frozen plan's in-scope
portion complete and independently verified.

## PHASE 8 — final adversarial review of the whole body of work (ADDED BY OPERATOR 2026-07-29)

**This is an ADDITION to the Definition of Done, not a replacement.** It RAISES the bar; it
must never be used to skip or soften any earlier phase. Runs only AFTER all implementation
work is complete — the operator was explicit: "once you are done with all of your
implementation work".

**Scope:** every commit produced by this effort, i.e. `b2ff8976..HEAD` (41 at the time this
was written; the range grows as the loop continues, so recompute it, do not hardcode a count).

**The question to answer**, in the operator's own framing: have we *not* regressed any
behaviour, not broken anything, not added unnecessary code, and not added unnecessary
complications — and has the overall **quality, clarity and simplicity** of this system
configuration genuinely increased as a result of all this work?

Note this is deliberately BROADER than a per-commit fess audit. Those asked "is this commit's
claim true?". Phase 8 asks "is the SYSTEM better, taken as a whole?" — which can be false even
when every individual commit is defensible. Specifically hunt for:

1. **Behavioural regressions** — anything that used to notify/verify/run and now does not.
   The alert-routing and severity changes are the highest-risk class here, along with the
   restic loop rewrite and the timer reschedule.
2. **Breakage** — dead references, rules that can no longer fire, metrics no longer produced,
   units that fail only on a cold boot (not observable from a running system).
3. **Unnecessary code** — anything added that duplicates an existing mechanism, or that guards
   a condition already guarded elsewhere. Candidates to challenge honestly: the whole-loop
   deadline vs `RuntimeMaxSec`, the coverage metric vs the daily report's alert history, and
   the volume of explanatory comment now in `resticOperations.nix`.
4. **Unnecessary complexity** — where a simpler construct would do the same job. Challenge the
   two-pass structure/data split, the three-bucket counter scheme, and the severity split.
5. **Clarity** — comments that are now wrong, stale, or contradict the code. This effort has
   already produced two self-contradictory comments that measurement caught; assume more.
6. **Net effect** — is the config simpler or merely more heavily annotated? Volume of
   justification is NOT quality.

**Method:** a multi-agent workflow (ultracode is on) — parallel reviewers with distinct lenses,
then ADVERSARIAL verification of every finding before it is reported, then synthesis. Findings
must be reproduced against the DEPLOYED artifact, not the diff. Report honestly even where the
verdict is "this commit made things worse".

**Standing constraints for every agent in it:** read-only; no `nixos-rebuild`; no unit
start/stop/restart; no real `restic` commands (B2 egress); never write to
`/var/lib/prometheus-node-exporter-textfiles` (mode 1777 — writing there injects fake metrics
into production); never read `/etc/litellm/config.yaml`; no `sops -d`; never surface secrets,
keys, tokens or private IPs.

## IN SCOPE for the autonomous loop

Ordered as agreed: restore broken detection first, so later changes are not made on
top of blind monitoring.

- **Phase 2 — dead-rule repair (19 items).** Includes D6 (Technitium: fix 7 ratio
  rules AND retune to measured maxima), the `blackbox-https` hyphen typo (5 rules),
  jupyterlab re-pointing (4), the dead `backup_alerts` group (delete, 3), the
  `health-checks.yaml` double-inclusion, `ResticRepositorySizeGrowing`'s 86,400x unit
  error, D15 (drop the `notebook.vulcan.lan` serverAlias), D18's rules, and the
  PublicEdgeDown dwell regression from commit `9d4ad5b6`.
- **Phase 3 — the three archetypes.** Success-that-isn't, outcome-vs-execution, ratio
  invariants, derived-data freshness, chronic availability, alert-history blindness.
  (Archetype (c), the push mirror, is ALREADY DONE — commit `63dfb993`.)
- **Phase 4 — daily-report redesign** (`scripts/log-summarizer.py`).
- **Phase 5 — alert fatigue**: resolve the two standing conditions, then D13 routing
  (promote 4 info alerts, digest 17).
- **Phase 6 — new coverage**: NUT/UPS (`services.prometheus.exporters.nut.enable` —
  reclassified fixableNow), D16 (nvme0n1 + smartd, one collector, smartd notification
  wired into the alerting plane), promtail scrapes for HA/node-red/sudo/kernel,
  M-92 exporter half, A-92 Matter churn alert, and **both halves of A-91** — the
  detection alert (HA service-call errors) AND the timeboxed VTherm fix attempt, since
  the decisions doc resolved "attempt the VTherm fix, **and** add detection either way".
  - **M-91 (HA entity-availability exporter) — BUILD BUT DO NOT THRESHOLD.** It is in
    scope to write the exporter and land the metric, but its alert threshold is BLOCKED
    behind D9, which is operator-executed. Reason: the decisions doc calls D9 the
    prerequisite and warns that a threshold set against today's 163 unavailable entities
    "would encode 37 known-dead twins as normal" — i.e. shipping the alert first
    manufactures exactly the dead-rule class this whole effort exists to remove. Ship the
    exporter, observe the post-cleanup baseline, then set the threshold.
- **D8's TechnitiumDNS half (158 MiB)** — decided "now" and small enough to carry no
  enclosure-load risk, so it belongs here, not in the gated table (which covers only the
  307 GB Machines upload and the PostgreSQL set awaiting dump confirmation).
- **D3's config-retirement half** — removing the Schwab data source from the
  stock-trader configuration. Reversible config; the credential/app-side teardown stays
  with the operator.
- **Phase 7 — backup integrity/hygiene**: per-repo restic loop isolation FIRST, then
  D10 (`--read-data-subset=2%` weekly, `RuntimeMaxSec=4h`, 06:30 de-herd), private-key
  permissions, D14 (drop `litellm.public`), D12 (guarded logind sweep, log-only first
  cycle), orphaned `.prom` cleanup.
- **M-92 fixable half**: raise the MemoryHigh limits for postgresql / loki /
  home-assistant.

## HUMAN-GATED — explicitly OUT of the loop

These are stop-and-escalate by the skill's own rules (destructive, irreversible, or
require operator action). Do NOT perform them autonomously.

| Item | Why gated |
|---|---|
| **D2 — `git filter-repo` + force-push to Gitea and GitHub** | Rewrites 675 commits and force-pushes shared history. Terminal, human-gated. Prepare and verify only; never push. |
| **Drop `LiteLLM_SpendLogs_prescrub_20260728`** | Operator chose 2026-07-29, after a full day of litellm on the scrubbed table. |
| ~~**D8 — Machines (307 GB) B2 upload**~~ **STRUCK 2026-07-29** | Operator: "That's not a volume I want to back up." Verified never implemented -- `Machines` is in `backupExcludes` (modules/storage/backups.nix:133) and its `mkBackup` call stays commented out; no commit of mine touched the exclusion. The decisions doc's "all three" answer is superseded for this volume. DO NOT un-exclude it. |
| **D8 — PostgreSQL B2 un-exclude** | Gated on the next nightly dump proving the ~8 GB shrink. |
| **D7 — destroy legacy snapshots** | Decided: NO ACTION (listed here for completeness, not because it awaits a gate). Let the ladder expire them. |
| **D4 — UPS self-test** | State change that transfers the host to a 4-year-old battery. Operator-triggered, AFTER NUT monitoring lands. |
| **D9 — HA entity deletion / integration reload** | Live Home Assistant mutation. Prepare the plan; operator executes. |
| **D11 — flake bumps** | Deferred to ~2026-08-10 nixpkgs re-float. |
| **D18 — enabling the canaries** | Needs a Discord channel snowflake from the operator. Ship the config with `enable = false` and the rules ready. |
| **D3 — Schwab retirement** | Config change is in scope; any credential/app-side teardown is the operator's. |

## Stop-and-escalate attempt counters

Reset a counter when its gate passes or the underlying cause demonstrably changes.
Escalate at 3.

| Gate | Attempts | Status |
|---|---|---|
| `nixos-rebuild` build/switch | 0 | — |
| `promtool check rules` | 0 | — |
| 0 err rules live | 0 | — |
| self-heal test suites | 0 | — |
| **fess-auditor subagent (read-data audit)** | **2** | **ESCALATION-WORTHY — went idle twice with no report, including after an explicit request naming the exact structure wanted. Did NOT send a third message (that is thrashing). Fell back to running the two highest-value checks by hand; both found real defects, fixed in `81ee8ed5`. NOTE this breaks the loop's evaluator-separation rule: those findings are me re-checking my own work. A future iteration should spawn a FRESH auditor for `3cd32cc1` + `81ee8ed5` rather than reuse this one.** |

## Progress log

Append one line per completed logical unit. Newest last.

- `2026-07-28` — Loop initialised. Anvil absent. Durable docs installed under `docs/`.
  Pre-loop work already committed and verified: `8762657d` (Discord fixture redaction,
  131 tests pass), `63dfb993` (push-mirror outcome exporter; archetype (c) closed;
  `GiteaPushMirrorFailing` pending on nixos-config as designed), `5552318b` (LiteLLM
  prompt-body scrub: 57 GB → 701 MB, 220,021 rows intact, store_prompts=false,
  retention interval 7d→6h). B2 `/etc/nixos` addition reverted at operator request;
  system store path verified byte-identical to the pre-change generation.
- `2026-07-28` — **Unit 1: durable state committed** (`b79dc574`, docs-only). Its fess
  audit found the private-IP note undercounted (10 → **14 files / 160 occurrences**, four
  omitted holding 102), an M-91/D9 scope contradiction, three decided items with no home in
  either list, and two wrong counts in the commit message. All corrected in the
  "Corrections" section above. The audit also caught two things that change Phase 2 itself:
  the MbsyncNotRunRecently duplicate is a promtool **false positive** (three distinct
  accounts/thresholds; deleting two would drop coverage) and `rbcca` has **no staleness
  coverage** at all. DoD item 3 strengthened to require `--lint-fatal` (verified: plain
  rc=0 vs `--lint-fatal` rc=3; health-checks.yaml is the only file failing it). Self-heal
  suites re-run fresh: openclaw **45/45**, hermes **86/86**.
- `2026-07-28` — **Unit 2: memory limits** (`0df1e897`, corrected by `273d4c52`).
  postgresql/loki/home-assistant raised off self-inflicted MemoryHigh values; postgres was
  pinned AT 3.5G with 3,899,187 throttle events. Audit found my `effective_cache_size`
  justification materially false and the 12G ceiling unmeasured → retuned to **6G/8G**
  (1.26x above the measured 4.8 GiB peak), real evidence substituted (pgscan_direct
  328,982,937 vs pgscan_kswapd 28,148,500 = 92% synchronous reclaim; 278M file refaults;
  peak exceeded the OLD MemoryMax), ceiling budget written down (70.5 GiB vs 62.25 GiB
  MemTotal = 113%, safe for four measured reasons). Throttle counter **frozen** across 3
  samples with live queries between; oom_kill=0. Also repaired a pre-existing `.gitignore`
  corruption: the fused pattern `/prd.md.nixos-build` meant NEITHER `/prd.md` nor the build
  mutex was ignored.
- `2026-07-28` — **Unit 3: jupyterlab/aria2 rule repair** (`895a39e7`, corrected by
  `c15581b2`). 10 dead rules → 6 live: 5 job-label/metric repairs + 4 deletions + 1
  threshold revision. Two root causes: the job `blackbox-https` (hyphen) never existed, and
  the trap is that the underscore `blackbox_https` is a DIFFERENT job (google.com only) so a
  naive swap would have left them dead — correct job is `blackbox_https_local`. Backtested
  against the real 2026-07-03 18:00–18:48 UTC outage (49 contiguous minutes). Fleet: **534
  rules, 0 err**. Audit then found three FALSE coverage claims in my comments (see the
  recurring-defect section above) plus an undisclosed 5m→15m dwell regression; all corrected
  in `c15581b2`.
- `2026-07-28` — **PHASE 2 CLOSED.** Units: `895a39e7`+`c15581b2` (jupyterlab/aria2, 10 dead
  rules -> 6 live), `ed211f95` (dead `backup_alerts` group deleted, rule-loading
  de-duplicated -19, mbsync consolidated +rbcca coverage, inhibit rule retargeted and
  functional for the first time), `ba6c87e5` (7 Technitium ratio rules repaired + retuned
  from a 30d distribution after finding the plan's 7d/5m thresholds would have fired FOUR
  rules in normal operation), `f66e9077` (4 more unfireable rules deleted + 7 audit
  corrections), `8b644d82` (3 DNS-exporter warmup gates, ResticRepositorySizeGrowing's
  86,400x unit error, and MY OWN PublicEdgeDown dwell regression: 10m could not fire on any
  observed outage and the plan's recommended 5m could not either — measured at 30s
  resolution, only 3m works; HostUnreachable now genuinely excludes the public job, which
  9d4ad5b6 had claimed but not achieved).
  **Gates: 538 -> 506 rules (alerting 505 + recording 1), 0 err, all 60 GENERATED rule files
  pass promtool --lint-fatal (the pre-existing health-checks.yaml rc=3 is closed),
  systemctl --failed empty, switch rc=0.**
  Method note worth keeping: `sum(prometheus_rule_group_rules)` is NOT usable for counting —
  it is labelled by rule-file store path, so after a reload both old and new paths sit in the
  lookback window and it double-counts (observed 985, 958 against a true 506). Use
  /api/v1/rules and remember to include the recording rule.
- **Switch exit-4 pattern (2 occurrences, NOT a gate failure):** budget-board-server's
  podman healthcheck runs while `health_status=starting` and returns 1, creating a transient
  failed unit that makes `switch-to-configuration` exit 4 even though the switch applied
  correctly. Journal confirms `health_status=starting` with `failingStreak=0`. **This
  matters beyond cosmetics: a real switch failure and this benign race are
  indistinguishable by exit code, which undermines DoD gate 2.** Fix (a healthcheck
  start-period on the budget-board quadlet) is queued as a Phase 6 item rather than
  hand-clearing the unit every cycle.

## Baseline at loop start (2026-07-28)

- `promtool check rules` over all `modules/monitoring/alerts/*.yaml`: **1 pre-existing
  FAILED** — `health-checks.yaml`, "1 duplicate rule(s) found. Metric:
  MbsyncNotRunRecently, Label(s): component=mail_sync severity=warning". Note promtool
  still exits 0 on this, so a naive `$?` check would miss it; the failure is only
  visible in the output text. Pre-existing, in scope for Phase 2.
- Live Prometheus: **538 rules, 0 at health=err**.
- `systemctl --failed`: **empty**.
- Self-heal suites: openclaw 45/45, hermes 86/86 (verified earlier this session).

## Corrections to commit b79dc574 (from its fess audit)

Recorded here rather than by rewriting history — it would be absurd to rewrite history to
fix a note about rewriting history.

### 1. The private-IP exposure note UNDERCOUNTED. Corrected figures.

The commit message says "ten pre-existing docs". The real number is **14 files, 160
occurrences**. All ten named were accurate, but **four were omitted and they hold 102 of
the 160** — the majority of the exposure:

| File | occurrences | unique |
|---|---|---|
| `MONITORING_COVERAGE_PLAN.md` | 33 | 7 |
| `MONITORING_DEFERRED_SPECS.md` | 28 | 3 |
| `TAILSCALE_HEADSCALE_PLAN.md` | 21 | 3 |
| `ports.txt` | 20 | 5 |

Two aggravating details: `MONITORING_COVERAGE_PLAN.md` is the single largest offender and
is the very file the commit message cites as the precedent being followed; and `ports.txt`
is the port registry `CLAUDE.md` treats as the one sanctioned place for port/interface
detail. **This matters because the note is explicitly framed as input to the pending,
irreversible D2 history-rewrite decision — an undercount biases that call.**

**Root cause of my error, worth internalising:** I piped the scan through `| head`, which
truncated the output at ten lines, and I then reported the truncated line count as the
finding. Same family as the promtool exit-0 trap on the line above: a tool that quietly
limits or reshapes its own output while looking authoritative. Never derive a COUNT from a
`head`/`tail`-truncated stream; count with `wc -l` on the untruncated stream or in code.

### 2. Two counts in the commit message are wrong (low impact, no action)

- "14 items revised" — the plan carries **28** distinct `REVISED —` markers; restricting
  to strong-disproof language still gives **17**. "14" appears nowhere in the plan.
- "3 proposed rules deleted outright after backtesting" conflates two separate figures:
  the plan says **two** rules were deleted after a range backtest disproved them, and
  **three** items were demoted-or-deleted for chronic firing. Neither supports the claim
  as phrased.

### 3. PHASE 2 CORRECTION — the MbsyncNotRunRecently "duplicate" is a promtool FALSE POSITIVE

**Do not "delete the duplicates".** Independently confirmed: the three rules select
DISTINCT accounts with DISTINCT thresholds — `health-checks.yaml:70` johnw >3600,
`:81` assembly >129600, `:92` bia >3600. promtool compares only the STATICALLY DECLARED
labels (`component`, `severity`), so it cannot see the `account` selector inside the expr
and reports a duplicate that does not exist semantically. **Deleting two rules to silence
the lint would silently drop mail-staleness monitoring for two accounts** — manufacturing
the exact silent-failure class this effort exists to eliminate.

Correct fix: collapse the three into ONE threshold-parameterised rule that keeps per-account
distinction (distinct `account` labels in the output series), so the lint passes and no
coverage is lost.

### 4. PHASE 2 BONUS GAP — the `rbcca` mail account has no staleness coverage

Confirmed live: `count by (account) (mbsync_last_sync_timestamp_seconds)` returns FOUR
accounts — `assembly`, `bia`, `johnw`, `rbcca` — against only THREE rules. `rbcca` is
monitored for sync FAILURE (`MbsyncLastSyncFailed` has no account selector) but not for
STALENESS, so a silently-stalled rbcca sync is invisible. The collapse in item 3 closes
this for free; make sure it does.

### 5. Unverified claims inherited from earlier work (do not treat as established)

- The plan's "61 live queries run at plan time" is not substantiated anywhere in the
  document — it asserts a verification stance, not a tally. Treat as unproven.
- The openclaw self-heal suite is recorded at 45 tests, but project memory records 31 in
  June 2026. The growth is plausible but was not confirmed; re-run before relying on it as
  a DoD gate.

## RECURRING DEFECT IN MY OWN OUTPUT — read this before writing any comment

Three separate audits this session caught the SAME class of error from me: **asserting a
negative or a coverage claim without querying for it.** Not one of these was an expression
defect; every one was a false statement written into a permanent comment or commit message,
where it would mislead the next reader — the exact defect class this whole effort exists to
remove.

| Claim I wrote | Reality |
|---|---|
| "ten pre-existing docs contain private IPs" | 14 files / 160 occurrences; I had piped the scan through `head` |
| "effective_cache_size told the planner to assume 4 GiB of OS cache … raising the ceiling resolves that" | e_c_s is TOTAL cache incl. shared_buffers; it caused zero throttling; raising the ceiling INVERTED the mismatch |
| "probe_http_duration_seconds has zero series under any job" | 205 series under one job incl. jupyter; real defect was per-PHASE labelling |
| "a single OOM-and-restart would go unpaged" | `KernelOOMKill` (for=0) already pages; and the unit transits `activating`, never `failed` (30d max = 0) |
| "nothing else watches jupyter's served cert" | cert-exporter tracks it at 337d; several fleet rules have NO selector and already match |

**Rules adopted for the rest of this loop:**
1. Never write "X does not exist", "nothing covers Y", or "Z would go unpaged" without
   running the query that would disprove it. Put the query's result in the comment.
2. Before claiming a deletion is covered by a parent rule, compare the **dwell** as well as
   the selector. A parent with a longer `for:` is a latency REGRESSION and must be disclosed
   (this caught the 5m→15m `ServiceStuckActivating` regression).
3. Never derive a count from a `head`/`tail`-truncated stream.
4. Quote headroom against the observed **maximum**, not the median — the max is what
   determines false-fire risk.
5. Prefer "I verified X returns N series" over "X is broken".

## OPEN FINDING — memory-qdrant: loaded but unusable (operator-reported 2026-07-28)

The operator asked OpenClaw to query memory-qdrant and it could not: the Qdrant API key is
not readable as a file inside the VM (it lives in the gateway config, redacted on read), so
`memory_search` is not invocable from the in-VM CLI path.

**Every monitoring signal for this was, and still is, GREEN:**

| Signal | Value | What it actually proves |
|---|---|---|
| `openclaw_channel_plugin_loaded{channel="memory-qdrant"}` | 1 | the plugin NAME appeared in the gateway's `[gateway] ready (N plugins: …)` startup LOG LINE, which the canary parses |
| `openclaw_gateway_ready_plugins_total` | 6 | a count from that same log line |
| `openclaw_plugin_init_failures_recent_total` | 0 | the ABSENCE of a failure log line |
| `up{job="qdrant"}`, `probe_success{qdrant.vulcan.lan}` | 1, 1 | the backing store answers |
| `QdrantDown` / `ServiceFailed` / `CollectionsEmptyUnexpectedly` | inactive | correctly |

Not one of them exercises the tool. This is the purest archetype-1 (success-that-isn't) case
found so far, and it sat inside the monitoring the audit rated healthy.

**A WRONG FIX I PROPOSED AND MUST NOT BE RETRIED:** adding `memory-qdrant` to
`EXPECTED_SERVERS` in `modules/monitoring/services/openclaw-mcporter-check.nix`. That file's
own comment (lines 40-50) forbids it: memory-qdrant is an in-process OpenClaw PLUGIN
(`openclaw.plugin.json` declares `kind="memory"`), loaded via `plugins.entries` in
openclaw-config.nix, exposing tools through the GATEWAY rather than mcporter. It will never
appear in `mcporter.json`, so listing it there emits a permanently-0 gauge. The comment
records that "an agent-authored health check made this exact category error and reported the
plugin as down (2026-07-27)" — i.e. the day before I proposed the same thing. `memory-vault`
IS a real MCP server; the similar name is the trap.

**What would actually detect it:** a capability probe that INVOKES a tool through the gateway
and asserts a sane response, rather than parsing a startup line. This is genuine new
implementation work, not a config tweak — it needs a gateway endpoint plus an auth path, and
the credential plumbing is the very thing that is broken. Size it honestly.

**Why the audit missed it:** it asked "is it up?" not "can it do its job?", for the OpenClaw
VM specifically. It also disclosed it could not reach inside either guest (johnw's SSH is
locked out of both — host-key mismatch in `~/.config/ssh/known_hosts`, password auth
disabled), so only host-visible signals were available. The disabled D18 Discord canaries
would NOT have caught this either: they test a Discord reply round-trip, not tool capability.

- `2026-07-29` — **Unit: restic snapshots isolation + gauge hardening** (`f4684b7c`). Resolves
  the fess audit of `2616b0b6`, which found isolation applied only to the `check` branch while
  the comments claimed it script-wide. Also: `repair` now gated on prune succeeding (restic's
  own help requires a correct index); `restic-check-metrics` moved `set -u` → `set -eu`
  (a failed write kept publishing last week's stale `1` and still exited 0); corrected my own
  false "ordered alphabetically" comment (`builtins.attrNames` is BYTE order, so `doc`/`src`
  sort last). Established by reading logwatch.pl that it runs report scripts via
  `open(TESTFILE, $Command . " |")` and **never checks close()** — so the exit status is
  invisible downstream and a bad repo silently TRUNCATED the daily report's restic section.
  14/14 harness scenarios; pre-fix control reached 1 of 9 repos vs 9 of 9 fixed.
  Per the wiggum skill, NOT re-audited (its only purpose was resolving an audit).
- `2026-07-29` — **Unit: D10 rotating data verification** (`3cd32cc1`). Bit-rot was
  undetectable: a plain `restic check` never reads pack payloads. Two deliberate deviations
  from the plan text, both recorded in the commit: `--read-data-subset=P/52` keyed to the ISO
  week instead of `2%` (a percentage subset is RANDOM, so it never guarantees coverage; P/52
  gives deterministic full coverage in a year at the same cost), and the plan's
  metrics-collision rationale is FALSE — `restic-metrics` passes `--no-lock` on every
  operation so it cannot contend for the repo lock. The 06:30 de-herd is still right for a
  different, verified reason: at `weekly` (Mon 00:00) a multi-hour run spills into the 02:10
  backup herd whose `forget --prune` waits only `--retry-lock=5m`.
  A harness scenario exposed a NEW silent failure I was about to ship — budget exhaustion left
  7 of 9 repos data-unverified while the run exited 0 reporting success. Closed by publishing
  `restic_read_data_*` with the invariant verified+skipped+failed==total, plus
  `ResticReadDataCoverageDegraded` and `ResticReadDataStale`. Severity is split: timeout
  (exit 124) must NOT page, a real pack error MUST.
  **LIVE VERIFICATION**: the switch triggered an immediate catch-up run (Persistent=true saw
  Mon 06:30 as a missed elapse). First production execution of this path. Measured throughput
  ~24 MB/s, i.e. **6x better than the 4 MB/s I projected** — the real run is ~20-25 min, not
  the ~2h estimated in the commit. The 3h budget has far more headroom than claimed.
- `2026-07-29` — **Unit: restic_repo_files_total dead since inception** (`0149d13d`). Found
  while auditing the textfile collector, not from the plan. The count was read from
  `stats --mode raw-data`, which counts BLOBS; `total_file_count` is absent from that mode's
  JSON (verified against the live binary: its keys are compression_*, snapshots_count,
  total_blob_count, total_size, total_uncompressed_size). So `// 0` silently produced 0 for
  all nine repos forever, hidden because the sibling metrics from the other two modes worked.
  Re-sourced from `restore-size`; verified it returns total_file_count 52717 for the smallest
  repo with a total_size matching that repo's live metric exactly. Nothing depended on the
  dead metric, so this closes a gap rather than correcting a false signal.
- `2026-07-29` — **Phase 7 cleanup: orphaned textfiles removed.** 7 leftover `*.prom.<pid>`
  files (Jun 14 – Jul 16) from writes that died before their `mv`. Proved they were NOT being
  scraped before deleting: `restic.prom.12358` held `restic_repo_size_bytes{Audio} 0` while the
  live series read 100899567908, with exactly 9 series not 18, and
  `node_textfile_scrape_error` 0 on all three instances. NOTE the `mbsync_assembly/bia.prom`
  files are email-sync metrics and are CURRENT — not the disabled rclone remotes; my initial
  grep was too loose.

## D12 — PREMISE DISPROVED, work item NOT implemented (2026-07-29)

The decision was "periodic guarded sweep, log-only for the first cycle" for "17 abandoned
logind sessions". The log-only caution was right, and it paid off: the sessions are **not
abandoned**, so no sweeper was built.

Evidence — all 17 `closing` sessions still host LIVE processes; **zero** are empty:

| Contents | Sessions | Note |
|---|---|---|
| live `nix-daemon` | 14 | leaked `--stdio` instances, 6–17 days old |
| `dirmngr` | 1 | GPG, lingers BY DESIGN |
| `gpg-agent` + `keyboxd` + `scdaemon` | 1 | GPG agent stack, lingers BY DESIGN |
| `etterminal` + `zsh` | 1 | a real live terminal with a shell in it |

Total cost across all 17 scopes: **36 MiB**. Precision note: `TasksCurrent=11` counts
THREADS, not processes — each of those sessions holds one 11-threaded `nix-daemon`, not 11
processes.

So a sweep keyed on state+age would kill a live `nix-daemon` (the exact hazard the decision
named), break GPG agent caching, and destroy a user's terminal session. An alert on "closing
sessions older than N days" would also be pure noise, since GPG agents lingering is normal.

**RETRACTED 2026-07-29 — the "14 leaked nix-daemon --stdio processes" claim was WRONG.**
Operator checked and found none; re-verified: exactly ONE `nix-daemon` process exists
(`nix-daemon --daemon`, the system daemon), and the closing-session count has fallen 17 -> 3 on
its own. I read only `/proc/PID/comm` (to avoid leaking a cmdline) and then INFERRED `--stdio`
from the name. They were almost certainly ordinary per-connection daemon workers that exited when
their clients went away. Nothing leaked and nothing needs root-causing. Same defect as my other
false assertions, inverted: I stated a specific MECHANISM from evidence that identified only a
process NAME. The right move was to field-target the cmdline safely, not to guess.

## D14 — verified and staged, DROP deliberately NOT executed (2026-07-29)

Operator reiterated caution about destructive actions and direct database manipulation
mid-session, so the verification was done and the drop was left for explicit confirmation.

Re-verified (not taken from the plan): 0 user relations, 0 non-default schemas, 0 active
connections, 0 references anywhere in the repo outside the plan docs. 7670 kB is empty-database
template overhead, not content. Owner `postgres`, grants to `litellm`.

Schema record captured at
`<scratchpad>/litellm.public.schema.sql` — contains only CREATE DATABASE + GRANTs, no tables.

Command awaiting confirmation:
```
sudo -u postgres psql -c 'DROP DATABASE "litellm.public";'
```

## Concurrent-session hazard observed (2026-07-29)

`modules/services/litellm-settings.nix` was modified at 10:45 by a DIFFERENT session while I
was building. Two consequences worth knowing:

1. `git add -A` staged it into my commit; caught and unstaged. **Use explicit paths, not
   `-A`, in this shared tree.**
2. My `nixos-rebuild switch` therefore DEPLOYED that session's uncommitted work-in-progress
   (a `model_group_settings.forward_client_headers_to_llm_api` entry). Benign config, but the
   operator should know it went live via my switch rather than theirs.

Also: `sudo nixos-rebuild --flake .` on a dirty tree makes nix's git fetcher write
root-owned objects into `.git/objects`, which then breaks `git commit` with "insufficient
permission for adding an object". Fix: `sudo chown -R johnw:users /etc/nixos/.git`.

- `2026-07-29` — **Unit: postgresql memory ceiling 10G/12G** (`d62dcb9e`). M-92's memory half
  was already applied 07-28; re-measuring showed loki (1,037 events → 0) and home-assistant
  (184 → 0) are FIXED and must NOT be raised further, while postgresql under-corrected. Its
  07-28 prediction ("working set fits without reclaim" at 6G) is falsified: peak is now 6.002
  GiB, above the 6.000 GiB soft limit. Method note worth keeping: `memory.pressure`
  UNDERSTATES this (68 s stall over 26 days) because evicting cache is not a stall — it
  returns as disk reads. The real signal is the buffer cache hit ratio: **89.38%** overall vs
  the >99% norm, litellm 62.94%, mailarchiver 84.04% on 472.6M reads, ~4.6 TB re-read.
  Confirmed the cgroup is the governing constraint (data dir on ext4 `/dev/nvme0n1p5` → kernel
  page cache, not ZFS ARC). Budget table updated 113% → 120%.

## budget-board switch exit 4 — PREMISE DISPROVED, no config fix (2026-07-29)

The open item was "budget-board healthcheck start-period (fixes recurring switch exit 4)".
`healthStartPeriod = "120s"` is **already set** (budgetboard-quadlet.nix:107) and is already
working correctly, so that fix would do nothing. Hit it live during this session's switch and
traced the real mechanism:

1. The switch restarts the pod; the server needs time for DB migrations.
2. The healthcheck timer fires ~30 s in and the check fails (app not yet listening).
3. Podman honors the start period correctly — the event log shows
   `health_status=starting, health_failing_streak=0`, so the CONTAINER is never marked
   unhealthy.
4. But the transient systemd unit that RAN the check exits 1, and podman creates that unit
   with **no `CollectMode`** (verified: 0 occurrences in
   `/run/systemd/transient/<id>-<hash>.service`), so it persists in `failed` state.
5. `switch-to-configuration` enumerates failed units at that instant → exit 4.
6. ~30 s later the next healthcheck succeeds and the state clears by itself.

Verified benign and self-healing: `systemctl --failed` empty afterwards, container
`healthy failingStreak=0`, generation switched and the intended change live. This is podman
transient-unit behavior, not a missing setting; raising the start period or the interval
cannot change step 4.

**Real residual risk worth the operator's attention:** a spurious exit 4 can MASK a genuine
switch failure. The mitigation is to verify a switch by checking the generation and
`systemctl --failed` rather than trusting the exit code — which is what was done here.

## D13 — analysis COMPLETE, implementation deliberately deferred (2026-07-29)

Stopped before editing on purpose: this change silences 17 alerts, and doing it with little
context left risks exactly the silent-monitoring-loss this project exists to remove. Every
fact below is verified, so the next pass can implement directly.

**Prerequisite CONFIRMED — "digest" is real, not a euphemism.** `AlertHistory` in
`scripts/log-summarizer.py` collects `ALERTS{alertstate="firing"}` with NO severity filter
(grouping by `(alertname, severity)`), so info alerts DO appear in the daily report. Null-routing
them at Alertmanager while they remain in that section genuinely implements "digest". Had it
filtered to warning+, null-routing would have been true silencing and D13 would need rework.

**Inventory: exactly 21 info rules**, matching the plan's count. All four D13 names exist:
`HostUnexpectedReboot` (category=system), `ContainerCVEScanFailed` (no category),
`ContainerCVEDBStale` (no category), `MicroVMStateShareExporterStale` (monitoring-meta).

**The `health_report_*` exemption is MOOT** — no rule matching `health_report|HealthReport`
exists at any severity. Do not add config for it.

**The one thing that changes the shape of the edit:** the `storage-receiver` route
(alertmanager.nix:138) matches `category = "storage"` with NO severity condition and NO
`continue = true`, so it TERMINATES. Exactly one info rule carries that category —
`ResticRepositorySizeGrowing` — so it currently goes to storage-receiver, not email. The other
20 fall through to `default-receiver`. Therefore a new info route must be inserted **before**
the storage route to catch all 17; placed after, `ResticRepositorySizeGrowing` would silently
escape the digest.

**Routes verified NOT to interfere:** watchdog-deadman (severity=watchdog),
the OpenClawConfigDrift route (single alertname, :75), the three self-heal routes, and both
`severity = "critical"` routes. None can intercept an info alert.

**Implementation:**
1. Add a receiver `{ name = "null-receiver"; }` (no notifiers) alongside the existing 8.
2. Insert BEFORE the storage route at :138:
   ```
   { matchers = [
       "severity=\"info\""
       "alertname!~\"HostUnexpectedReboot|ContainerCVEScanFailed|ContainerCVEDBStale|MicroVMStateShareExporterStale\""
     ];
     receiver = "null-receiver";
     continue = false; }
   ```
   Note `matchers` (Alertmanager >= 0.22) is needed for the NEGATIVE regex; the file's existing
   `match`/`match_re` cannot express `!~`. This would be the file's first use of `matchers`.
3. The promoted 4 then fall through to `default-receiver` (email) as intended.

**Verification REQUIRED before trusting it** — do not rely on reading the config:
`amtool config routes test --config.file=<generated alertmanager.yml>` for each of the 21
alertnames, asserting the 4 land on `default-receiver` and the 17 on `null-receiver`. Also
re-assert that a `severity=critical` alert still reaches BOTH `iphone-notifier` and
`critical-receiver`, since a mis-ordered insert could shadow them.

- `2026-07-29` — **Unit: invariant + whole-loop deadline** (`81ee8ed5`). Fixes two defects in
  `3cd32cc1` found by running its own audit checks 6 and 8 by hand after the subagent failed.
  (1) The published invariant was SELF-CONTRADICTORY — it claimed
  `verified+skipped+failed==total` and then that a structure-check failure lands in none of
  the three. Reproduced: fail Home → 8+0+0 vs total 9. Correct relation now written down as
  `== repos that passed their structure check <= total`. No alert depended on the equality, so
  nothing fired wrongly, but the comment would have misled someone into writing one that did.
  (2) The 4h RuntimeMaxSec hard kill WAS reachable: only read-data was budgeted, while
  check/prune/repair are untimed and each waits `--retry-lock=1h`. A kill aborts mid-loop and
  destroys the per-repo accounting the whole Phase-7 effort provides. Added a 3.5h whole-loop
  deadline that NAMES unreached repos and fails the run.
  Method lesson: my first harness for this reported false passes because the stub read `$1`
  without filtering `--retry-lock=1h`, so injected failures never fired and two scenarios
  tested nothing while appearing green. Always assert the injection actually took effect.

- `2026-07-29` — **Independent adversarial audit + fixes** (workflow `wf_2aa5ff44-590`, fixes in
  `8e1940a6`). Restored the evaluator separation that broke when the earlier subagent failed
  twice: 3 lenses → a refute-first skeptic per finding → synthesis. **15 raised, 12 refuted, 4
  survived.** It REFUTED my biggest open risk — the `--read-data-subset=P/52` coverage claim
  holds (1.56–1.95% per bucket, finite-pack rounding), so the feature's justification stands.
  - **F1 (my own half-fix):** the whole-loop deadline is tested only at the TOP of an iteration,
    so it bounds when a repo may START, not run length. With fixed `--retry-lock=1h` on
    check/prune/repair, worst case was `12600 + 3×3600 = 6.5h` — ABOVE the 4h kill it exists to
    avoid, with 1800s slack smaller than ONE operation's lock allowance. Auditor reproduced 6h.
    Fixed by scaling lock wait to remaining budget / 3 (floor 60s, cap 3600s). Took the
    auditor's advice to scale `--retry-lock` rather than wrap in `timeout` — a kill mid-prune is
    itself a data risk. Bound now holds: a repo starting at T with remaining R waits
    `3 × min(3600, R/3) <= R`, finishing by `T + R`.
  - **F2:** `ResticReadDataStale` cannot catch a metric that NEVER arrives (absent series →
    empty vector), and nothing seeds these six series or covers them via
    TextfileCollectorStale*. Added `ResticReadDataMetricsAbsent` (24h). Safe now, not at
    authoring time — the series exist post-first-run.
  - **F3:** three above/below inversions introduced by `81ee8ed5`, the commit whose purpose was
    fixing comment-truth defects. Rejected the same reviewer's "delete ~40 lines of changelog"
    — recording why a mistake was made is this repo's convention, and its own verifier
    discarded it as style.
  - **INFO:** replaced projections the live run falsified (~9x off): 800s total, 402s structure
    / 398s read-data, Photos 103s, ~40 MB/s. Budgets deliberately NOT tightened — B2 bandwidth
    varies, repos grow, over-provisioning is free, a spurious cut costs coverage.
  Method note for Phase 8: the workflow shape (distinct lenses → refute-first verifier →
  synthesis) worked where a single auditor failed twice. **Reuse it.** The 12 refutations were
  as valuable as the 4 findings — several objections were already anticipated in comments.

- `2026-07-29` — **D13 landed** (`602418a7`) + **a serious pre-existing paging gap fixed**
  (`f181eb48`). D13 verified with 26 amtool route tests (4 promoted → email, 17 → null-receiver,
  4 regression cases). The gap was found BY those regression tests, not by the plan: the storage
  route matched `category="storage"` alone, had no `continue`, and preceded both critical routes,
  so **19 critical storage alerts never paged** — TankMountGone, all 5 ZFS pool alerts, all 4
  NVMe boot-disk alerts, all restic failures — email-only on a 12h repeat. Four of those NVMe
  rules are ones I added earlier in THIS effort, so I had shipped critical boot-disk alerting
  into a bucket that could not page. Fixed by `severity!="critical"` on that route (not
  `continue=true`, which would double-deliver warnings). 28 amtool tests pass.
  **CONCURRENT-SESSION HAZARD, now costly:** the `f181eb48` edit was LOST after building and
  deploying — no stash, no checkout/reset in reflog, and the other session's commit touched only
  litellm-settings.nix, so a stale-content file write from it. Result was source/system drift with
  the RUNNING system holding a fix the source lacked, which the next rebuild would have silently
  reverted. Recovered and proven complete by rebuilding to a closure **byte-identical** to
  `/run/current-system`. **Rule for this tree: commit immediately; never leave a verified edit
  uncommitted.**
  Two false readings caught before acting: the amtool harness reported 0/27 because the config
  path lives in the pre-start script not the unit file; and a grep suggested the fix was missing
  from the deployed config because the generated JSON escapes quotes as `severity!=\"critical\"`.
  **BRANCH STATE:** 26 local commits vs 1 on origin/main (the other session's `89f0c818`).
  Diverged, NOT pushed — pushing is human-gated. Do not resolve this autonomously.

## Resume instructions

1. Re-read this file, the frozen plan, and the decisions doc in full.
2. Re-probe Anvil.
3. Baseline verify BEFORE new work: `sudo nixos-rebuild build --flake '.#vulcan'`,
   `promtool check rules` on `modules/monitoring/alerts/*.yaml`, live err-rule count,
   `systemctl --failed`.
4. Read the progress log to find the next unstarted unit.
5. Continue the loop. Never start new work on a broken base.
