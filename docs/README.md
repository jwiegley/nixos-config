# `/etc/nixos/docs/` — Index

Compiled 2026-07-27 by opening every file in this tree. This is a map, not a
rewrite: nothing was renamed, moved, or edited to produce it.

Scope of what is catalogued below: **92 files under `docs/`** — 90 markdown
(47 at the root of `docs/`, including this index, plus 43 under
`superpowers/`) and 2 non-markdown (`ports.txt`, `create-postgres-user.sql`) —
together with the **10 markdown files that live outside `docs/`** and are real
documentation rather than pytest scaffolding.

## Start here — which documents are authoritative

| Question | Authoritative document |
|---|---|
| **How is this system built?** — architecture, module layout, hardware, flake inputs, management commands | [`/etc/nixos/README.md`](../README.md) |
| **How do I operate on it safely?** — the security rules, the forbidden-path list, data-loss rules, port-registry discipline | [`/etc/nixos/CLAUDE.md`](../CLAUDE.md) |
| **What is actually listening on what?** | [`ports.txt`](ports.txt) — machine-reconciled against live sockets by `modules/monitoring/services/port-drift-exporter.nix` |
| **What do I do after a reboot?** | [`REBOOT_RESILIENCE.md`](REBOOT_RESILIENCE.md) |

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

As of 2026-07-27, 28 of the 46 pre-existing documents at the root of `docs/`
open with a self-describing status or archival banner of their own — usually
`> **Status (2026-07-27):** …` or `> **Archival — <date>.**`. Where a file's
own banner and this table disagree, the banner is closer to the document and
wins.

---

## Operate — runbooks, checklists, recovery

| Document | What it covers / who needs it | Status |
|---|---|---|
| [REBOOT_RESILIENCE.md](REBOOT_RESILIENCE.md) | Consolidated per-subsystem symptom → cause → fix → verify record of everything that makes vulcan survive a cold boot, keyed to the checks in `scripts/post-reboot-validation.sh`. The first thing to open after any reboot or suspected boot problem. | current |
| [COLD_REBOOT_CHECKLIST.md](COLD_REBOOT_CHECKLIST.md) | The pre-reboot ritual and per-check validation matrix. Its banner records that the reboot it was written for happened on 2026-06-10 and passed 21/0/0, and that the document is retained as the standing procedure to run around *any* future cold reboot. | current |
| [CRASH_DEBUGGING.md](CRASH_DEBUGGING.md) | What `modules/core/crash-debug.nix` sets up (persistent journal, kernel log, sar/atop, kdump) and the ordered command sequence to run after a spontaneous reboot. For diagnosing unexplained restarts. | current |
| [STOCK_TRADER_SCHWAB_TOKEN_RENEWAL.md](STOCK_TRADER_SCHWAB_TOKEN_RENEWAL.md) | Step-by-step recovery when `StockTraderSchwabDataSourceDown` fires: the browser OAuth must run on hera, the token is then pushed to vulcan and installed 0600. Short, verified, and needed roughly weekly. | current |
| [openclaw-hermes-integration.md](openclaw-hermes-integration.md) | Operator runbook for the OpenClaw ↔ Hermes bridge — topology, component map, the six MCP tools, paste-and-run verification, failure modes with one-command remediation, and the metrics reference. Fact-checked against the tree 2026-07-27. | current |
| [UPDATE_GITHUB_TOKENS.md](UPDATE_GITHUB_TOKENS.md) | How to use `scripts/update-github-tokens.py` to bulk-rotate the GitHub PAT embedded in every Gitea push and pull mirror, including dry-run mode. Needed whenever the PAT expires. | current |
| [SIEVE_FILTERING.md](SIEVE_FILTERING.md) | Where the delivery-time and IMAPSieve scripts live under `/var/lib/dovecot/sieve/users/<user>/`, and how to edit, compile, and test them. For mail-routing changes. | current |
| [BOOT_SWITCH_ROBUSTNESS_AUDIT.md](BOOT_SWITCH_ROBUSTNESS_AUDIT.md) | The 2026-06-08 read-only 13-dimension audit of boot and `nixos-rebuild switch` robustness: what was solid, and the ranked residual risks (local DNS readiness, late ZFS mounts). Its banner states every residual finding has since been fixed. Background reading for `REBOOT_RESILIENCE.md`. | archival |
| [BOOT_SLOWNESS_RCA_2026-06-24.md](BOOT_SLOWNESS_RCA_2026-06-24.md) | Root-cause analysis of one boot (2026-06-24): concludes it was not a regression, separates the real ~125 s DNS-dead window from the cosmetic 15-minute `systemd-analyze` figure, and lists a prioritized fix plan. For anyone re-investigating slow boots. | archival |
| [POST_REBOOT_AUDIT_2026-07-03.md](POST_REBOOT_AUDIT_2026-07-03.md) | Multi-agent health audit after the 2026-07-03 reboot: corrected two-outage timeline, the two console stack-trace storms and their causes, what was fixed during the audit, and what needed the operator. | archival |
| [CLAUDE_MEM_NIXOS_REPAIR.md](CLAUDE_MEM_NIXOS_REPAIR.md) | 2026-05-27 diagnosis and fix of claude-mem's search backend on vulcan: a systemd *user* service missing `PATH` and `LD_LIBRARY_PATH`, repaired with one drop-in. About developer tooling on this host, not about any vulcan service. | archival |
| [CLAUDE_MEM_MULTI_MACHINE_FIX.md](CLAUDE_MEM_MULTI_MACHINE_FIX.md) | The portable companion to the above: a diagnostic script plus per-platform (NixOS / Ubuntu / macOS) fixes for the same five claude-mem issues. For fixing other machines, not vulcan. | archival |

