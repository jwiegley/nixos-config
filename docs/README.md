# `/etc/nixos/docs/` — Index

Compiled 2026-07-27 by opening every file in this tree; re-surveyed 2026-07-30;
reconciled 2026-08-19 against the Nagios removal and the documentation sweep that
followed it. This is a map, not a rewrite: nothing was renamed, moved, or edited
to produce it.

Scope of what is catalogued below, measured 2026-08-19 (`find docs -type f | wc -l`):
**98 files under `docs/`** — 95 markdown (52 at the root of `docs/`, including this
index, plus 43 under `superpowers/`) and 3 non-markdown (`ports.txt`,
`create-postgres-user.sql`, `PLAN.org`) — together with the **10 markdown files that
live outside `docs/`** and are real documentation rather than pytest scaffolding
(`find . -name '*.md' -not -path './docs/*'`, excluding `.pytest_cache/`).

The root markdown count is 52 on both dates by coincidence, not by stasis: the
2026-08-19 Nagios removal deleted `NAGIOS_PROMETHEUS_MIRROR_SPEC.md` and
`HOME_ASSISTANT_NAGIOS_MONITORING.md`, and two files written since the last survey
took their place in the count. Do not read an unchanged total as an unchanged tree.

## Start here — which documents are authoritative

| Question | Authoritative document |
|---|---|
| **How is this system built?** — architecture, module layout, hardware, flake inputs, management commands | [`/etc/nixos/README.md`](../README.md) |
| **How do I operate on it safely?** — the security rules, the forbidden-path list, data-loss rules, port-registry discipline | [`/etc/nixos/CLAUDE.md`](../CLAUDE.md) |
| **What is actually listening on what?** | [`ports.txt`](ports.txt) — machine-reconciled against live sockets by `modules/monitoring/services/port-drift-exporter.nix` |
| **What do I do after a reboot?** | [`REBOOT_RESILIENCE.md`](REBOOT_RESILIENCE.md) |
| **What work is open on this repo?** | [`PLAN.org`](PLAN.org) — the `obr` issue tracker's exported surface. Written by `obr sync --flush-only`; edit issues through `obr`, not by hand |

Those two root documents are authoritative *by role*. Where they disagree with
a file under `docs/`, they win on intent; where they disagree with the running
system, the running system wins.

**`docs/superpowers/` is a historical record.** It is the archive of design
specs and execution plans for work proposed, and mostly carried out, between
April and July 2026. Read it to learn *why* something is shaped the way it is.
Do not read it as a description of current state, and do not follow its task
checklists.

## Status labels used below

- **current** — describes how the system works today, or is a runbook you would
  actually follow now.
- **archival** — a dated audit, RCA, design record, superseded proposal, or
  completed plan. Accurate about its moment; kept for provenance. Not a
  description of today.
- **needs-review** — names files, modules, services, or versions that could not
  be reconciled with the repository or the running host as of 2026-07-27.
  Verify before acting on it.

Measured 2026-08-19: **23 of the 52** markdown files at the root of `docs/` open
with a self-describing status or archival banner of their own — usually
`> **Status (2026-07-27):** …` or `> **Archival — <date>.**`
(`grep -lE '^> \*\*(Status|Archival)|^\*\*Status' docs/*.md | wc -l`). Where a
file's own banner and this table disagree, the banner is closer to the document
and wins. All 43 files under `superpowers/` carry a banner.

For the 29 root files with no banner — including this index — the status column
below is the *only* status they have, so it is the one that has to be maintained.

Those three labels say whether a document is *true*. They do not say whether it
is *safe to delete*, which is a different question and the one the size of this
tree now raises. The survey immediately below answers that one, per area, with
four classes:

- **DURABLE REFERENCE** — describes the running system or is a runbook; edit in
  place, never delete.
- **COMPLETED TRACKING** — a finished plan, audit, or loop log. Its value is
  provenance. Deletable *only* after checking whether code cites it. Nix and
  Python outside `docs/` name a `docs/` path on **84 lines** covering 22 distinct
  paths (35 of the lines are `ports.txt`), and roughly half of the rest point at
  documents classed COMPLETED TRACKING below. Deleting such a file turns each
  citation into a dangle. Counts move as other work lands — re-measure with
  `grep -rhoE 'docs/[A-Za-z0-9_./-]+\.(md|txt|sql|org)' --exclude-dir=.git --exclude-dir=docs --exclude-dir=.obr .`
  (measured 2026-08-19; the drop from 98 lines / 25 paths is the Nagios removal
  taking `NAGIOS_PROMETHEUS_MIRROR_SPEC.md` and its 8 citations with it)
- **DEFERRED INTENT** — designed, not built. Deleting it discards the only
  record of the decision. Keep until built or explicitly abandoned.
- **STALE** — describes something that no longer exists. Delete, or rewrite to
  say what replaced it. Actively harmful, because it reads as a runbook.

## Deletion-readiness survey (2026-07-30, re-measured 2026-08-19)

`docs/` is **~3,730 KB**. Five artifacts — `MONITORING_COVERAGE_PLAN` (332 KB),
`MONITORING_DEFERRED_SPECS` (304 KB), `REMEDIATION_PLAN_2026-07-28` (220 KB),
`HEALTH_AUDIT_2026-07-28` (148 KB), `WIGGUM_HANDOFF` (52 KB) — are **1,056 KB of it (28%)**, and
`superpowers/` is a further **1,516 KB across 43 files (41%)** — so 69% of the
tree is plan and audit output, not reference. `PLAN.org` is a further ~350 KB (9%)
and is in a class of its own: generated, live, and never hand-edited. The total is
given approximately on purpose — `PLAN.org` is rewritten by `obr sync --flush-only`
and grows with every issue filed, so an exact figure here would be stale within the
day. Sizes are `du -k`, citation counts are `grep -r 'docs/<name>' --exclude-dir=docs`.

