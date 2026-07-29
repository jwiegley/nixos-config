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
| **D8 — Machines (307 GB) first B2 upload** | Load-induced enclosure hang is a documented failure mode. Manual daytime run with `uas_eh_abort` watch. |
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

## Resume instructions

1. Re-read this file, the frozen plan, and the decisions doc in full.
2. Re-probe Anvil.
3. Baseline verify BEFORE new work: `sudo nixos-rebuild build --flake '.#vulcan'`,
   `promtool check rules` on `modules/monitoring/alerts/*.yaml`, live err-rule count,
   `systemctl --failed`.
4. Read the progress log to find the next unstarted unit.
5. Continue the loop. Never start new work on a broken base.