## Monitoring

| Document | What it covers / who needs it | Status |
|---|---|---|
| [NAGIOS_PROMETHEUS_MIRROR_SPEC.md](NAGIOS_PROMETHEUS_MIRROR_SPEC.md) | Design for generating a Nagios service check from every Prometheus/Loki/VictoriaMetrics rule so the two stacks validate each other by construction. Its banner records the design as implemented and live (verified 2026-07-27, all three tiers imported); the counts inside the body are the 2026-06-10 snapshot. | current |
| [HOME_ASSISTANT_ALERTING.md](HOME_ASSISTANT_ALERTING.md) | Why the 23 Prometheus `homeassistant_*` alert rules could never fire (HA pushes to VictoriaMetrics and is never scraped into Prometheus), what replaced them in Node-RED, and the original rule intent kept as an implementation reference. | current |
| [HOME_ASSISTANT_NAGIOS_MONITORING.md](HOME_ASSISTANT_NAGIOS_MONITORING.md) | Setting up and running `check_homeassistant_integrations` — thresholds, exit codes, token provisioning, usage examples, and the explicit limits of what the script can see. For Nagios/HA integration-health work. | current |
| [TECHNITIUM_DNS_MONITORING_SETUP.md](TECHNITIUM_DNS_MONITORING_SETUP.md) | One-time setup for the Technitium DNS exporter on `localhost:9274`: building the container image locally because none is published, generating the API token, and wiring Prometheus, Grafana and Alertmanager. | current |
| [MAC_STUDIO_POWER_MONITORING.md](MAC_STUDIO_POWER_MONITORING.md) | How Apple Silicon SMC power, current and temperature sensors reach Prometheus through `macsmc_hwmon`, the full metric list, the Grafana dashboard, and example queries. Reference for anyone touching power telemetry on this hardware. | current |
| [OPNSENSE-EXPORTER-SETUP.md](OPNSENSE-EXPORTER-SETUP.md) | Deploying the OPNsense Prometheus exporter as a Podman quadlet on `localhost:9273` — API key provisioning, SOPS wiring, verification, and the exact series it collects. | current |
| [OPNSENSE-EXPORTER-WORKAROUND.md](OPNSENSE-EXPORTER-WORKAROUND.md) | The two upstream bugs (boolean `monitor_disable`, null `product_check`) first hit on v0.0.11 and the `opnsense-api-transformer` proxy that works around them. Its banner notes the deployed image now resolves to 0.0.16 but the workaround has not been re-tested without the proxy. | current |
| [DISCORD_CANARY_SETUP.md](DISCORD_CANARY_SETUP.md) | The remaining one-time steps to activate the mutual OpenClaw ↔ Hermes Discord round-trip canary. `modules/monitoring/services/discord-canary.nix` is imported, but both probes are still `enable = false` with an empty `channelId` in `hosts/vulcan/default.nix`, exactly as the runbook says. | current |
| [LOG_SUMMARIZER.md](LOG_SUMMARIZER.md) | What `scripts/log-summarizer.py` collects, how it calls LiteLLM, its logwatch integration, output format, and troubleshooting. For anyone changing the daily log digest. | current |
| [MONITORING_COVERAGE_PLAN.md](MONITORING_COVERAGE_PLAN.md) | The 2026-06-09 17-domain census of monitoring coverage (203 gaps: 15 P0 / 83 P1 / 105 P2) with a per-domain appendix. All phases shipped on 2026-06-09/10, so it now functions as provenance — eight Nix comments cite it as the reason a rule exists. 328 KB; navigate by heading. | archival |
| [MONITORING_DEFERRED_SPECS.md](MONITORING_DEFERRED_SPECS.md) | Thirteen implementation-ready chapters for the items deliberately deferred out of the coverage plan (CVE scanning, VM egress, `pg_stat_statements`, HA `_str` purge, port drift, Nagios's future), each ending in a decision only the operator can make. Some have since been built anyway — the port-drift exporter exists — so check each chapter against the tree before treating it as open work. | archival |
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
| [LITELLM_TOOL_USE_BUG_REPORT.md](LITELLM_TOOL_USE_BUG_REPORT.md) | A ready-to-file upstream bug report against LiteLLM 1.82.3: the Anthropic → Responses-API converter emits `function_call` before assistant text, with root cause, reproduction, suggested fix, and user-side workarounds. Useful if the same symptom reappears. | archival |
| [SHERLOCK-OPENCLAW-PROMPT.md](SHERLOCK-OPENCLAW-PROMPT.md) | A task prompt written *for an agent* — how to give OpenClaw the Sherlock read-only SQL tool across the microVM boundary. Not documentation of the system; its banner records the task as done. | archival |

## Setup — one-time integration guides

These were written as "do this once" procedures.

| Document | What it covers / who needs it | Status |
|---|---|---|
| [RSPAMD_SETUP.md](RSPAMD_SETUP.md) | The full Rspamd installation: how it ties into Dovecot, a dedicated Redis, PostgreSQL history, Prometheus/Alertmanager/Nagios/Grafana, plus the two required secrets and the certificate. Reference when changing spam filtering. | current |
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
| [TAILSCALE_HEADSCALE_PLAN.md](TAILSCALE_HEADSCALE_PLAN.md) | A 2026-07-11 two-part document: Part I weighs a self-hosted Headscale-coordinated Tailscale mesh against the existing OPNsense WireGuard and Cloudflare tunnels; Part II is an eleven-phase deployment runbook. Design accepted but **not implemented** — as of 2026-07-27 no `services.headscale` or `services.tailscale` declaration exists anywhere in this repository. Its appendix D lists the volatile version-specific facts to reconfirm before building. | current |

### `docs/superpowers/`

**The entire `superpowers/` directory is historical.** All 43 files are dated
design specs (`specs/`, 21 files) or task-by-task execution plans (`plans/`,
22 files) produced by the brainstorm → design → plan → implement workflow.
Plans carry `- [ ]` checkboxes addressed to an implementing agent; those
checkboxes reflect the state at the time of writing and must not be
re-executed. Specs record the reasoning and trade-offs behind subsystems that
now exist. Every document here is **archival** unless its own header says
otherwise — a few (the climate-comfort bias regression, and the newest
secretary work) say "draft" or "pending implementation".

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
| [`/etc/nixos/CLAUDE.md`](../CLAUDE.md) | The operating rules: the security pre-flight check and forbidden-path list, the tmpfiles data-loss rules, file-permission rules, the port-registry procedure, and a quick command reference. Authoritative for "how do I operate on this safely". One dangling reference remains — its closing line imports `@./.taskmaster/CLAUDE.md`, and there is no `.taskmaster` directory in this repository. | needs-review |
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

Of the 46 pre-existing markdown files at the root of `docs/`, the split is:

- **SCREAMING_SNAKE_CASE** — 40 files, the large majority
  (`REBOOT_RESILIENCE.md`, `HOME_ASSISTANT_DEVICES.md`,
  `MONITORING_COVERAGE_PLAN.md`, …).
- **UPPERCASE-WITH-HYPHENS** — 3 files: `OPNSENSE-EXPORTER-SETUP.md`,
  `OPNSENSE-EXPORTER-WORKAROUND.md`, `SHERLOCK-OPENCLAW-PROMPT.md`.
- **lowercase** — 3 files: `openclaw-hermes-integration.md`,

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
one. As of 2026-07-27, 14 distinct `docs/` paths are named across 50 lines of
Nix comments, and the documents cross-reference each other and are referenced
from `/etc/nixos/CLAUDE.md` in eleven places. A rename pass must fix every
reference in the same commit. **Nothing was renamed in this pass.**

Two of those 14 Nix-cited paths do not resolve inside this repository, and both
are already annotated at the citation site rather than being silent dangles:
`docs/OOM_ANALYSIS_2025-11-12.md` (`modules/core/memory-limits.nix`, whose
comment records that the document is absent from the tree and from git
history), and `docs/deploy/freshness-rollout-runbook.md`
(`modules/services/stock-trader.nix`, whose comment says the path is in the
upstream stock-trader repository, not this one).