| Area | Size | Class | Evidence |
|---|---|---|---|
| Runbooks and recovery — `REBOOT_RESILIENCE`, `COLD_REBOOT_CHECKLIST`, `CRASH_DEBUGGING`, `UPDATE_GITHUB_TOKENS`, `SIEVE_FILTERING`, `openclaw-hermes-integration` | ~80 KB | DURABLE REFERENCE | `post-reboot-validation.sh` cites `COLD_REBOOT_CHECKLIST.md`; `pkgs/hermes-mcp/README.md` is a pointer to the OpenClaw↔Hermes runbook. Both describe units that exist. |
| Subsystem reference — `ports.txt`, `HOME_ASSISTANT_DEVICES`, `WATER_ATTRIBUTION`, `FLUME_DATA_REFERENCE`, `RSPAMD_SETUP`, `MAC_STUDIO_POWER_MONITORING`, `MONITORING_CONVENTIONS` | ~140 KB | DURABLE REFERENCE | Most-cited area: `ports.txt` 35 citations, `WATER_ATTRIBUTION.md` 4 from `scripts/flume-data/`. Until 2026-08-19 this row also led with `NAGIOS_PROMETHEUS_MIRROR_SPEC.md` and its 8 citations across 6 files; that document, the `scripts/check_prom_rule.py` that was its largest consumer, and Nagios itself were all removed together. |
| Monitoring plan artifacts — `MONITORING_COVERAGE_PLAN` (328 KB), `MONITORING_DEFERRED_SPECS` (300 KB) | 628 KB | COMPLETED TRACKING (the first) / DEFERRED INTENT (the second) | Coverage plan: 9 citations in 7 files, all as "why this rule exists". Deferred specs: 12 citations in 12 files — and several chapters have since been built (`port-drift-exporter.nix`, `vm-egress-exporter.nix`, `config-drift-exporter.nix` all cite it), so it is now part-built intent, not open work. |
| The 2026-07-28 audit → remediation set — `HEALTH_AUDIT`, `REMEDIATION_PLAN`, `REMEDIATION_DECISIONS`, `WIGGUM_HANDOFF`, `HA_ENTITY_WORKLIST` | 444 KB | COMPLETED TRACKING, one loop still open | The three frozen documents are cited only by `WIGGUM_HANDOFF.md`, which is the live log of the loop consuming them; `HA_ENTITY_WORKLIST_2026-07-29.md` is cited twice from the entity-availability exporter. Not deletable while the loop runs — see the table below. |
| `superpowers/plans/` (22 files) | 1,012 KB | COMPLETED TRACKING | All 22 open `> **Archival — <date>.**` and all 22 declare `> **Outcome:** implemented (see <path>)`. All 29 distinct repo paths named across those outcome lines exist (checked file-by-file 2026-07-30); the one outcome that names no path — the openuv plan's `openuv_forecast` REST sensor — resolves too (3 hits in `modules/services/home-assistant.nix`). 2 plans are cited from code, on 3 lines (2026-08-19; was 3 plans on 4 lines). |
| `superpowers/specs/` (21 files) | 500 KB | COMPLETED TRACKING, except two | 19 of 21 declare an implemented outcome whose path exists. The exceptions are the two climate-comfort specs — see DEFERRED INTENT below. 2 specs are cited from code (2026-08-19; `agent_health_report.py` and the Hermes self-heal daemon — the OpenClaw one went with OpenClaw). |
| `2026-05-14-climate-comfort-design.md`, `2026-05-15-climate-comfort-bias-regression-design.md` | 16 KB | DEFERRED INTENT | The only two `superpowers/` files with no `Outcome:` line, and `grep -rli 'climate.comfort\|comfort_setpoint\|climate-comfort'` outside `docs/` returns nothing. Designed 2026-05-14/15, never built. |
| `TAILSCALE_HEADSCALE_PLAN.md` | 52 KB | DEFERRED INTENT | `grep -rn 'services.headscale\|services.tailscale' --include='*.nix'` returns nothing, so the 2026-07-27 "not implemented" finding still holds on 2026-07-30. |
| `EMAIL_TESTER_MONITORING_SETUP.md` | 12 KB | DEFERRED INTENT | Its own banner enumerates the modules that do not exist; what exists is `modules/services/email-tester-manual.nix`, which records the omission as deliberate. |
| `STOCK_TRADER_SCHWAB_TOKEN_RENEWAL.md` | 4 KB | **STALE** | The chore it documents was abolished. See its row below. |

Two consequences worth acting on before any deletion pass:

1. **A `superpowers/` file is not free to delete just because it is archival.**
   Four of them are cited from Nix or Python (2026-08-19; was six — the
   openclaw-hardening plan and the openclaw self-heal design lost their citations
   when OpenClaw was removed). The cheap fix in each case is to move the one
   durable sentence into the citing file's comment first.
2. **Nothing under `superpowers/` needs re-reading to know its state.** The
   banner plus `Outcome:` line is machine-checkable, and the check passed for
   41 of 43 files. That is what makes a later bulk decision safe.

---

## Operate — runbooks, checklists, recovery

