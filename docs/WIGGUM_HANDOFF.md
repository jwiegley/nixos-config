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
3. `promtool check rules` passes on every changed file under `modules/monitoring/alerts/`.
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
  M-91 (HA entity-availability exporter), M-92 exporter half, A-92 Matter churn alert,
  A-91 detection half (HA service-call error alert).
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
| **D7 — destroy legacy snapshots** | Decided: NO ACTION. Let the ladder expire them. |
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

## Baseline at loop start (2026-07-28)

- `promtool check rules` over all `modules/monitoring/alerts/*.yaml`: **1 pre-existing
  FAILED** — `health-checks.yaml`, "1 duplicate rule(s) found. Metric:
  MbsyncNotRunRecently, Label(s): component=mail_sync severity=warning". Note promtool
  still exits 0 on this, so a naive `$?` check would miss it; the failure is only
  visible in the output text. Pre-existing, in scope for Phase 2.
- Live Prometheus: **538 rules, 0 at health=err**.
- `systemctl --failed`: **empty**.
- Self-heal suites: openclaw 45/45, hermes 86/86 (verified earlier this session).

## Resume instructions

1. Re-read this file, the frozen plan, and the decisions doc in full.
2. Re-probe Anvil.
3. Baseline verify BEFORE new work: `sudo nixos-rebuild build --flake '.#vulcan'`,
   `promtool check rules` on `modules/monitoring/alerts/*.yaml`, live err-rule count,
   `systemctl --failed`.
4. Read the progress log to find the next unstarted unit.
5. Continue the loop. Never start new work on a broken base.