| Document | What it covers / who needs it | Status |
|---|---|---|
| [REBOOT_RESILIENCE.md](REBOOT_RESILIENCE.md) | Consolidated per-subsystem symptom → cause → fix → verify record of everything that makes vulcan survive a cold boot, keyed to the checks in `scripts/post-reboot-validation.sh`. The first thing to open after any reboot or suspected boot problem. | current |
| [COLD_REBOOT_CHECKLIST.md](COLD_REBOOT_CHECKLIST.md) | The pre-reboot ritual and per-check validation matrix. Its banner records that the reboot it was written for happened on 2026-06-10 and passed 21/0/0, and that the document is retained as the standing procedure to run around *any* future cold reboot. | current |
| [CRASH_DEBUGGING.md](CRASH_DEBUGGING.md) | What `modules/core/crash-debug.nix` sets up (persistent journal, kernel log, sar/atop, kdump) and the ordered command sequence to run after a spontaneous reboot. For diagnosing unexplained restarts. | current |
| [STOCK_TRADER_SCHWAB_TOKEN_RENEWAL.md](STOCK_TRADER_SCHWAB_TOKEN_RENEWAL.md) | **STALE — the chore no longer exists.** The Schwab data source was retired entirely on 2026-07-29 (decision D3, commit `fc5835a9`): `modules/services/stock-trader.nix:178` records that the credentials are no longer provided and `SCHWAB_TOKEN_PATH` is unset, and `modules/monitoring/alerts/stock-trader.yaml:69-71` records the four Schwab rules as deleted — so `StockTraderSchwabDataSourceDown`, the alert this runbook is keyed to, cannot fire because it no longer exists. Nothing in the repo references this file except this index. Quotes are `alpha_vantage`/`yfinance` now. Delete, or keep only as the record of why the source was dropped. | needs-review |
| [OSS_SECRETARY_FROM_HERMES.md](OSS_SECRETARY_FROM_HERMES.md) | How to query the open-source-secretary triage data conversationally through Hermes: the six read-only tools, what they can and cannot answer (titles yes, bodies never; daily snapshot, not live), how to read the answers, and troubleshooting. | current |
| [openclaw-hermes-integration.md](openclaw-hermes-integration.md) | **SUPERSEDED 2026-07-31** — describes the OpenClaw <-> Hermes bridge; that VM and its half of the topology were removed. Kept as design history for the surviving hermes-mcp front door. | current |
| [UPDATE_GITHUB_TOKENS.md](UPDATE_GITHUB_TOKENS.md) | How to use `scripts/update-github-tokens.py` to bulk-rotate the GitHub PAT embedded in every Gitea push and pull mirror, including dry-run mode. Needed whenever the PAT expires. | current |
| [SIEVE_FILTERING.md](SIEVE_FILTERING.md) | Where the delivery-time and IMAPSieve scripts live under `/var/lib/dovecot/sieve/users/<user>/`, and how to edit, compile, and test them. For mail-routing changes. | current |
| [BOOT_SWITCH_ROBUSTNESS_AUDIT.md](BOOT_SWITCH_ROBUSTNESS_AUDIT.md) | The 2026-06-08 read-only 13-dimension audit of boot and `nixos-rebuild switch` robustness: what was solid, and the ranked residual risks (local DNS readiness, late ZFS mounts). Its banner states every residual finding has since been fixed. Background reading for `REBOOT_RESILIENCE.md`. | archival |
| [BOOT_SLOWNESS_RCA_2026-06-24.md](BOOT_SLOWNESS_RCA_2026-06-24.md) | Root-cause analysis of one boot (2026-06-24): concludes it was not a regression, separates the real ~125 s DNS-dead window from the cosmetic 15-minute `systemd-analyze` figure, and lists a prioritized fix plan. For anyone re-investigating slow boots. | archival |
| [POST_REBOOT_AUDIT_2026-07-03.md](POST_REBOOT_AUDIT_2026-07-03.md) | Multi-agent health audit after the 2026-07-03 reboot: corrected two-outage timeline, the two console stack-trace storms and their causes, what was fixed during the audit, and what needed the operator. | archival |
| [PLAINTEXT_EXPOSURE_AUDIT_2026-08-02.md](PLAINTEXT_EXPOSURE_AUDIT_2026-08-02.md) | A LAN-wide audit of services still reachable over plaintext, sorting each into one of three groups — already has an HTTPS vhost, has no HTTPS equivalent at all, or is non-HTTP — plus a section of endpoints verified compliant rather than assumed, an explicit statement of the audit's own limits, and a ranked remediation order. **Its remediation order is not known to be complete**; treat the list as open work until each line is checked against the running host. Read it before adding any new listener. | needs-review |
| [CLAUDE_MEM_NIXOS_REPAIR.md](CLAUDE_MEM_NIXOS_REPAIR.md) | 2026-05-27 diagnosis and fix of claude-mem's search backend on vulcan: a systemd *user* service missing `PATH` and `LD_LIBRARY_PATH`, repaired with one drop-in. About developer tooling on this host, not about any vulcan service. | archival |
| [CLAUDE_MEM_MULTI_MACHINE_FIX.md](CLAUDE_MEM_MULTI_MACHINE_FIX.md) | The portable companion to the above: a diagnostic script plus per-platform (NixOS / Ubuntu / macOS) fixes for the same five claude-mem issues. For fixing other machines, not vulcan. | archival |

## Monitoring

| Document | What it covers / who needs it | Status |
|---|---|---|
| [HOME_ASSISTANT_ALERTING.md](HOME_ASSISTANT_ALERTING.md) | Why the 23 Prometheus `homeassistant_*` alert rules could never fire (HA pushes to VictoriaMetrics and is never scraped into Prometheus), what replaced them in Node-RED, and the original rule intent kept as an implementation reference. | current |
| [TECHNITIUM_DNS_MONITORING_SETUP.md](TECHNITIUM_DNS_MONITORING_SETUP.md) | One-time setup for the Technitium DNS exporter on `localhost:9274`: building the container image locally because none is published, generating the API token, and wiring Prometheus, Grafana and Alertmanager. | current |
| [MAC_STUDIO_POWER_MONITORING.md](MAC_STUDIO_POWER_MONITORING.md) | How Apple Silicon SMC power, current and temperature sensors reach Prometheus through `macsmc_hwmon`, the full metric list, the Grafana dashboard, and example queries. Reference for anyone touching power telemetry on this hardware. | current |
| [OPNSENSE-EXPORTER-SETUP.md](OPNSENSE-EXPORTER-SETUP.md) | Deploying the OPNsense Prometheus exporter as a Podman quadlet on `localhost:9273` — API key provisioning, SOPS wiring, verification, and the exact series it collects. | current |
| [OPNSENSE-EXPORTER-WORKAROUND.md](OPNSENSE-EXPORTER-WORKAROUND.md) | The two upstream bugs (boolean `monitor_disable`, null `product_check`) first hit on v0.0.11 and the `opnsense-api-transformer` proxy that works around them. Its banner notes the deployed image now resolves to 0.0.16 but the workaround has not been re-tested without the proxy. | current |
| [DISCORD_CANARY_SETUP.md](DISCORD_CANARY_SETUP.md) | **REMOVED — do not follow.** The cross-agent canary went with OpenClaw (2026-07-31) and the remaining synthetic Hermes probes on 2026-08-05, because every probe landed in the real message history. | needs-review |
| [LOG_SUMMARIZER.md](LOG_SUMMARIZER.md) | What `scripts/log-summarizer.py` collects, how it calls the LLM gateway (LiteLLM was removed 2026-08-01), its logwatch integration, output format, and troubleshooting. | current |
| [MONITORING_CONVENTIONS.md](MONITORING_CONVENTIONS.md) | The authoring rules for a Prometheus / Loki / vmalert rule on this host: prove the metric exists with `count(last_over_time(X[30d]))`, know which of the two TSDBs your file is evaluated against, and the other measured constraints on `for:`, labelling and severity. Read before adding or retuning any alert rule. Each claim names the file that enforces it. **Note one constraint has lifted:** its §on `for:` budgets used to describe a hard external cap imposed by the Nagios↔Prometheus mirror's check-retry approximation. The mirror went on 2026-07-31 and Nagios on 2026-08-19, and that section is now written in the past tense — `for:` is bounded only by what the alert means. | current |
| [MONITORING_COVERAGE_PLAN.md](MONITORING_COVERAGE_PLAN.md) | The 2026-06-09 17-domain census of monitoring coverage (203 gaps: 15 P0 / 83 P1 / 105 P2) with a per-domain appendix. All phases shipped on 2026-06-09/10, so it now functions as provenance — eight Nix comments cite it as the reason a rule exists. 328 KB; navigate by heading. | archival |
| [MONITORING_DEFERRED_SPECS.md](MONITORING_DEFERRED_SPECS.md) | Thirteen implementation-ready chapters for the items deliberately deferred out of the coverage plan (CVE scanning, VM egress, `pg_stat_statements`, HA `_str` purge, port drift, Nagios's future), each ending in a decision only the operator can make. Some have since been built anyway — the port-drift exporter exists — so check each chapter against the tree before treating it as open work. The Nagios chapter is settled and not open: Nagios was removed entirely on 2026-08-19. This file still carries ~60 Nagios mentions and was left that way on purpose, being archival. | archival |
| [EMAIL_TESTER_MONITORING_SETUP.md](EMAIL_TESTER_MONITORING_SETUP.md) | A proposal for hourly automated mail-pipeline testing with Nagios and Prometheus that was **never deployed** — its banner enumerates the four modules, the timer, the exporter, the metrics and the alerts that do not exist. What exists is `modules/services/email-tester-manual.nix`, whose header records that automated monitoring was omitted deliberately to avoid over-training rspamd on test messages. | archival |

## Reference — subsystem docs, inventories, the registry

| Document | What it covers / who needs it | Status |
|---|---|---|
| [ports.txt](ports.txt) | The curated port registry: every listening port with its interface binding and owning service, followed by a legend and a short list of ports seen previously but no longer listening. **Must be updated in the same change that adds a port** (see `/etc/nixos/CLAUDE.md`). | current |
| [HOME_ASSISTANT_DEVICES.md](HOME_ASSISTANT_DEVICES.md) | Per-device integration inventory — the built-in components configured via `extraComponents` and the custom/HACS ones — with setup steps, features, and required credentials for each. The device inventory `/etc/nixos/CLAUDE.md` points at. | current |
| [WATER_ATTRIBUTION.md](WATER_ATTRIBUTION.md) | The live water-attribution feature: every sensor it creates, what the residual "other" absorbs, how to add or split a B-Hyve zone, autofill-detection tuning, the weekly report email, and backfill scope. Its detection thresholds are stated as the live band as of 2026-07-27. | current |
| [FLUME_DATA_REFERENCE.md](FLUME_DATA_REFERENCE.md) | The historical per-minute Flume data: the four physical locations, the full PostgreSQL schema, connection recipes, a query cookbook, how data gets in, and operational notes. The reference for any water-data analysis. | current |
| [HOME_ASSISTANT_TRASH_REMINDER.md](HOME_ASSISTANT_TRASH_REMINDER.md) | Phase 1 (deployed): the Node-RED nightly trash announcement built on `waste_collection_schedule` per-bin sensors, with a smoke test. Phase 2 (colour-cycling lamp escalation) is designed but blocked on hardware. | current |
| [CLOUDFLARE_TUNNELS.md](CLOUDFLARE_TUNNELS.md) | Operating the Cloudflare tunnel — status, logs, restart, connectivity tests. Its banner records the correction to today's reality: exactly one tunnel named `data` fronting four hostnames, the second "rsync" tunnel having been removed in 2025. | current |
| [quadlet-guide.md](quadlet-guide.md) | A general primer on Podman quadlets under NixOS: what they are, why they beat docker-compose, and the essential systemd command vocabulary. Its banner warns that the example *service names* are historical — most quadlets are now rootless per-user Home Manager units. Orientation for anyone new to the container layer. | current |
| [create-postgres-user.sql](create-postgres-user.sql) | Not documentation: a seven-line `${USER}` / `${PASS}` / `${DB}` template for creating a PostgreSQL role, database, and grants. Filed here for lack of a better home. | current |
| [FLUME_FIXTURE_EDA.md](FLUME_FIXTURE_EDA.md) | Exploratory analysis over a four-day fully-instrumented window (2026-05-20..23) that bootstrapped the v3 fixture library, explicitly labelled preliminary and due for recalibration. | archival |
| [FLUME_V3_DESIGN.md](FLUME_V3_DESIGN.md) | Design for v3 attribution: the per-minute wide table, the tiered attribution algorithm, the user-labelling feedback loop, and dishwasher ground truth. Much of it shipped — `flume_minute_attributions` and `flume_user_labels` appear in `scripts/flume-data/flume_db_sync.py` — so treat it as the design record, not a to-do list. | archival |
| [NESTED_CONTAINERS_PODMAN_QUADLET.md](NESTED_CONTAINERS_PODMAN_QUADLET.md) | A research memo answering "*could* rootless Podman quadlets run inside a NixOS `systemd-nspawn` container?" Its banner states plainly that this is **not** how vulcan is configured: quadlets run rootless via home-manager directly on the host, and none of the four nspawn containers enable Podman inside. | archival |
| [LITELLM_REMOVAL_2026-08-01.md](LITELLM_REMOVAL_2026-08-01.md) | The record of removing LiteLLM and migrating the LLM gateway: what replaced it, which capabilities were dropped deliberately rather than lost, two nginx defects found the hard way, the `HostUnreachable` fix that had been double-alerting 42 targets, and how SOPS was made independent of the stale litellm names. Its closing section lists operator actions that were outstanding when it was written — check them before assuming the migration is fully closed. The companion `LITELLM_TOOL_USE_BUG_REPORT.md` below is about the retired software itself. | archival |
| [LITELLM_TOOL_USE_BUG_REPORT.md](LITELLM_TOOL_USE_BUG_REPORT.md) | A ready-to-file upstream bug report against LiteLLM 1.82.3: the Anthropic → Responses-API converter emits `function_call` before assistant text, with root cause, reproduction, suggested fix, and user-side workarounds. Useful if the same symptom reappears. | archival |
| [SHERLOCK-OPENCLAW-PROMPT.md](SHERLOCK-OPENCLAW-PROMPT.md) | A task prompt written *for an agent* — how to give OpenClaw the Sherlock read-only SQL tool across the microVM boundary. Not documentation of the system; its banner records the task as done. | archival |

## Setup — one-time integration guides

These were written as "do this once" procedures.

| Document | What it covers / who needs it | Status |
|---|---|---|
| [RSPAMD_SETUP.md](RSPAMD_SETUP.md) | The full Rspamd installation: how it ties into Dovecot, a dedicated Redis, PostgreSQL history, Prometheus/Alertmanager/Grafana, plus the two required secrets and the certificate. Reference when changing spam filtering. | current |
| [GITHUB_MIRROR_SETUP.md](GITHUB_MIRROR_SETUP.md) | Configuring the bidirectional GitHub ↔ Gitea mirroring service — discovery timer, the 8-hour sync cadence in both directions, the two required tokens, testing. Pairs with `UPDATE_GITHUB_TOKENS.md`. | current |
| [GITEA_ORG_WORKFLOW.md](GITEA_ORG_WORKFLOW.md) | Setting up the Gitea Actions runner and the build-and-deploy workflow for the `org-jw` repository, including the rclone/WebDAV publish target and the two SOPS keys it needs. | current |
| [ICLOUD_CONTACTS_SETUP.md](ICLOUD_CONTACTS_SETUP.md) | Adding a second vdirsyncer pair so `nasimw`'s iCloud contacts sync to Radicale alongside johnw's Fastmail pair: Radicale user, app-specific password, config, verification. | current |
| [HOME_ASSISTANT_BHYVE_RAIN_DELAY.md](HOME_ASSISTANT_BHYVE_RAIN_DELAY.md) | Forecast-driven rain delay for the Orbit B-Hyve controller, including why forecast beats observed precipitation and several threshold variants to choose from. | current |
| [HOME_ASSISTANT_NWS_RAIN_DETECTION.md](HOME_ASSISTANT_NWS_RAIN_DETECTION.md) | Building rain-detection template sensors from the NWS integration's `weather.kmhr` entity using the modern `weather.get_forecasts` service. Feeds the rain-delay automation above. | current |
| [HOME_ASSISTANT_VACATION_MODE.md](HOME_ASSISTANT_VACATION_MODE.md) | A presence-simulation automation: randomized evening light on/off gated on `binary_sensor.everyone_away`, with the customization knobs. | current |
| [NODE_RED_SETUP.md](NODE_RED_SETUP.md) | The original standing-up of Node-RED on vulcan: the service module on port 1880, the nginx vhost, the Step-CA certificate, and the SOPS-held Home Assistant token, with the manual steps that could not be declared. | archival |
| [CLOUDFLARE_MIGRATION.md](CLOUDFLARE_MIGRATION.md) | The 2025 procedure for moving `newartisans.com` DNS from Name.com to Cloudflare and creating a tunnel. Its banner records that the DNS half is done and the document's second subject — an n8n webhook proxy — is obsolete: n8n and all five of its modules were removed from this repository in 2026-03. | archival |

## Design & history

### Design documents at the root of `docs/`

| Document | What it covers / who needs it | Status |
|---|---|---|
| [TAILSCALE_HEADSCALE_PLAN.md](TAILSCALE_HEADSCALE_PLAN.md) | A 2026-07-11 two-part document: Part I weighs a self-hosted Headscale-coordinated Tailscale mesh against the existing OPNsense WireGuard and Cloudflare tunnels; Part II is an eleven-phase deployment runbook. Design accepted but **not implemented** — re-checked 2026-07-30, no `services.headscale` or `services.tailscale` declaration exists anywhere in this repository. Its appendix D lists the volatile version-specific facts to reconfirm before building. | current |

### The 2026-07-28 audit → remediation set

Five documents produced in sequence by one effort. Read them in this order; each
supersedes part of the one before it. **The first three are frozen** — the loop
that consumes them says so explicitly, and lowering their bar to make a gate pass
is the failure mode they were frozen against.

| Document | What it covers / who needs it | Status |
|---|---|---|
| [HEALTH_AUDIT_2026-07-28.md](HEALTH_AUDIT_2026-07-28.md) | The source audit: 7 read-only subsystem sweeps plus an adversarial re-verification pass, 116 findings (2 critical / 45 warning / 69 info), of which 34 were missed by the sweeps and caught only by the adversarial pass and 6 sweep findings were refuted. Its two most reusable lessons are method, not fact: every domain reasoned from an *instantaneous* Alertmanager state and so missed four multi-hour critical outages in the week, and a component can fail while every layer above it reports success. | archival |
| [REMEDIATION_PLAN_2026-07-28.md](REMEDIATION_PLAN_2026-07-28.md) | 76 items in 7 phases derived from the audit, with every PromQL/LogQL expression executed live at plan time and expressions whose metric does not yet exist marked `UNVERIFIED (metric absent by design)`. 220 KB; navigate by phase heading. Header states plainly that nothing in it had been applied when it was written — check the loop log below for what since was. | archival |
| [REMEDIATION_DECISIONS_2026-07-28.md](REMEDIATION_DECISIONS_2026-07-28.md) | The 18 operator decisions and 10 scope-creep items that resolve the plan's open questions; supersedes the plan's §8 and §9. Short, tabular, and the authoritative record of *why* a plan item was dropped, deferred or reshaped — including D3, which retired the Schwab data source and with it the weekly OAuth chore. | current |
| [WIGGUM_HANDOFF.md](WIGGUM_HANDOFF.md) | The live log of the `/wiggum` loop executing that plan: per-phase progress, gate attempts, premises disproved mid-flight, and its own author's recurring defects. The one file in this set that is still being written. Read it before touching any monitoring file, because it records what is half-applied. | current |
| [HA_ENTITY_WORKLIST_2026-07-29.md](HA_ENTITY_WORKLIST_2026-07-29.md) | Decision-D9 worklist generated from Home Assistant's recorder DB: the unavailable/unknown entities split into three groups needing three different actions (delete re-registration debris, fix one integration, accept the rest). Prerequisite for thresholding the entity-availability exporter, which cites this file twice — a threshold set against today's count would encode the debris as normal. | current |

### `docs/superpowers/`

**The entire `superpowers/` directory is historical.** All 43 files are dated
design specs (`specs/`, 21 files) or task-by-task execution plans (`plans/`,
22 files) produced by the brainstorm → design → plan → implement workflow.
Plans carry `- [ ]` checkboxes addressed to an implementing agent; those
checkboxes reflect the state at the time of writing and must not be
re-executed. Specs record the reasoning and trade-offs behind subsystems that
now exist.

Surveyed file-by-file 2026-07-30, and the state of this directory is
machine-checkable rather than a matter of judgement:

- **43 of 43** open with `> **Archival — <date>.**`.
- **41 of 43** then declare `> **Outcome:** implemented (see <path>)`, and every
  repo path named on those lines exists today.
- **2 of 43** declare no outcome: `2026-05-14-climate-comfort-design.md` and
  `2026-05-15-climate-comfort-bias-regression-design.md`. Nothing in the repo
  outside `docs/` mentions the feature. These are the directory's only genuinely
  open design intent.
- **4 of 43** are cited from Nix or Python outside `docs/`, on 5 lines
  (re-measured 2026-08-19) — the MCP-bridge plan (twice), the openuv plan, the
  Hermes self-heal design, and the unified-health-report design. Those citations
  are load-bearing provenance; do not delete the target without first moving the
  cited sentence into the citing file. Two files dropped off this list when
  OpenClaw was removed — the openclaw-hardening plan and the OpenClaw self-heal
  design — so they are now archival with nothing pointing at them.

Ignore the in-body `**Status:**` line of any file here: several read "Draft" or
"pending implementation" for work that shipped months ago (the open-source
secretary spec says "pending spec review" while `pkgs/open-source-secretary/`
and `modules/services/open-source-secretary.nix` both exist). The banner and
the `Outcome:` line are the maintained fields; the body status is not.

#### `superpowers/plans/`

| Plan | Subject |
|---|---|
| [2026-04-22-openclaw-hardening.md](superpowers/plans/2026-04-22-openclaw-hardening.md) | Package-level fix for the OpenClaw plugin-init regression plus four defense-in-depth monitoring layers. |
| [2026-04-22-perplexica-to-vane.md](superpowers/plans/2026-04-22-perplexica-to-vane.md) | Renaming the Perplexica deployment to Vane across modules and migrating its on-disk state. |
| [2026-05-05-openclaw-self-heal.md](superpowers/plans/2026-05-05-openclaw-self-heal.md) | Building the Alertmanager-webhook self-heal daemon with deterministic → AI action escalation. |
| [2026-05-05-openclaw-stock-trader-integration.md](superpowers/plans/2026-05-05-openclaw-stock-trader-integration.md) | Wrapping eight stock-trader REST endpoints as an MCP stdio server inside the OpenClaw microVM. |
| [2026-05-05-openclaw-stock-trader-integration-resume.md](superpowers/plans/2026-05-05-openclaw-stock-trader-integration-resume.md) | Hand-off notes for the above: deployed, with only the end-to-end Discord check left, blocked on a Schwab token. |
| [2026-05-11-hermes-vm-phase1.md](superpowers/plans/2026-05-11-hermes-vm-phase1.md) | Standing up the Hermes Agent as an isolated standalone microVM with its own Discord bot. |
| [2026-05-11-openclaw-vm-ssh-probe.md](superpowers/plans/2026-05-11-openclaw-vm-ssh-probe.md) | Replacing "skipped from host context" MCP statuses in the nightly report with real in-VM `mcporter list` results over SSH. |
| [2026-05-12-openclaw-hermes-mcp-bridge.md](superpowers/plans/2026-05-12-openclaw-hermes-mcp-bridge.md) | The `hermes-mcp` host service exposing six session-aware tools over HTTPS/SSE to OpenClaw. |
| [2026-05-12-openuv-pool-time.md](superpowers/plans/2026-05-12-openuv-pool-time.md) | Daily OpenUV forecast pull driving a Node-RED "pool time" announcement gated on water temperature. |
| [2026-05-13-node-red-event-logging.md](superpowers/plans/2026-05-13-node-red-event-logging.md) | Capturing every Node-RED message and audit event into PostgreSQL with a Grafana inspection dashboard. |
| [2026-05-14-openclaw-nix-config.md](superpowers/plans/2026-05-14-openclaw-nix-config.md) | Replacing the monolithic SOPS `openclaw/config` blob with a Nix-generated template plus atomic per-credential secrets. |
| [2026-05-15-hermes-egress-and-dashboard.md](superpowers/plans/2026-05-15-hermes-egress-and-dashboard.md) | Tightening Hermes microVM egress to 443/53 and adding the 28-metric integration dashboard. |
| [2026-05-15-openclaw-hermes-runbook-smoke.md](superpowers/plans/2026-05-15-openclaw-hermes-runbook-smoke.md) | Producing `docs/openclaw-hermes-integration.md` and a 15-minute MCP-over-SSE synthetic smoke probe. |
| [2026-05-16-flake-check-coverage.md](superpowers/plans/2026-05-16-flake-check-coverage.md) | Adding schema-snapshot checks, a runtime drift detector, and the pytest suites to `nix flake check`. |
| [2026-05-20-hermes-self-heal-and-nightly-report.md](superpowers/plans/2026-05-20-hermes-self-heal-and-nightly-report.md) | Bringing Hermes to OpenClaw parity with a Python self-heal daemon and a 06:15 emailed nightly report. |
| [2026-05-22-water-attribution.md](superpowers/plans/2026-05-22-water-attribution.md) | Delivering live per-category water attribution in HA plus the weekly cross-check and historical backfill. |
| [2026-05-27-cloud-drive-backup-sync.md](superpowers/plans/2026-05-27-cloud-drive-backup-sync.md) | Nightly one-way rclone mirror of cloud drives into per-account ZFS datasets with freshness alerting. |
| [2026-06-01-unified-agent-health-report.md](superpowers/plans/2026-06-01-unified-agent-health-report.md) | Collapsing the two divergent nightly-report scripts into one profile-driven `agent_health_report.py`. |
| [2026-06-09-drafts-mcp-bridge.md](superpowers/plans/2026-06-09-drafts-mcp-bridge.md) | Bridging hera's stdio Drafts.app MCP server to a loopback SSE endpoint with three differently-scoped consumers. |
| [2026-07-02-rbcca-mail-mirror.md](superpowers/plans/2026-07-02-rbcca-mail-mirror.md) | Mirroring `jwiegley@rbcca.org` into local Dovecot and enabling send-as through Gmail SMTP. |
| [2026-07-21-noninvasive-drafts-mcp-probe.md](superpowers/plans/2026-07-21-noninvasive-drafts-mcp-probe.md) | Splitting the Drafts MCP probe into a transport-only scheduled mode and a manual app-check mode, so nothing drives AppleEvents on a timer. |
| [2026-07-22-open-source-secretary.md](superpowers/plans/2026-07-22-open-source-secretary.md) | A daily job that scans GitHub/Gitea issues and notifications, has Hermes triage the deltas, and emails a prioritized summary. |

#### `superpowers/specs/`

| Spec | Subject |
|---|---|
| [2026-04-22-perplexica-to-vane-design.md](superpowers/specs/2026-04-22-perplexica-to-vane-design.md) | Approved design for the Perplexica → Vane rebrand, image swap, and state preservation. |
| [2026-05-05-openclaw-self-heal-design.md](superpowers/specs/2026-05-05-openclaw-self-heal-design.md) | Why the startup-only canary missed weekly silent Discord outages, and the self-heal architecture that replaced it. |
| [2026-05-05-openclaw-stock-trader-integration-design.md](superpowers/specs/2026-05-05-openclaw-stock-trader-integration-design.md) | Draft design for exposing stock-trader's API to OpenClaw as MCP tools. |
| [2026-05-12-openuv-pool-time-design.md](superpowers/specs/2026-05-12-openuv-pool-time-design.md) | The UV-crossing prediction and pool-temperature gate; marked shipped, with as-built deltas in its §13. |
| [2026-05-13-node-red-event-logging-design.md](superpowers/specs/2026-05-13-node-red-event-logging-design.md) | The as-shipped design of the Node-RED → PostgreSQL event pipeline (hooks, partitions, retention). |
| [2026-05-14-climate-comfort-design.md](superpowers/specs/2026-05-14-climate-comfort-design.md) | Adaptive HVAC setpoint blending — the approved comfort model. |
| [2026-05-14-openclaw-nix-config-design.md](superpowers/specs/2026-05-14-openclaw-nix-config-design.md) | The two-stage template plus atomic-secret render pipeline for `openclaw.json`. |
| [2026-05-15-climate-comfort-bias-regression-design.md](superpowers/specs/2026-05-15-climate-comfort-bias-regression-design.md) | A follow-on regression-based bias upgrade to the climate model; still marked draft, for later implementation. |
| [2026-05-15-hermes-egress-and-dashboard-design.md](superpowers/specs/2026-05-15-hermes-egress-and-dashboard-design.md) | Rationale for narrowing the Hermes FORWARD chain and for the combined integration dashboard. |
| [2026-05-15-openclaw-hermes-runbook-smoke-design.md](superpowers/specs/2026-05-15-openclaw-hermes-runbook-smoke-design.md) | Design of the runbook and the bridge-level smoke probe, closing the MCP-bridge plan's last acceptance criterion. |
| [2026-05-16-flake-check-coverage-design.md](superpowers/specs/2026-05-16-flake-check-coverage-design.md) | Why build-time schema checks were needed and how the drift detector and pytest checks were shaped. |
| [2026-05-20-hermes-self-heal-and-nightly-report-design.md](superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md) | Hermes' five-action allowlist, its deliberate divergence from OpenClaw on unknown alerts, and the eight nightly-report signal sources. |
| [2026-05-22-water-attribution-design.md](superpowers/specs/2026-05-22-water-attribution-design.md) | The original water-attribution design: categories, declarative HA generation, and the Python cross-check/backfill split. |
| [2026-05-27-cloud-drive-backup-sync-design.md](superpowers/specs/2026-05-27-cloud-drive-backup-sync-design.md) | The nightly rclone-to-ZFS mirror design, including OAuth token handling and reliance on sanoid for history. |
| [2026-05-28-hermes-service-parity-design.md](superpowers/specs/2026-05-28-hermes-service-parity-design.md) | Giving the Hermes VM full OpenClaw host-service parity — SearXNG plus six MCP servers, reusing existing secrets. |
| [2026-06-01-unified-agent-health-report-design.md](superpowers/specs/2026-06-01-unified-agent-health-report-design.md) | The eleven-section union and per-agent profile table that superseded the two nightly-report scripts. |
| [2026-06-08-drafts-mcp-bridge-design.md](superpowers/specs/2026-06-08-drafts-mcp-bridge-design.md) | The approved cross-host design for the Drafts MCP bridge, deliberately stopping short of an implementation spec. |
| [2026-06-09-drafts-mcp-bridge-spec.md](superpowers/specs/2026-06-09-drafts-mcp-bridge-spec.md) | The implementation-ready successor to the above, carrying every file body, diff, and `path:line` anchor. |
| [2026-06-27-rbcca-mail-mirror-design.md](superpowers/specs/2026-06-27-rbcca-mail-mirror-design.md) | Design for the rbcca.org mirror and send-as path; its header records it as implemented and deployed 2026-07-02. |
| [2026-07-21-noninvasive-drafts-mcp-probe-design.md](superpowers/specs/2026-07-21-noninvasive-drafts-mcp-probe-design.md) | Why the scheduled probe's AppleScript call had to go, and the two-mode contract that replaced it. |
| [2026-07-22-open-source-secretary-design.md](superpowers/specs/2026-07-22-open-source-secretary-design.md) | The `oss_secretary` package design — deterministic collector as source of truth, LLM as advisory prioritizer. |

---

## Documentation living outside `docs/`

| Path | What it covers / who needs it | Status |
|---|---|---|
| [`/etc/nixos/README.md`](../README.md) | The build-level overview: key features, architecture, the infrastructure component tour, hardware and platform, quick start, the management-command cookbook, the module tree, secrets management, and all 23 flake inputs with their pin rationales. Authoritative for "how is this system built"; its counts are anchored to 2026-07-27. | current |
| [`/etc/nixos/CLAUDE.md`](../CLAUDE.md) | The operating rules: the security pre-flight check and forbidden-path list, the tmpfiles data-loss rules, file-permission rules, the port-registry procedure, and a quick command reference. Authoritative for "how do I operate on this safely". Re-checked 2026-08-19: the dangling `@./.taskmaster/CLAUDE.md` import this row used to flag is gone, and the file now closes with the `obr` workflow block instead. It names a `docs/` path on 9 lines, all of which resolve. | current |
| [`/etc/nixos/SECURITY.md`](../SECURITY.md) | The repository's public-facing vulnerability-reporting policy and response timeline, aimed at the GitHub mirror rather than at operators of this host. | current |
| [`certs/CERTIFICATES.md`](../certs/CERTIFICATES.md) | Step-CA certificate management: per-vhost nginx certificates under `/var/lib/nginx-certs/`, the annual renewal driven by Apple's ≤398-day rule, per-service cert locations, and the renewal wrappers. Its banner marks the older single-wildcard OpenSSL procedure as background only. | current |
| [`modules/lib/README.md`](../modules/lib/README.md) | Reference for the six shared Nix helpers in `modules/lib/`, with the required argument sets spelled out. It also records that `mkQuadletService` has exactly one remaining consumer as of 2026-07-27, most quadlets having moved to per-user home-manager modules. | current |
| [`scripts/flume-data/README.md`](../scripts/flume-data/README.md) | Layout, test invocation, the configuration warning that `zones.json` is Nix-generated and must not be hand-edited, and the CLI surface for the water cross-check and backfill codebase. | current |
| [`modules/monitoring/dashboards/vdirsyncer-dashboard-guide.md`](../modules/monitoring/dashboards/vdirsyncer-dashboard-guide.md) | How to build a Grafana dashboard from the four metrics `vdirsyncer-status.service` exposes on `127.0.0.1:8089`, including the per-pair labelling trap. Shipped beside the dashboard JSON it describes. | current |
| [`pkgs/hermes-mcp/README.md`](../pkgs/hermes-mcp/README.md) | A three-line pointer from the package to its operational runbook (`docs/openclaw-hermes-integration.md`) and its implementation-history plan. | current |
| [`/etc/nixos/HANDOFF-alarmdotcom.md`](../HANDOFF-alarmdotcom.md) | A 2026-05-22 hand-off note covering the in-flight upgrade of the HACS `alarmdotcom` integration and its `pyalarmdotcomajax` bump. Its banner records the outcome as implemented in `overlays/default.nix`. It sits at the repo root rather than in `docs/`. | archival |
| [`pkgs/stock-trader.deps.md`](../pkgs/stock-trader.deps.md) | A generated audit of stock-trader's runtime Python dependencies taken from the v0.1.0 source tree on 2026-04-26. Its banner notes the deployment now pins the v0.2.0 tag, so the list must be re-derived before it is trusted. | archival |

Further `README.md` files exist under `.pytest_cache/` directories. Those are
generated by pytest and are not documentation.

---

## Observation: naming is inconsistent (no renames were made)

Of the 52 markdown files at the root of `docs/`, the split is (counted
2026-07-30; these four groups partition the 52 exactly):

- **SCREAMING_SNAKE_CASE** — 41 files, the large majority
  (`REBOOT_RESILIENCE.md`, `HOME_ASSISTANT_DEVICES.md`,
  `MONITORING_COVERAGE_PLAN.md`, …).
- **SCREAMING_SNAKE_CASE with a trailing date** — 6 files:
  `BOOT_SLOWNESS_RCA_2026-06-24.md`, `POST_REBOOT_AUDIT_2026-07-03.md`,
  `HEALTH_AUDIT_2026-07-28.md`, `REMEDIATION_PLAN_2026-07-28.md`,
  `REMEDIATION_DECISIONS_2026-07-28.md`, `HA_ENTITY_WORKLIST_2026-07-29.md`.
- **UPPERCASE-WITH-HYPHENS** — 3 files: `OPNSENSE-EXPORTER-SETUP.md`,
  `OPNSENSE-EXPORTER-WORKAROUND.md`, `SHERLOCK-OPENCLAW-PROMPT.md`.
- **lowercase** — 2 files: `openclaw-hermes-integration.md`,
  `quadlet-guide.md`.

All 43 files under `superpowers/` use dated `YYYY-MM-DD-kebab-case.md`. The
split does not track content: `quadlet-guide.md` and
`BOOT_SLOWNESS_RCA_2026-06-24.md` are both archival. Nor is dating consistent —
`BOOT_SLOWNESS_RCA_2026-06-24.md` and `POST_REBOOT_AUDIT_2026-07-03.md` carry
their date in the filename, while the equally dated
`BOOT_SWITCH_ROBUSTNESS_AUDIT.md` does not.

**Recommended convention, for new files only:**

1. `kebab-case.md`, matching `superpowers/` and the newest hand-written docs.
2. Prefix a leading `YYYY-MM-DD-` when the document is a snapshot of a moment —
   an audit, an RCA, or a post-incident report — so its shelf life is visible
   in a directory listing.
3. No date prefix for living reference and runbooks, which are meant to be
   edited in place rather than superseded.

Renaming the existing files is a separate, deliberate change, not a cosmetic
one. As of 2026-08-19, **22 distinct `docs/` paths are named across 84 lines** of
Nix comments and Python docstrings, the documents cross-reference each other, and
`/etc/nixos/CLAUDE.md` names a `docs/` path on 9 lines. A rename pass must fix every
reference in the same commit. **Nothing was renamed in this pass.**

Exactly one of those cited paths does not resolve inside this repository, and it
is annotated at the citation site rather than being a silent dangle:
`docs/deploy/freshness-rollout-runbook.md`, cited from
`modules/services/stock-trader.nix`, whose comment says in place that the path
lives in the upstream stock-trader repository and not in this one.

That invariant — *no unresolvable `docs/` citation is ever silent* — was briefly
false and was repaired on 2026-08-19 rather than merely observed. Two other
entries stood here:

- `docs/OOM_ANALYSIS_2025-11-12.md`, cited from `modules/core/memory-limits.nix`.
  That citation is gone from the module entirely, so the path is no longer named
  anywhere outside this paragraph.
- A `SESSION_GATHER` document under `docs/`, cited from
  `modules/services/session-gather.nix:24` at the end of a comment describing the
  service's read access. It had never existed in this tree or in git history and
  nothing at the citation site said so — the one genuine silent dangle
  (`nixos-h1t`). Fixed by dropping the pointer, not by writing the document: the
  comment already carried the entire security contract it deferred.

Re-check this invariant with the survey command above, comparing each result
against the tree. It is cheap, and a silent dangle is the failure mode that
turns a comment into a dead end for exactly the reader who needed it most.
