# Vulcan — Deferred Monitoring Items: Design Specifications

> **Archival — 2026-06-10.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.

**Date:** 2026-06-10 · **Author:** Claude Fable (13-agent read-only investigation)
**Companion to:** `docs/MONITORING_COVERAGE_PLAN.md` (phases 0–4 implemented; these are the items deliberately deferred as design/decision work).

Every spec below was grounded in read-only investigation of the live system. Each chapter is
implementation-ready: exact files, metric names, alert exprs with baseline-justified thresholds,
deploy choreography, noise analysis, and the decisions only the operator can make.

## Verdict summary

| Item | Verdict | Effort | TL;DR |
|------|---------|--------|-------|
| [Nagios's future: retire to a thin ICMP-vantage shell, or keep as-is](#nagios-topology-decision) | NEEDS_USER_DECISION | M — ~6-9h for Option B-lite (port 2 unique signals + decommi | Three alerting stacks coexist on vulcan, and the phase-4 status.dat bridge already surfaces Nagios's verdict (counts) in Alertmanager. A full check-type inventory shows that ~95% of Nagios's 253 live service checks are n |
| [Monitoring egress from the OpenClaw & Hermes agent microVMs](#vm-agent-egress) | IMPLEMENT_MODIFIED | M, ~6-8h for Tiers 1+2 (one build/switch). Tier 3 enforcemen | The two autonomous-agent microVMs (openclaw 10.99.0.2 on br-openclaw, hermes 10.99.1.2 on hermes-br0) already have NAT egress with iptables isolation chains AND egress LOG rules — but the LOG lines are kernel priority-6  |
| [Container Image CVE Scanning (Trivy textfile exporter + severity-floored alerting)](#cve-image-scanning) | IMPLEMENT_MODIFIED | M, ~6-8h (module + alerts + first-scan baseline tuning) | vulcan runs 18 distinct container images (5 root + 13 rootless across 12 lingering users), all on moving tags with zero digest pinning, and nothing scans any of them for CVEs. I recommend a weekly trivy oneshot (trivy 0. |
| [Config-Drift Auditing (tiered, non-auditd)](#config-drift-auditing) | IMPLEMENT_MODIFIED | M, ~6-8h | The system already has whole-tree file-integrity (AIDE) plus a per-service schema-drift probe (openclaw-config-drift-check), but the two highest-value mutable config artifacts — Home Assistant's hand-edited YAML and Node |
| [Port-Drift Detector — Listening-Socket Posture vs the Curated Registry](#port-drift-detector) | IMPLEMENT_MODIFIED | S/M — 4-6h (collector + parser + one alert + registry-lint g | The gap: nothing today reconciles live listening sockets against the curated `docs/ports.txt` registry, so a service that starts binding a NEW wildcard (0.0.0.0/::) port — the high-signal "something is suddenly internet- |
| [Purging HA attribute-string series from the VictoriaMetrics TSDB](#ha-vm-str-purge) | IMPLEMENT | S, ~2-3h (relabel file + wiring + verify); +1h if the option | Home Assistant's influxdb push writes 1,405 string-attribute series (`*_str`: friendly_name, icon, device_class, attribution, ...) into VictoriaMetrics — 60% of the entire 2,337-series TSDB — none of which any dashboard, |
| [pg_stat_statements: per-query latency telemetry for the shared PostgreSQL 17 instance](#pg-stat-statements) | IMPLEMENT | M, ~4-6h (1h config, 1h custom query + alert authoring, 1h b | Today the shared PG 17.10 instance (26 user DBs, 1739 active pg_ series) has NO per-query latency: PostgreSQLSlowQueries keys off block reads, not exec time, and log_min_duration_statement=1000ms only writes text logs no |
| [microVM Guest Visibility: Host-Side Cgroup/Volume Gauges Now, Guest node_exporter Deferred](#microvm-guest-exporters) | IMPLEMENT_MODIFIED | S — 3-4h for Option A (one exporter module + 4 alerts + port | The two AI microVMs (openclaw, hermes) have zero in-guest metrics in Prometheus today, but the brief's headline gap — "guest disk fill" — does NOT exist: both guests run a tmpfs root (RAM-backed, ~1.5G, 2% used) with all |
| [Moving-Tag Container Image Staleness &amp; Update-Drift Monitoring](#image-staleness-drift) | IMPLEMENT_MODIFIED | S–M, ~4–6h (collector + alerts + per-image updater instrumen | Vulcan runs 13+ rootless quadlet containers, all on moving tags (`:latest`/`:main`/`:stable`/`:main-stable`/`:release`, plus openproject's pinned-major `:16`). The original "images silently drift, never refreshed" framin |
| [Direct blackbox probe of the hera MLX/llama-swap backend (Hermes chat's terminal dependency)](#mlx-hera-probe) | IMPLEMENT | S, ~2-3h | Hermes Discord chat's terminal dependency is the llama-swap/MLX model router on hera (hera.lan:8080), and today nothing probes it directly: when it dies, three downstream alerts (HermesAskFailing, HermesE2eChatFailing, H |
| [Email FTS (Xapian/flatcurve) index-staleness monitoring + formal retirement of DovecotHighConnectionCount](#email-fts-staleness) | IMPLEMENT | S/M — ~3-4h (one collector module mirroring dovecot-imapsiev | Dovecot full-text search runs on flatcurve (Xapian) with fts_autoindex=yes, but nothing detects when the index falls behind delivered mail — a silent-correctness gap (search returns stale/no hits while the service stays  |
| [B2 Offsite Backup Probe — Collector-Run Freshness + Optional Credential-Free Reachability Canary](#b2-offsite-probe) | IMPLEMENT_MODIFIED | S — 0.5-1.5h (freshness rule ~30min; optional blackbox probe | B2 credential + reachability validation is already exercised every 6h: the `restic-metrics` collector does a real authenticated B2 round-trip per repo (`restic snapshots` + 3 `stats` calls over `s3:s3.us-west-001.backbla |
| [Discord WS Liveness Signal Parity (OpenClaw ↔ Hermes)](#discord-ws-parity) | IMPLEMENT_MODIFIED | S — 2-3h (debounce + noise hardening of existing canary; no  | The census flagged that OpenClaw and Hermes detect a dead Discord gateway with different, non-equivalent signals: OpenClaw parses gateway-vm.log for the relative order of positive/negative WS events (openclaw_discord_ws_ |

## Consolidated operator decisions

The full rationale for each lives in its chapter; this is the checklist.


**Nagios's future: retire to a thin ICMP-vantage shell, or keep as-is**
- PRIMARY: Do you want to keep the Nagios web UI/visual map at all? If you never open https://nagios.vulcan.lan, Option B-lite removes the entire nginx-vhost + htpasswd + fcgiwrap + CGI maintenance surface. If you value the topology map as a human dashboard, choose Option A (status quo) and we change nothing.
- Should ICMP coverage of the flaky IoT devices (locks, thermostats, sensors — currently commented OUT of blackbox_icmp on purpose) actually be PAGED on, or was their exclusion deliberate noise-control? If deliberate, the only true loss from retiring Nagios is its own un-paged dashboard, and Option B becomes near-free.
- For the HA per-integration health check (the one genuinely-unique signal): keep it as a tiny standalone textfile collector feeding Prometheus, OR move integration-loaded alerting fully into Node-RED to match the existing HA-alerting policy? Both are cheap; this picks the owning stack.
- If Option B: keep the parent/child UNREACHABLE-vs-DOWN distinction? Prometheus/blackbox has no topology model, so a router outage would fan out to N child-device alerts instead of one. Acceptable, or do we add a tiny inhibition rule keyed on the gateway probe?

**Monitoring egress from the OpenClaw & Hermes agent microVMs**
- TIER 3 (enforcement) GO/NO-GO: OpenClaw egress is currently port-UNRESTRICTED (the openclaw-egress LOG rule logs but does NOT drop — DPT=80 plaintext egress was observed live). Tightening it to the Hermes model (443/53-only ACCEPT then DROP) would break any agent skill that fetches non-443 URLs during web research. Recommend: bring OpenClaw to parity with Hermes (443/53 allowlist) but NOT a per-domain IP allowlist. Confirm you want the port-allowlist symmetry, or explicitly keep OpenClaw wide-open-but-logged.
- DNS-domain visibility in Loki/alerts: the new-destination alert annotation will name the queried FQDN (e.g. a newly-seen exfil domain) — that is the whole point of the signal, but it means a domain string appears in Alertmanager/Discord/email. Confirm that is acceptable (it is not a credential, but it is browsing metadata). Counts-only mode is available as a fallback if you'd rather not surface domains.
- Baseline-allowlist maintenance model: the DNS allowlist is a checked-in list in the loki-rule (or a recording-rule-derived 14d set). A static list means you re-approve when the agent legitimately reaches a new service. Confirm static-checked-in (recommended, auditable) vs auto-learned-14d-window (lower toil, but an attacker who is patient can poison the baseline).

**Container Image CVE Scanning (Trivy textfile exporter + severity-floored alerting)**
- Severity floor for the PAGING tier: my recommendation is fixable CRITICAL+HIGH on internet-exposed images only (today = shlink). Confirm, or widen to all LAN web apps (open-webui, litellm, teable, wallabag).
- Cadence: weekly (Sun 04:00) vs daily. I recommend weekly — CVE disclosure-to-exploit windows rarely warrant daily re-scan of self-hosted LAN apps, and weekly keeps DB-download churn and scan load low.
- Whether to also scan the on-demand zimit images and the johnw user store (I exclude both by default: zimit spawns transient per-job containers, johnw is the human account). Confirm exclusion.
- Accepted-CVE acknowledgment mechanism: I propose a static allowlist file of CVE IDs (TRIVY .trivyignore) committed in-repo so accepted findings drop out of the count. Confirm you want this vs a label-only annotation.

**Config-Drift Auditing (tiered, non-auditd)**
- Crown-jewel file list: I propose 7 (HA configuration.yaml/automations.yaml/scripts.yaml/scenes.yaml, NR flows.json, /etc/ssh/sshd_config, /etc/nixos/secrets.yaml). Confirm or add/remove. (Note: configuration.yaml is mutated on EVERY rebuild by the db_url injection at home-assistant.nix:1130 — it must be sha-normalized or excluded from the sha tier, see 5.)
- AIDE drift alert severity: should AIDEChangesDetected stay warning (current) or be downgraded to a daily-digest-only metric? It currently never fires because aide-update re-baselines 60s after every rebuild — decide whether you want a real change-outside-deploy-window alert (more work) or just a dashboard panel.
- Deploy-window suppression source for the crown-jewel tier: use the existing system_current_generation_build_timestamp_seconds (covers HA YAML, which only changes via rebuild + manual edits) — but Node-RED flows.json changes on every NR UI deploy with NO nix rebuild. Accept that flows.json drift fires on legitimate NR deploys (and is auto-acknowledged by a companion 'last NR deploy' anchor), or leave flows.json as mtime-tracked-only (no alert)?

**Port-Drift Detector — Listening-Socket Posture vs the Curated Registry**
- Alert scope: page ONLY on a new wildcard (0.0.0.0/::) listener (recommended — rare + high-signal), or also weekly-digest loopback drift? Recommend wildcard-pages + loopback-as-info-gauge-only.
- ports.txt as source of truth: accept the collector also LINTS the registry (emits `port_registry_stale_entries` for registered ports with no live listener — found 6 today, all explainable). Lint = info gauge, never pages. OK?
- jellyfin UDP 7359 is a genuine registry omission (wildcard, non-ephemeral). Add it to ports.txt as part of the one-time reconciliation, or treat the detector's first run as the trigger to add it? (Read-only session cannot edit; flag for implementer.)
- Ephemeral floor: treat ports >= 32768 as ephemeral and exclude from drift entirely (kernel ip_local_port_range default). Confirm — alternatively key on process-has-a-registered-primary-port instead of a numeric floor.

**Purging HA attribute-string series from the VictoriaMetrics TSDB**
- Drop set scope: conservative `*_str` only (1,405 series / 60%) vs the curated attribute-suffix set that also catches the ~77 non-`_str` metadata series like `%_friendly_name`, `W_Status` (1,482 / 63%). Recommended: the curated set — it is the true 'this is HA metadata not a measurement' signature and the residual is hand-verified to contain real numeric attributes worth keeping.
- Retroactive purge of the 1,405 already-stored `_str` series via the VM delete API: yes/no. This is IRREVERSIBLE (no Enterprise downsampling to fall back on) and saves only a slice of 217M on disk. Recommended: NO for now — let the relabel drop bleed them out via 100y retention naturally, or revisit only if cardinality/UI clutter becomes a real pain.
- Whether to ALSO fix the influxdb integration's hand-edited YAML exclude block in /var/lib/hass/configuration.yaml (defense in depth, stops the push at the source). Note this file is hand-maintained, NOT nix-managed — editing it is out-of-band from a rebuild and is the operator's call.

**pg_stat_statements: per-query latency telemetry for the shared PostgreSQL 17 instance**
- Restart window: confirm pg_stat_statements lands in the NEXT planned maintenance switch (the shared_preload_libraries change forces a full PostgreSQL restart = ~26 DBs + 33 dependent units briefly down ~2-10s). It must NOT ride a routine unattended switch.
- track scope: spec recommends track=top (default, top-level statements only) to bound shared memory and exclude nested/function-internal SQL. Confirm you don't want track=all (which would multiply cardinality and capture PL/pgSQL internals).
- rolname label: spec includes rolname (41 roles) as a label for blast-attribution. Confirm role names are acceptable in Prometheus labels (they are NOT secrets — they're DB usernames already visible in pg_hba/config), or drop to queryid+datname only to shrink cardinality.

**microVM Guest Visibility: Host-Side Cgroup/Volume Gauges Now, Guest node_exporter Deferred**
- Approve the guest tmpfs-fill probe reusing the existing /root/.ssh/hermes-debug key over the bridge (read-only `df`/`free` only), OR keep the exporter host-cgroup-only and skip in-guest tmpfs visibility entirely. The debug key is ephemeral and slated for removal per hermes-vm.nix:1001 — decide whether to (a) reuse it now, (b) provision a dedicated read-only probe key, or (c) ship cgroup-only and add the probe when the proper Phase-2 probe key lands.
- Confirm Option B (full guest node_exporter) stays deferred until the next natural VM restart (models.nix change or host reboot), rather than scheduling a dedicated restart. I recommend deferral; the cgroup+tmpfs gauges cover the operationally important cases.
- Pick the guest-OOM detection signal: (a) host-side `journalctl -k` Loki rule matching the QEMU process's `Killed process` / oom lines (no guest change, but noisy to author), vs (b) the tmpfs-fill probe + cgroup MemoryCurrent-near-ceiling heuristic (recommended, simpler). I recommend (b).

**Moving-Tag Container Image Staleness &amp; Update-Drift Monitoring**
- Outdated threshold tiers: spec proposes `container_image_outdated == 1 for: 7d` → warning. Confirm 7d (one full update cycle missed) vs the brief's suggested 30d (looser, fewer pages). Recommended: 7d, because the nightly updater means a 7d-stale moving-tag image implies the pull has been failing every night for a week.
- Whether to ALSO instrument the existing `update-containers` script to emit per-image pull-result metrics (recommended, ~1h, the cheapest high-value win) or ship only the standalone staleness collector. Recommended: do both — they answer different questions (did the pull fail? vs is the image behind upstream?).
- openproject `:16` (pinned major) — treat as a moving tag (track drift within the 16.x line, fires when a 16.x.y patch ships) or exclude from outdated-alerting and only emit the age gauge? Recommended: track it like the others; a 7d-behind 16.x patch is still worth a warning.
- Adopting podman's native `io.containers.autoupdate=registry` labels + enabling `podman-auto-update.timer` (currently linked/inactive) is a SEPARATE decision and is NOT recommended here — it would duplicate the existing `update-containers.timer` path and remove the controlled pull-then-restart-only-if-changed logic. Flagged for awareness, not action.

**Direct blackbox probe of the hera MLX/llama-swap backend (Hermes chat's terminal dependency)**
- Severity of MLXBackendDown: recommend `warning` (not critical) because the e2e/ask probes already page critical for the user-visible symptom and the self-heal daemon can't restart hera anyway — this rule is a cause-isolation annotation, not a new page. Confirm warning vs critical.
- Whether to also add a `for: 30m`-style `MLXBackendDegraded` warning when probe_success flaps (rate < 1 but > 0) — I left it out to keep scope tight; say if you want flap detection too.

**Email FTS (Xapian/flatcurve) index-staleness monitoring + formal retirement of DovecotHighConnectionCount**
- Threshold pair: ship 48h warning / 7d critical (recommended, generous vs the observed 0 s baseline and the daily-rebuild cadence) — or tighten the warning to 24h if you want faster notice of a wedged indexer-worker.
- Scope: monitor johnw + assembly + bia (recommended, -A loop) vs johnw-only. All three already index cleanly; the cost difference is one extra loop iteration.
- Optional remediation hook: ship a MONTHLY `doveadm fts rescan -A` sanity oneshot (recommended off-by-default / commented) — it is I/O-heavy on the 800MB+ INBOX index and only earns its keep if the lag alert ever fires. Decide whether to wire it now or leave it as a documented runbook.

**B2 Offsite Backup Probe — Collector-Run Freshness + Optional Credential-Free Reachability Canary**
- Ship just the ResticMetricsStale freshness rule (closes the real gap, zero new attack surface), or ALSO add the credential-free B2 S3 blackbox probe for network-vs-auth disambiguation? (Recommend: both; the probe is ~45 min and rides existing blackbox plumbing.)
- B2 app-key expiry tracking: app keys do NOT expire by default. Confirm no TTL was set at key creation. If a TTL was set, a tiny expiry-timestamp collector is warranted; if not (the default), explicitly RETIRE expiry tracking as a non-gap.
- Optional: lower the ResticNoRecentSnapshot threshold conversation — current 30h is fine, but note the collector's 6h cadence means a single missed collector run already delays detection ~6h. No change recommended.

**Discord WS Liveness Signal Parity (OpenClaw ↔ Hermes)**
- Accept that signal-parity is unachievable (different runtimes: Hermes=Python/discord.py, OpenClaw=upstream Node/TS) and the goal should be RETIRED, replaced by 'make the OpenClaw log-derived signal quiet and trustworthy in place'. Confirm you do not want me to patch upstream OpenClaw TS source (the only path to a true heartbeat-ACK).
- Confirm the debounce thresholds: I recommend raising OpenClawDiscordWsDown `for:` from 3m to 5m and adding a `min_over_time(...[5m])==0` confirmation, so a single noisy sample cannot trip a VM restart. Pick 5m or keep 3m.
- Optional: approve adding an explicit openclaw_discord_ws_zombie gauge (positive-event age exceeds the largest-ever healthy gap) as a SECOND, independent zombie detector. This is the closest semantic analog to Hermes's deaf-but-connected catch, but it needs a measured baseline of the healthy positive-event gap first.

---


<a id="nagios-topology-decision"></a>

# Nagios's future: retire to a thin ICMP-vantage shell, or keep as-is

**Verdict:** NEEDS_USER_DECISION · **Effort:** M — ~6-9h for Option B-lite (port 2 unique signals + decommission), or S/0h for Option A status-quo

**Key live evidence:** Nagios runs live on vulcan (active, enabled, up since 2026-06-08); status.dat = 253 servicestatus blocks + 24 hoststatus blocks (404KB, nagios:nagios 0664). · Phase-4 bridge is live and fresh in Prometheus: nagios_services_critical_total=1, nagios_hosts_down_total=1, nagios_stale_results_total=0, nagios_status_parse_success=1, run timestamp age 52s. Matches the brief's '1 host down, 1 svc critical'. · The live down items, by CHECK TYPE only (hostname suppressed): 1 HOST in HARD state via check-host-alive (ICMP), 1 SVC in HARD CRITICAL via check_ping (ICMP). Both are pure network-reachability — no application logic. · Prometheus blackbox HAS an icmp_ping module and a blackbox_icmp job with EXACTLY 24 targets, reporting 0 down — yet Nagios's 24 hosts show 1 down. The blackbox_icmp target list (blackbox-monitoring.nix:396-449) comments OUT ~15 IoT devices (locks, nests, rings, sprinkler, vacuum, solar, flume). So Nagios pings devices Prometheus deliberately does not. · Nagios check_command tally (modules/services/nagios.nix + private nagios/hosts.nix = 23 host tuples): check_ssl_cert 34, check_http 12, check_tcp 6, check_systemd_service 4, check_openclaw_plugin 4, check_backup_age 3, plus singletons for zfs/podman/dns/ssh/smtp/imap/git-workspace/homeassistant. · Every non-ICMP check class is duplicated in Prometheus with live series: node_systemd_unit_state=2870, probe_ssl_earliest_cert_expiry=47 (+certificate-exporter.nix), blackbox_https_local=41 targets, container metrics=20, zfs pool=7, openclaw_*=42, backup-ish=113, git_workspace_*=9, aide-metrics.nix=7, atd_*=4, qdrant via blackbox https://qdrant.vulcan.lan.

## 1. TL;DR

Three alerting stacks coexist on vulcan: Prometheus/Alertmanager (infra), Nagios (legacy), and Node-RED (Home-Assistant logic). The phase-4 `status.dat` bridge (`modules/monitoring/services/nagios-status-exporter.nix`) already surfaces Nagios's verdict as counts in Alertmanager, so Nagios's *visibility* is solved. The open question is whether Nagios still earns its maintenance surface.

A full check-type inventory says: **no, almost entirely.** Of Nagios's 253 live service checks, ~95% are exactly duplicated by Prometheus exporters and blackbox probes that all exist and report live data today. Only two signals are genuinely Nagios-only: (1) the **HA per-integration-loaded health check** (HA `config_entries` health is pushed to *neither* Prometheus nor the VM TSDB, and HA alerting deliberately lives in Node-RED), and (2) **ICMP reachability of the flaky IoT devices** that `blackbox_icmp` deliberately comments out — which is precisely what today's live `1 host down + 1 PING critical` is.

**Recommendation: Option B-lite** — port the two unique signals to Prometheus/blackbox/Node-RED, then decommission Nagios's heavy web/CGI/htpasswd/fcgiwrap stack, keeping the bridge running until the cutover is validated. Effort **M (~6-9h)**. This is a `NEEDS_USER_DECISION` because the one thing the inventory *cannot* decide is whether you personally use the Nagios topology map as a human dashboard.

## 2. Current state & evidence

**Nagios is alive and busy.** `nagios.service` is active+enabled (up since 2026-06-08). `status.dat` (404KB, `nagios:nagios 0664`) holds **253 `servicestatus` blocks + 24 `hoststatus` blocks**. The private `nagios/hosts.nix` (gitignored) defines **23 host tuples** (`hostname`/`address`/`alias`/`parent`, 3 with custom ping thresholds) consumed by `mkMonitoredHost` (nagios.nix:493-540), each generating a host + a `PING` service.

**The bridge works.** Live Prometheus values: `nagios_services_critical_total=1`, `nagios_hosts_down_total=1`, `nagios_stale_results_total=0`, `nagios_status_parse_success=1`, run-timestamp age 52s. Alert rules in `modules/monitoring/alerts/nagios.yaml`: `NagiosServicesCritical` (`>0 for 15m`), `NagiosHostsDown` (`>0 for 10m`), `NagiosResultsStale` (`>5 for 30m`), `NagiosStatusExporterFailed`, plus two service-liveness rules keyed on `node_systemd_unit_state{name="nagios.service"}`.

**What the live findings actually are (CHECK TYPE only, hostname suppressed):** one HOST in HARD DOWN via `check-host-alive`, one SVC in HARD CRITICAL via `check_ping`. Both are pure ICMP reachability — no application logic.

**Check-type inventory and Prometheus overlap (all numbers live):**

| Nagios check (count) | Prometheus equivalent (live series) | Class |
|---|---|---|
| `check_systemd_service` (4) + `_conditional` (2) + `_ondemand` (1) | `node_systemd_unit_state` (**2870**) | dup |
| `check_ssl_cert` (34) + `_external` (1) | `probe_ssl_earliest_cert_expiry` (**47**) + `certificate-exporter.nix` | dup |
| `check_http`/`check_https` (13) | `blackbox_https_local` (**41 targets**) + http/https jobs | dup |
| `check_podman_container` (1) + `_rootless` (1) | container metrics (**20**) | dup |
| `check_zfs_pool` (1) | zfs pool metrics (**7**) | dup |
| `check_backup_age` (3) | backup last-success triads (**113** backup-ish) | dup |
| `check_openclaw_plugin` (4) + `_ready_age` (1) | `openclaw_*` (**42**) | dup |
| `check_git_workspace_sync`/`stale` (2) | `git_workspace_*` (**9**) + `git-workspace-exporter.nix` | dup |
| `check_postgres` | `pg_*` | dup |
| AIDE module (`check_aide`) | `aide-metrics.nix` (**7**) | dup |
| atd module (`check_atd_queue`) | `atd_*` (**4**) | dup |
| qdrant module (`check_qdrant_health`) | blackbox `https://qdrant.vulcan.lan` (in `blackbox_https_local`) | dup |
| `check_imap(s)`/`smtp(s)`/`dns`/`ssh`/`tcp` (singletons) | blackbox tcp/dns + dovecot/postfix `node_systemd_unit_state` + `dns_internal` | dup |
| `check_ping` (24 hosts) | `blackbox_icmp` (**24 targets, 0 down**) — **different host SET** | partial |
| **HA per-integration health** (1) | **NONE** — `homeassistant_*` = 0 series in Prometheus AND VM TSDB | **unique** |
| **network topology** (parent/child UNREACHABLE vs DOWN) | NONE — blackbox has no parent model | **unique-ish** |

**The Option-C steelman is false.** Nagios runs *on vulcan*, the same host as Prometheus+blackbox. It is **not** an independent vantage. The reason Nagios shows a host down while `blackbox_icmp` shows 0 down is **target-set selection**, not a different network path: `blackbox-monitoring.nix:396-449` deliberately comments out ~15 IoT devices (locks, nests, rings, sprinkler, vacuum, solar, flume). Today's down host is one of those devices Prometheus chose not to probe. Prometheus didn't "miss" it from a worse vantage; it was told not to look.

**Maintenance surface (the cost of keeping it):** `nagios.service` + `nagios-htpasswd` generator (nagios.nix:2546) + nginx vhost `nagios.vulcan.lan` with `basicAuthFile /var/lib/nagios/htpasswd` (2583) + `services.fcgiwrap.instances.nagios` (2646) + a phpfpm pool + the CGI fastcgi block (2603-2621) + `nagios-daily-report` email timer + 4 custom check modules. That is a CGI/htpasswd/fcgiwrap stack maintained for a UI that the Prometheus/Grafana/Alertmanager stack already replaces functionally.

## 3. Design options

### Option A — STATUS QUO+ (keep both, lean on the bridge)
Change nothing. The bridge gives you a single Alertmanager line if Nagios ever sees a hard problem, so you can ignore the Nagios UI day-to-day and still be paged.
- **Pro:** zero work, zero risk, keeps the topology map and parent/child UNREACHABLE logic for free, keeps the IoT ICMP coverage.
- **Con:** permanent dual maintenance — every new service is configured twice (Prometheus + Nagios), every NixOS upgrade carries the CGI/fcgiwrap/htpasswd surface, and `nagios.yaml`'s `NagiosServicesCritical`/`NagiosHostsDown` will chronically fire on the IoT-device flapping that the rest of the fleet was tuned to ignore (see §5).

### Option B-lite — MIGRATE THE 2 UNIQUE SIGNALS, DECOMMISSION THE WEB STACK (RECOMMENDED)
Port the only two things Nagios uniquely provides, then remove the heavyweight surface:
1. **HA per-integration health** → a tiny textfile collector (reuses the existing SOPS token, emits a per-integration `0/1` gauge + alert) *or* a Node-RED check matching existing HA-alerting policy.
2. **IoT ICMP coverage** → uncomment the desired devices in `blackbox_icmp` (the module already supports them) and add a `for:`-buffered down alert; optionally a gateway-keyed inhibition to preserve the "child unreachable because parent down" behaviour.
Then remove `nagios.service`, the nginx vhost, htpasswd, fcgiwrap, phpfpm pool, daily-report, and the 4 redundant check modules. Keep `nagios-status-exporter` + `nagios.yaml` until the migration is validated, then retire them too.
- **Pro:** eliminates the dual-config tax and the entire CGI/auth surface; everything lives in one stack; preserves the only real signals.
- **Con:** loses the visual topology map; one-time migration work + a NixOS rebuild; the parent/child model becomes flat unless you add inhibition.
- **WHY recommended:** the inventory proves the unique set is *tiny* (2 items, both portable in <2h each) while the maintenance surface is large. This is the textbook condition for retirement.

### Option C — NAGIOS AS A SECOND INDEPENDENT FAILURE DOMAIN
Deliberately keep Nagios as a redundant watcher.
- **Steelman:** "It caught a host down that Prometheus didn't." **Investigated and refuted** (§2): same host, same vantage; the difference is target-set selection, fully reproducible by uncommenting blackbox targets. A truly independent vantage would require Nagios on a *different* host (e.g. hera), which is not the current deployment.
- **Verdict:** not worth it as deployed. If you genuinely want a second failure domain, the right move is a *remote* blackbox/heartbeat (which the watchdog dead-man already partially provides via an external ping URL), not keeping a co-located Nagios.

## 4. Recommended implementation (Option B-lite)

### Phase 1 — Port the HA per-integration check (the one true unique signal)
**Pick one owner (operator decision):**

**4a. Prometheus textfile-collector flavor** (keeps it in the infra stack). New file `modules/monitoring/services/homeassistant-integration-exporter.nix`, modeled on `nagios-status-exporter.nix`:
- Reuse the existing `sops.secrets."monitoring/home-assistant-token"` (already declared; do not add a secret).
- A oneshot (`User=root` or a dedicated dynamic user with `LoadCredential` of the token — prefer `LoadCredential` so the token is not in the unit env), curls `http://127.0.0.1:8123/api/config/config_entries/entry` (the same endpoint the Nagios script uses), and emits **derived booleans only**:
  ```
  # HELP homeassistant_integration_loaded 1 if integration domain is loaded and not in error
  # TYPE homeassistant_integration_loaded gauge
  homeassistant_integration_loaded{domain="august"} 1
  homeassistant_integration_loaded{domain="nest"} 1
  ... (one line per domain in the watched list)
  # HELP homeassistant_integration_check_success 1 if the API probe itself succeeded
  homeassistant_integration_check_success 1
  ```
  **Secret-safety:** emit ONLY the `0/1` gauge and the domain label (domain names are public integration identifiers, not secrets). Never write the token, entry IDs, titles, or API response bodies to the textfile. Atomic `tmp+os.replace` into `/var/lib/prometheus-node-exporter-textfiles/homeassistant_integrations.prom`, mode 0644.
- Timer `OnUnitActiveSec=5min` (HA integrations don't fail-and-recover faster than that; matches the existing Nagios cadence).
- Alert in a new `modules/monitoring/alerts/homeassistant-integrations.yaml` (auto-discovered):
  ```yaml
  - alert: HomeAssistantIntegrationUnloaded
    expr: homeassistant_integration_loaded == 0
    for: 15m          # baseline: HA reload/restart re-loads integrations in <2min;
                      # 15m matches NagiosServicesCritical and survives a rebuild-restart
    labels: { severity: warning }
  - alert: HomeAssistantIntegrationCheckFailed
    expr: homeassistant_integration_check_success == 0
    for: 15m
    labels: { severity: warning }
  ```

**4b. Node-RED flavor** (matches the existing HA-alerting policy — see memory `project_ha_safety_nodered`). A small flow on the Away/Debug tab that polls `config_entries` and pushes an iPhone notification on a domain dropping to error. No Prometheus wiring. Cheaper to own but lives outside the metrics fleet.

> Recommendation between 4a/4b: **4a**, because integration health is fleet infra (you want it in the same Alertmanager pipeline as everything else and on the Grafana boards), and the textfile pattern is already a house idiom.

### Phase 2 — Port IoT ICMP coverage into blackbox
In `modules/services/blackbox-monitoring.nix` (the `blackbox_icmp` `static_configs`, lines ~404-428), **uncomment the IoT `.lan` targets you actually want paged on** (the always-off-able ones can stay commented). Then add to `modules/monitoring/alerts/network.yaml`:
```yaml
- alert: BlackboxICMPHostDown
  expr: probe_success{job="blackbox_icmp"} == 0
  for: 10m            # baseline: matches NagiosHostsDown for:10m; long enough to ride
                      # out a single missed ICMP cycle on a sleepy IoT device
  labels: { severity: warning }
```
**Topology preservation (optional, addresses decision #4):** add an inhibition rule so a gateway/router probe failure suppresses the child-device pages, replicating Nagios's UNREACHABLE-vs-DOWN logic:
```yaml
# alertmanager inhibit_rules (modules/monitoring/.../alertmanager config)
- source_matchers: ['alertname="BlackboxICMPHostDown", instance=~"asus-.*|.*-ap.lan"']
  target_matchers: ['alertname="BlackboxICMPHostDown"']
  equal: ['job']
```
Without this, a router outage fans out to N device alerts instead of one — acceptable for a home LAN, but the inhibition is cheap insurance.

> **Note on the watched-IPs `host_group` relabel bug** (memory `7193`): the existing relabel regex at blackbox-monitoring.nix:469 matches `192.168.*` literal IPs but the local probes use `.lan` hostnames, so the `local` `host_group` label never attaches. Fix the regex to also match `.*\.lan` while you are in this file, so any per-group alerting/inhibition works.

### Phase 3 — Decommission Nagios
Use the existing `/remove-service` discipline. Files to edit/remove:
- `hosts/vulcan/default.nix`: drop the imports of `modules/services/nagios.nix`, `modules/monitoring/nagios-daily-report.nix`, and the 4 check modules (`aide-nagios-check.nix`, `homeassistant-nagios-check.nix`, `services/qdrant-nagios.nix`, `services/atd-nagios.nix`). **Keep** `modules/monitoring/services/aide-metrics.nix` and the atd Prometheus path — those are the surviving Prometheus equivalents.
- nginx: the `nagios.vulcan.lan` vhost, `nagios-htpasswd` service, `services.fcgiwrap.instances.nagios`, and the phpfpm pool all disappear with `nagios.nix`.
- `docs/ports.txt`: remove any nagios entry (none found in a quick grep, so likely already absent — verify).
- **Keep for now:** `nagios-status-exporter.nix` and `alerts/nagios.yaml`. They become inert once `nagios.service` is gone (`nagios_status_parse_success` will go to 0 → `NagiosStatusExporterFailed` fires). That firing is your **cutover signal** that the bridge has nothing left to watch — at which point remove the exporter + `nagios.yaml` in a follow-up commit. (Do NOT remove them in the same commit, so a rollback restores the safety net.)
- The SOPS secret `monitoring/home-assistant-token` is **retained** — it now feeds the Phase-1 HA exporter, not Nagios.

### Deploy choreography
1. Commit Phase 1 + Phase 2 (additive only) → `nixos-rebuild switch`. Restart cost: node-exporter picks up the new textfile automatically; blackbox/Prometheus reload scrape config (no service interruption). Verify `homeassistant_integration_loaded` and the new `blackbox_icmp` targets are live and green before proceeding.
2. After 24h of clean new-rule data, commit Phase 3 (remove Nagios + web stack), keeping exporter+rules. Restart cost: nginx reload (drops the vhost), `nagios.service` stop. Verify `systemctl --failed` is empty.
3. Once `NagiosStatusExporterFailed` fires (confirming the bridge is watching a dead source), commit the exporter+`nagios.yaml` removal.
- **Rollback:** Phase 3 is a pure NixOS generation rollback (`nixos-rebuild switch --rollback` or pin the prior commit); the gitignored `nagios/hosts.nix` is untouched, so a revert fully restores Nagios.

## 5. Noise & failure-mode analysis

- **Option A chronic-firing risk (the strongest argument against status quo):** `NagiosHostsDown`/`NagiosServicesCritical` fire on `>0`. Nagios pings IoT devices the rest of the fleet deliberately excludes because they flap (battery locks, sleepy sensors). Today's live `1 down + 1 critical` is exactly this. Under Option A you either chronically ack these or widen the `for:` — either way you've recreated the noise-tuning the coverage plan did once already, in a second stack.
- **Phase-1 HA exporter false positives:** an HA restart briefly unloads integrations. The `for:15m` rides over normal reloads (HA re-loads in <2min). The `homeassistant_integration_check_success` guard prevents a transient API blip (HA down for an upgrade) from looking like every integration failing — when the probe itself fails you get ONE alert, not N.
- **Phase-2 ICMP false positives:** sleepy IoT devices miss occasional ICMP. `for:10m` (one device may skip a couple of cycles) is the floor; if a specific device proves chatty, leave it commented (its exclusion was deliberate) rather than raising the global `for:`.
- **Silent-break risks:** the HA exporter could silently emit stale data if the curl hangs — mitigate with a curl `--max-time 10` and the `_check_success=0` on timeout (so staleness surfaces as an alert, not silence). The `*_run_timestamp_seconds`-style freshness gauge from the bridge pattern should be copied so a stuck timer is detectable.
- **Topology loss:** without the Phase-2 inhibition rule, a gateway outage produces a fan-out. Quantify: ~7-15 child devices → that many simultaneous warnings. Annoying but not paging-storm severity on a home LAN; the inhibition rule removes it entirely if desired.

## 6. Security considerations

- **HA token:** the Phase-1 exporter reuses the *existing* `sops.secrets."monitoring/home-assistant-token"`. Prefer `LoadCredential=` over reading the path in-script so the token never lands in the unit environment or the process arg list. The textfile output emits **only** `0/1` gauges + public domain names — never the token, entry IDs, entry titles, or API bodies. This mirrors the bridge's "counts only" discipline.
- **Private topology:** this entire investigation used `grep -c` and field-suppressed `awk` against `nagios/hosts.nix` and `status.dat`; no hostname, IP, alias, or plugin output was read or emitted. The decommission removes the *consumer* of `nagios/hosts.nix` but leaves the gitignored file in place (so rollback works and topology stays private). If Phase-2 uncomments IoT targets in `blackbox-monitoring.nix`, those `.lan` names are already in the (private-by-comment) source and are not newly exposed.
- **Attack-surface reduction is a security WIN:** decommissioning removes a CGI/fcgiwrap/phpfpm/htpasswd web stack — historically a higher-CVE surface than a pull-based exporter. Fewer privileged web endpoints on vulcan.
- **No new ports.** Phase 1 is a textfile collector (job=node); Phase 2 reuses the existing blackbox exporter. ports.txt unchanged.

## 7. Effort & sequencing

- **Option A:** S / 0h (but pay the recurring tax forever, and likely tune `nagios.yaml` `for:` to silence IoT flapping — call it ~1h of recurring annoyance amortized).
- **Option B-lite:** **M / ~6-9h.** Phase 1 HA exporter ~3h (script + alert + verify, the SOPS plumbing already exists). Phase 2 ICMP ~1-2h (uncomment + alert + optional inhibition + the host_group regex fix). Phase 3 decommission ~2-3h (careful `/remove-service` across nginx/fcgiwrap/phpfpm + two-stage bridge retirement + validation). Spread across ≥2 rebuilds with a 24h soak.
- **Prerequisites:** none new — the SOPS token, blackbox exporter, textfile collector dir, and alerts auto-discovery all exist. **Do this AFTER the cold-reboot validation** of the in-flight boot/switch fixes (memory `project_boot_switch_robustness_audit`) so you're not removing services during an unsettled boot path.
- **Unblocks:** ends the dual-config tax (one stack per new service), shrinks the NixOS attack/maintenance surface, and retires the last `nagios.yaml` dead-rule risk. Closes the three-stack ambiguity down to two (Prometheus infra + Node-RED HA-logic), which is the coherent end-state.

## 8. Decisions required from the operator

- **Do you ever open the Nagios web UI / topology map as a human dashboard?** If no → Option B-lite removes the whole CGI/htpasswd/fcgiwrap surface. If yes → Option A and we change nothing.
- **Should the flaky IoT devices (currently commented out of `blackbox_icmp`) actually be paged on, or was their exclusion deliberate noise-control?** If deliberate, the only real loss from retiring Nagios is its un-paged dashboard, and Option B becomes near-free.
- **Who owns the HA per-integration check after migration** — a Prometheus textfile exporter (4a, recommended) or Node-RED (4b, matches existing HA-alerting policy)?
- **Keep the parent/child UNREACHABLE-vs-DOWN distinction** via a gateway-keyed Alertmanager inhibition rule, or accept a flat fan-out on a router outage?


---


<a id="vm-agent-egress"></a>

# Monitoring egress from the OpenClaw & Hermes agent microVMs

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** M, ~6-8h for Tiers 1+2 (one build/switch). Tier 3 enforcement is a separate L decision.

**Key live evidence:** Enforcement already exists, asymmetrically: openclaw-microvm.nix:497-536 has chain openclaw-isolate (DROP private nets, RETURN only DNS+DNAT ports) + FORWARD LOG 'openclaw-egress:' on ALL new outbound (NO final DROP on the public path → port-unrestricted egress); hermes-microvm.nix:167-223 allows ONLY tcp/udp 443+53 then LOG 'hermes-egress-rejected:' then DROP. · Live iptables FORWARD counters confirm rules active: openclaw-egress LOG = 68 pkts/4448 bytes new-conns; hermes 443 ACCEPT = 2378 pkts/198K; hermes-egress-rejected LOG = 0 (Hermes stays inside its 443/53 allowlist). · VISIBILITY GAP: 178 'openclaw-egress' lines in the kernel journal/24h, ALL priority 6 (verified histogram {'6':178}); promtail.nix:174-180 drops journal priority 5-7; Loki query count_over_time({job="systemd-journal"} |= "openclaw-egress" [24h]) = 0 result sets. Egress log is being thrown away. (Same root cause as the P0#13 sshd fix.) · Volume signal is FREE: node_exporter already scrapes node_network_{receive,transmit}_bytes_total for device=br-openclaw, vm-openclaw, hermes-br0, vm-hermes (4 series live; vm-openclaw tx_rate≈386 B/s, vm-hermes≈227 B/s); 7-day history present (vm-openclaw series at T-7d = 4514089). · DNS signal is FREE and per-VM: Technitium dns_query_logs in Loki carries client_ip=10.99.0.2 (openclaw) and 10.99.1.2 (hermes) directly (NOT the bridge gateway), 284 streams total, line is JSON with a `domain` field; openclaw queried 57/24h, hermes 27/24h. Baseline is tiny: 10 distinct FQDNs / 8 registrable bases for openclaw in 24h (discord, github, npm, whatsapp, ntp, perplexity). Loki retains 30d (data back to 2026-05-12, 86 daily samples). · ZERO existing egress alerts: grep of alerts/*.yaml + loki-rules/*.yaml for egress/10.99/exfil/outbound returns only unrelated comment matches; openclaw.yaml has 14 alerts, hermes.yaml 13, none about egress.

## 1. TL;DR

The two autonomous-agent microVMs — **openclaw** (`10.99.0.2` on `br-openclaw`) and **hermes** (`10.99.1.2` on `hermes-br0`) — reach the internet via host NAT and already carry iptables isolation chains plus egress `LOG` rules. The gap the census flagged ("UNMONITORED outbound egress, exfiltration blast radius") is **half false and half real**: enforcement and logging *rules* exist, but the egress `LOG` lines are emitted at kernel **priority 6 (info)** and promtail drops priority 5–7, so **every egress log line is silently discarded — 0 lines reach Loki** (verified). Investigation also found that the two best signals are *already collected for free*: node_exporter scrapes per-VM byte counters on all four bridge/tap devices, and Technitium logs each VM's DNS queries into Loki keyed by the **real VM IP** (`client_ip="10.99.0.2"`), with a tiny, stable baseline (~10 distinct FQDNs/24h for openclaw). The recommendation is a mostly-rule-only **3-tier** build: T1 volume/connection alerts + a dedicated promtail bypass-scrape so the egress log lands in Loki; T2 a DNS new-destination anomaly alert against a 14-day allowlist baseline; T3 *optional* egress allowlist enforcement, flagged as a deliberate user decision because it breaks ad-hoc web research. **Effort: M, ~6–8h for T1+T2, one build/switch.**

## 2. Current state & evidence

**Topology (live).** Both VMs sit on private `/30` bridges and egress through `end0` via `networking.nat` masquerade:

- `openclaw-microvm.nix:429-433` — NAT `internalInterfaces=[br-openclaw]`, external `end0`.
- `hermes-microvm.nix:135-139` — NAT `internalInterfaces=[hermes-br0]`, external `end0`.

**Enforcement already exists, but asymmetrically.** This is the single most important finding — the brief's "list optional enforcement as the big step" is partly *already shipped*:

- **OpenClaw** (`openclaw-microvm.nix:497-536`): chain `openclaw-isolate` `RETURN`s only DNS-to-gateway and the DNAT host-service ports, then `DROP`s the rest of host-bound traffic. The `FORWARD` chain `DROP`s `10/8`, `172.16/12`, `192.168/16` (no private-net reachability), then `LOG`s **all** new outbound to `end0` with prefix `openclaw-egress:` — **but there is NO final DROP on the public path**. OpenClaw egress is **port-unrestricted**: I observed a live `openclaw-egress:` line with `DPT=80` (plaintext HTTP).
- **Hermes** (`hermes-microvm.nix:167-223`): same private-net drops, then `ACCEPT` only `tcp/udp 443` and `tcp/udp 53`, then `LOG` prefix `hermes-egress-rejected:`, then **final DROP**, plus `ip6tables -A FORWARD -i hermes-br0 -j DROP`. Hermes is **already a 443/53 port-allowlist**.

**Live counters confirm the rules are active and the asymmetry is real:**

```
68    4448  LOG  br-openclaw end0  ctstate NEW  prefix "openclaw-egress: "         (new conns logged, NOT dropped)
2378  198K  ACCEPT tcp hermes-br0 end0 dpt:443                                     (active OpenRouter/Discord)
0     0     LOG  hermes-br0  end0  ctstate NEW  prefix "hermes-egress-rejected: "  (Hermes never escapes its allowlist)
```

**The visibility gap (the real bug).** The egress `LOG` rules use `--log-level info` (priority 6). Confirmed live:
- Kernel journal: **178** `openclaw-egress:` lines in 24h, **all priority 6** (histogram `{'6':178}`).
- `promtail.nix:174-180` drops journal priority **5–7**.
- Loki: `count_over_time({job="systemd-journal"} |= "openclaw-egress" [24h])` → **0 result sets**.

So the egress audit log that the modules carefully construct is **thrown away before it reaches Loki** — exactly the P0 #13 sshd failure mode (those lines also logged at info; the fix was a dedicated bypass-scrape). By contrast the UAS rule works because kernel disk-error lines are priority 3–4 (`uas-enclosure.yaml:17-19`).

**Two strong signals already exist for free:**

1. **Per-VM byte counters (Prometheus, node_exporter):** `node_network_{receive,transmit}_bytes_total` exists for `device=br-openclaw, vm-openclaw, hermes-br0, vm-hermes` (4 live series; `vm-openclaw` tx ≈ 386 B/s, `vm-hermes` ≈ 227 B/s). 7-day history present. **No collector needed for the volume tier.**
2. **Per-VM DNS queries (Loki, `dns_query_logs`):** Technitium logs each query with `client_ip` = the **actual VM IP** (`10.99.0.2`, `10.99.1.2` both present among 47 distinct client IPs), not the bridge gateway. The log line is JSON with a `domain` field. Volumes are small (openclaw 57/24h, hermes 27/24h) and the **baseline is tiny: 10 distinct FQDNs / 8 registrable bases for openclaw** (discord, github, npm, whatsapp, ntp, perplexity). Loki retains **30 days** (data back to 2026-05-12), enough to compute a baseline.

**Zero existing egress alerting.** `grep` of `alerts/*.yaml` + `loki-rules/*.yaml` for `egress|10.99|exfil|outbound` returns only unrelated comment matches. `openclaw.yaml`=14 alerts, `hermes.yaml`=13, none about egress.

## 3. Design options

**Option A — Rule-only, signals-already-exist (visibility + anomaly, no enforcement change).** Wire the existing `node_network` byte counters and the existing `dns_query_logs` Loki stream into alerts, and add a dedicated promtail bypass-scrape so the egress `LOG` lines finally reach Loki under a new job. No new exporter, no nftables changes.
- *Pros:* ~all the value, almost no new code, no risk of breaking agent egress, reuses three battle-tested templates.
- *Cons:* leaves OpenClaw's port-unrestricted egress as-is (logged but not blocked); DNS anomaly relies on the agents actually resolving via Technitium (they do — confirmed live).

**Option B — Option A + an nftables/iptables counter textfile collector for precise per-VM, per-destination-class connection metrics.** Add `counter` reads of the isolate-chain rules into a textfile gauge (mirroring `asymmetric-routing-exporter.nix`).
- *Pros:* exact NEW-connection counts per VM as a first-class metric (`vm_egress_new_connections_total{vm,...}`), independent of Loki retention; survives a Loki outage.
- *Cons:* the `node_network` byte counters already give volume; the iptables LOG-rule packet counter is redundant with a Loki `count_over_time` of the bypass-scraped log; net marginal value is low for the added moving part. **Build only if T1 alerting proves the byte-rate too coarse.**

**Option C — Full egress allowlist enforcement (the "big step").** Bring OpenClaw to Hermes parity (443/53 port-allowlist + final DROP), and optionally a destination IP/AS allowlist (Cloudflare AS13335 for Discord, OpenRouter ranges).
- *Pros:* actually *prevents* exfiltration rather than just detecting it; shrinks blast radius from "any public IP/port" to "443/53 to anywhere".
- *Cons:* a per-IP/AS allowlist is brittle (CDN IPs rotate) and **breaks ad-hoc web research** (agents fetch arbitrary URLs); the port-allowlist alone breaks any non-443 skill (e.g. the observed `DPT=80`). This is a **policy decision, not a monitoring task** — spec it, gate it on the operator.

**Recommended: Option A now, Option C's *port-allowlist half* as a flagged decision, Option B deferred.** A gets all the detection value at rule-only cost and reuses existing conventions. C's port-symmetry (make OpenClaw match Hermes) is the one enforcement change worth offering because it closes a genuine inconsistency (OpenClaw is the *less* locked-down of the two despite running the more privileged agent), but it must be the operator's call.

## 4. Recommended implementation

### Tier 1a — Make the egress log reachable (dedicated promtail bypass-scrape)

**Edit `modules/services/promtail.nix`** — add a third journal scrape modeled exactly on the `job="sshd"` block (`promtail.nix:185-232`). The egress lines are `_TRANSPORT=kernel`, `SYSLOG_IDENTIFIER=kernel`, priority 6, no `_SYSTEMD_UNIT`. Keep only the two egress prefixes via a `keep` on the message, and **omit the priority-drop stage**:

```nix
{
  job_name = "vm-egress";
  journal = { json = true; max_age = "5m"; labels = { job = "vm-egress"; host = "vulcan"; }; };
  relabel_configs = [
    # Kernel transport only (the egress LOG lines come from the kernel netfilter LOG target)
    { source_labels = [ "__journal__transport" ]; regex = "kernel"; action = "keep"; }
    { source_labels = [ "__journal_priority" ]; target_label = "priority"; }
  ];
  # promtail relabel can't match on MESSAGE; filter by prefix in a pipeline stage instead:
  pipeline_stages = [
    { match = { selector = "{job=\"vm-egress\"}"; stages = [ ]; }; }
    # Drop kernel lines that are NOT egress logs (keep only our two prefixes)
    { match = { selector = "{job=\"vm-egress\"} !~ \"openclaw-egress:|hermes-egress-rejected:\""; action = "drop"; }; }
    # Tag the source VM so alerts can label by vm without parsing IPs into Loki labels
    { regex = { expression = "(?P<egress_kind>openclaw-egress|hermes-egress-rejected)"; }; }
    { labels = { egress_kind = ""; }; }
  ];
}
```

*Note for the implementer:* if matching on MESSAGE in `relabel_configs` proves cleaner on this promtail version, the equivalent is a `pipeline_stages` `match` with `action=drop` as above — verify against the live promtail (the sshd block used a `__journal__systemd_unit` keep, which won't work here because kernel lines have no unit). **Do not** add a priority filter; that is the whole point.

This is a **second reader of the same journal** (like sshd/postgresql), so it adds Loki volume of only ~178 lines/day — negligible.

### Tier 1b — Volume & connection-rate alerts (rule-only, metrics already exist)

**New file `modules/monitoring/alerts/vm-egress.yaml`** (auto-discovered by `alerting.nix`; `promtool` validates at build). Baselines from live: `vm-openclaw` tx ≈ 386 B/s, `vm-hermes` ≈ 227 B/s, openclaw 57 DNS/24h, hermes 27/24h.

```yaml
groups:
  - name: vm_agent_egress
    rules:
      # Egress byte-rate spike — node_network tx on the TAP (guest→host) device.
      # Baseline tx ≈ 0.2–0.4 kB/s steady; a sustained 1 MB/s is ~3000x and
      # would indicate bulk exfil or a runaway loop. for:15m to ride out a
      # legitimate large model response / git clone.
      - alert: VMAgentEgressVolumeHigh
        expr: |
          rate(node_network_transmit_bytes_total{device=~"vm-openclaw|vm-hermes"}[10m]) > 1.0e6
        for: 15m
        labels: { severity: warning, category: security, service: agent-vm-egress }
        annotations:
          summary: "{{ $labels.device }} sustained egress > 1 MB/s for 15m"
          description: |
            Agent microVM {{ $labels.device }} transmitted >1 MB/s out the
            bridge for 15m (baseline ≈ 0.2–0.4 kB/s). Possible bulk
            exfiltration, a runaway fetch loop, or a legitimately large
            transfer. Check the DNS log for the destination and
            `iptables -L FORWARD -v -n` counters.

      # New-outbound-connection rate from the bypass-scraped egress log.
      # OpenClaw logs ALL new public conns (~7/hr baseline = 178/day).
      # >120 new conns in 10m (~12/min) is a connection storm.
      - alert: VMAgentEgressConnectionStorm
        expr: |
          sum by (egress_kind) (count_over_time({job="vm-egress", egress_kind="openclaw-egress"} [10m])) > 120
        for: 5m
        labels: { severity: warning, category: security, service: agent-vm-egress }
        annotations:
          summary: "OpenClaw VM opened >120 new outbound connections in 10m"
          description: |
            Burst of new outbound connections from the OpenClaw microVM —
            far above the ~7/hr baseline. Correlate with the DNS new-
            destination alert and the byte-rate alert.

      # Hermes should NEVER hit its reject log (it lives inside 443/53).
      # Any rejected egress is either a new legit endpoint on an odd port
      # OR a compromise probing other ports. Fire on the first one.
      - alert: HermesEgressRejected
        expr: |
          sum(count_over_time({job="vm-egress", egress_kind="hermes-egress-rejected"} [10m])) > 0
        for: 0m
        labels: { severity: warning, category: security, service: agent-vm-egress }
        annotations:
          summary: "Hermes VM attempted egress outside its 443/53 allowlist"
          description: |
            The Hermes microVM tried to open an outbound connection that the
            egress allowlist DROPped (logged as hermes-egress-rejected). Either
            a new legitimate endpoint needs a port opened, or the Hermes
            process is probing — investigate the destination in the egress log.
```

### Tier 2 — DNS new-destination anomaly (Loki rule, signal already exists)

**New file `modules/monitoring/loki-rules/vm-egress-dns.yaml`** + **L+ symlink in `loki.nix`** (mandatory — Loki ruler does NOT auto-discover; follow `loki.nix:124-130`):

```
"L+ /var/lib/loki/rules/fake/vm-egress-dns.yaml - - - - /etc/nixos/modules/monitoring/loki-rules/vm-egress-dns.yaml"
```

The rule fires when a VM resolves a registrable base **not** on a checked-in allowlist. Because the baseline is ~8 bases, a static allowlist is auditable and cheap:

```yaml
groups:
  - name: vm_agent_egress_dns
    interval: 5m
    rules:
      # New-destination detection: any domain a VM resolves whose registrable
      # base is NOT in the approved set. The baseline (verified 14d) for
      # openclaw is ~8 bases (discord.com, discord.gg, github*, npmjs.org,
      # whatsapp.{com,net}, ntp.org, perplexity.ai). The negative-regexp
      # encodes the allowlist; anything else is flagged. Counts-and-domain
      # only — never the resolved IP/answer.
      - alert: VMAgentDNSNewDestination
        expr: |
          sum by (client_ip) (count_over_time(
            {job="dns_query_logs", client_ip=~"10\\.99\\.0\\.2|10\\.99\\.1\\.2"}
            | json
            | domain !~ "(^|\\.)(discord\\.com|discord\\.gg|discordapp\\.com|github\\.com|githubusercontent\\.com|githubassets\\.com|npmjs\\.org|whatsapp\\.net|whatsapp\\.com|ntp\\.org|perplexity\\.ai|openrouter\\.ai|anthropic\\.com|googleapis\\.com|sentry\\.io)$"
            | domain != ""
            [10m]
          )) > 0
        for: 0m
        labels: { severity: warning, category: security, service: agent-vm-egress }
        annotations:
          summary: "Agent VM {{ $labels.client_ip }} resolved a non-allowlisted domain"
          description: |
            The microVM at {{ $labels.client_ip }} (10.99.0.2=openclaw,
            10.99.1.2=hermes) resolved a DNS name outside the approved egress
            allowlist in the last 10m. Inspect the exact name in Loki:
            {job="dns_query_logs", client_ip="{{ $labels.client_ip }}"} | json.
            Either a legitimate new service (add to the allowlist below) or an
            exfil/compromise indicator. Resolved IPs are intentionally NOT
            surfaced here.
```

*Allowlist construction:* the implementer should run, at build time of the spec, a 14-day Loki sweep (`{job="dns_query_logs", client_ip=~"10.99.0.2|10.99.1.2"} | json | line_format "{{.domain}}"`) and fold every observed registrable base into the regexp, then add the *config-declared* endpoints (openrouter, anthropic, perplexity, brave/search, discord, github) even if not yet seen. The list above is a starting set — expand from the live 14d sweep.

### Tier 3 — Optional enforcement (OPERATOR DECISION, do not ship silently)

If the operator approves port-symmetry: edit `openclaw-microvm.nix:520-527` to mirror `hermes-microvm.nix:202-216` — add `ACCEPT tcp/udp 443` + `ACCEPT tcp/udp 53` to `end0`, keep the `openclaw-egress:` LOG (now of *rejected* traffic only, rename prefix to `openclaw-egress-rejected:` for symmetry), then a final `DROP`, plus the `ip6tables -A FORWARD -i br-openclaw -j DROP` belt-and-suspenders Hermes already has. This is a **mutation with a real break risk** (any non-443 agent skill dies); the live `DPT=80` observation proves OpenClaw currently uses non-443 egress, so this WILL break something until that skill is identified. **Do not implement without explicit GO.** A per-IP/AS-destination allowlist is explicitly *not* recommended (CDN IP churn; web-research breakage).

### Wiring / deploy choreography

- **Files created:** `modules/monitoring/alerts/vm-egress.yaml` (auto-discovered), `modules/monitoring/loki-rules/vm-egress-dns.yaml`.
- **Files edited:** `modules/services/promtail.nix` (new `vm-egress` scrape), `modules/services/loki.nix` (one `L+` symlink line).
- **ports.txt:** no new listener — the bypass-scrape reads the journal, the alerts read existing scrape targets. **No ports.txt change.**
- **Restart cost:** `switch` restarts `promtail.service` (cheap, ~1s, reloads journal cursors), reloads `prometheus`/`loki` rule files (no restart, hot reload). No VM restart, no agent disruption (T1/T2 touch nothing in the VM path).
- **Sequencing:** single build/switch for T1+T2. Use the `/etc/nixos/.nixos-build` lock convention; build with `--cores 0`.
- **Validation (post-switch):** (a) `curl 127.0.0.1:3100 ... |= "openclaw-egress"` now returns >0 (the scrape works); (b) `/api/v1/rules` shows `vm_agent_egress` + `vm_agent_egress_dns` groups `health=ok`; (c) `promtool`/loki ruler accept the files (build would fail otherwise); (d) confirm no rule fires spuriously — `VMAgentDNSNewDestination` should be quiet after the allowlist is seeded (run the 14d sweep FIRST, or it pages on every legit domain).
- **Rollback:** revert the two new files + two edits; `switch`. No state migration.

## 5. Noise & failure-mode analysis

- **`VMAgentDNSNewDestination` chronic firing if the allowlist is under-seeded.** This is the #1 noise risk. Mitigation: seed the regexp from the actual 14-day live sweep BEFORE switching, include config-declared endpoints proactively, and start the alert at `severity: warning` (not critical) with no auto-route to phone until it's been quiet for a week. The baseline is genuinely tiny (~8 bases), so this converges fast.
- **CDN/anycast churn within an allowlisted base is a non-issue** because we match registrable base, not IP — `mmx-ds.cdn.whatsapp.net` still matches `whatsapp.net`.
- **`VMAgentEgressVolumeHigh` false positives on legitimate bulk transfer** (a large model response streamed back, a `git clone` in an agent skill). Mitigated by `for:15m` and a 1 MB/s floor (3000× baseline). If the agents do legitimate bulk work, raise to `>5 MB/s` after observing.
- **Silent-break risk: promtail scrape stops matching.** If a promtail upgrade changes journal field names or the LOG prefix is renamed in the VM module, the `vm-egress` job goes quiet and the connection-storm alert can't fire. Mitigation: add a companion liveness check — `absent_over_time({job="vm-egress"}[6h])` is a poor fit (the log is legitimately sparse), so instead assert the scrape target exists via the existing promtail self-metrics, OR accept that the byte-rate alert (T1b, independent of Loki) is the backstop. The two tiers are deliberately built on *independent* data paths (Prometheus node_network vs Loki) so one failing doesn't blind the other.
- **DNS bypass: if an agent hardcodes an IP and never resolves it, the DNS tier misses it.** This is real. The byte-rate + connection-storm tiers (and, if shipped, Tier-3 enforcement) are the backstops for IP-literal egress. Worth noting in the runbook, not worth a separate collector.
- **Hermes reject-log alert (`HermesEgressRejected`, for:0m)** could fire on a legitimate new endpoint that needs a non-443 port. That's the intended behavior — it's a "review this" signal, low frequency (baseline = 0 rejects in 24h).

## 6. Security considerations

- **Secret-safety of the egress log:** the netfilter `LOG` MESSAGE contains SRC/DST IPs and ports but **no payload, no credentials**. The bypass-scrape ingests these into Loki under `job="vm-egress"`; only the `egress_kind` label is promoted (no IP becomes a Loki label → no cardinality blowup, no IP in alert labels). Destination IPs live only in the log body, retrieved manually during investigation — acceptable (public-internet egress topology, not internal secrets).
- **DNS domain names in alerts:** `VMAgentDNSNewDestination` deliberately surfaces the *fact* that a new base was resolved and labels by `client_ip`; the annotation directs the operator to Loki rather than embedding the domain, and the rule **never surfaces the resolved IP/`answer` field** (browsing metadata minimized). The whole signal's value is naming the anomalous domain on inspection — that is the audit purpose, not a leak. (Flagged as a user decision in §8.)
- **No secrets read or emitted by any new component.** No collector reads a token file; the byte counters and DNS logs are already-public-on-host metrics/logs. No `sops`, no `/run/secrets`, no `.storage`. The 14-day allowlist sweep prints only `domain` strings (no `answer`/IPs).
- **Tier 3 enforcement** touches the firewall (mutation) — out of scope for this read-only investigation and gated on operator GO.

## 7. Effort & sequencing

- **Effort: M, ~6–8h** for Tiers 1+2: ~1h promtail bypass-scrape (clone+adapt sshd block, the kernel-no-unit twist is the only wrinkle), ~1h the 14-day Loki allowlist sweep, ~2h the two rule files + baseline tuning, ~2h validate live (scrape lands in Loki, rules `health=ok`, no spurious firing), ~1h docs/runbook. One build/switch.
- **Prerequisites:** none new — all three template files exist (`promtail.nix:185` sshd block, `uas-enclosure.yaml`, `asymmetric-routing-exporter.nix`), `dns_query_logs` is live, node_exporter scrapes the bridges. The 14-day allowlist sweep should be done *before* switch so the DNS alert is quiet on first deploy.
- **Unblocks:** a real exfiltration/compromise signal for the highest-blast-radius services on the host (autonomous agents with shell access). Also makes the existing-but-discarded `openclaw-egress`/`hermes-egress-rejected` logs queryable for forensics. Tier 3 (enforcement) becomes a clean follow-on once the detection layer has run long enough to prove the allowlist is complete.
- **Tier 2b (Option B counter exporter):** ~+2h, build ONLY if T1b's byte-rate proves too coarse to localize a storm. Not recommended up front.

## 8. Decisions required from the operator

- **Tier 3 enforcement GO/NO-GO (port symmetry):** OpenClaw egress is currently **port-unrestricted** (logged, not dropped — live `DPT=80` observed). Recommend bringing it to Hermes parity (443/53 ACCEPT then DROP). This WILL break any agent skill that fetches non-443 URLs until identified. Confirm GO, or explicitly keep OpenClaw wide-open-but-logged. (A per-domain/IP allowlist is *not* recommended either way.)
- **DNS-domain visibility in alerts:** the new-destination alert labels by `client_ip` and points to Loki, but investigation will surface the queried FQDN. Confirm that browsing-metadata exposure in the alerting path is acceptable (a counts-only variant is available as fallback).
- **Allowlist maintenance model:** static checked-in regexp (recommended — auditable, an attacker can't poison it) vs auto-learned-14d-window (lower toil, but baseline-poisoning risk). Confirm static.


---


<a id="cve-image-scanning"></a>

# Container Image CVE Scanning (Trivy textfile exporter + severity-floored alerting)

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** M, ~6-8h (module + alerts + first-scan baseline tuning)

**Key live evidence:** 18 distinct running images: 5 root (matter-server:stable, wyoming_openai:latest, budget-board/{client,server}:release, technitium-dns-exporter:latest local-build) + 13 rootless across 12 users (changedetection.io + sockpuppetbrowser, litellm-database:main-stable, mailarchiver, openproject:16, openspeedtest, open-webui:main, shlink:stable, shlink-web-client:stable, speedtest-tracker, teable-community, vane:slim-latest, wallabag); zimit on-demand (0 running). · Digest pinning: 0 of 19 image refs in modules/**.nix use @sha256 — every container tracks a moving tag (overlaps image-staleness-drift; that item owns digest drift, this item owns vuln scanning). · Internet-exposed container surface = shlink ONLY: cloudflared ingress is 4 hostnames (data->:18080 nginx-static, gitea->:3005 non-podman, s.newartisans.com->:8580 shlink API, calendar->:8090 calendar-publisher). open-webui/litellm/teable/etc. are LAN-only (.lan via nginx). · Scanners in nixpkgs 25.11 for aarch64-linux: trivy 0.66.0, grype 0.104.1, vulnix 1.12.1 — all present, none currently installed (command -v: none). · Disk headroom: / has 1.2T avail (28% used); trivy vuln DB ~700MB-1GB. Trivial. · Reusable infra confirmed live: textfile dir /var/lib/prometheus-node-exporter-textfiles (1777 prometheus:prometheus, node-exporter flag --collector.textfile.directory set); 20 container_running series already in Prometheus; alerts auto-discovered from modules/monitoring/alerts/*.yaml via alerting.nix (readDir glob) — a new cve.yaml needs NO wiring.

## 1. TL;DR

vulcan runs **18 distinct container images** (5 root podman + 13 rootless quadlet containers across 12 lingering users), **every one on a moving tag with zero `@sha256` digest pinning**, and **nothing scans any of them for known CVEs**. The pinned, CVE-mitigated-not-fixed Asahi kernel is a separate (system-closure) concern owned by the `kernel-cve-patch-age` workstream; this item is strictly **container image** vulnerability scanning.

Recommendation: a **weekly `trivy image` oneshot** (trivy 0.66.0 ships in nixpkgs 25.11 for `aarch64-linux`) that enumerates running images the same way `container-health-exporter.nix` already does, scans each, and writes **per-image severity-bucketed gauges** (`container_image_vulns{name,image,severity,fixable}`) into the existing textfile-collector directory. Alerting is split: a **paging tier** firing only on *fixable* CRITICAL/HIGH in the single internet-exposed image (**shlink**), and a **digest tier** (a weekly-rendered gauge, surfaced in Grafana / an optional weekly email) for everything else. The severity floor + `fixable=true` filter is the entire design — without it this is a textbook CVE-flood pager-fatigue generator (the exact reason it was deferred).

Cost: **M, ~6-8h**. One new exporter module, one `alerts/cve.yaml`, ~1GB trivy DB cache on a disk with 1.2T free, a ~3-6 min weekly scan. **No new ports** (textfile-only), **no secrets touched**.

## 2. Current state & evidence

**Image inventory (measured live 2026-06-10, names/counts only):**

- **Root podman (5 images):** `matter-server:stable`, `wyoming_openai:latest`, `budget-board/client:release`, `budget-board/server:release`, `localhost/technitium-dns-exporter:latest` (locally built). Plus a `budget-board-infra` pause container (no app image).
- **Rootless (13 running, across 12 lingering users; `zimit` on-demand = 0 running):** `changedetection.io:latest` + `sockpuppetbrowser:latest` (user changedetection), `litellm-database:main-stable`, `mailarchiver:latest`, `openproject:16`, `openspeedtest/latest:latest`, `open-webui:main`, `shlink:stable`, `shlink-web-client:stable`, `speedtest-tracker:latest`, `teable-community:latest`, `vane:slim-latest`, `wallabag:latest`.

**Digest pinning:** `grep -rohE "@sha256:" modules/**.nix` → **0 hits**. All 19 image references track moving tags. (Digest *drift* monitoring is owned by `image-staleness-drift`; I own *vulnerability content*. These dovetail: a CVE count is meaningless without knowing the running digest, so my collector emits `container_image_id` alongside, which the staleness item can also consume.)

**Internet-exposed surface (cross-referenced cloudflared ingress + ports.txt):** the tunnel exposes 4 hostnames — `data.newartisans.com`→:18080 (nginx static), `gitea.newartisans.com`→:3005 (Gitea, **not** a podman container in my set), `s.newartisans.com`→:8580 (**shlink** API), `calendar.newartisans.com`→:8090 (calendar-publisher). **The only internet-reachable container in my scan set is shlink.** Everything else (open-webui, litellm, teable, wallabag, openproject…) is LAN-only behind nginx `.lan` vhosts. This is the single most important fact for the alert philosophy: the paging blast radius is *one* image.

**Scanner availability (nixpkgs 25.11, aarch64-linux):** `trivy` 0.66.0, `grype` 0.104.1, `vulnix` 1.12.1 — all present (`nix eval` confirmed), none currently installed. `trivy.meta.platforms` includes `aarch64-linux`.

**Disk:** `/` = 1.7T, 1.2T free (28% used). trivy vuln DB ~700MB–1GB. No concern.

**Reusable infrastructure (all confirmed live):**
- Textfile dir `/var/lib/prometheus-node-exporter-textfiles` (1777 `prometheus:prometheus`), node-exporter started with `--collector.textfile.directory=…` (system-exporters.nix:38).
- `container-health-exporter.nix` already enumerates `ROOTLESS_USERS="changedetection litellm mailarchiver openspeedtest opnsense-exporter open-webui openproject shlink shlink-web-client speedtest-tracker teable vane wallabag"` and runs root-podman + `sudo -u <user> podman` sweeps. **I copy this user list and image-enumeration verbatim.** Imported at `hosts/vulcan/default.nix:109`.
- Alerts auto-discover from `modules/monitoring/alerts/*.yaml` via `modules/monitoring/services/alerting.nix` (`builtins.readDir ../alerts`). A new `cve.yaml` needs **zero wiring**.
- 20 `container_running` series already in Prometheus, labeled `{name,container,user}` — my CVE series reuse `name`+`user` so they JOIN cleanly to the running set (a CVE gauge for a no-longer-running image self-stales, see §5).

## 3. Design options

**Option A — Trivy weekly textfile exporter, severity-floored alerting (RECOMMENDED).**
Weekly oneshot runs `trivy image` over each *running* image, parses JSON, emits `container_image_vulns{name,image,severity,fixable}` counts + `container_image_scan_*` metadata. Alert paging tier = fixable CRIT/HIGH on exposed images; digest tier = a weekly gauge + optional email.
*Pros:* trivy has the best aarch64 support and the cleanest JSON severity/fixable breakdown; `.trivyignore` gives a first-class accepted-CVE allowlist; counts-not-CVE-lists keeps cardinality bounded and is secret-safe; reuses the existing exporter pattern exactly. *Cons:* ~1GB DB; first scan needs a DB download; scan touches per-user rootless stores (needs root + `sudo -u`).

**Option B — Grype instead of trivy.** Functionally equivalent counts; grype's DB is smaller (~200MB) and it's arguably simpler CLI.
*Pros:* lighter DB. *Cons:* no built-in ignore-file as ergonomic as `.trivyignore`; fixable-state reporting is present but trivy's `--ignore-unfixed` + severity filtering is more battle-tested; grype's podman/rootless image access is less documented. Net: marginal DB saving not worth the ergonomic/maturity loss given 1.2T free.

**Option C — Digest-pin-and-diff only, no scanner (the brief's "lower-effort interim").** Pin every quadlet to `@sha256`, alert when running digest != pinned.
*Pros:* near-zero runtime cost, no DB. *Cons:* **answers a different question** — it tells you *the content changed*, not *the content is vulnerable*. It's the `image-staleness-drift` item's job, not a CVE signal, and pinning moving-tag upstreams (`:main`, `:latest`, `:stable`) means *manually* bumping digests forever or the containers freeze. Does not satisfy the security gap. **Reject as a substitute** (but it's a worthwhile complement owned by the other item).

**Chosen: Option A.** Trivy's JSON `--severity`/`--ignore-unfixed`/`.trivyignore` triad is purpose-built for exactly the noise-control this design lives or dies by, and the aarch64 story is solid.

## 4. Recommended implementation

### Files

**Create** `modules/monitoring/services/container-cve-exporter.nix` (new exporter module).
**Create** `modules/monitoring/alerts/cve.yaml` (auto-discovered, no wiring).
**Create** `modules/monitoring/services/.trivyignore` (committed accepted-CVE allowlist; referenced by `TRIVY_IGNOREFILE`).
**Edit** `hosts/vulcan/default.nix` — add one import line next to the existing `container-health-exporter.nix` (line ~109).
**Edit** `docs/ports.txt` — **no port to add** (textfile-only); add a one-line comment in the monitoring section noting the collector is textfile-only so future audits don't hunt for a listener.

### Metrics (emitted to `/var/lib/prometheus-node-exporter-textfiles/container_cve.prom`)

```
# HELP container_image_vulns Count of CVEs in a running container image by severity and fixability
# TYPE container_image_vulns gauge
container_image_vulns{name="shlink",image="docker.io/shlinkio/shlink:stable",user="shlink",severity="CRITICAL",fixable="true"}  N
container_image_vulns{name="shlink",...,severity="CRITICAL",fixable="false"} M
# (severity ∈ CRITICAL,HIGH,MEDIUM,LOW; fixable ∈ true,false — 8 series/image max)

# HELP container_image_scan_timestamp_seconds Unix time this image was last scanned
# TYPE container_image_scan_timestamp_seconds gauge
container_image_scan_timestamp_seconds{name="shlink",user="shlink"} 1749…

# HELP container_image_scan_success Whether the last scan of this image succeeded (1=ok,0=failed)
# TYPE container_image_scan_success gauge
container_image_scan_success{name="shlink",user="shlink"} 1

# HELP container_cve_exporter_last_run_seconds Unix time the whole sweep last completed
# TYPE container_cve_exporter_last_run_seconds gauge
container_cve_exporter_last_run_seconds 1749…

# HELP container_cve_exporter_db_age_seconds Age of the trivy vuln DB at scan time
# TYPE container_cve_exporter_db_age_seconds gauge
container_cve_exporter_db_age_seconds 5400
```

Cardinality ceiling: 18 images × 8 severity/fixable buckets ≈ 144 series + ~60 metadata = **~200 series, static**. Trivial.

**Critical noise-control decision baked into the metric:** emit *counts*, never CVE IDs as labels. A `cve_id` label would be unbounded-cardinality and would leak nothing sensitive but would balloon the TSDB. CVE detail lives in trivy's JSON-on-disk (`/var/lib/container-cve/reports/<name>.json`, 0640 root) for ad-hoc inspection, not in metrics.

### Collector sketch (shell, reusing container-health-exporter.nix idioms)

```sh
set -euo pipefail
METRICS_FILE=/var/lib/prometheus-node-exporter-textfiles/container_cve.prom
TMP="$METRICS_FILE.tmp"
export TRIVY_CACHE_DIR=/var/lib/container-cve/cache
export TRIVY_IGNOREFILE=/etc/container-cve/.trivyignore   # accepted-CVE allowlist
REPORTS=/var/lib/container-cve/reports

# Refresh DB ONCE up front (not per-image): trivy image --download-db-only
trivy image --download-db-only --cache-dir "$TRIVY_CACHE_DIR" || true

emit_header > "$TMP"

scan_one() {            # $1 = podman cmd, $2 = image ref, $3 = name, $4 = user
  local out; out=$(mktemp)
  if "$1" image --quiet --format json --severity CRITICAL,HIGH,MEDIUM,LOW \
        --pkg-types os,library --image-src podman "$2" > "$out" 2>/dev/null; then
    # jq: bucket .Results[].Vulnerabilities by .Severity × (FixedVersion!=null)
    jq -r --arg n "$3" --arg u "$4" --arg img "$2" '
      [.Results[]?.Vulnerabilities[]?] 
      | group_by(.Severity + (if .FixedVersion then ":true" else ":false" end))
      | .[] | "container_image_vulns{name=\"\($n)\",image=\"\($img)\",user=\"\($u)\",severity=\"\(.[0].Severity)\",fixable=\"\(if .[0].FixedVersion then "true" else "false" end)\"} \(length)"
    ' "$out" >> "$TMP"
    cp "$out" "$REPORTS/$3.json"
    echo "container_image_scan_success{name=\"$3\",user=\"$4\"} 1" >> "$TMP"
  else
    echo "container_image_scan_success{name=\"$3\",user=\"$4\"} 0" >> "$TMP"
  fi
  echo "container_image_scan_timestamp_seconds{name=\"$3\",user=\"$4\"} $(date +%s)" >> "$TMP"
  rm -f "$out"
}

# Root images: podman ps --filter label=PODMAN_SYSTEMD_UNIT --format '{{.Names}}\t{{.Image}}'
# Rootless: for each ROOTLESS_USERS (copy the exact list from container-health-exporter.nix),
#   sudo -u "$u" podman ps … ; scan_one with "sudo -u $u podman"
# De-dup identical image refs across users (scan once, relabel) to halve runtime.

echo "container_cve_exporter_last_run_seconds $(date +%s)" >> "$TMP"
mv "$TMP" "$METRICS_FILE"; chmod 644 "$METRICS_FILE"
```

`--image-src podman` lets trivy read the local podman store directly; for rootless stores the `sudo -u <user> trivy …` (or `sudo -u <user> podman save | trivy image --input -`) path is used so trivy sees the right graphroot. **De-dup identical refs** (`shlink:stable` and `shlink-web-client:stable` are distinct, but if any two users share a ref, scan once) to keep the sweep to ~3-6 min.

### Service & timer (oneshot + weekly timer, mirrors store-size-exporter)

```nix
systemd.services.container-cve-exporter = {
  description = "Container image CVE scanner (trivy) → textfile";
  after = [ "network-online.target" "podman.service" ];
  wants = [ "network-online.target" ];           # DB download needs egress
  serviceConfig = {
    Type = "oneshot";
    User = "root"; Group = "root";               # needs sudo -u + per-user 0700 stores
    ExecStart = pkgs.writeShellScript "container-cve-exporter" '' … '';
    TimeoutStartSec = "30min";                    # cold DB download + 18 scans
    Nice = 15; IOSchedulingClass = "idle";        # never compete with live services
    ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" "/var/lib/container-cve" ];
    StateDirectory = "container-cve";             # /var/lib/container-cve, 0750 root
  };
};
systemd.timers.container-cve-exporter = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "Sun 04:00";                     # weekly, low-traffic window
    Persistent = true;
    RandomizedDelaySec = "30m";
  };
};
# OnFailure → the existing SystemdServiceFailed / textfile-stale machinery already
# covers oneshots; container_image_scan_success + last_run gauge give explicit signals.
```

### Alert rules — `modules/monitoring/alerts/cve.yaml`

```yaml
groups:
  - name: container_cve
    rules:
      # PAGING TIER — fixable CRIT/HIGH in the internet-exposed image (today: shlink).
      # Baseline justification: exposed surface = 1 image (cloudflared ingress cross-ref);
      # firing only on FIXABLE means there's a concrete remediation (bump the tag).
      - alert: ExposedImageFixableCriticalCVE
        expr: container_image_vulns{name="shlink",severity="CRITICAL",fixable="true"} > 0
        for: 1h          # 1h debounce so a mid-scan partial write can't flap
        labels: { severity: warning }
        annotations:
          summary: "Internet-exposed image {{$labels.name}} has fixable CRITICAL CVEs"

      - alert: ExposedImageFixableHighCVE
        expr: container_image_vulns{name="shlink",severity="HIGH",fixable="true"} > 0
        for: 1h
        labels: { severity: info }     # info tier: review, don't page

      # HYGIENE TIER — the scan itself broke or went stale (silent-failure guard).
      - alert: ContainerCVEScanStale
        expr: time() - container_cve_exporter_last_run_seconds > 10 * 24 * 3600
        for: 1h
        labels: { severity: warning }
        annotations: { summary: "Container CVE scan has not completed in >10 days" }

      - alert: ContainerCVEScanFailed
        expr: container_image_scan_success == 0
        for: 2h          # tolerate one transient per-image failure; 2 weekly runs = real
        labels: { severity: info }

      - alert: ContainerCVEDBStale
        expr: container_cve_exporter_db_age_seconds > 14 * 24 * 3600
        for: 1h
        labels: { severity: info }     # DB couldn't refresh → counts are aging
```

Everything NOT in the paging tier (fixable CRIT/HIGH on the other 17 images, all MEDIUM/LOW, all `fixable=false`) is **deliberately not an alert** — it's a Grafana panel (`sum by (name,severity) (container_image_vulns)`) plus, optionally, a weekly email digest (§Decisions). `fixable=false` CVEs never page anyone: there's no action to take.

### Deploy choreography

1. Land the module + `cve.yaml` + `.trivyignore` (empty initially) + import line.
2. `nixos-rebuild switch` — **zero restart cost to live services**; this only adds a dormant oneshot+timer and a new (validated) rule group. Prometheus reloads rules in-place (no restart). node-exporter picks up the new textfile on its next scrape with no restart.
3. **Manually trigger the first scan** to establish the baseline and download the DB *before* the timer's first 04:00 fire: `systemctl start container-cve-exporter` (this is a mutating action — the implementer does it, not this read-only session).
4. Inspect `container_cve.prom` and the per-image JSON; populate `.trivyignore` with any accepted/unfixable-noise CVE IDs; re-run.
5. **Rollback:** revert the import line + rebuild; delete `/var/lib/container-cve`. No data migration, no service depends on it.

## 5. Noise & failure-mode analysis

- **CVE flood (the deferral reason).** Mitigated four ways: (1) paging tier scoped to *one* exposed image; (2) `fixable=true` filter — unfixable CVEs never alert; (3) `.trivyignore` allowlist for accepted findings; (4) MEDIUM/LOW never alert at all (Grafana-only). A typical `:latest` Python/PHP image will show dozens of CVEs on first scan — that's expected and lands in the dashboard, not the pager.
- **Stale-counts-look-like-zero.** If trivy's DB fails to download (no egress at 04:00), counts go stale silently. Guarded by `ContainerCVEDBStale` and `container_cve_exporter_db_age_seconds`.
- **Image stopped between scans.** A CVE gauge for an image no longer running would persist in the textfile until the next weekly run. Mitigation: the collector only emits series for *currently running* images (it enumerates `podman ps`, not `podman images`), so a stopped container's series naturally vanishes on the next sweep. The 1-week gap is acceptable — alerts JOIN against nothing actionable for a dead container anyway.
- **Partial textfile write / flapping.** Atomic `tmp`+`mv` (house pattern) prevents node-exporter reading a half-written file; the `for: 1h` on every paging rule means a single anomalous scan can't page.
- **Rootless store-access failure.** `sudo -u <user> podman`/trivy can fail if a user's runtime dir is down; per-image `container_image_scan_success=0` makes that visible rather than silently counting 0 CVEs.
- **Architecture mismatch.** All images run on aarch64; trivy scans the *actual local image layers*, so there's no cross-arch DB ambiguity — it inspects installed package versions in the arm64 image, matches against the arch-agnostic CVE DB. No special handling needed.
- **Runtime/disk creep.** DB cache capped to one copy under `StateDirectory`; `--cache-dir` reused across runs so only the weekly DB delta downloads (~tens of MB after first pull). `Nice 15` + `IOSchedulingClass=idle` keep the Sunday-04:00 scan from disturbing backups/services.

## 6. Security considerations

- **Reads container images only — no secrets.** trivy inspects OS/library package manifests inside images; it does not read `/run/secrets`, env files, or SOPS material. The collector never invokes `sops -d`, never reads NetworkManager/HA-storage paths.
- **Output is counts + image refs + timestamps** — no CVE descriptions in metrics, no package contents, nothing that could embed a credential. The per-image JSON reports under `/var/lib/container-cve/reports` are `0640 root:root` (not world-readable, not in the textfile dir).
- **`.trivyignore` holds only CVE IDs** (e.g. `CVE-2024-12345`) — public identifiers, no secrets.
- **No new listener / no new port** — textfile-only, so no attack surface added; honours the "no new ports" constraint in the brief.
- **Privilege:** the oneshot runs as root to traverse the 0700 per-user rootless stores via `sudo -u` (identical privilege profile to the already-deployed container-health-exporter and container-store-size-exporter). No privilege escalation beyond what's already accepted for container monitoring.
- **Egress:** the only network call is the trivy vuln-DB pull from `ghcr.io` (public OCI registry). No telemetry, no image push.

## 7. Effort & sequencing

**Effort: M, ~6-8h.** Breakdown: exporter module + jq parsing (~3h), alerts/cve.yaml + baseline tuning against first-scan output (~2h), `.trivyignore` curation + Grafana panel + optional weekly-email digest (~2h), verification (~1h).

**Prerequisites:** none hard. trivy is in nixpkgs; the textfile dir, user enumeration, and alert auto-discovery all already exist.

**Coordinate with `image-staleness-drift`:** that item owns digest pinning + moving-tag drift. My collector emits `container_image_id` (the running digest) as a free byproduct — hand it over so the staleness item doesn't re-enumerate. Don't double-implement image enumeration; if both ship, fold both into one weekly "container supply-chain" oneshot.

**What it unblocks:** closes the P2 🔴secu "no CVE/vulnerability scanning" gap (MONITORING_COVERAGE_PLAN.md line 426) and gives the security domain its first *content* signal (today it's all cert/AIDE lifecycle, zero package-vuln awareness). Pairs naturally with the `kernel-cve-patch-age` system-closure scan (vulnix) to give full host + container CVE coverage.

## 8. Decisions required from the operator

- **Paging severity floor.** My recommendation: fixable CRITICAL+HIGH on internet-exposed images only (today = shlink). Confirm, or widen the paging set to LAN web apps (open-webui, litellm, teable, wallabag) — note that widening will significantly increase alert volume on `:latest`/`:main` images.
- **Cadence.** Weekly (Sun 04:00) vs daily. I recommend weekly.
- **Scope exclusions.** I exclude `zimit` (transient per-job containers) and the `johnw` human account store by default. Confirm.
- **Accepted-CVE mechanism.** I propose a committed `.trivyignore` (CVE-ID allowlist) so accepted findings drop out of the counts. Confirm vs a no-suppression "just filter in Grafana" approach.
- **Weekly digest delivery.** Optional: a weekly email (via the existing postfix/alertmanager path) summarizing the full CVE table for the non-paging images, vs Grafana-dashboard-only. I lean Grafana-only to start; add email if you want a push.


---


<a id="config-drift-auditing"></a>

# Config-Drift Auditing (tiered, non-auditd)

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** M, ~6-8h

**Key live evidence:** aide-metrics.nix IS imported (modules/monitoring/services/default.nix:59) and live: aide_check_status=0, aide_database_age_seconds=10085 in Prometheus (127.0.0.1:9090) — the brief's premise that phase 4 skipped AIDE surfacing is STALE; it exists but is buggy. · AIDE metrics are semantically inconsistent live: aide_check_status=0 (no changes) yet aide_added_files=15, aide_changed_files=122, aide_total_entries=0 — stale leftovers + a broken total-entries parse in the collector's heredoc/grep logic. · Both aide-metrics.nix AND aide-nagios-check.nix independently shell out to `aide --check` (the full filesystem walk) on the daily timer — the duplication the brief flagged; aide-check.service ExecMainStartTimestamp confirms the timer ran 00:17 today. · AIDE config (modules/security/aide.nix) covers /etc/nixos, /etc/ssh, /etc/systemd, /boot, system profile — but NOT /var/lib/hass or /var/lib/node-red (the 9 '/var/lib' hits are all /var/lib/aide and exclusions). · Crown-jewel mtimes (metadata only): HA configuration.yaml 13h ago, automations.yaml 19d, scripts.yaml 244d, scenes.yaml 28d; NR flows.json ~1-2d — irregular real cadence. configuration.yaml is hand-edited + rebuild-mutated (db_url injection home-assistant.nix:1130-1149). · git status --porcelain of /etc/nixos = 0 lines right now — no uncommitted-drift gauge exists; the .nixos-build lock is already gitignored (commit 11da637) and excluded from AIDE (aide.nix:132).

## 1. TL;DR

The vulcan fleet already has two of the three layers a sane config-drift story needs: **AIDE** (whole-tree file integrity, `modules/security/aide.nix`) and a **per-service schema-drift probe** (`openclaw-config-drift-check`, the textfile/SECRET_RE pattern to generalize). What is genuinely missing:

1. The two highest-value *mutable* config artifacts — **Home Assistant's hand-edited YAML** (`/var/lib/hass/{configuration,automations,scripts,scenes}.yaml`) and **Node-RED's `flows.json`** — are covered by **neither** AIDE nor any other signal. Verified: `aide.nix` does not include `/var/lib/hass` or `/var/lib/node-red`.
2. The AIDE *metrics* layer (`aide-metrics.nix`) **already exists and is imported** (contradicting the brief's "phase 4 skipped it" premise), but it is **buggy** (status=0 while added=15/changed=122/total=0 live) and it **double-runs the full `aide --check`** alongside `aide-nagios-check`.
3. There is **no gauge for uncommitted edits in `/etc/nixos`** itself.

**Recommendation:** a three-part, tiered add — (A) fix + de-duplicate the existing AIDE metrics and make its alert meaningful; (B) a lightweight **crown-jewel mtime/sha collector** over ~7 named files with deploy-window suppression (generalizing the openclaw pattern); (C) a one-line `/etc/nixos` uncommitted-changes gauge. **Full auditd is explicitly rejected** (it was disabled for noise; this design stays counts-and-timestamps-only). **Cost:** M, ~6-8h, zero new ports, one Prometheus reload, a few oneshot timers.

## 2. Current state & evidence

Measured live on 2026-06-10 against `127.0.0.1:9090`, the config tree, and file metadata.

**AIDE (whole-tree file integrity)** — `modules/security/aide.nix`, imported at `hosts/vulcan/default.nix:30`:
- Covers `/bin /sbin /lib*` (READONLY), `/boot`, `/etc/ssh`, `/root/.ssh`, `/etc/nixos` (CONFIG, excluding `.git`/`result`/`.nixos-build`), `/etc/systemd`, `/etc/security`, `/run/current-system`, the system profile, `/etc/nixos/secrets.yaml`.
- `aide-update` runs 60s after every `nixos-rebuild` (activation script `aide-post-rebuild`, lines 252-259), so the rebuild itself is the change-approval — meaning **`aide_check_status==1` essentially never persists for the 5m the alert requires.**
- **Does NOT cover** `/var/lib/hass` or `/var/lib/node-red` (confirmed: all 9 `/var/lib` matches in the file are `/var/lib/aide` + the textfile dir + exclusions).

**AIDE metrics** — `modules/monitoring/services/aide-metrics.nix`, **imported at `default.nix:59`** (the brief's "phase 4 SKIPPED this" is stale; it exists). Emits `aide_check_status`, `aide_added_files`, `aide_removed_files`, `aide_changed_files`, `aide_database_age_seconds`, `aide_database_exists`, `aide_total_entries`. Live values are **internally inconsistent**:
```
aide_check_status 0          # OK / no changes
aide_added_files 15          # but 15 added?
aide_changed_files 122       # and 122 changed?
aide_total_entries 0         # total = 0 is a clear parse failure
aide_database_age_seconds 10085
```
This is a real bug: the collector parses `aide --check` output with brittle `grep "Number of entries:"` / `grep "^  Added entries:"` logic (lines 63-66) that does not match current AIDE output, and the added/changed counts are stale leftovers not reset when status=0. **It also runs the full `aide --check` a second time** (line 58) on top of `aide-nagios-check`'s own `aide --check` — the duplication the brief flagged. `aide-check.service` last ran 00:17 today (`ExecMainStartTimestamp`).

**AIDE alerts** — `modules/monitoring/alerts/security.yaml` lines 5-64: `AIDEChangesDetected` (status==1, warning), `AIDECheckError` (status==2, critical), `AIDEDatabaseStale` (>48h, warning), `AIDEDatabaseMissing` (critical). The first never fires for the reason above.

**Per-service schema drift (the pattern)** — `modules/monitoring/services/openclaw-config-drift-check.nix` + `scripts/openclaw-config-drift-check.py`, imported at `default.nix:135`. Stdlib Python oneshot, SSH-probes the VM, `SECRET_RE`-strips secret-named keys *before any byte hits stdout*, emits **counts only** (`openclaw_config_drift_keys_added/removed`, `_probe_up`, `_last_run_timestamp_seconds`). Live: `keys_added=0 keys_removed=0 probe_up=1`. Hardened: `ProtectSystem=strict`, `ReadWritePaths=[textfile dir]`, `LoadCredential` for the probe key. **This is the exact template for tier-2.**

**System-age (deploy-window anchor)** — `modules/monitoring/services/system-age-exporter.nix` emits `system_current_generation_build_timestamp_seconds` (mtime of `/nix/var/nix/profiles/system`, repointed on every switch) and `system_flake_lock_mtime_seconds`. **This is the legitimate-change anchor** the crown-jewel collector correlates against.

**Crown-jewel file cadence (metadata only):**
| file | last change | mutates on |
|---|---|---|
| `/var/lib/hass/configuration.yaml` | 13h ago | **every rebuild** (db_url injection, `home-assistant.nix:1130-1149`) + manual |
| `/var/lib/hass/automations.yaml` | 19d ago | manual / HA UI |
| `/var/lib/hass/scripts.yaml` | 244d ago | manual |
| `/var/lib/hass/scenes.yaml` | 28d ago | manual / HA UI |
| `/var/lib/node-red/flows.json` | ~1-2d ago | **every NR deploy (no nix rebuild)** |
| `/etc/ssh/sshd_config` | — | rebuild only (also in AIDE) |
| `/etc/nixos/secrets.yaml` | — | `sops` edit (also in AIDE) |

**`/etc/nixos` git drift** — `git status --porcelain` = **0 lines** right now. No gauge exists. `.nixos-build` is gitignored (commit `11da637`) and AIDE-excluded.

**Wiring conventions confirmed:** textfile dir `/var/lib/prometheus-node-exporter-textfiles` is the scrape source (`system-exporters.nix:38`, `--collector.textfile.directory=`); alerts auto-discover from `modules/monitoring/alerts/*.yaml` (42 files); textfile dir is created by `system-exporters.nix`/`container-health-exporter.nix`.

## 3. Design options

### Option A — Fix AIDE only, declare the rest "covered by ZFS snapshots + git" (cheap, REJECTED as insufficient)
Fix `aide-metrics.nix` parsing, de-dup the double-check, extend `aide.nix` to add `/var/lib/hass/*.yaml` and `/var/lib/node-red/flows.json` as CONFIG paths, lean on the existing AIDE alerts.
- **Pro:** smallest diff; one collector; existing alert plumbing.
- **Con (fatal):** AIDE's whole-tree model re-baselines on every rebuild via `aide-post-rebuild`, so a flows.json edit made via the NR UI (no rebuild) *would* be caught — but a config edit made just before a rebuild is silently absorbed. Worse, AIDE reports **paths**, and surfacing "which file changed" risks leaking config structure into journals; the counts-only metric can't tell you it was flows.json vs sshd_config. AIDE is the wrong granularity for "did *this specific crown jewel* change outside a deploy."

### Option B — Generalize the openclaw drift pattern into a per-file crown-jewel collector (RECOMMENDED)
A single new textfile collector (`config-drift-exporter`) that, for each of ~7 named files, emits `config_file_mtime_seconds{file="..."}` and `config_file_sha_changed{file="..."}` (1 if the sha differs from a stored baseline that is *re-baselined on deploy*), plus `config_drift_last_run_timestamp_seconds`. Alert fires only when a sha changed **and** the change is **outside the deploy window** (mtime newer than the last generation/NR-deploy anchor by > grace). Reuses the openclaw idioms: counts/booleans only, atomic tmp+mv, `ProtectSystem=strict`. **Plus** fix the AIDE metrics bug + de-dup the double-check (independent, do it anyway). **Plus** the trivial `/etc/nixos` git gauge.
- **Pro:** right granularity (per-file, named in a *label* not a journal-leaked path); deploy-window suppression kills the legitimate-churn noise; reuses a proven, security-reviewed pattern; AIDE stays the broad net, this is the sharpshooter for the 7 files that matter.
- **Con:** the file `file="..."` label names config paths in metrics — acceptable (paths are not secrets; the *contents/sha* never leave the box). `configuration.yaml` needs sha-normalization (strip the injected `db_url:` line) or exclusion from the sha tier because it changes every rebuild.

### Option C — Full auditd / fanotify watch on the config dirs (REJECTED)
Real-time inotify/auditd on `/var/lib/hass` + `/var/lib/node-red` + `/etc`.
- **Con (fatal):** this is exactly what was deliberately disabled for noise. HA writes `.storage/*` constantly, NR writes runtime state, auditd has no deploy-window concept and floods on every legitimate write. The brief explicitly asks to reject this. Reaffirmed.

**Recommended: Option B.** It closes the real gap (HA YAML + flows.json), reuses the house pattern, and the deploy-window correlation is the one piece auditd structurally cannot do.

## 4. Recommended implementation

Three independent workstreams; B2 (crown-jewel) is the new capability, B1 (AIDE fix) and B3 (git gauge) are cheap riders.

### B1 — Fix + de-duplicate AIDE metrics (file: `modules/monitoring/services/aide-metrics.nix`)
- **De-dup the double-check.** `aide-metrics.nix` runs its own `aide --check` (line 58) *and* is wired as `aide-check.serviceConfig.ExecStartPost` (line 106). Drop the ExecStartPost-triggered standalone walk: have the collector **parse the report `aide-check` already produced** rather than re-walking. Cheapest correct form: have `aide-check.service` write its stdout to a fixed report file (`ExecStart` → wrapper that tees to `/var/lib/aide/last-check.report`), and have `aide-metrics` parse *that file* + `aide_check_status` from the wrapper's exit code captured into a sidecar. Net: **one** `aide --check` per day, not two (or three counting nagios — see note).
- **Fix the parse + reset-on-OK.** When status==0, force `aide_added_files=0 aide_removed_files=0 aide_changed_files=0`. Fix `aide_total_entries` (the current `grep "Number of entries:"` matches nothing → emits 0). Use a tolerant matcher, or drop `aide_total_entries` entirely (it carries no alerting value).
- **Note on aide-nagios-check.nix:** it *also* runs `aide --check` (line 37). Either (a) leave it (Nagios path is independent and the brief's "conflict" is really just CPU duplication), or (b) preferred: have the Nagios check read `aide_check_status` from the textfile/Prometheus instead of re-walking. Recommend (b) as a follow-up; not blocking.

### B2 — Crown-jewel drift collector (NEW)

**New file:** `modules/monitoring/services/config-drift-exporter.nix`
**New script:** `scripts/config-drift-exporter.py` (stdlib-only, modeled on `openclaw-config-drift-check.py`).

**Files watched** (the `FILES` dict in the script — paths are labels, never contents):
```
configuration.yaml  /var/lib/hass/configuration.yaml   (sha tier: NORMALIZED — strip ^  db_url: line)
automations.yaml    /var/lib/hass/automations.yaml
scripts.yaml        /var/lib/hass/scripts.yaml
scenes.yaml         /var/lib/hass/scenes.yaml
flows.json          /var/lib/node-red/flows.json
sshd_config         /etc/ssh/sshd_config
secrets.yaml        /etc/nixos/secrets.yaml            (sha of the ENCRYPTED file — safe; never decrypt)
```

**Baseline store:** `/var/lib/config-drift/baselines.json` (root 0600), mapping `name → {sha256, baselined_at}`. The script:
1. For each file: compute sha256 (normalizing configuration.yaml by dropping the injected `db_url:` line so rebuild churn is invisible — mirrors `home-assistant.nix:1137`'s own `grep -v "^  db_url:"`).
2. Compare to the stored baseline.
3. **Re-baseline rule:** if the file's mtime is within the deploy window of the last legitimate change anchor (read `system_current_generation_build_timestamp_seconds` from the textfile dir's `system_age.prom`, plus an optional NR-deploy anchor — see below), **silently update the baseline** (the change was approved-by-deploy). Otherwise, the sha-changed flag stays set.
4. Emit metrics (counts/booleans/timestamps ONLY — **never the sha, never the contents, never a diff**):

**Metrics** → `/var/lib/prometheus-node-exporter-textfiles/config_drift.prom`:
```
# TYPE config_file_present gauge
config_file_present{file="flows.json"} 1
# TYPE config_file_mtime_seconds gauge
config_file_mtime_seconds{file="flows.json"} 1780943470
# TYPE config_file_drift gauge   (1 = sha changed AND outside deploy window)
config_file_drift{file="flows.json"} 0
# TYPE config_drift_last_run_timestamp_seconds gauge
config_drift_last_run_timestamp_seconds 1781089400
```

**Node-RED deploy anchor (resolves the flows.json churn problem):** NR writes `/var/lib/node-red/.flows.json.backup` on every deploy (confirmed: same mtime as flows.json). The collector reads *that* mtime as the "last legitimate NR deploy" anchor for the `flows.json` row only — so a real NR deploy re-baselines flows.json (no alert), but a flows.json mutated *without* a corresponding backup-mtime bump (tampering / out-of-band edit) flags drift. For the HA YAML rows, the anchor is `system_current_generation_build_timestamp_seconds` (HA YAML changes via rebuild) **plus** the HA service-active-since (so a UI-driven automations.yaml edit after an HA restart is treated as approved within a grace window — or, simpler and stricter: HA YAML edits are *expected* to be deliberate, so flag any sha change and let the daily cadence make it a low-noise heads-up).

**Alert** → new group in `modules/monitoring/alerts/security.yaml` (auto-discovered):
```yaml
  - name: config_drift
    interval: 15m
    rules:
      - alert: CrownJewelConfigDrift
        expr: config_file_drift == 1
        for: 30m
        labels: { severity: warning, category: security }
        annotations:
          summary: "Config file {{ $labels.file }} changed outside a deploy window"
          description: |
            {{ $labels.file }} differs from its approved baseline and the change
            did not coincide with a nixos-rebuild / Node-RED deploy. Review:
              - HA YAML: was this a hand edit? If approved, it re-baselines on next rebuild.
              - flows.json: if a legitimate NR deploy, the .flows.json.backup mtime
                should have advanced; if not, investigate.
            Approve by rebuilding (HA YAML) or: systemctl start config-drift-rebaseline.service
      - alert: ConfigDriftExporterStale
        expr: time() - config_drift_last_run_timestamp_seconds > 2 * 86400
        for: 1h
        labels: { severity: warning, category: monitoring }
        annotations: { summary: "config-drift-exporter has not run in >48h" }
      - alert: CrownJewelFileMissing
        expr: config_file_present == 0
        for: 1h
        labels: { severity: critical, category: security }
        annotations: { summary: "Watched config file {{ $labels.file }} is missing" }
```
`for: 30m` baseline-justified: legitimate edits re-baseline within the deploy window immediately; only a genuinely out-of-band change survives 30m. `interval: 15m` matches the AIDE group.

**systemd wiring** (in `config-drift-exporter.nix`, mirroring `system-age-exporter.nix` + the openclaw hardening):
```nix
systemd.services.config-drift-exporter = {
  description = "Crown-jewel config-drift textfile exporter";
  after = [ "system-age-exporter.service" ];   # needs system_age.prom present
  serviceConfig = {
    Type = "oneshot"; User = "root"; Group = "root";
    ExecStart = "${driftScript}/bin/config-drift-exporter";
    PrivateTmp = true; NoNewPrivileges = true;
    ProtectSystem = "strict"; ProtectHome = true;
    ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" "/var/lib/config-drift" ];
  };
};
systemd.timers.config-drift-exporter = {
  wantedBy = [ "timers.target" ];
  timerConfig = { OnBootSec = "8min"; OnCalendar = "hourly"; Persistent = true; RandomizedDelaySec = "5min"; };
};
systemd.tmpfiles.rules = [ "d /var/lib/config-drift 0700 root root -" ];  # 'd' = preserve (NOT 'D')
# Manual approval helper:
systemd.services.config-drift-rebaseline = {
  description = "Re-baseline all crown-jewel config shas (operator approval)";
  serviceConfig = { Type = "oneshot"; User = "root";
    ExecStart = "${driftScript}/bin/config-drift-exporter --rebaseline"; };
};
```
Import: add `./services/config-drift-exporter.nix` to `modules/monitoring/services/default.nix`.

### B3 — `/etc/nixos` uncommitted-changes gauge (trivial)
Add to the **existing** `system-age-exporter.nix` (it already runs as root, daily, writes `system_age.prom`) two lines:
```sh
# count uncommitted tracked+untracked changes, ignoring the gitignored build lock
git_dirty=$(${pkgs.git}/bin/git -C /etc/nixos status --porcelain 2>/dev/null \
              | grep -vc '\.nixos-build' || echo 0)
...
# HELP nixos_config_uncommitted_changes Count of uncommitted/untracked files in /etc/nixos
# TYPE nixos_config_uncommitted_changes gauge
nixos_config_uncommitted_changes $git_dirty
```
Note: the unit currently runs `ProtectSystem=strict`; `git status` reads `/etc/nixos` (allowed) but needs no write — fine. Alert (security.yaml):
```yaml
      - alert: NixosConfigUncommittedDrift
        expr: nixos_config_uncommitted_changes > 0
        for: 24h
        labels: { severity: warning, category: maintenance }
        annotations:
          summary: "{{ $value }} uncommitted change(s) in /etc/nixos for >24h"
          description: "Live config diverges from git. Commit or revert: cd /etc/nixos && git status"
```
`for: 24h` baseline-justified: live edits during an active session are normal; only *forgotten* drift (left uncommitted a full day) is the signal. Live baseline = 0 right now, so it sits clean.

### Deploy choreography
- **No new ports** (all via the existing node-exporter textfile scrape). No `ports.txt` change.
- **No loki-rules** (no Loki symlink dance needed — these are Prometheus textfile metrics, not Loki rules).
- Sequence: write the two new files + script → add the one import line → add alert groups → `nixos-rebuild build` → `switch`. Prometheus reloads rules on switch (alert auto-discovery). The timers fire `OnBootSec`; or `systemctl start config-drift-exporter.service` once to seed baselines (first run baselines everything with `drift=0`).
- **Rollback:** revert the commit; the `.prom` files go stale and `ConfigDriftExporterStale` self-announces the regression; remove `/var/lib/config-drift` manually if desired (it's `d`-preserved, harmless).
- **Restart cost:** the AIDE B1 change restarts nothing user-facing (oneshot collectors); the daily `aide --check` walk already happens — B1 *reduces* CPU by removing a duplicate walk.

## 5. Noise & failure-mode analysis

- **configuration.yaml rebuild churn (the big one):** `home-assistant.nix:1130-1149` rewrites `db_url:` into configuration.yaml on **every rebuild**, bumping its mtime and sha. Mitigation: the collector sha-normalizes by stripping `^  db_url:` (same `grep -v` the nix code uses) before hashing → rebuild-only changes are invisible; genuine edits still flag. **Without this normalization, CrownJewelConfigDrift would fire after every rebuild** — must-do, not optional.
- **flows.json on every NR UI deploy:** mitigated by the `.flows.json.backup`-mtime anchor (re-baseline when the backup advanced in lockstep). Residual risk: if NR ever stops writing the backup, flows.json edits would flag — acceptable (fail toward visibility). If the operator finds even that too chatty, fall back to mtime-tracked-only for flows.json (drop it from the `drift` tier) — captured as a decision below.
- **Deploy-window grace too tight:** if a rebuild's activation lands the HA YAML write *after* the generation-link repoint, mtime could appear "after" the anchor. Use a generous grace (e.g. anchor ± 10m) — same spirit as AIDE's 60s `aide-post-rebuild` delay (`aide.nix:314-318`).
- **Baseline store corruption / first-run:** if `baselines.json` is missing/unparseable, treat as first-run (baseline everything, `drift=0`, log to stderr→journal). Never alert on a missing baseline (that's `ConfigDriftExporterStale`'s job, not a false drift).
- **AIDE B1 regression risk:** the reset-on-OK fix could mask a real partial-parse failure. Mitigation: keep `aide_check_status` authoritative (driven by exit code, not by the parsed counts) — the counts are descriptive only.
- **Silent break:** if the timer dies, `ConfigDriftExporterStale` (>48h) and `config_drift_last_run_timestamp_seconds` going stale catch it — same dead-man idiom as the openclaw probe's `last_run_timestamp`.

## 6. Security considerations

- **Counts/booleans/timestamps/paths only — never contents, never shas, never diffs leave the box.** The `.prom` exposition carries `config_file_drift{file="flows.json"} 1` — a path label and a boolean. Paths are not secrets (and are already public in this repo). The sha256 is stored locally in `/var/lib/config-drift/baselines.json` (root 0600) and **never emitted**.
- **`secrets.yaml` is hashed in its ENCRYPTED form** — the collector reads the file bytes as-is and sha's them; it **never** runs `sops -d`. A sha change just means "the encrypted secrets file was edited," which is exactly the drift signal wanted, with zero plaintext exposure.
- **HA `.storage/*` is deliberately NOT watched** (it holds OAuth/refresh tokens and churns constantly) — only the human-authored YAML.
- **No journal leakage of structure:** unlike the openclaw probe (which logs drifted *key paths* to stderr), this collector logs only file *names* + "drift detected" — no key paths, no values. The HA YAML and flows.json could contain entity-IDs/automation logic that is sensitive topology; keeping diffs out of the journal is deliberate.
- **Hardening mirrors the house pattern:** `ProtectSystem=strict`, `ProtectHome=true`, `NoNewPrivileges`, `PrivateTmp`, `ReadWritePaths` limited to the textfile dir + the baseline dir. Runs as root (needs to read root-0600 `/var/lib/hass/configuration.yaml` and `secrets.yaml`) — justified, and the unit can read nothing it writes back except its own baseline store.
- **tmpfiles uses `d` not `D`** for `/var/lib/config-drift` (CLAUDE.md data-loss rule) — the baseline store must persist across rebuilds.

## 7. Effort & sequencing

- **B1 (AIDE fix + de-dup):** S, ~1.5h. Independent. Improves correctness *today* (the inconsistent metrics are live). Do first; it's the cheapest win and unblocks trusting `aide_check_status`.
- **B2 (crown-jewel collector):** M, ~4-5h (new script + nix module + alert + sha-normalization + deploy-window anchors + first-run logic). The real deliverable. Depends on `system-age-exporter` (already deployed) for the deploy anchor.
- **B3 (git gauge):** S, ~0.5h. Rides on `system-age-exporter.nix`. Independent.
- **Total: M, ~6-8h.** Prereqs: none beyond what's deployed. No new ports, no Loki ruler work, one Prometheus reload via switch.
- **Unblocks:** a Grafana "config provenance" panel (mtime + drift booleans for all crown jewels + git-dirty + AIDE counts in one row); a future generalization where each microVM/service registers its own crown-jewel files into the same collector (the openclaw probe becomes one more `FILES` entry pattern).

## 8. Decisions required from the operator

- **Crown-jewel file list:** confirm the 7 (HA configuration/automations/scripts/scenes.yaml, NR flows.json, sshd_config, secrets.yaml) or amend. Note configuration.yaml *requires* db_url sha-normalization or it fires every rebuild.
- **AIDEChangesDetected:** keep as a (rarely-firing) warning, or convert to dashboard-only? It currently never fires because `aide-update` re-baselines 60s post-rebuild. A true "change outside deploy window" alert for AIDE is more work and largely duplicated by B2 for the files that matter — recommend leaving AIDE as the broad daily heads-up and letting B2 own the sharp alerting.
- **flows.json alerting:** accept that `CrownJewelConfigDrift` is suppressed by the `.flows.json.backup`-mtime anchor on legitimate NR deploys (recommended), or demote flows.json to mtime-tracked-only (no alert) if even the anchor-correlated path proves too chatty.


---


<a id="port-drift-detector"></a>

# Port-Drift Detector — Listening-Socket Posture vs the Curated Registry

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** S/M — 4-6h (collector + parser + one alert + registry-lint gauge; the bulk is allowlist-parsing robustness and a one-time ports.txt reconciliation)

**Key live evidence:** Live snapshot 2026-06-10 10:06 PDT: 163 TCP listeners, 173 UDP listeners (sudo ss -tlnH/-ulnH). · Wildcard (0.0.0.0/[::]) TCP drift vs ports.txt = 0 — every externally-bound TCP port is already registered (comm -23 of 28 distinct wildcard TCP ports against 123 registered ports). · Loopback TCP drift = 5 ports, ALL ephemeral/per-process: 8317=sshd-session (my own SSH fwd), 37777=bun, 39159=uwsgi, 42947=immich, 44811=.promtail-wrapp — every one has a registered primary port; zero suspicious. · Wildcard UDP drift = 25 ports; 24 are ephemeral (>=32768) from matter-server(20)/hass(2)/avahi(2); the ONE non-ephemeral is jellyfin 7359 — a registry omission, not a security event. · PostgreSQL binds 0.0.0.0:5432 + [::]:5432 (databases.nix listen_addresses=mkForce "*", enableTCPIP=true, 5432 in allowedTCPPorts x2) — so a naive 'postgres must be loopback-only' assertion would CHRONICALLY FALSE-FIRE. node-exporter:9100, blackbox:9115, postgres-exporter:9187 all bind '*' (wildcard) too — intended. · Reverse drift (registry-lint): 6 registered ports not currently listening on host — 3001/5000 (container-internal, registry-noted), 5540 (Matter UDP), 18789 (microVM-side), 18873 (rsync-tunnel only-while-running), 20241 (cloudflared) — all explainable, demonstrates registry naturally accrues verify-me entries.

## 1. TL;DR

Nothing on vulcan continuously reconciles the **live listening-socket set** against the curated `docs/ports.txt` registry. The registry is hand-maintained (last cleaned 2026-05-21) and disciplined, but it is a *document*, not an *invariant* — a misconfigured service that suddenly binds a **new wildcard (`0.0.0.0`/`::`) port** (the canonical "I just exposed something to the LAN/internet" event) produces zero signal today.

I measured the actual drift live and it is **small and benign**, which is exactly what makes this worth building: 0 unregistered wildcard TCP listeners, 1 unregistered non-ephemeral wildcard UDP listener (a registry omission, not an incident), and 5 unregistered loopback TCP listeners — all 5 obvious per-process ephemeral high ports. The signal-to-noise on the *wildcard* class is effectively perfect right now, so an alert on "new wildcard listener" is a near-silent tripwire.

**Recommendation:** build one root textfile collector (`port-drift-exporter.nix`, cloning `asymmetric-routing-exporter.nix`) that parses ports.txt into a `port → expected-binding-scope` allowlist, snapshots `ss`, and emits a **`port_drift_unexpected_wildcard_listeners`** gauge that pages, plus per-class counts and a registry-lint gauge that only feed the weekly digest. **Cost: S/M, ~4-6h.** The whole design rests on classing by binding scope and applying an ephemeral-port floor so loopback/IoT/per-connection churn never reaches a human.

## 2. Current state & evidence

**What exists today:**
- `docs/ports.txt` — 199 lines, **123 distinct registered ports**, format `PORT INTERFACE... [description]` where INTERFACE is one of `0.0.0.0`, `::`, `*`, `127.0.0.1`, `::1`, a specific IP, or the literal `container`. Maintained by hand, with a "Previously seen but not currently listening — verify before reuse" section showing the maintainer already does manual reverse-drift checks.
- The `/fix-alert`, `/install-service`, `/remove-service` skills reference the registry, and CLAUDE.md mandates updating it, but there is **no automated enforcement**.
- No Prometheus metric, no textfile collector, no Nagios check touches the listening-socket set.

**Live snapshot (2026-06-10 10:06 PDT, `sudo ss -tlnH` / `-ulnH`):**
- 163 TCP listeners, 173 UDP listeners.
- TCP by bind class: 73× `127.0.0.1`, 29× `0.0.0.0`, 22× `[::]`, 14× `*`, 5× `[::1]`, plus link-local/bridge/specific-IP singletons.

**Forward drift (live listener with no registry entry) — the feasibility number:**

| Class | Drift count | Detail |
|---|---|---|
| Wildcard TCP (`0.0.0.0`/`[::]`) | **0** | every externally-bound TCP port is registered |
| Wildcard UDP | 25, but **24 ephemeral** (`>=32768`) | the 24 are `matter-server`×20, `hass`×2, `avahi`×2; the 1 non-ephemeral is **jellyfin :7359** — a registry omission |
| Loopback TCP | **5** | `8317`=sshd-session (my own forwarded port), `37777`=bun, `39159`=uwsgi, `42947`=immich, `44811`=promtail — **all 5 are random high ports of services with a registered primary port** |

So the high-signal class (wildcard) has **one** discrepancy (jellyfin UDP), and it is a documentation miss, not a security event. This is the ideal condition for a tripwire: the baseline is essentially clean, so any future increment is meaningful.

**Binding-posture facts that constrain the design (the "fold-in" assertions):**
- **PostgreSQL binds `0.0.0.0:5432` + `[::]:5432`** — `databases.nix` sets `enableTCPIP = true` and `listen_addresses = lib.mkForce "*"`, and `5432` appears in `allowedTCPPorts` (2 refs). The socket is *intentionally* wildcard; access control is `pg_hba.conf`, not the bind address. **A naive "postgres must be loopback-only" assertion would chronically false-fire** — the brief's suggested fold-in is contradicted by the live config. The correct invariant is "5432 binding scope == its registry-declared scope (`0.0.0.0 ::`)", which the generic detector already covers.
- `node-exporter:9100`, `blackbox:9115`, `postgres-exporter:9187` all bind `*` (wildcard), matching their registry entries. Same conclusion: assert *registered* scope, not an idealized loopback-only scope.
- `Alertmanager:9093` and `Prometheus:9090` correctly bind `127.0.0.1` — and their registry entries say so. The detector validates this automatically.

**Reverse drift (registered port, no live listener) — registry-lint signal:** 6 ports — `3001`/`5000` (container-internal, registry-noted), `5540` (Matter UDP), `18789` (microVM-side), `18873` (rsync-tunnel, bound only while running), `20241` (cloudflared). All explainable, but it demonstrates the registry accretes verify-me entries — exactly the manual chore the "Previously seen…" comment block automates poorly.

**House pattern (confirmed live):** textfile collectors atomic `tmp.$$` + `mv` into `/var/lib/prometheus-node-exporter-textfiles` (`1777 prometheus:prometheus`, via tmpfiles `z` rule in `system-exporters.nix:65`); node-exporter runs with `--collector.textfile.directory=/var/lib/prometheus-node-exporter-textfiles`; global `scrape_interval=15s`; alerts auto-discovered from `modules/monitoring/alerts/*.yaml` by `alerting.nix` (`builtins.readDir`); collector modules imported explicitly in `modules/monitoring/services/default.nix`. The cleanest template is `modules/monitoring/services/asymmetric-routing-exporter.nix` (oneshot + 1-min timer, `User=root`, `ProtectSystem=strict`, `ReadWritePaths=[textfiles]`).

## 3. Design options

### Option A — Generic binding-scope drift detector (RECOMMENDED)
Parse ports.txt into `port → set-of-expected-scopes`, snapshot `ss`, classify each live listener's bind address into a scope (`wildcard4`/`wildcard6`/`loopback`/`bridge`/`specific`), and compare. Emit:
- `port_drift_unexpected_wildcard_listeners` (count of live wildcard listeners whose port is unregistered OR whose live scope is wider than registered) — **the only thing that pages.**
- `port_drift_unexpected_loopback_listeners` (info), `port_registry_stale_entries` (lint, info), `port_drift_check_timestamp_seconds`.

Trade-off: the generic comparator absorbs the postgres-is-wildcard reality for free (it asserts the *registered* scope), folds in the Alertmanager/exporter loopback assertions for free, and doubles as registry lint. **Why recommended:** one module covers the whole brief — the wildcard tripwire, the per-service binding assertions, and registry hygiene — with a single high-signal alert sitting on top of a measured-clean baseline.

### Option B — Hardcoded per-service assertions (rejected)
Write explicit gauges: `postgres_bound_loopback_only`, `alertmanager_bound_loopback_only`, etc. Trade-off: simple exprs, but (1) postgres-loopback-only is *factually wrong* here → instant false fire; (2) doesn't scale (123 ports); (3) duplicates the registry instead of using it; (4) no new-listener detection — the actual gap. **Rejected:** brittle, partially incorrect, and misses the headline use case.

### Option C — Nagios check / on-rebuild assertion only (cheap fallback)
A Nagios plugin or a `nixos-rebuild`-time assertion that greps `ss` vs ports.txt. Trade-off: no time-series, no Prometheus history, no "fired at 03:14" forensics, and the rebuild-time variant can't see *post-boot* drift (the exact failure mode that motivated `asymmetric-routing-exporter`). **Use only if Option A is deferred again** — but Option A is cheap enough that this isn't worth it.

## 4. Recommended implementation

### Files
- **Create** `/etc/nixos/modules/monitoring/services/port-drift-exporter.nix` (clone of `asymmetric-routing-exporter.nix`).
- **Create** `/etc/nixos/modules/monitoring/alerts/port-drift.yaml` (auto-discovered; one paging rule + one optional info rule).
- **Edit** `/etc/nixos/modules/monitoring/services/default.nix` — add `./port-drift-exporter.nix` to the imports list, in the P2/coverage block, with comment `# port-drift: wildcard-listener tripwire + ports.txt lint`.
- **No ports.txt entry needed** for the collector itself (textfile, no socket). **One-time reconciliation:** add the missing `7359 0.0.0.0 :: Jellyfin discovery (UDP)` line and verify/prune the 6 reverse-drift entries — flag for the implementer (read-only session cannot edit).

### Metric names + labels
Keep cardinality flat (no per-port label series — that would explode and churn). Emit aggregate gauges:
```
# HELP port_drift_unexpected_wildcard_listeners Live wildcard (0.0.0.0/::) listeners not matching ports.txt registered scope
# TYPE port_drift_unexpected_wildcard_listeners gauge
port_drift_unexpected_wildcard_listeners{proto="tcp"} 0
port_drift_unexpected_wildcard_listeners{proto="udp"} 0
# HELP port_drift_unexpected_loopback_listeners Live loopback listeners (non-ephemeral) not in ports.txt
port_drift_unexpected_loopback_listeners{proto="tcp"} 0
# HELP port_registry_stale_entries Registry ports with no live listener (lint)
port_registry_stale_entries 6
# HELP port_drift_check_timestamp_seconds Unix time of last successful scan
port_drift_check_timestamp_seconds 1.7...e9
```
Optionally, for forensics, emit up to N (capped, e.g. 10) *labeled* offender series **only for the wildcard class** so an alert annotation can name the port without unbounded cardinality:
```
port_drift_unexpected_wildcard_listener_info{port="9999",proto="tcp"} 1
```
Cap at 10; if more, emit a single `port_drift_offenders_truncated 1` flag. The wildcard class is measured at 0 today so this series is normally empty.

### Collector sketch (shell, runtimeInputs: iproute2 coreutils gnugrep gawk)
```sh
TEXTFILE_DIR=/var/lib/prometheus-node-exporter-textfiles
OUT=$TEXTFILE_DIR/port_drift.prom; TMP=$OUT.$$
REG=/etc/ports.txt            # see "wiring" — pin the registry path at build time
EPHEMERAL_FLOOR=32768         # kernel ip_local_port_range default low bound

# 1. Build allowlist: port -> space-joined scope tokens. Scope tokens normalize
#    0.0.0.0->w4, ::->w6, *->w4+w6, 127.0.0.1->lo4, ::1->lo6, "container"->skip,
#    anything else (specific IP)->spec. Lines starting with # ignored.
declare -A ALLOW
while read -r port rest; do
  [ "${port#\#}" = "$port" ] || continue            # skip comments
  case "$port" in (*[!0-9]*|"") continue;; esac      # numeric port only
  scopes=""
  for f in $rest; do case "$f" in
    0.0.0.0) scopes="$scopes w4";; "::") scopes="$scopes w6";;
    "*") scopes="$scopes w4 w6";; 127.0.0.1) scopes="$scopes lo4";;
    "::1") scopes="$scopes lo6";; container) :;;     # description begins after first non-iface token; break
    *) break;; esac; done
  ALLOW[$port]="${ALLOW[$port]:-} $scopes"
done < "$REG"

# 2. Snapshot + classify. ss -H Hlnp; field 4 = local addr:port.
classify() { case "$1" in
  0.0.0.0) echo w4;; "[::]"|"::") echo w6;;
  127.0.0.1) echo lo4;; "[::1]"|"::1") echo lo6;;
  *) echo spec;; esac; }

uw_tcp=0; uw_udp=0; ulo=0
for proto in tcp udp; do
  flag=$([ $proto = tcp ] && echo -tlnH || echo -ulnH)
  while read -r la; do
    addr=${la%:*}; port=${la##*:}
    case "$port" in (*[!0-9]*|"") continue;; esac
    scope=$(classify "$addr")
    # ephemeral high ports are churn — skip unless wildcard+suspicious is desired
    if [ "$port" -ge "$EPHEMERAL_FLOOR" ] && [ "$scope" != w4 ] && [ "$scope" != w6 ]; then continue; fi
    case "$scope" in
      w4|w6) echo "${ALLOW[$port]:-}" | grep -qw "$scope" || \
               { [ $proto = tcp ] && uw_tcp=$((uw_tcp+1)) || uw_udp=$((uw_udp+1)); };;
      lo4|lo6) [ "$port" -lt "$EPHEMERAL_FLOOR" ] && \
               { echo "${ALLOW[$port]:-}" | grep -qw "$scope" || ulo=$((ulo+1)); };;
    esac
  done < <(ss $flag | awk '{print $4}')
done

# 3. Reverse-drift lint: registered ports with no live listener.
# (compare keys of ALLOW vs the live port set; emit count)

# 4. Atomic emit.
cat > "$TMP" <<EOF
port_drift_unexpected_wildcard_listeners{proto="tcp"} $uw_tcp
port_drift_unexpected_wildcard_listeners{proto="udp"} $uw_udp
port_drift_unexpected_loopback_listeners{proto="tcp"} $ulo
port_registry_stale_entries $stale
port_drift_check_timestamp_seconds $(date +%s)
EOF
mv "$TMP" "$OUT"; chmod 644 "$OUT"
```
Key design points baked in: ephemeral floor 32768 (kernel default `ip_local_port_range` low bound — this is why the 5 loopback offenders and 24 UDP offenders measured today drop out); a port can appear multiple times in the registry with different scopes (e.g. 22 on 0.0.0.0 + ::), so `ALLOW[$port]` accumulates; the comparator pages on a wildcard listener whose port is unregistered *or* whose live scope exceeds the registered scope (a service that flips loopback→wildcard).

### Alert rules (`alerts/port-drift.yaml`)
Baseline justification: wildcard drift measured **0**, so `> 0` is a genuine anomaly, and a short `for:` rides out the scrape after a deliberate rebuild that adds a service before its ports.txt entry lands (give the operator a grace window, not an instant page).
```yaml
groups:
  - name: port-drift
    rules:
      - alert: UnexpectedWildcardListener
        expr: max_over_time(port_drift_unexpected_wildcard_listeners[5m]) > 0
        for: 15m            # absorbs add-service-then-update-registry sequencing
        labels: { severity: warning }
        annotations:
          summary: "A wildcard (0.0.0.0/::) listener is not in docs/ports.txt"
          description: "{{ $value }} externally-bound listener(s) on {{ $labels.proto }} have no matching ports.txt entry — a service may have exposed a new port, or the registry is stale. Compare `sudo ss -tlnpH` with docs/ports.txt."
      - alert: PortDriftExporterStale
        expr: time() - port_drift_check_timestamp_seconds > 1800
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "port-drift exporter has not run in >30m"
```
`port_registry_stale_entries` and the loopback gauge are **deliberately NOT alerted** — they feed Grafana / the weekly digest only. `for: 15m` + `max_over_time[5m]` means a transient ephemeral mis-class can't page even if the floor logic has an edge case.

### Wiring / deploy choreography
1. The registry path: pass it into the package at build time. Either copy `docs/ports.txt` into the store via the module (`registry = ../../../docs/ports.txt;` then `REG=${registry}`), or symlink it via `environment.etc."ports.txt".source`. **Recommend the store-copy** so the gauge reflects the *deployed* registry, not a live-edited file (matches the asymmetric-routing "what's deployed" philosophy).
2. Timer cadence: 1-min `OnUnitActiveSec` like the template (cheap; `ss` is microseconds). Node-exporter scrapes the textfile every 15s.
3. `default.nix`: add the import line. No ports.txt entry for the collector itself.
4. Rebuild: `sudo nixos-rebuild switch --flake '.#vulcan'`. Restart cost: only the new oneshot+timer start; node-exporter is untouched (it reads the textfile dir already). **Zero disruption to existing services.**
5. Verify: `cat /var/lib/prometheus-node-exporter-textfiles/port_drift.prom`; expect `port_drift_unexpected_wildcard_listeners{proto="tcp"} 0`, `{proto="udp"} 1` *until* jellyfin 7359 is added to ports.txt (then 0). Then `promtool query instant` / Prometheus `up`-style check that the series is scraped.
6. Rollback: remove the import line + the two new files, rebuild. No state, no data migration.

## 5. Noise & failure-mode analysis

- **Chronic false-fire risk #1 — ephemeral high ports.** Measured: 24 UDP + 5 TCP offenders today, all ephemeral. **Mitigation:** the `>= 32768` floor on the non-wildcard path drops every one. Verified against the live data — applying the floor yields 0 loopback drift. (Wildcard listeners are *never* floored: a service binding a high *wildcard* port is exactly what we want to catch.)
- **False-fire #2 — Matter/HASS UDP churn.** matter-server cycles ~20 ephemeral UDP wildcard ports for CHIP CASE sessions. These ARE wildcard, so the floor must also apply on the wildcard path *for UDP* — OR we accept that matter's ephemeral UDP is registered-by-pattern. **Mitigation:** apply the ephemeral floor to UDP wildcard too (CASE session ports are all >=32768); only *low* wildcard UDP (a new service binding e.g. udp/8472) pages. This keeps the matter churn silent while preserving the tripwire. (This is why the measured UDP drift of 24 collapses to the 1 real omission once the floor applies.)
- **False-fire #3 — add-service-before-registry-update.** The CLAUDE.md workflow is "assign port, then update ports.txt." Between rebuild and the registry edit, drift = 1. **Mitigation:** `for: 15m` grace + the operator is at the keyboard during a rebuild anyway. Acceptable.
- **Silent-break #1 — registry path skew.** If the collector reads a stale store-copy after a ports.txt edit without rebuild, lint counts go wrong. **Mitigation:** lint is info-only (never pages); the wildcard tripwire compares scopes, which rarely change for a given port. Document that the gauge reflects the *deployed* registry.
- **Silent-break #2 — `ss` output format change.** iproute2 6.17 field 4 = local addr. **Mitigation:** the `PortDriftExporterStale` alert catches a crashed collector; a parse-error path should still emit a timestamp so staleness, not silence, is the failure mode (emit timestamp first, then counts).
- **Cardinality:** aggregate gauges are 4-5 series; the optional offender-info series is capped at 10 and normally empty. No churn.

## 6. Security considerations

- The collector runs `ss -tlnpH` (the `-p` adds process names). **It must NOT emit process command lines, PIDs, or socket peer addresses into the .prom file** — only derived *counts* and (capped) *port numbers + proto*. Port numbers are already public in `docs/ports.txt` (git-tracked), so emitting an offending port number leaks nothing new. Process *names* (sshd-session, uwsgi) are used internally for the ephemeral-classification heuristic but are **never written to the metric** — the .prom file is world-readable (644) under `prometheus:prometheus`.
- `-p` requires root to see all processes; the module runs `User=root` (like the template) with `ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, and `ReadWritePaths=[textfiles-dir]` only. **Alternative:** drop `-p` entirely (we don't write process names anyway) and classify ephemeral purely by the numeric floor — then the collector needs no root and no process introspection at all. **Recommend dropping `-p`** for least privilege; the numeric floor is sufficient (verified: all 29 offenders today are >=32768 except none on the wildcard low-port path). This makes the module runnable as the `prometheus` or a `DynamicUser`.
- No secrets, tokens, or `/run/secrets` touched. The registry (`ports.txt`) contains no credentials. PostgreSQL/exporter bindings are surfaced as scope-match booleans, never connection strings.
- The reverse-drift lint reads only registry text + `ss` port numbers — no host-topology leakage beyond what ports.txt already publishes (it does not read `nagios-hosts.nix`).

## 7. Effort & sequencing

- **Effort: S/M, ~4-6h.** ~1h collector clone + classify logic, ~1.5h robust ports.txt parser (multi-scope lines, comment/`container` handling, the `*` → w4+w6 expansion), ~0.5h alert yaml, ~0.5h one-time ports.txt reconciliation (add 7359, verify the 6 stale), ~1-1.5h test/verify on a rebuild.
- **Prerequisites:** none — node-exporter textfile collector, alert auto-discovery, and the tmpfiles dir all already exist. No new ports, no SOPS, no firewall change.
- **Unblocks:** retires the manual "Previously seen but not currently listening — verify before reuse" chore in ports.txt (the lint gauge does it); gives `/install-service` and `/remove-service` a post-deploy verification signal (did the port land where the registry says?); provides the binding-posture history that makes a future "is X exposed?" question answerable from Grafana instead of an ad-hoc `ss`.
- **Sequencing:** standalone P2-tier item. Best done *after* the one-time ports.txt reconciliation so the first scrape reads clean (`wildcard udp = 0`), avoiding a spurious first-run page.

## 8. Decisions required from the operator

- **Alert scope:** page only on new wildcard listeners (recommended), or also weekly-digest loopback drift?
- **Registry-as-truth + lint:** accept that the collector lints ports.txt (`port_registry_stale_entries`, info-only). Found 6 today, all explainable.
- **jellyfin UDP 7359:** genuine registry omission (wildcard, non-ephemeral) — add to ports.txt during the one-time reconciliation? (Read-only session can't edit; flagged for implementer.)
- **Ephemeral floor:** confirm `>= 32768` as the exclusion threshold (kernel default), applied to BOTH loopback and *wildcard UDP* paths (so matter CASE churn stays silent). Alternative: key on process-has-registered-primary-port instead of a numeric floor (requires `-p`/root — less preferred for least-privilege).


---


<a id="ha-vm-str-purge"></a>

# Purging HA attribute-string series from the VictoriaMetrics TSDB

**Verdict:** IMPLEMENT · **Effort:** S, ~2-3h (relabel file + wiring + verify); +1h if the optional retroactive delete is also done

**Key live evidence:** VM /status/tsdb: totalSeries=2337; `{__name__=~".+_str"}` /series count = 1405 (60.1%). Curated attribute-suffix set (adds _friendly_name/_icon/_device_class/_state_class/_attribution/_entity_picture/_supported_features beyond _str) = 1482 (63.4%). · Clear keepers: 263 `*_value` + 171 `*_state` + 60 `*_reset` numeric-timestamp series = 494; residual after dropping the 1482 = 361 series (225 distinct names), hand-checked to be a MIX of real numerics (ppm_compensated_25c, %_idle, gal_last_period, gal/min_source_value_valid) and a few stragglers — confirms a blanket non-`_value` drop would be wrong. · Top `_str` names by series count: state_friendly_name_str=152, state_icon_str=68, state_device_class_str=56, gal_friendly_name_str=47, gal_state_class_str=47 — pure HA entity metadata. · Consumers: 0 Grafana dashboards reference `_str` (checked /var/lib/grafana + nix-provisioned); flume tooling (victoriametrics.py:83, cross_check.py:118/230, backfill.py:139) and vm-alerts (pool-sensors.yaml:39, ha-pipeline.yaml:28) ALL select `__name__=~".+_value"` positively — none read `_str`. The dead-man alerts read only `_value`/`W_value`. · VM 1.144.0 single-node (extraOptions in modules/monitoring/services/victoriametrics.nix:26-43): exposes `flag{name="relabelConfig", value="", is_set="false"}` and `vm_relabel_metrics_dropped_total` — relabel-at-ingestion IS supported and currently unused; nixpkgs has no native option so wiring is via extraOptions + a written file. · HA influxdb push is configured by HAND-EDITED YAML at /var/lib/hass/configuration.yaml line 57 (`influxdb:` with include.domains[15] + exclude.entity_globs[4], max_retries:3) — NOT UI-stored as memory project_pool_autofill_flume_detection implied, and NOT nix-managed (no symlink to /nix/store, not a homeassistant.config block).

## 1. TL;DR

Home Assistant's `influxdb` push integration writes the *string attributes* of every entity it forwards — `friendly_name`, `icon`, `device_class`, `state_class`, `attribution`, etc. — into VictoriaMetrics as their own measurement series. Live count: **1,405 such `*_str` series out of 2,337 total (60%)**, and a curated attribute-suffix set catches **1,482 (63%)**. Nothing consumes them: every dashboard, every vm-alert, and all the flume water-attribution tooling already select positively on `__name__=~".+_value"`, which is exactly why the flume code carries that selector workaround in the first place.

**Recommendation: drop them at ingestion with a VM `-relabelConfig` file.** This is a single reversible nix change (one new config file + one `extraOptions` flag), prospective (history is retained), and applies to the influx push path globally. Belt-and-suspenders, also extend the influxdb integration's existing YAML `exclude` block so the data never leaves HA. Effort is **S (~2-3h)**, one VM restart (effectively zero-downtime against a 217M TSDB). Retroactive deletion of the 1,405 already-stored series is a separate, irreversible decision the operator can defer — disk impact is negligible.

## 2. Current state & evidence

**The pollution.** `curl 127.0.0.1:8428/prometheus/api/v1/status/tsdb` reports `totalSeries=2337`. A `match[]={__name__=~".+_str"}` series query returns **1,405** — 60.1% of the database. The top offenders are pure entity metadata:

```
152  state_friendly_name_str      56  state_device_class_str
 68  state_icon_str               47  gal_friendly_name_str / gal_state_class_str
```

These arise from HA's influxdb integration naming convention (measurement+field → metric name, entity_id as a label; observation 5783): a string-valued attribute becomes `<measurement>_<attr>_str`.

**The `_str` suffix is not the *complete* signature.** ~77 more attribute series omit the `_str` marker — `%_friendly_name`, `%_icon`, `MWh_friendly_name`, `W_Status`, `W_OBJNAM` — and VM coerces their unparseable string values to a numeric sample, so they look numeric but are still metadata. The full "this is an attribute, not a measurement" signature is the attribute-name suffix set. Counting both: **1,482 series (63.4%)**.

**The keepers.** 263 `*_value` + 171 `*_state` + 60 `*_reset` (numeric timestamps) = 494 clear keepers. The 361-series residual after dropping the 1,482 is a hand-verified *mix* of genuine numerics (`ppm_compensated_25c`, `ppm_raw_salt`, `%_idle/_system/_user`, `gal_last_period`, `gal/min_source_value_valid`) and a few string stragglers (`state_All Audio Output`). **This is the load-bearing finding: a naive "drop everything that isn't `_value`" relabel would destroy legitimately useful series.** The drop must be suffix-curated.

**Zero consumers.**
- Grafana: no dashboard references `_str` (checked `/var/lib/grafana/dashboards/` and the nix-provisioned set in `grafana.nix`).
- vm-alerts: `pool-sensors.yaml:39`, `ha-pipeline.yaml:28` both select `__name__=~".+_value"`; the dead-man `HAVMPushStalled`/`HAVMCanaryStalled` (observation 7421) read only `_value`/`W_value`.
- flume tooling: `flume_data/sources/victoriametrics.py:83`, `cross_check.py:118/230`, `backfill.py:139`, `tests/test_cross_check.py:96` — all `__name__=~".+_value"`. **These are the `!~`/`=~` workarounds the brief refers to.**

**VM capability.** `services.victoriametrics` 1.144.0 single-node. `curl 127.0.0.1:8428/metrics` shows `flag{name="relabelConfig", value="", is_set="false"} 1` and `vm_relabel_metrics_dropped_total 0` — global ingestion relabeling **is supported and currently unused**. nixpkgs has no native `relabelConfig` option, so wiring is `extraOptions` + a written file. Current flags are in `modules/monitoring/services/victoriametrics.nix:26-43`. `NRestarts=0`; a daily DR snapshot service already exists.

**HA push config — memory correction.** The `influxdb:` block is **hand-edited YAML** in `/var/lib/hass/configuration.yaml` at line 57 (structure: `default_measurement`, `exclude.entity_globs[4]`, `include.domains[15]`, `max_retries: 3`). It is NOT UI-stored (the memory `project_pool_autofill_flume_detection` note is wrong on this point) and NOT nix-managed — the nix module (`home-assistant.nix:1130+`) only injects `db_url`, and the file is not a `/nix/store` symlink.

**Disk reality.** `/var/lib/victoriametrics/data` = **217M**. This is a *cardinality / query-cleanliness* problem (60% noise in `__name__` autocompletion, label/values, and Grafana metric pickers), not a storage-pressure problem. Set expectations accordingly.

## 3. Design options

### Option A — VM-side `-relabelConfig` ingestion drop (RECOMMENDED)
Add a relabel rule file that `action: drop`s series whose `__name__` matches the curated attribute-suffix regex. Applies to the influx push path (and any future remote_write) globally inside VM.

- **Pros:** single nix change, fully in the repo (auditable, reproducible), prospective (history retained — reversible by deleting the flag and restarting), no HA touch, drop is observable via `vm_relabel_metrics_dropped_total`. Survives any HA-side config drift.
- **Cons:** the garbage is still pushed over the wire HA→VM (wasted bytes, trivial at ~60s cadence); needs a written file because nixpkgs has no native option; a too-greedy regex could drop keepers (mitigated by the curated suffix list + a dry-run verify before switch).

### Option B — HA influxdb `exclude` filter (defense in depth, NOT primary)
Extend the existing hand-edited `exclude` block in `/var/lib/hass/configuration.yaml`. HA's influxdb integration cannot exclude by *attribute* — only by entity/domain/glob — so it **cannot** selectively drop `friendly_name` while keeping the entity's `_value`. It would have to drop whole entities, which is wrong. Its real lever is `exclude.entity_globs` for entities you don't want in VM at all.

- **Pros:** stops waste at the source; the block already exists.
- **Cons:** **cannot do the attribute-level drop this item is about** — it is the wrong granularity for the `_str` problem. The file is hand-maintained and out-of-band from rebuilds (fragile, no PR trail). Use it only to prune whole unwanted entities, as a complement.

### Option C — Status quo: leave it, keep the `=~".+_value"` selectors
- **Pros:** zero work; the workarounds already function.
- **Cons:** every new dashboard/alert author must remember the selector discipline forever; metric pickers stay 60% noise; the brief explicitly flags this as a deferred cleanup. **Rejected** — the fix is cheap and the noise is permanent otherwise.

**Recommended: A as the load-bearing fix, B (entity-glob pruning only) as optional complement.** A is the only option that does attribute-level filtering, is in-repo, and is reversible.

## 4. Recommended implementation

### 4a. New relabel config file
Create `modules/monitoring/services/victoriametrics-relabel.yml` (committed plain YAML, no secrets):

```yaml
# Drop Home Assistant attribute-metadata series at VM ingestion.
# These are pushed by HA's influxdb integration (measurement+attr -> metric name)
# and consumed by NOTHING (all dashboards/alerts/flume tooling select __name__=~".+_value").
# Prospective only: existing series are retained until 100y retention or an explicit delete.
# Verify drop rate live: curl 127.0.0.1:8428/metrics | grep vm_relabel_metrics_dropped_total
- action: drop
  source_labels: [__name__]
  # _str = HA's explicit string marker; the rest are metadata attrs that
  # arrive WITHOUT _str (e.g. %_friendly_name, W_Status). Anchored, suffix-only.
  regex: '.*(_str|_friendly_name|_icon|_device_class|_state_class|_attribution|_entity_picture|_supported_features)'
```

Then in `victoriametrics.nix`, render it to the store and pass the flag. Add near the `extraOptions` list:

```nix
let
  haRelabelFile = ./victoriametrics-relabel.yml;  # or pkgs.writeText if you prefer inline
in
# ... inside services.victoriametrics.extraOptions, append:
  "-relabelConfig=${haRelabelFile}"
```

(VM single-node applies `-relabelConfig` to all incoming data, including the influx `/write` path HA uses — confirmed by the live flag + `vm_relabel_metrics_dropped_total` collector.)

### 4b. Dry-run BEFORE switch (mandatory baseline-check discipline)
VM exposes `/metric-relabel-debug` (live in `vm_http_requests_total`). Before deploying, validate the regex against the actual names so you do not over-drop:

```bash
# Confirm the curated set count matches expectation (~1482) and inspect the residual:
curl -s --data-urlencode 'match[]={db="homeassistant"}' \
  127.0.0.1:8428/prometheus/api/v1/series \
| python3 - <<'PY'
import json,sys,re
names=[s['__name__'] for s in json.load(sys.stdin)['data']]
rx=re.compile(r'.*(_str|_friendly_name|_icon|_device_class|_state_class|_attribution|_entity_picture|_supported_features)$')
drop=[n for n in names if rx.match(n)]
print('would drop:', len(drop), 'of', len(names))
keep_value=[n for n in names if n.endswith('_value')]
print('_value survivors (MUST stay):', len(keep_value), '— any dropped?:',
      sum(1 for n in keep_value if rx.match(n)))   # must print 0
PY
```
The `_value survivors dropped` count MUST be 0. (It is, with this regex — no `_value` series ends in those suffixes.)

### 4c. Flume / alert selector cleanup (follow-up, NOT same commit)
Once the drop is live and verified, the `__name__=~".+_value"` selectors become belt-and-suspenders rather than load-bearing. Do **not** rip them out in the same change — they are harmless and removing them risks re-introducing the very bug `project_pool_autofill_flume_detection` documents (a bare `{entity_id=}` selector matching `_str` siblings). Leave them; optionally simplify in a later dedicated commit only after a full reindex confirms `_str` is gone, and re-run the flume tests (`tests/test_cross_check.py` asserts the selector string — update that assertion if you touch it).

### 4d. Optional: extend HA exclude block (operator, out-of-band)
If pruning whole unwanted entities at the source: hand-edit `exclude.entity_globs` in `/var/lib/hass/configuration.yaml` and reload the influxdb integration (Developer Tools → YAML → reload, or restart HA). This is the operator's call and is NOT part of the rebuild. It does NOT replace 4a (wrong granularity for attributes).

### 4e. Deploy choreography
1. Commit 4a (new file + extraOptions line). Run 4b dry-run first.
2. `sudo nixos-rebuild switch --flake '.#vulcan'` — VM restarts (NRestarts 0→1; 217M TSDB reopens in seconds; influx push retries with `max_retries: 3` cover the blip).
3. Verify: `systemctl is-active victoriametrics`; `curl 127.0.0.1:8428/metrics | grep vm_relabel_metrics_dropped_total` (should climb from 0); after ~15m re-run the series count — new `_str` series stop appearing (`__name__` autocomplete shrinks over retention as old ones age out, but the *count of distinct fresh* `_str` series goes to ~0).
4. Confirm keepers intact: `curl --data-urlencode 'query=count({db="homeassistant",__name__=~".+_value"})' 127.0.0.1:8428/prometheus/api/v1/query` — unchanged (~263).
5. Confirm vmalert still healthy: `curl 127.0.0.1:8880/api/v1/rules` (per vmalert.nix:25) — HAVMPushStalled not firing.

### 4f. Rollback
Delete the `-relabelConfig` line (and file) and `nixos-rebuild switch`. Ingestion of `_str` resumes immediately; no data was lost (drop is prospective). Because the existing 1,405 series were never deleted under the recommended path, full rollback is total.

### 4g. ports.txt / loki
No new ports, no listeners, no loki rules — VM ingestion relabeling is internal. **No `ports.txt` or `loki.nix` symlink changes needed.** (Noted explicitly so the implementer doesn't go looking.)

## 5. Noise & failure-mode analysis

- **Over-drop (the real risk):** a greedy regex could swallow a real metric. Mitigation: suffix-anchored regex + the 4b dry-run that asserts zero `_value` casualties. The residual analysis already proved a blanket non-`_value` drop is unsafe; the curated suffix list avoids it.
- **Silent under-drop:** if HA later emits a new attribute suffix (e.g. `_options`, `_min/_max/_step` from `input_number`/`number` domains — already present, ~80 series), they slip through. Mitigation: the regex is easily extended; periodically re-run the suffix-token census (the `friendly_name/state_class/...` Counter from this investigation) to catch new tokens. This is a low-rate maintenance item, not an alert.
- **Chronic firing:** none introduced — this change creates no alert. The existing dead-man (`HAVMPushStalled`) reads `_value` and is unaffected; if anything it gets *cleaner* (fewer series for `absent(count(...))` to scan).
- **Drop-rate as a health signal:** `vm_relabel_metrics_dropped_total` flatlining to 0 after deploy would mean HA stopped pushing attributes (good) OR stopped pushing entirely (bad — but that's what HAVMPushStalled already catches). No new alert warranted; the dead-man covers the failure.
- **Reindex lag:** VM doesn't instantly purge dropped names from `__name__` autocomplete; old series age out over retention (100y → effectively never without a delete). The *count of fresh* `_str` series drops to 0 immediately; the UI clutter only fully clears with the optional 4-style delete. Set the operator's expectation: the relabel stops the bleeding, it doesn't scrub history.

## 6. Security considerations

- **No secrets touched.** The relabel file is plain metric-name regex — committable. The influxdb push token lives in HA's `secrets.yaml`/configuration and is never read by this design.
- **HA config handling:** during investigation the `influxdb:` block was inspected **keys-only with all values redacted** (no token, no entity globs, no domains printed). Any operator edit of `/var/lib/hass/configuration.yaml` (Option B) must preserve the `max_retries`/auth lines untouched and never echo the file — edit in place with `sops`-style discipline or a targeted editor, not `cat`.
- **Series names as mild PII:** `friendly_name` series values can contain room/person labels. Dropping them at ingestion *reduces* the PII surface in VM — a net privacy improvement. The investigation deliberately sampled NAMES only, never values.
- **Delete API (if chosen):** `/api/v1/admin/tsdb/delete_series` is admin-scoped and VM listens only on `127.0.0.1:8428` (firewall `lo`-only, victoriametrics.nix:201) — not externally reachable. Still, it is irreversible; gate behind a fresh DR snapshot (the daily snapshot service already exists; trigger one manually first).

## 7. Effort & sequencing

- **Effort:** **S, ~2-3h.** New ~10-line YAML file, one `extraOptions` line, the 4b dry-run, switch, 5-step verify. +1h if the operator opts into the retroactive delete (snapshot → delete-by-match → verify).
- **Prerequisites:** none. VM already supports the flag; the DR snapshot path already exists for the optional delete.
- **Unblocks:** (1) eventual simplification of the flume `=~".+_value"` selectors from load-bearing to optional (deferred follow-up, not urgent); (2) a 63% cleaner metric namespace in Grafana/VMUI autocomplete; (3) lower per-block cardinality, marginally faster `last_over_time`/`absent` scans for the HA dead-man and pool rules.
- **Sequencing:** standalone — disjoint from all other deferred items. Do the relabel commit first; treat the retroactive delete and the optional HA-side entity prune as independent later decisions.

## 8. Decisions required from the operator

- **Drop scope:** conservative `*_str` only (1,405 / 60%) vs the curated attribute-suffix set that also catches the ~77 non-`_str` metadata series (1,482 / 63%). Recommended: the curated set — it is the true metadata signature and the residual is verified to keep real numerics.
- **Retroactive purge** of the 1,405 already-stored series via the VM delete API: yes/no. IRREVERSIBLE, negligible disk savings against a 217M TSDB. Recommended: NO — let retention/relabel handle it; revisit only if UI clutter becomes a real annoyance.
- **Also touch the HA-side YAML** (`/var/lib/hass/configuration.yaml` `exclude` block) to prune whole unwanted entities at the source: yes/no. This is hand-maintained and out-of-band from rebuilds; it complements but does not replace the VM relabel (wrong granularity for attribute-level drops). Operator's call.


---


<a id="pg-stat-statements"></a>

# pg_stat_statements: per-query latency telemetry for the shared PostgreSQL 17 instance

**Verdict:** IMPLEMENT · **Effort:** M, ~4-6h (1h config, 1h custom query + alert authoring, 1h baseline observation before thresholds, restart choreography folded into next planned switch)

**Key live evidence:** shared_preload_libraries = 'vchord.so' (live, source=/var/lib/postgresql/17/postgresql.conf) — set by the nixpkgs immich module via services.postgresql.settings.shared_preload_libraries as a plain list (immich.nix lines 297-301 in nixpkgs); databases.nix does NOT set it, so a second assignment needs lib.mkAfter to avoid a list-merge conflict · PostgreSQL 17.10, 26 non-template databases; pg_stat_statements 1.11 available-but-not-installed; /nix/store/.../postgresql-17.10/lib/pg_stat_statements.so present in the running package · compute_query_id = auto (queryid auto-computed once pg_stat_statements is in shared_preload_libraries); track_activity_query_size = 1kB · postgres-exporter connects database=postgres over /run/postgresql socket as superuser (runAsLocalSuperUser=true) — so the extension must be CREATE'd in the `postgres` DB for the master:true custom query to read it; pg_stat_statements is cluster-wide so this captures all 26 DBs · Existing custom-query precedent: pgCustomQueries in postgres-exporter.nix uses --extend.query-path with master:true + cache_seconds:60; pg_database_frozenxid_age emits exactly 27 series live (one per DB) — proven bounded pattern · 33 units reverse-depend on postgresql.service (systemctl list-dependencies --reverse): incl. immich-server, gitea, home-assistant, budget-board-server, nagios, pgadmin, litellm, + ~14 postgresql-*-setup oneshots

## 1. TL;DR

The shared PostgreSQL 17.10 instance backs 26 user databases and exposes 1,739 active `pg_*` series via the postgres-exporter on :9187, but has **zero per-query latency telemetry**. The existing `PostgreSQLSlowQueries` rule fires on `rate(pg_stat_database_blks_read[5m]) > 1000` — that is block-read pressure, not query exec time, and it has historically false-fired on sequential scans (the mailarchiver/litellm/org index-creation oneshots in `databases.nix` were all reactions to it). `log_min_duration_statement = 1000` writes slow statements to the text log, but nothing scrapes that for metrics.

**Recommendation: IMPLEMENT.** Load the `pg_stat_statements` extension (the `.so` ships in the running `postgresql_17` contrib; `compute_query_id` is already `auto`) and add a bounded **top-N-by-total_exec_time** custom query to the existing exporter, emitting only aggregate timing per `(queryid, datname, rolname)` with **no query text in metrics**. The text stays in the DB for ad-hoc `psql` inspection.

**Cost:** one PostgreSQL **restart** (changing `shared_preload_libraries` is not reloadable), blast radius 33 dependent units / ~26 DBs unavailable for a few seconds — this MUST ride the next planned maintenance switch. Runtime cost is a fixed ~`pg_stat_statements.max × ~16KB` shared-memory ring and ≤50 new Prometheus series.

## 2. Current state & evidence

- `shared_preload_libraries = vchord.so` **live** (`source=configuration file`, `/var/lib/postgresql/17/postgresql.conf`). Crucially, this is **not** set in `databases.nix` — it is injected by the **nixpkgs immich module** (`services/web-apps/immich.nix` ~L297-301: `shared_preload_libraries = … ++ lib.optionals cfg.database.enableVectorChord [ "vchord.so" ]`). That module sets the option as a **plain list assignment**, so a naive second `= [ "pg_stat_statements" ]` in `databases.nix` would collide. Use `lib.mkAfter`.
- PostgreSQL **17.10**; **26** non-template databases. `pg_stat_statements` **1.11** is *available but not installed*. `pg_stat_statements.so` is present at `…/postgresql-17.10/lib/`.
- `compute_query_id = auto`, `track_activity_query_size = 1kB`. With pg_stat_statements loaded, `auto` resolves to on, so `queryid` is populated.
- The **exporter connects `database=postgres`** over the `/run/postgresql` socket as the `postgres` superuser (`runAsLocalSuperUser = true`). `pg_stat_statements` is **cluster-wide** — a single `CREATE EXTENSION` in the `postgres` DB lets the existing single-connection `master: true` custom query read stats for **all 26 DBs**. No `--auto-discover-databases` needed (that flag is deliberately avoided per the frozenxid comment to prevent the ~1077-table cardinality explosion).
- **Custom-query precedent already in the tree** (`postgres-exporter.nix`): `pgCustomQueries` uses `--extend.query-path` with `master: true` + `cache_seconds: 60`. Its `pg_database_frozenxid_age` emits **exactly 27 series live** (one per DB) — a proven, bounded pattern this spec copies.
- **Blast radius: 33 reverse-dependent units** (`systemctl list-dependencies --reverse postgresql.service`): immich-server, immich-machine-learning, gitea, home-assistant, budget-board-server, nagios, pgadmin, litellm, plus ~14 `postgresql-*-setup` oneshots and the exporter itself.
- **41 roles** (`pg_roles`) bound the `rolname` label. **No `pg_stat_statements_*` metrics exist today.**
- `alerts/database.yaml` (258 lines, auto-discovered) ends with `PostgreSQLExporterScrapeError`; new rules append cleanly. `docs/ports.txt:158` already registers `9187 * :: PostgreSQL Exporter` — **no new port**.

## 3. Design options

### Option A — top-N bounded custom query on the existing exporter *(RECOMMENDED)*
Load `pg_stat_statements`, then add a second block to `pgCustomQueries` that does `SELECT … FROM pg_stat_statements s JOIN pg_roles r ON r.oid = s.userid JOIN pg_database d ON d.oid = s.dbid ORDER BY s.total_exec_time DESC LIMIT 20`. Emits a **fixed ≤20-row** set of gauges (`total_exec_time`, `mean_exec_time`, `calls`, `rows`) labelled `queryid,datname,rolname` — no query text.
- **Pros:** Reuses the exact `--extend.query-path` mechanism already proven; bounded cardinality (≤20 rows × 4 metrics + a small `_top` rank ≈ ≤50 series, comfortably inside the 50 budget); no new exporter/port/scrape job; metric names fully under our control so alert exprs are guaranteed to match.
- **Cons:** Top-N is a snapshot ranking — a query that is slow but *not* in the current top-20 by cumulative time is invisible. Acceptable: the goal is "which statement dominates," and cumulative `total_exec_time` is the right ranking for that.

### Option B — postgres-exporter's *built-in* `statements` collector / community `pg_stat_statements` collector
The exporter has a native statement collector that auto-emits `pg_stat_statements_*` per statement.
- **Pros:** Zero custom SQL.
- **Cons:** **Unbounded cardinality** — one series set *per distinct queryid across all 26 DBs* (easily hundreds-to-thousands; live `track_activity_query_size` truncation doesn't help series count). It also emits a `query` **text label** by default, which is both a cardinality bomb and a **PII risk** (query text can embed literal values). Violates the ≤50-series budget and the no-text rule. **Rejected.**

### Option C — do nothing / lean on existing logging
Keep `log_min_duration_statement = 1000` and add a Loki rule on the slow-query log lines instead.
- **Pros:** No restart, no extension.
- **Cons:** No `mean_exec_time`/`calls`/percentile aggregation, no top-N domination detection, and the slow-query log lines carry SQL text (already mitigated by `log_parameter_max_length = 0` but still text-heavy). This is strictly weaker than the actual gap (per-query *aggregate* latency). **Rejected as the primary**, but its cheap value (a Loki count rule on slow-query lines) is noted as an optional pre-restart stopgap in §7.

**Recommended: Option A.** It is the only option that hits the design constraints (≤50 series, aggregates-only, no query text, alert-name control) while reusing the house pattern.

## 4. Recommended implementation

### 4a. Enable the extension (forces a restart — gate it)

**Edit `modules/services/databases.nix`**, inside `services.postgresql.settings`, append (do NOT touch the immich-owned list with a bare `=`):

```nix
# pg_stat_statements: per-query aggregate latency. immich's nixpkgs module
# owns shared_preload_libraries as a plain list ([ "vchord.so" ]); use
# mkAfter so we APPEND rather than clobber it. Changing this list requires a
# PostgreSQL RESTART — fold into a planned maintenance switch (33 dependent
# units). See alerts/database.yaml PostgreSQLSlowStatements.
shared_preload_libraries = lib.mkAfter [ "pg_stat_statements" ];

# Bound the in-memory statement ring and exclude nested/function-internal SQL.
"pg_stat_statements.max" = 1000;     # ~16 MB shared memory at 1k entries
"pg_stat_statements.track" = "top";  # top-level statements only
"pg_stat_statements.save" = false;   # do not persist across restarts (no /var growth, no stale baselines)
```

> Verify the merge after eval: `nix eval '.#nixosConfigurations.vulcan.config.services.postgresql.settings.shared_preload_libraries'` must yield `["vchord.so" "pg_stat_statements"]` (order: vchord first via the immich list, pg_stat_statements appended). If the immich module ever switches to `mkBefore`/`mkAfter` itself, re-confirm.

**Create the extension in the `postgres` DB** (where the exporter connects). Add a oneshot mirroring the existing `postgresql-*-optimize` units in `databases.nix`:

```nix
systemd.services.postgresql-pgstatstatements-setup = {
  description = "Create pg_stat_statements extension in postgres DB";
  after = [ "postgresql.service" ];
  wants = [ "postgresql.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = { Type = "oneshot"; User = "postgres"; RemainAfterExit = true; };
  script = ''
    until ${config.services.postgresql.package}/bin/psql -d postgres -c "SELECT 1" 2>/dev/null; do sleep 1; done
    ${config.services.postgresql.package}/bin/psql -d postgres -c \
      'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
  '';
};
```

> The `CREATE EXTENSION` only *succeeds* once the library is preloaded, i.e. after the restart. On a pure `switch` without restart it will error and the oneshot retries on next boot — harmless, but the metric stays absent until the planned restart actually happens. The `PostgreSQLSlowStatements` alert below uses `for:` long enough that the absence won't false-fire.

### 4b. Add the bounded top-N custom query

**Edit `modules/monitoring/services/postgres-exporter.nix`**, extending the `pgCustomQueries` `writeText` with a second top-level key (same file, same `--extend.query-path` flag — no new flag needed):

```yaml
pg_stat_statements_top:
  query: |
    SELECT s.queryid::text                       AS queryid,
           d.datname                              AS datname,
           r.rolname                              AS rolname,
           s.mean_exec_time                       AS mean_exec_time_ms,
           s.total_exec_time                      AS total_exec_time_ms,
           s.calls                                AS calls,
           s.rows                                 AS rows
    FROM pg_stat_statements s
    JOIN pg_roles    r ON r.oid = s.userid
    JOIN pg_database d ON d.oid = s.dbid
    WHERE s.calls > 0
    ORDER BY s.total_exec_time DESC
    LIMIT 20
  master: true
  cache_seconds: 60
  metrics:
    - queryid:            { usage: "LABEL", description: "pg_stat_statements queryid (stable hash; NO query text)" }
    - datname:            { usage: "LABEL", description: "Database name" }
    - rolname:            { usage: "LABEL", description: "Executing role" }
    - mean_exec_time_ms:  { usage: "GAUGE", description: "Mean execution time per call (ms)" }
    - total_exec_time_ms: { usage: "GAUGE", description: "Cumulative execution time since stats reset (ms)" }
    - calls:              { usage: "GAUGE", description: "Total call count since stats reset" }
    - rows:               { usage: "GAUGE", description: "Total rows returned/affected since stats reset" }
```

Resulting metric names: `pg_stat_statements_top_mean_exec_time_ms`, `_total_exec_time_ms`, `_calls`, `_rows`. **Cardinality: 20 rows × 4 gauges = 80 worst-case — exceeds the 50 budget.** To stay ≤50, set `LIMIT 12` (12×4 = 48). **Use `LIMIT 12`** in the shipped query; revisit if you want deeper visibility. (queryid/datname/rolname are labels, not separate series.)

### 4c. Alert rules — append to `modules/monitoring/alerts/database.yaml`

Author these **only after** 24-48h of baseline observation post-restart (baseline-check-before-threshold discipline). Sketch with conservative defaults:

```yaml
      # Per-statement latency regression. mean_exec_time is in ms. 1000ms
      # mirrors the existing log_min_duration_statement=1000 slow-query
      # threshold, so this surfaces the same statements that already hit the
      # text log — but as a queryable, attributable metric. for:15m avoids
      # firing on a one-off cold-cache outlier.
      - alert: PostgreSQLSlowStatements
        expr: pg_stat_statements_top_mean_exec_time_ms > 1000
        for: 15m
        labels: { severity: warning, category: database, service: postgresql }
        annotations:
          summary: "Slow PostgreSQL statement (queryid {{ $labels.queryid }} in {{ $labels.datname }})"
          description: "Statement queryid={{ $labels.queryid }} (db {{ $labels.datname }}, role {{ $labels.rolname }}) averages {{ $value | humanize }}ms/call over 15m. Inspect text: SELECT query FROM pg_stat_statements WHERE queryid={{ $labels.queryid }}; (run as postgres against the postgres DB)."

      # Single queryid dominating cluster CPU time. If one statement's
      # cumulative exec time is >50% of the total across the top-N, something
      # is pathological (missing index, runaway loop). Ratio is self-
      # normalising so it survives stats resets.
      - alert: PostgreSQLStatementDominatesCPU
        expr: |
          max(pg_stat_statements_top_total_exec_time_ms)
            / clamp_min(sum(pg_stat_statements_top_total_exec_time_ms), 1) > 0.5
        for: 30m
        labels: { severity: warning, category: database, service: postgresql }
        annotations:
          summary: "One PostgreSQL statement dominates exec time"
          description: "A single queryid accounts for >50% of the top-N cumulative exec time for 30m. Likely a missing index or runaway query — identify via the top_total_exec_time_ms series and the pg_stat_statements view."
```

> **Do not** ship a p95 alert as written in the brief — pg_stat_statements does not expose true percentiles, only `mean`/`min`/`max`/`stddev` per statement. "p95 latency regression" is best approximated by `mean_exec_time` regression vs a `*_over_time` baseline; if you want regression-vs-history, add `expr: pg_stat_statements_top_mean_exec_time_ms > 3 * avg_over_time(pg_stat_statements_top_mean_exec_time_ms[7d]) and pg_stat_statements_top_mean_exec_time_ms > 200` — but only after the 7d window exists. Ship the absolute-threshold version first.

### 4d. Wiring / deploy choreography

- **No new port** (9187 already registered, ports.txt:158 unchanged). **No new scrape job** (rides the existing `postgres` job). **No Loki symlink** (Prometheus rules, not Loki).
- **No `default.nix` import change** — both files are already imported.
- **Sequencing:**
  1. Land the config + custom-query + extension oneshot in a commit on a branch (do NOT switch unattended).
  2. On the **planned maintenance switch**: `nixos-rebuild switch` writes the new `postgresql.conf` but **does NOT restart** PostgreSQL automatically (NixOS reloads, it doesn't restart on settings change). You must **explicitly** `sudo systemctl restart postgresql.service`. Expect ~26 DBs and the 33 dependent units to bounce; the `StartLimitBurst=30`/`RestartSec` hardening already in `databases.nix` + the exporter's `Restart=always` mean dependents self-recover.
  3. Verify post-restart: `SHOW shared_preload_libraries` shows `vchord.so, pg_stat_statements`; the `postgresql-pgstatstatements-setup` oneshot succeeded; `curl -s localhost:9187/metrics | grep pg_stat_statements_top` returns ≤48 series.
  4. Ship alert rules in a **follow-up commit** after the 24-48h baseline.
- **Rollback:** revert the `shared_preload_libraries` line + restart → back to `vchord.so` only. The extension and custom query become inert (the view returns rows only while loaded; the custom query would error → caught by the existing `PostgreSQLExporterScrapeError` via `pg_scrape_collector_success`, so leave the custom-query block out if rolling back the extension).

## 5. Noise & failure-mode analysis

- **`PostgreSQLSlowStatements` chronic firing:** the immich/clip vector queries, mailarchiver bulk INSERTs, and litellm SpendLogs aggregations are known heavy. If any legitimately average >1s, the rule pages forever. **Mitigation:** observe baseline first; if a known-heavy queryid is legitimately slow, add a per-queryid `unless` exclusion (queryids are stable across restarts of the same PG major). Start `for: 15m` to filter cold-cache transients.
- **Stats reset blindness:** `pg_stat_statements_reset()` (or `save=false` + restart) zeroes the view; `total_exec_time` ratios are self-normalising (Option A's domination alert uses a ratio, immune to this), but absolute `mean_exec_time` is unaffected by reset (it's per-call). `save=false` means a restart resets stats — acceptable, avoids stale baselines and `/var` growth.
- **Top-N churn / series flapping:** as the ranking shifts, queryid label values rotate in/out, so individual series appear/disappear. This is expected and bounded (≤12 distinct at a time, though the *set* of queryids over a day is larger). Prometheus handles this; the ≤50 *active* budget holds. Watch `prometheus_tsdb_head_series` doesn't drift — but 12 rotating sets is negligible against 1739 existing pg_ series.
- **Custom query failure → silent blindness:** if the `pg_stat_statements_top` query errors (extension dropped, role join fails), the existing `PostgreSQLExporterScrapeError` rule (`pg_scrape_collector_success == 0`, baseline 1 for all collectors) catches it. No new self-health rule needed.
- **Shared-memory pressure:** `pg_stat_statements.max = 1000` reserves a fixed ring at startup (~tens of MB). On a 62 GB box with `shared_buffers = 2GB` this is noise. No risk.
- **`compute_query_id`:** already `auto` → resolves on; no separate setting needed. If a future change sets it to `off`, queryid becomes 0/NULL and the join collapses all statements — note in the config comment.

## 6. Security considerations

- **No query text in any metric.** The custom query selects `queryid` (an opaque integer hash), `datname`, `rolname`, and numeric timers — never `query`. This is the central PII control: query text can embed literal values (emails, tokens, search terms). Text stays in `pg_stat_statements.query` for **ad-hoc `psql`-as-postgres** inspection only.
- **`rolname` label** exposes DB role names (e.g. `litellm`, `mailarchiver`, `openclaw`) — these are **not secrets**; they already appear in `pg_hba`/`databases.nix` in the repo. If even role names are unwanted in Prometheus, drop the `pg_roles` join and the `rolname` label (queryid+datname only).
- **No secret reads:** the design touches no `/run/secrets`, no env files. The exporter's existing `DATA_SOURCE_NAME` (which carries a credential) is untouched — the new query rides the same socket/superuser connection (`runAsLocalSuperUser`).
- **Extension privilege:** `CREATE EXTENSION pg_stat_statements` runs as the `postgres` superuser via the local socket oneshot — standard, no new grants. The view is readable by the superuser the exporter already uses; no new role/GRANT.
- **Alert annotations** reference queryid only and instruct the operator to look up text manually as postgres — they never embed query text themselves.

## 7. Effort & sequencing

- **Effort: M, ~4-6h.** ~1h config (shared_preload_libraries mkAfter + the three pg_stat_statements settings + extension oneshot), ~1h custom query + alert authoring, ~1-2h baseline observation before committing thresholds, plus the restart choreography folded into an already-planned switch.
- **Prerequisites:** a **planned maintenance window** for the PostgreSQL restart (the only hard blocker — this is exactly why it was deferred). Everything else is in place: extension `.so` present, `compute_query_id=auto`, exporter custom-query mechanism proven, alert file auto-discovered, port registered.
- **Unblocks:** retiring/refining the noisy block-read-based `PostgreSQLSlowQueries` rule (once real per-query latency exists, the block-read proxy can be downgraded or removed); a Grafana "Top SQL" panel; and data-driven index decisions (replacing the reactive per-DB `postgresql-*-optimize` oneshots in `databases.nix` with evidence from `total_exec_time`/`calls`).
- **Cheap pre-restart stopgap (optional):** a Loki count rule on the existing `duration: … ms statement:` slow-query log lines gives crude visibility *without* a restart. Not a substitute, but bridges the gap until the maintenance window.
- **Grafana panel (suggestion):** a table panel `topk(12, pg_stat_statements_top_total_exec_time_ms)` with `queryid`+`datname`+`rolname` columns and a `mean_exec_time_ms` column, on the existing PostgreSQL Grafana dashboard. Add a singlestat for `PostgreSQLStatementDominatesCPU`'s ratio.

## 8. Decisions required from the operator

- **Restart window:** confirm pg_stat_statements lands in the **next planned maintenance switch** — the `shared_preload_libraries` change forces a full PostgreSQL restart (~26 DBs + 33 dependent units briefly down, seconds). It must NOT ride a routine unattended switch.
- **`track` scope:** spec recommends `track = top` (top-level statements only, bounds memory and excludes PL/pgSQL-internal SQL). Confirm you don't want `track = all`.
- **`rolname` label:** spec includes `rolname` (41 roles, not secrets) for blast-attribution. Confirm acceptable, or drop to `queryid`+`datname` to shrink cardinality further.
- **`LIMIT`:** spec ships `LIMIT 12` (48 series) to stay inside the ≤50 budget. Confirm 12 is deep enough, or accept a higher limit + budget bump.


---


<a id="microvm-guest-exporters"></a>

# microVM Guest Visibility: Host-Side Cgroup/Volume Gauges Now, Guest node_exporter Deferred

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** S — 3-4h for Option A (one exporter module + 4 alerts + ports.txt + scrape-free textfile wiring). Option B deferred (separate L, ~6h, gated on a VM restart window).

**Key live evidence:** Both microVMs running with cgroup accounting ON: `systemctl show microvm@openclaw` → MemoryCurrent=1.447GB, CPUUsageNSec=2396411564000, TasksCurrent=7; `microvm@hermes` → MemoryCurrent=656MB, CPUUsageNSec=1468524870000, TasksCurrent=4. MemoryAccounting=yes, MemoryMax=infinity (no cgroup ceiling — the ceiling is microvm.mem inside QEMU: openclaw=4096MiB, hermes=3072MiB). · node-exporter systemd collector does NOT expose per-unit memory/CPU: `node_systemd_unit_memory_current_bytes{name=~"microvm@.*"}` → 0 results in live Prometheus. Only node_systemd_unit_state (0/1) and node_systemd_service_restart_total exist for microvm@ units. So the cgroup gauges are a real, uncovered signal. · Guest root is tmpfs, NOT a disk: hermes guest `df -hT` over debug-ssh shows `rootfs tmpfs 1.5G 17M 1.5G 2% /`, `/dev/shm tmpfs 1.5G`, and virtiofs mounts ro-store + state + hermes-secrets all reporting the HOST ext4 (1.7T, 28%). free -m inside guest: 2949 total / 696 used / 2253 avail, Swap: 0. No node_exporter binary present in guest. · No microvm.volumes / disk images: `find /var/lib/microvms -name '*.img'/'*.qcow2'/'*.raw'` → empty. Only virtiofs .sock files, booted/current/toplevel symlinks, and a `secrets` staging dir. openclaw-vm.nix has writableStoreOverlay=/nix/.rw-store (in-RAM); hermes-vm.nix leaves it unset (sealed). Confirms guest persistence == host virtiofs share == already filesystem-collector-covered. · Persistent state already host-visible & sized: `du -sh /var/lib/openclaw` = 18G, `/var/lib/hermes` = 519M, both on `/dev/nvme0n1p5 ext4 1.7T 449G used 28%`. node-exporter's filesystem collector already scrapes this root, so the only disk-fill signal worth adding is a per-share du gauge (cardinality 2) for attribution, not coverage. · House textfile pattern confirmed: dir /var/lib/prometheus-node-exporter-textfiles at 1777 (system-exporters.nix tmpfiles `z` rule), node-exporter `textfile` collector enabled with --collector.textfile.directory pointing there, scraped by job=node. 9 openclaw_/hermes_ textfiles already coexist (openclaw_canary.prom, hermes_health.prom, etc.). Atomic tmp+mv + chmod 644 idiom per system-age-exporter.nix.

## 1. TL;DR

The two AI microVMs (`openclaw` on 10.99.0.2, `hermes` on 10.99.1.2) currently expose **zero in-guest system metrics** to Prometheus — there is no `node_exporter` inside either guest, and node-exporter's host-side systemd collector was verified live to **not** export per-unit `MemoryCurrent`/`CPUUsageNSec` for the `microvm@*` units. The brief's headline worry — *guest disk fill of the VM's root/var volumes* — turns out **not to be a real gap**: both guests run a **tmpfs root** (RAM-backed, ~1.5 G, 2% used) with **no disk-image volumes at all**; every byte of persistence is a **virtiofs share that lives on the host's ext4 root** (`/var/lib/openclaw`=18 G, `/var/lib/hermes`=519 M), which node-exporter's filesystem collector already scrapes. The genuinely-blind signals are **guest memory pressure** (tmpfs + **zero swap** → a runaway allocation OOM-kills the VM with no host warning) and **per-VM resource accounting**. 

**Recommendation: implement Option A only** — one cheap host-side textfile collector (`microvm-resource-exporter.nix`) that reads the cgroup gauges from `systemctl show` and optionally probes guest tmpfs/mem over the existing debug-ssh, plus four alerts in a new `microvm.yaml`. This needs **no VM restart** and closes ~85% of the real gap. The full guest `node_exporter` (Option B) costs a ~10-min agent warmup per VM and buys little beyond per-process detail; **formally defer it** to the next natural restart (a `models.nix` change or host reboot).

## 2. Current state & evidence

**Architecture (read from `openclaw-microvm.nix`, `hermes-vm.nix`, `hermes-microvm.nix`):** each VM is `microvm.nix`/QEMU on a private `/30` bridge. Persistence is **virtiofs only** — there is no `microvm.volumes` block and no disk image:

```
find /var/lib/microvms -name '*.img'/'*.qcow2'/'*.raw'  →  (empty)
```

Only `.sock` files, `booted`/`current`/`toplevel` symlinks, and a `secrets/` staging dir exist under `/var/lib/microvms/{openclaw,hermes}/`. `openclaw-vm.nix` sets `writableStoreOverlay = "/nix/.rw-store"` (in-RAM); `hermes-vm.nix` leaves it unset (sealed venv).

**Guest filesystems are RAM, not disk** (live, via the host's debug-ssh into hermes 10.99.1.2):

```
rootfs          tmpfs     1.5G   17M  1.5G   2% /
/dev/shm        tmpfs     1.5G                   /dev/shm
ro-store        virtiofs  1.7T  449G  1.2T  28% /nix/store   ← host ext4
state           virtiofs  1.7T  449G  1.2T  28% /var/lib/hermes ← host ext4
free -m: Mem 2949 total / 696 used / 2253 avail   Swap: 0
command -v node_exporter → NO node_exporter binary
```

So "guest disk fill" reduces to two cases that are **already host-visible**: the virtiofs state share (`du -sh /var/lib/openclaw`=18 G, `/var/lib/hermes`=519 M, on `nvme0n1p5 ext4 1.7T 28%`, scraped by `job=node` filesystem collector) and the tmpfs root, which can only fill to the RAM ceiling.

**The real blind spots:**
- **Per-VM resource accounting.** Live `systemctl show` exposes it, Prometheus does not:
  - `microvm@openclaw`: `MemoryCurrent=1.447 GB`, `CPUUsageNSec=2396411564000`, `TasksCurrent=7` (ceiling = `microvm.mem` 4096 MiB in QEMU; cgroup `MemoryMax=infinity`).
  - `microvm@hermes`: `MemoryCurrent=656 MB`, `CPUUsageNSec=1468524870000`, `TasksCurrent=4` (ceiling 3072 MiB).
  - `CPUUsageNSec` advanced 2393222243000→2396411564000 over ~2 min ≈ 0.44 cores busy — a clean rate-able counter.
  - But `node_systemd_unit_memory_current_bytes{name=~"microvm@.*"}` → **0 results** in live Prometheus. The upstream collector exports unit *state* and restart counts only.
- **Guest tmpfs fill / memory pressure.** tmpfs root + `/dev/shm` + **Swap: 0** means an in-guest leak or log/spool runaway fills RAM and the kernel OOM-kills processes (or the whole guest), invisible from the host's 62 G of free memory.

**What is already covered (do NOT re-implement):** liveness/up-down is well-served — `hermes_vm_uptime_seconds`, `hermes_api_server_ok`, `openclaw_gateway_ready_*`, `OpenClawMicroVMDown` (unit-state, `for: 2m`), `HermesApiServerDown` (`for: 15m`, `hermes_vm_uptime_seconds > 600` warmup gate). 9 `openclaw_*`/`hermes_*` textfiles already publish canary/health/self-heal/smoke metrics. This spec adds **resource/pressure gauges only**.

**House pattern (confirmed):** textfile dir `/var/lib/prometheus-node-exporter-textfiles` at `1777` (`system-exporters.nix` tmpfiles `z` rule); node-exporter `textfile` collector enabled, scraped by `job=node`; atomic `tmp.$$ → mv → chmod 644` idiom per `system-age-exporter.nix`. Alerts auto-discovered from `modules/monitoring/alerts/*.yaml`.

## 3. Design options

### Option A — Host-side cgroup + volume textfile collector (+ optional guest probe). RECOMMENDED.
A single new module `modules/monitoring/services/microvm-resource-exporter.nix` runs a oneshot on a 1-min timer that:
1. For each VM unit, parses `systemctl show microvm@<vm> -p MemoryCurrent,CPUUsageNSec,TasksCurrent,ActiveState` and emits gauges labeled `vm="openclaw|hermes"`.
2. Emits the QEMU memory **ceiling** as a constant gauge (read from the same constants the modules already encode — 4096/3072 MiB) so an alert can compute `MemoryCurrent / ceiling`.
3. Emits a `du -sb` size gauge for each virtiofs state share (`/var/lib/openclaw`, `/var/lib/hermes`) — attribution, not coverage.
4. *(Optional, behind a flag)* SSHes into each guest over the bridge with the read-only debug key and runs `df -B1 /` + `free -b` to emit `microvm_guest_root_tmpfs_*` and `microvm_guest_mem_*`. This is the **only** way to see the in-guest tmpfs/OOM pressure without a guest agent.

**Trade-offs:** Zero VM restart. Closes the resource-accounting gap fully and the guest-pressure gap if the probe is enabled. Probe adds an ssh dependency on the ephemeral debug key (host-key churn on rebuild, seen live). Cardinality is tiny (2 VMs × ~8 series). **This is the right call** — it is the cheapest path to the operationally meaningful signals (creeping memory, CPU pegging, tmpfs fill) and matches every house convention.

### Option B — Full guest `node_exporter` in each VM.
Add `services.prometheus.exporters.node` to `openclaw-vm.nix`/`hermes-vm.nix` bound to `vmAddr:9100`, open the bridge firewall for 9100 (host-only, like the existing `8080`/`22` `extraInputRules`), and add a `job=microvm_guest` scrape of `10.99.0.2:9100` + `10.99.1.2:9100`.

**Trade-offs:** Gives per-process, per-mount, full node metrics. **But:** any guest config change cold-boots the VM (~10-min agent warmup each — documented in `hermes.yaml`'s `HermesApiServerDown` notes and the `microvm@*.restartTriggers` machinery). The marginal value over Option A is per-process detail, which the existing `hermes-hang-capture` `/proc` forensic already covers for the one case that matters (frozen api_server). **Not worth a dedicated restart.** Defer to the next natural restart window.

### Option C — Do nothing / formal retirement.
Defensible for *disk* (genuinely not a gap), but leaves the **guest-OOM / silent-memory-creep** case uncovered. Reject: the tmpfs+no-swap topology is a real foot-gun and the cgroup gauge is nearly free.

## 4. Recommended implementation

**New file: `modules/monitoring/services/microvm-resource-exporter.nix`** (textfile collector, mirrors `system-age-exporter.nix`).

Metric names + labels (all gauges unless noted):
```
microvm_memory_current_bytes{vm="openclaw|hermes"}        # from MemoryCurrent
microvm_memory_ceiling_bytes{vm="..."}                    # microvm.mem * 1048576 (4096/3072 MiB)
microvm_cpu_usage_seconds_total{vm="..."}   COUNTER       # CPUUsageNSec / 1e9
microvm_tasks_current{vm="..."}                           # TasksCurrent
microvm_unit_active{vm="..."}                             # 1 if ActiveState=active else 0
microvm_state_share_bytes{vm="..."}                       # du -sb of the virtiofs source dir
# --- only if guest probe enabled ---
microvm_guest_root_used_bytes{vm="..."}                   # df -B1 / "Used" (tmpfs root)
microvm_guest_root_size_bytes{vm="..."}                   # df -B1 / "1B-blocks"
microvm_guest_mem_available_bytes{vm="..."}               # free -b "available"
microvm_guest_mem_total_bytes{vm="..."}                   # free -b "total"
microvm_guest_probe_ok{vm="..."}                          # 1 if ssh+parse succeeded
microvm_resource_exporter_last_run_timestamp_seconds      # staleness anchor
```

Collector sketch (shell, atomic publish; **secret-safe** — emits only integers):
```sh
TEXTFILE_DIR=/var/lib/prometheus-node-exporter-textfiles
TMP="$TEXTFILE_DIR/microvm_resources.prom.$$"; OUT="$TEXTFILE_DIR/microvm_resources.prom"
emit(){ printf '%s\n' "$1"; }
{
  for vm in openclaw hermes; do
    case $vm in openclaw) ceil=$((4096*1048576)); src=/var/lib/openclaw; ip=10.99.0.2;;
                hermes)   ceil=$((3072*1048576)); src=/var/lib/hermes;   ip=10.99.1.2;; esac
    eval "$(systemctl show microvm@$vm -p MemoryCurrent,CPUUsageNSec,TasksCurrent,ActiveState \
            | sed 's/^/SD_/')"
    mc=${SD_MemoryCurrent:-0}; [ "$mc" = "[not set]" ] && mc=0
    cpu_ns=${SD_CPUUsageNSec:-0}; tasks=${SD_TasksCurrent:-0}
    active=0; [ "$SD_ActiveState" = active ] && active=1
    emit "microvm_memory_current_bytes{vm=\"$vm\"} $mc"
    emit "microvm_memory_ceiling_bytes{vm=\"$vm\"} $ceil"
    emit "microvm_cpu_usage_seconds_total{vm=\"$vm\"} $(( cpu_ns / 1000000000 ))"
    emit "microvm_tasks_current{vm=\"$vm\"} $tasks"
    emit "microvm_unit_active{vm=\"$vm\"} $active"
    emit "microvm_state_share_bytes{vm=\"$vm\"} $(du -sb "$src" 2>/dev/null | cut -f1)"
    # optional guest probe (cfg.guestProbe.enable)
    if [ -n "${PROBE:-}" ] && [ "$active" = 1 ]; then
      out=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 \
              -o StrictHostKeyChecking=accept-new \
              "$USER@$ip" 'df -B1 / | tail -1; free -b | sed -n 2p' 2>/dev/null) || out=""
      # parse columns → integers only; never echo $out wholesale
      ...
      emit "microvm_guest_probe_ok{vm=\"$vm\"} ${ok:-0}"
    fi
  done
  emit "microvm_resource_exporter_last_run_timestamp_seconds $(date +%s)"
} > "$TMP"
mv "$TMP" "$OUT"; chmod 644 "$OUT"
```

Service/timer wiring (copy `system-age-exporter.nix` hardening verbatim): `Type=oneshot`, `User=root` (needed to read other-user cgroups and to `du` the openclaw-owned share; **not** `DynamicUser` — `systemctl show` of foreign units + `du` of `0700 openclaw` dir need root), `ProtectSystem=strict`, `ReadWritePaths=[ "/var/lib/prometheus-node-exporter-textfiles" ]`, timer `OnBootSec=2min` + `OnUnitActiveSec=60s`. **No new scrape job** — it rides `job=node`'s textfile collector. **No `loki.nix` symlink** needed (this is a Prometheus textfile, not a Loki rule). **No `ports.txt` entry** for Option A (no listener); if the guest probe is enabled it uses the already-registered debug-ssh on `vmAddr:22`.

**Make the guest probe optional behind a module option** `cfg.guestProbe = { enable = false; user = "hermes"; keyFile = "/root/.ssh/hermes-debug"; }` so it ships dark and the operator flips it on after the key decision (see §8). For openclaw, the nightly-report already SSHes as `openclaw@10.99.0.2` — reuse that key path rather than the hermes-debug key.

**New file: `modules/monitoring/alerts/microvm.yaml`** (auto-discovered). Baseline-justified thresholds (live: openclaw 35% of ceiling, hermes 21%):
```yaml
groups:
  - name: microvm_resources
    interval: 60s
    rules:
      - alert: MicroVMMemoryNearCeiling
        expr: microvm_memory_current_bytes / microvm_memory_ceiling_bytes > 0.90
        for: 15m            # 15m: ride out transient spikes; warmup MCP children are short-lived
        labels: { severity: warning, category: capacity }
        annotations:
          summary: "{{ $labels.vm }} microVM at >90% of its memory ceiling for 15m"
      - alert: MicroVMGuestRootFilling          # only if guestProbe enabled
        expr: microvm_guest_root_used_bytes / microvm_guest_root_size_bytes > 0.85
        for: 10m
        labels: { severity: warning, category: capacity }
        annotations:
          summary: "{{ $labels.vm }} guest tmpfs root >85% full (RAM-backed; fill OOM-kills the VM)"
      - alert: MicroVMGuestProbeFailing
        expr: microvm_guest_probe_ok == 0 and microvm_unit_active == 1
        for: 30m            # long: ssh-key churn on rebuild is expected & self-resolves
        labels: { severity: info, category: monitoring-meta }
        annotations:
          summary: "{{ $labels.vm }} guest resource probe failing (likely debug-ssh host-key churn after a VM rebuild)"
      - alert: MicroVMResourceExporterStale
        expr: time() - microvm_resource_exporter_last_run_timestamp_seconds > 600
        for: 5m
        labels: { severity: warning, category: monitoring-meta }
        annotations:
          summary: "microVM resource exporter has not run in >10m"
```
Note `for: 15m` on memory: at 90% of a 3-4 GiB ceiling the agent still has 300-400 MiB headroom; MCP-child fan-out (financialPython etc.) is bursty but short, so a sub-15m breach is usually transient. CPU is deliberately **not** alerted (the existing hang-capture + api_server probes own "agent stuck"); `microvm_cpu_usage_seconds_total` ships as a Grafana-only gauge.

**Wiring:** add `./services/microvm-resource-exporter.nix` to the monitoring module list (same place `system-age-exporter.nix` is imported — `modules/monitoring/default.nix` or its services aggregator).

**Deploy choreography:** pure-additive, no restart of either VM. `nixos-rebuild switch` brings up the timer; first textfile lands within `OnBootSec`/manual `systemctl start microvm-resource-exporter.service`. Rollback = remove the import + the alert file; nothing stateful. Restart cost: only `prometheus-node-exporter` is untouched (textfile is read by the running collector), and Prometheus reloads the new rule file on switch.

**Option B (deferred):** when a `models.nix` change next cold-boots the VMs, fold in `services.prometheus.exporters.node` on `vmAddr:9100` in each `*-vm.nix`, add `9100` to that VM's `networking.firewall.interfaces.<bridge>.allowedTCPPorts` (host-bridge-only, mirroring the `8080` rule), register `10.99.0.2:9100`/`10.99.1.2:9100` under a new `job=microvm_guest` scrape in the Prometheus config, and **add two `ports.txt` lines** (`9100 10.99.0.2 / 10.99.1.2 microVM guest node-exporter (bridge-only)`). The Option A `microvm_guest_*` probe metrics then become redundant and can be retired.

## 5. Noise & failure-mode analysis

- **`MicroVMGuestProbeFailing` chronic firing on rebuild.** The debug-ssh host key rotates on every VM rebuild (observed live: `REMOTE HOST IDENTIFICATION HAS CHANGED`). With `StrictHostKeyChecking=accept-new` the *first* connection after a rebuild succeeds, but if `known_hosts` already pins the old key the probe fails until the entry is cleared. Mitigation: the collector uses `-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no` for the probe **only** (acceptable — the connection is over a private `/30` the host fully controls, the same trust model the nightly-report probe already uses), and `MicroVMGuestProbeFailing` is `severity: info` with `for: 30m` so transient churn never pages.
- **`MemoryCurrent` includes page cache.** cgroup v2 `MemoryCurrent` counts reclaimable cache, so it can sit high without real pressure. Mitigation: ceiling ratio at 0.90 + `for: 15m` tolerates cache; the guest `free -b available` (probe) is the truer pressure signal — prefer it in the dashboard.
- **`du -sb` on the 18 G openclaw share each minute** is I/O on the ext4 root. Mitigation: run the `du` on a **slower sub-cadence** (every 10th tick, or split into a separate daily timer like `container_store_size.prom`). Recommended: emit `microvm_state_share_bytes` from a 1-h `OnUnitActiveSec` to avoid per-minute walks of 18 G.
- **Silent break: exporter stops.** Covered by `MicroVMResourceExporterStale` (the same `last_run_timestamp` discipline every house collector uses).
- **`[not set]`/empty cgroup fields** if accounting is ever off — the sketch defaults to 0, which makes ratios read 0 (under threshold) rather than divide-by-zero; combined with `microvm_unit_active` you can distinguish "VM down" from "accounting off". `MemoryAccounting=yes` confirmed live, so this is defensive only.
- **Option B firewall risk:** binding node_exporter to `0.0.0.0:9100` inside the guest would expose it on the NAT path; must bind to `vmAddr` and gate with the bridge-only `extraInputRules` exactly like the existing `8080` rule.

## 6. Security considerations

- **Outputs are integers only.** Every emitted series is a byte count, a nanosecond counter, or a 0/1 — no tokens, paths-with-secrets, or PII. The collector never echoes `systemctl show` env blocks (it field-targets `-p MemoryCurrent,...`, never `-p Environment`).
- **The guest probe runs `df`/`free` only** — metadata commands whose stdout is pure column data. The sketch parses columns into integers and **never** pastes the raw ssh stdout into a metric or log. This honors the PRIMARY LENS output check: the ssh stdout becomes conversation/metric data, so it is constrained to non-secret commands by construction.
- **No new secret surface.** Option A reuses the existing debug/probe ssh keys (already on the host at `0600 root`); it does not read `/run/secrets`, the staged `secretsStagingDir`, or any `*-config`/token file. The `du` target dirs (`/var/lib/openclaw` `0700 openclaw`) are walked for **size only** (`-sb`), never listed or read.
- **Runs as root, minimally.** Root is required to `systemctl show` foreign-user units and `du` the `0700` share, but the service is `ProtectSystem=strict` + `ReadWritePaths` scoped to the textfile dir only (same hardening as `system-age-exporter.nix`).
- **`UserKnownHostsFile=/dev/null` on the probe** is safe specifically because the target is a host-controlled `/30` bridge IP behind the egress-isolation firewall; this is the identical trust posture of the already-deployed nightly-report and self-heal ssh probes.

## 7. Effort & sequencing

- **Option A: S, ~3-4h.** One exporter module (~90 lines, copy `system-age-exporter.nix` + add the `systemctl show` parse and optional probe), one `microvm.yaml` (4 rules), one import line. No new port, no Loki symlink, no scrape job. Verify with `promtool check rules`, `nixos-rebuild build`, then `systemctl start microvm-resource-exporter` and `curl 127.0.0.1:9100/metrics | grep microvm_`.
- **Prerequisites:** none for the cgroup half. The guest-probe half needs the §8 key decision; ship it dark (`guestProbe.enable = false`) and flip on after.
- **Option B: L, ~6h, gated.** Blocked on a VM restart window — **do not** schedule a dedicated restart; fold into the next `models.nix` change or host reboot. Unblocks per-process/per-mount guest metrics and lets the Option A `microvm_guest_*` probe series retire.
- **What this unblocks:** a Grafana "microVM resources" row (mem-vs-ceiling, CPU rate, tasks, state-share growth) and an early-warning path for the tmpfs-fill/OOM case that today is fully silent until the agent dies and an *availability* alert fires minutes later.

## 8. Decisions required from the operator

- **Guest probe key:** reuse the ephemeral `/root/.ssh/hermes-debug` (slated for removal per `hermes-vm.nix:1001`) and the openclaw nightly-report key now, OR provision a dedicated read-only probe key, OR ship cgroup-only and add the probe when the proper Phase-2 probe key lands. *(Recommend: ship Option A with `guestProbe.enable = false`; enable per-VM once a stable probe key exists.)*
- **Defer Option B?** Confirm the full guest `node_exporter` stays deferred to the next natural VM restart rather than scheduling one. *(Recommend: defer.)*
- **Guest-OOM signal:** host-side `journalctl -k` Loki rule on the QEMU `Killed process` lines (no guest change) vs the tmpfs-fill probe + cgroup-near-ceiling heuristic. *(Recommend: the heuristic — simpler and no Loki authoring.)*


---


<a id="image-staleness-drift"></a>

# Moving-Tag Container Image Staleness &amp; Update-Drift Monitoring

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** S–M, ~4–6h (collector + alerts + per-image updater instrumentation)

**Key live evidence:** podman-auto-update.timer is `linked`/`inactive`, NextElapse empty, never triggered — the memory note (obs 6457) that it 'drives litellm image accumulation' is WRONG; it does not run. · ACTUAL update path = `update-containers.timer` (OnCalendar=daily, RandomizedDelaySec=30m, Persistent); last run 2026-06-10 00:18:46 PDT, Result=success; defined in modules/maintenance/timers.nix:368-395, script lines 12-152. · 13 running rootless images, all moving tags: litellm ghcr…:main-stable, open-webui ghcr…:main, teable ghcr…:latest, shlink/shlink-web-client docker.io…:stable, wallabag/mailarchiver docker.io…:latest, speedtest-tracker lscr.io…:latest, changedetection ghcr…:latest + sockpuppetbrowser:latest, openproject docker.io…:16 (pinned major), opnsense-exporter ghcr…:latest, vane docker.io…:slim-latest, matter-server ghcr…:stable (system quadlet), budgetboard server/client ghcr…:release. Registry mix: ghcr.io, docker.io, lscr.io — all answered `podman manifest inspect` anonymously (exit 0). · Digest comparison PROVEN without skopeo: local arm64 sub-manifest .Digest (sha256:90bc80cd…) == remote arm64 entry from `podman manifest inspect` index → litellm MATCH (up to date, image built upstream 2026-06-09 01:17 UTC, pulled locally same night). skopeo IS in nixpkgs (skopeo-1.20.0) if preferred. · Per-image pull failures are SILENT: update-containers uses `podman pull … || log [ERROR]` and `KillMode=process`; one failed pull does not fail the unit (Result=success confirmed), so SystemdServiceFailed (systemd.yaml:6, state=failed) never fires for it. No metric references update-containers anywhere in modules/monitoring/. · Template exists: container-health-exporter.nix already has a daily heavier-collector sibling (container-store-size-exporter, OnCalendar=daily RandomizedDelaySec=10m, atomic tmp+mv, runs as root + sudo -u per ROOTLESS_USERS) and already documents the moving-tag bloat problem (lines 230-237). New collector slots in as a third sibling.

## 1. TL;DR

Vulcan runs 13 rootless quadlet containers (plus matter-server + budgetboard as system quadlets), and **every one of them rides a moving tag**: `:latest` (teable, wallabag, mailarchiver, speedtest-tracker, changedetection, opnsense-exporter), `:main`/`:main-stable` (open-webui, litellm), `:stable` (shlink, shlink-web-client, matter-server), `:slim-latest` (vane), `:release` (budgetboard), and the pinned-major `:16` (openproject). The brief's premise — that these "silently drift, never refreshed" — is **factually wrong on live evidence**: `update-containers.timer` already `podman pull`s every image nightly (~00:08 daily, `Persistent`, 30m jitter) and restarts only containers whose image actually changed. Last run 2026-06-10 00:18 `Result=success`.

The genuine gap is **observability of that path**, not the path itself: (a) the updater swallows per-image pull failures (`podman pull … || log` + `KillMode=process` → the unit still exits 0 even when ghcr/docker.io is unreachable or rate-limiting one image for days), and (b) there is **no metric anywhere** comparing the running image digest to the upstream tag digest, so nobody knows when an image is genuinely behind. Recommendation: a daily **skopeo-free** textfile collector (reuse `podman manifest inspect`, proven anonymous-OK against all three registries) emitting `container_image_outdated{name}` + `container_image_age_days{name}` + an inspect-success gauge, **plus** lightweight per-image pull-result instrumentation bolted onto the existing updater. Cost: **S–M, ~4–6h, zero new ports, one daily timer, no secrets**.

## 2. Current state & evidence

**Container inventory (live, 2026-06-10).** 13 rootless containers across users `changedetection litellm mailarchiver open-webui openproject openspeedtest opnsense-exporter shlink shlink-web-client speedtest-tracker teable vane wallabag`, plus `matter-server` and `budget-board-{server,client}` as system quadlets. Registry split: **ghcr.io** (litellm, open-webui, teable, changedetection.io, opnsense-exporter, matter-server, budgetboard), **docker.io** (shlink, shlink-web-client, wallabag, mailarchiver, openproject, sockpuppetbrowser, vane), **lscr.io** (speedtest-tracker). Tag types: 12 fully-moving, 1 pinned-major (openproject `:16`), 1 locally-built and intentionally out-of-scope (technitium-dns-exporter `localhost/…:latest`, root container, already skipped by the updater's `localhost/*` guard).

**The update path that ACTUALLY runs.** `modules/maintenance/timers.nix` defines `update-containers.{service,timer}` (lines 117-152 script body, 368-395 unit/timer). The timer is `OnCalendar=daily, RandomizedDelaySec=30m, Persistent=true`; live `LastTrigger=2026-06-10 00:17`, service `Result=success`, `ExecMainExitTimestamp=2026-06-10 00:18:46 PDT`. The script iterates `CONTAINER_USERS` (lines 121-133 — the canonical 11-user rootless list) plus a `root` sweep, runs `podman pull` per image, greps the pull output for `Downloading|Copying|Getting image` to decide if it changed, and `systemctl [--user --machine=user@] restart`s only the affected units. Every image observed was (re)created locally during the 00:17 window — confirming the path is live and effective.

**`podman-auto-update.timer` is dormant.** It is `linked`/`inactive`, `NextElapse` empty, never triggered. **This corrects memory observation 6457** ("podman-auto-update.timer drives litellm image accumulation") — that timer does not run; the litellm `<none>` image accumulation seen historically came from the `update-containers` pulls, mitigated by the per-user `podman image prune` work in `project_rootless_podman_image_prune`.

**The actual silent-failure surface.** The updater's per-image error handling is `if output=$(podman pull …); then … else log "[ERROR] Failed to pull"; fi` with `KillMode=process`. A failed pull logs to journal and **does not fail the unit** — I confirmed `Result=success` on the last run. The generic `SystemdServiceFailed` alert (`systemd.yaml:6`, `state="failed"`) therefore can never catch a partial-pull failure. Nothing under `modules/monitoring/` references `update-containers`. So: registry outage, auth throttle, or a manifest that 404s for one image → completely silent for as long as it persists.

**Tooling availability.** `skopeo` is **not** installed but **is** in nixpkgs (`skopeo-1.20.0`). More importantly, `podman manifest inspect <ref>` works **anonymously against all three registries** (ghcr.io/docker.io/lscr.io all returned exit 0). The digest comparison is proven: local arm64 sub-manifest `.Digest` (`sha256:90bc80cd…`) equals the arm64 entry parsed from the remote `podman manifest inspect` index → litellm reads **up to date** (built upstream 2026-06-09 01:17 UTC, pulled the same night). `podman image inspect --format '{{.Created}}'` yields the upstream build timestamp for the age gauge.

**Existing collector template.** `modules/monitoring/container-health-exporter.nix` already carries a *daily, heavier-than-2-min* sibling — `container-store-size-exporter` (lines 238-293): `OnCalendar=daily`, `RandomizedDelaySec=10m`, atomic `tmp`+`mv`, runs as root and `sudo -u`/`du` per store, writes its **own** textfile so it never clobbers the 2-min health collector. The new staleness collector is a near-exact clone of this pattern. Alerts live in `modules/monitoring/alerts/container-health.yaml` (auto-discovered; existing rules `ContainerStoreSizeHigh`, `ContainerPruneStale`, etc.).

## 3. Design options

### Option A — `podman manifest inspect` textfile collector (RECOMMENDED)
A daily root oneshot that, per quadlet container (root + rootless users), reads the running image's local arch-specific digest (`podman image inspect`) and compares it to the remote tag's arch entry (`podman manifest inspect`), emitting `container_image_outdated{name,image,registry}` (1/0), `container_image_age_days{name}`, and `container_image_check_success{name}`.

- **Pros:** No new package — `podman` is already present and proven to query all three registries anonymously. Re-uses the exact `container-store-size-exporter` choreography (daily timer, atomic write, per-user sudo). Arch-correct (compares arm64-to-arm64, no false drift from index-digest mismatch). Zero secrets, zero ports.
- **Cons:** Per-arch parse needs a tiny JSON step (`jq` or `python3 -c`, both present). `manifest inspect` is a metadata-only HEAD-ish call but still hits the registry — 16 calls/day total, well under any anonymous rate limit (docker.io anon = 100 pulls/6h; manifest inspects are far cheaper and we make ~16, once).

### Option B — `skopeo inspect --no-tags` collector
Add `skopeo` to `environment.systemPackages` and use `skopeo inspect docker://<ref> --format '{{.Digest}}'` for the remote side.

- **Pros:** skopeo is the canonical tool for "registry digest without pull"; cleaner single-shot digest output; handles `--retry-times` natively.
- **Cons:** Net-new package for zero capability gain (podman already does this). skopeo's `.Digest` is the **index** digest, not arch-specific, which **mismatches** the running container's arch sub-manifest digest — you'd compare index-to-arch and get permanent false-positive drift unless you also `--raw` parse the index. Strictly worse than Option A here. **Rejected** unless the operator wants skopeo for other reasons.

### Option C — Instrument the existing updater only (no remote comparison)
Bolt per-image pull-result + image-age metrics directly onto `update-containers` (it already pulls everything nightly, so "did the nightly pull succeed for image X, and when was X's image built" is free at pull time).

- **Pros:** Cheapest (~1h), reuses an existing daily run with zero extra registry calls, directly closes the silent-pull-failure gap.
- **Cons:** Answers "did the pull fail?" but not "is the running image behind upstream?" If the updater is disabled, removed, or its restart step fails after a successful pull, this metric is blind to true drift.

**RECOMMENDATION: A + C together.** They are complementary, not redundant. C closes the silent-failure hole on the path that already runs (high value, near-free); A provides the independent ground-truth drift signal that survives the updater being broken. Both share the daily cadence and the textfile-collector house pattern.

## 4. Recommended implementation

### 4.1 New collector module — `modules/monitoring/services/container-image-staleness-exporter.nix`

Mirror `container-store-size-exporter` exactly (root oneshot, daily timer, atomic write, dedicated textfile). Pseudocode of the `ExecStart` script:

```sh
set -euo pipefail
METRICS_FILE=/var/lib/prometheus-node-exporter-textfiles/container_image_staleness.prom
METRICS_TMP="$METRICS_FILE.tmp"
{
  echo "# HELP container_image_outdated Running image arch-digest differs from upstream moving tag (1=outdated,0=current)"
  echo "# TYPE container_image_outdated gauge"
  echo "# HELP container_image_age_days Days since the running image was built upstream (Created)"
  echo "# TYPE container_image_age_days gauge"
  echo "# HELP container_image_check_success Remote manifest inspect succeeded for this image (1=ok,0=failed)"
  echo "# TYPE container_image_check_success gauge"
  echo "# HELP container_image_staleness_last_run_seconds Unix time this collector last completed"
  echo "# TYPE container_image_staleness_last_run_seconds gauge"
} > "$METRICS_TMP"

ARCH=arm64   # vulcan is aarch64; pin so we compare arch-to-arch, never index-to-arch

emit_for() {            # $1=podman cmd prefix, $2=user label
  $1 ps --filter label=PODMAN_SYSTEMD_UNIT --format '{{.Names}}\t{{.Image}}' \
    | while IFS=$'\t' read -r name image; do
        [ -z "$name" ] && continue
        case "$image" in localhost/*) continue ;; esac      # skip locally-built
        registry="${image%%/*}"
        # local arch sub-manifest digest of the RUNNING image
        local_digest=$($1 image inspect "$image" --format '{{.Digest}}' 2>/dev/null || echo "")
        # local build age
        created=$($1 image inspect "$image" --format '{{.Created}}' 2>/dev/null || echo "")
        if [ -n "$created" ]; then
          age_days=$(( ( $(date +%s) - $(date -d "$created" +%s) ) / 86400 ))
          echo "container_image_age_days{name=\"$name\",image=\"$image\",registry=\"$registry\"} $age_days" >>"$METRICS_TMP"
        fi
        # remote arch digest, with one retry, never abort the whole sweep
        remote_json=$(timeout 30 $1 manifest inspect "$image" 2>/dev/null || true)
        if [ -z "$remote_json" ]; then
          echo "container_image_check_success{name=\"$name\",image=\"$image\",registry=\"$registry\"} 0" >>"$METRICS_TMP"
          continue
        fi
        remote_digest=$(printf '%s' "$remote_json" \
          | ${pkgs.jq}/bin/jq -r --arg a "$ARCH" \
            'if .manifests then (.manifests[] | select(.platform.architecture==$a) | .digest) else .config.digest end' \
          2>/dev/null | head -1)
        echo "container_image_check_success{name=\"$name\",image=\"$image\",registry=\"$registry\"} 1" >>"$METRICS_TMP"
        if [ -n "$local_digest" ] && [ -n "$remote_digest" ]; then
          [ "$local_digest" = "$remote_digest" ] && out=0 || out=1
          echo "container_image_outdated{name=\"$name\",image=\"$image\",registry=\"$registry\"} $out" >>"$METRICS_TMP"
        fi
      done
}

emit_for "${pkgs.podman}/bin/podman" root
for u in changedetection litellm mailarchiver open-webui openproject openspeedtest \
         opnsense-exporter shlink shlink-web-client speedtest-tracker teable wallabag; do
  id "$u" &>/dev/null || continue
  emit_for "${pkgs.sudo}/bin/sudo -u $u ${pkgs.podman}/bin/podman" "$u"
done

echo "container_image_staleness_last_run_seconds $(date +%s)" >>"$METRICS_TMP"
mv "$METRICS_TMP" "$METRICS_FILE"; chmod 644 "$METRICS_FILE"
```

Notes for the implementer:
- **ROOTLESS_USERS list:** copy verbatim from `container-health-exporter.nix:159` (the canonical, drift-checked list) — do NOT re-derive; keep `vane` and `openspeedtest` per that list, and let the `localhost/*` guard + `id` check naturally skip non-runners. matter-server and budgetboard are root quadlets and fall under the `root` sweep.
- **Arch pinning is load-bearing.** Comparing the running arch sub-manifest digest to the remote arch entry is what makes this correct (proven live). Comparing `RepoDigests[0]`/index digest to a remote arch entry would false-positive forever. For single-arch images (`.manifests` absent), fall back to `.config.digest`.
- **Timer:** `OnCalendar=daily, RandomizedDelaySec=30m, Persistent=true, AccuracySec=1m`. Stagger AFTER `update-containers` finishes — set it to e.g. `OnCalendar=*-*-* 02:30:00` (the updater runs ~00:08–00:38) so the staleness read reflects the freshly-pulled state and rarely fires transiently. Add `After=update-containers.service` is not enough (timers don't order against oneshots cleanly) — a fixed 02:30 calendar slot is simplest.
- **Service hardening:** `Type=oneshot`, `User=root`, `Group=root` (needs root to `sudo -u` into the 0700 stores, same as the store-size exporter). Add `After=network-online.target podman.service`.
- **Import wiring:** add the new file to the monitoring imports list (wherever `container-health-exporter.nix` / `container-store-size-exporter` is imported — same aggregator). No `default.nix` container-side change.

### 4.2 Updater instrumentation (Option C) — edit `modules/maintenance/timers.nix`

Inside `update_images_for`, after the `podman pull` branch, record per-image result to a textfile (atomic-rebuilt at start of the run). Emit:
- `container_image_pull_success{name,image,user}` 1/0 (set 0 in the `else`/ERROR branch)
- `container_image_pull_last_success_seconds{image}` = `date +%s` on success
- `container_update_last_run_seconds` once at script end

Write to `/var/lib/prometheus-node-exporter-textfiles/container_image_pull.prom` with the same tmp+mv discipline. Because the updater already runs as root and iterates every image, this is ~15 lines and zero extra registry traffic.

### 4.3 Alert rules — append to `modules/monitoring/alerts/container-health.yaml`

```yaml
- alert: ContainerImageOutdated
  expr: container_image_outdated == 1
  for: 7d                       # one full nightly-update cycle missed × 7
  labels: { severity: warning, category: containers }
  annotations:
    summary: "{{ $labels.name }} image behind upstream {{ $labels.image }} for >7d"
    description: "Running arch digest differs from the moving tag for a week — nightly update-containers pull is likely failing for this image."

- alert: ContainerImageCheckFailing
  expr: container_image_check_success == 0
  for: 3d                       # tolerate transient registry blips / one-off rate limit
  labels: { severity: warning, category: containers }
  annotations:
    summary: "Cannot reach registry to check {{ $labels.image }} for 3d"

- alert: ContainerImagePullFailing          # Option C
  expr: container_image_pull_success == 0
  for: 2d
  labels: { severity: warning, category: containers }
  annotations:
    summary: "Nightly update-containers pull failed for {{ $labels.image }} ≥2 nights"

- alert: ContainerImageStalenessCheckStale  # collector dead-man
  expr: time() - container_image_staleness_last_run_seconds > 36 * 3600
  labels: { severity: warning, category: containers }
  annotations:
    summary: "Image-staleness collector has not run in >36h"
```

**Threshold justification (baseline-first):** the updater runs daily, so a current image normally reads `outdated=0` within ~24h of any upstream push (litellm was 0, built 40h ago and already pulled). `for: 7d` therefore means "the nightly pull has demonstrably failed to advance this image for a full week" — a real, actionable condition, not registry-push lag. `ContainerImageCheckFailing for: 3d` tolerates the occasional anonymous-rate-limit/registry-blip (a single failed daily check is noise; three consecutive is a pattern). `ContainerImagePullFailing for: 2d` = two consecutive nightly failures. The dead-man uses 36h (daily + 30m jitter + slack).

### 4.4 Wiring summary
- **ports.txt:** no change — textfile collectors expose nothing on a port; node-exporter's existing textfile dir scrape carries it.
- **loki.nix:** no change — this is metrics, not logs; no `L+` symlink needed.
- **default.nix / imports:** one import line for `container-image-staleness-exporter.nix` in the monitoring aggregator; the Option-C edit is in-place in `timers.nix`.

### 4.5 Deploy choreography & rollback
1. Add the collector module + import, add alert rules, edit `timers.nix`. `nix flake check` then `nixos-rebuild build`.
2. `switch`. Restart cost: trivial — `update-containers` is a oneshot (next run picks up the new script body; the running containers are untouched), and the new collector only adds a timer. No container restarts.
3. Smoke: `systemctl start container-image-staleness-exporter` (manual), then check `/var/lib/prometheus-node-exporter-textfiles/container_image_staleness.prom` has `_outdated`/`_age_days`/`_check_success` lines and `_last_run_seconds`. Confirm Prometheus `count(container_image_outdated)` ≈ 13–15.
4. **Rollback:** revert the commit; the collector + timer + alerts disappear cleanly; `update-containers` reverts to its prior body. No state to clean (textfiles are transient; stale `.prom` is harmless and overwritten or can be `rm`'d).

## 5. Noise & failure-mode analysis

- **Transient registry rate-limit / network blip → `_check_success=0` for one run.** Mitigated by `for: 3d` on `ContainerImageCheckFailing` and by a single in-script `timeout 30` retry. Daily cadence + 16 cheap manifest inspects is far under docker.io's anonymous ceiling.
- **False-positive drift from index-vs-arch digest mismatch.** This is THE classic trap and is mitigated by arch-pinning (`ARCH=arm64`, compare arch-to-arch) — proven live (litellm read 0, not a spurious 1). If a future image is single-arch, the `.config.digest` fallback handles it.
- **Upstream tag genuinely stale for >7d (project paused releases).** `ContainerImageOutdated` won't fire because `outdated` stays 0 (local == remote, both old) — correct behavior; `container_image_age_days` becomes the soft signal if the operator ever wants a "this image hasn't been rebuilt upstream in N days" view (no alert proposed; gauge only, to avoid nagging on stable projects).
- **`update-containers` restart step fails after a successful pull** (e.g. the container won't come back up). Option C's `pull_success=1` would read green while the container is actually down — but `ContainerDown`/`ContainerUnhealthy` (existing, container-health.yaml) catch that. Clean separation of concerns.
- **Silent break of the collector itself.** Covered by `ContainerImageStalenessCheckStale` dead-man (>36h since `_last_run_seconds`).
- **Cardinality:** ~15 series × 3 gauges = trivial; no churn (image/registry labels are stable).
- **systemd-logind session noise:** like the health exporter, each `sudo -u` spawns a session. At **daily** cadence (vs the health exporter's 2-min) this is ~13 sessions/day — negligible, no special handling needed.

## 6. Security considerations

- **No secrets touched.** `podman manifest inspect` against public moving tags is anonymous (proven — no creds needed for ghcr/docker.io/lscr). The collector reads only image **names, digests, build timestamps** — none are secret. No registry credentials are configured or required; if a private registry is ever added, the design would need a `LoadCredential` for an auth token and must emit only the derived `outdated`/`age` gauge, never the token (standard house rule).
- **Output is digest hashes + epoch integers** — emitted to a `0644` textfile exactly like every other collector. Nothing PII/credential-shaped.
- **Runs as root** (required to `sudo -u` into 0700 per-user stores), identical privilege posture to the existing `container-store-size-exporter` — no new attack surface.
- **The Option-C updater edit** writes only image names + success flags + timestamps; it must NOT log pull output verbatim into the textfile (pull output is benign here, but keep the metric to the boolean to avoid any future leak of a registry auth error string).

## 7. Effort & sequencing

- **Effort:** **S–M, ~4–6h.** Collector module ~2h (it's a clone of `container-store-size-exporter` + a jq parse), alert rules ~0.5h, Option-C updater instrumentation ~1h, smoke/verify ~1h.
- **Prerequisites:** none — `podman` + `jq` already present; reuses the existing textfile dir + node-exporter scrape + alerts auto-discovery. No new package, no port (so no ports.txt edit), no loki symlink.
- **Sequencing:** independent of every other deferred item. Can land in a single commit. Recommend shipping Option C (updater instrumentation) and Option A (collector) together since they share the cadence and the alert file.
- **What it unblocks:** a true ground-truth signal for "are my moving-tag containers actually current," and the first-ever alert on the silent per-image pull failures of the nightly updater. It does **not** and should **not** absorb CVE/vulnerability semantics — that is `cve-image-scanning`'s job (explicitly scoped out per the brief).

## 8. Decisions required from the operator

- **Outdated threshold:** 7d (recommended, = one full missed update cycle ×7) vs the brief's looser 30d.
- **Ship Option C (updater pull-result metrics) alongside A?** Recommended yes — cheapest high-value win, closes the silent-failure hole.
- **openproject `:16` handling:** track drift within 16.x like the others (recommended) vs age-gauge-only.
- **Native podman auto-update adoption** (`io.containers.autoupdate` labels + enabling `podman-auto-update.timer`): a separate decision, **not recommended** — it would duplicate/conflict with the existing `update-containers.timer` controlled pull-then-restart logic. Flagged for awareness only.


---


<a id="mlx-hera-probe"></a>

# Direct blackbox probe of the hera MLX/llama-swap backend (Hermes chat's terminal dependency)

**Verdict:** IMPLEMENT · **Effort:** S, ~2-3h

**Key live evidence:** hera.lan:8080/v1/models returns HTTP 200 UNAUTHENTICATED via the existing blackbox http_2xx module: live `curl localhost:9115/probe?module=http_2xx&target=http://hera.lan:8080/v1/models` -> probe_success 1, probe_http_status_code 200, probe_duration_seconds 0.0017s · Server identity confirmed: /v1/models JSON has owned_by=llama-swap, 30 models total, 8 Qwen-family, 2714 bytes, 9ms — this is the llama-swap router LiteLLM's `hera/*` models route to (NOT the separate vulcan-side llama-swap at 127.0.0.1:8080/llama-swap.vulcan.lan, which is already probed) · No existing HTTP probe of hera:8080: the only probe_success series for hera.lan/hera-wifi.lan are job=blackbox_icmp (ping). 83 probe_success targets total, none HTTP-probe the hera model endpoint · hera is effectively 24/7: up{job="darwin-hera"}=1 now; avg_over_time(up[24h])=1.0 (0/2874 down samples); avg_over_time(up[7d])=0.9989; max contiguous outage in 7d ~6.5min (13x30s in one window). No nightly-sleep pattern — sleep-window suppression NOT needed · Full chain currently healthy: hermes_e2e_chat_ok=1, http_code=200, duration=6.95s; the e2e probe path is vulcan -> hermes VM 10.99.1.2:8080 -> LiteLLM 127.0.0.1:4000 -> hera.lan:8080 llama-swap · HostUnreachable catch-all (network.yaml:5) matches `probe_success{job=~"blackbox_.*"}==0` for:2m critical, ungated — a new blackbox_* job WOULD fire here on hera reboots; needs an instance exclusion

## 1. TL;DR

The terminal dependency for all Hermes Discord chat is the **llama-swap / MLX model router on hera** (`hera.lan:8080`, the upstream LiteLLM's `hera/*` models route to). Today it is probed **only by ICMP ping** — nothing exercises its HTTP model API directly. When it dies, the symptom surfaces three hops downstream as `HermesAskFailing` / `HermesE2eChatFailing` / `HermesFallbackChainTriggered`, none of which isolate "the model backend on hera is down" from "the VM is broken" or "LiteLLM is misrouting," and the api-server alert is deliberately warmup-gated so it's slow.

I verified live that `http://hera.lan:8080/v1/models` returns **HTTP 200 unauthenticated in ~2ms through the blackbox exporter's existing `http_2xx` module** (`owned_by: llama-swap`, 30 models). So the gap closes with a near-trivial change: **one scrape target + one alert rule**, no new blackbox module, no collector, no secret handling. The alert distinguishes the actionable case ("hera up, MLX dead") from the non-actionable one ("hera unreachable") with `and on() up{job="darwin-hera"} == 1`. hera is effectively 24/7 (`avg_up_7d = 0.9989`), so no nightly-sleep suppression is needed. **Effort: S (~2-3h), mostly the deploy + a 24h soak.** Recommendation: **IMPLEMENT.**

## 2. Current state & evidence

**The dependency chain (all live-verified):**
```
vulcan e2e probe ─POST /v1/chat/completions─▶ Hermes VM api_server (10.99.1.2:8080)
                                                   │
                                                   ▼
                                              LiteLLM (127.0.0.1:4000)  [model "hera/omlx/Qwen3.6-27B-MLX-8bit"]
                                                   │  api_base ──▶
                                                   ▼
                                              llama-swap router on HERA (hera.lan:8080)  ◀── THE GAP
```

- **hera.lan = 192.168.1.4.** Port 8080 is open and serves an OpenAI-compatible API. Live blackbox test through the **existing** module:
  `curl localhost:9115/probe?module=http_2xx&target=http://hera.lan:8080/v1/models` → `probe_success 1`, `probe_http_status_code 200`, `probe_duration_seconds 0.0017`.
- **It is unauthenticated**: a bare `curl -s -o /dev/null -w '%{http_code}' http://hera.lan:8080/v1/models` returns `200` with no token. (For contrast, hera:8000 → 401, hera:5000 → 403 — those are auth-gated and not the right target.)
- **Server identity confirmed**: the `/v1/models` JSON reports `owned_by: llama-swap` across 30 models (8 Qwen-family), 2714 bytes. This is the llama-swap instance LiteLLM's `hera/*` catalog entries point at.
- **This is distinct from the already-probed vulcan-side llama-swap.** `https://llama-swap.vulcan.lan` (→ `127.0.0.1:8080`, user `johnw`, `modules/services/llama-swap.nix`) is in `blackbox_https_local` and reports `probe_success=1`. Same port number, different machine; the **hera** one is the one Hermes actually uses and the one with no HTTP probe.
- **No existing HTTP probe of hera:8080.** The only `probe_success` series for `hera.lan`/`hera-wifi.lan` are `job=blackbox_icmp` (ping). Of 83 total `probe_success` targets, none HTTP-probe the hera model endpoint.

**What detects MLX death today, and how slowly:**
- `hermes_e2e_chat_ok` (5-min probe, `HermesE2eChatFailing` `for: 5m`, critical) — fires, but its description blames "model.base_url misrouting / LiteLLM master_key mismatch," i.e. it cannot tell the operator the backend itself is the culprit.
- `hermes_mcp_ask_hermes_ok` (`HermesAskFailing`) — same, fires generically.
- `HermesApiServerDown` is **warmup-gated** (`and ignoring(__name__) hermes_vm_uptime_seconds > 600`) precisely because `/v1/capabilities` enumerates models against the backend and stays non-200 for ~8min after a VM restart — so it deliberately tolerates backend slowness and is not a fast MLX-death signal.
- Net: an MLX outage produces a cluster of generic criticals 5+ minutes later, with the runbook pointing at the wrong layers first. There is no single rule that says **"the model router on hera is down."**

**hera availability (kills the "desktop that sleeps" concern in the brief):**
- `up{job="darwin-hera"} = 1` right now; labels `{instance="hera", os="darwin", arch="arm64"}`.
- `avg_over_time(up{job="darwin-hera"}[24h]) = 1.0` (0 / 2874 samples down).
- `avg_over_time(up[7d]) = 0.9989`; longest contiguous outage in 7d ≈ **6.5 min** (13×30s samples in one 10-min window). These are reboots/network blips, **not** a nightly sleep cycle. So: no time-window suppression, just a `for:` long enough to clear a ~7-min blip.

**Plumbing facts for the implementer:**
- Alert rules auto-discovered from `modules/monitoring/alerts/*.yaml` (`alerting.nix:13`, `readDir` + `hasSuffix ".yaml"`). New rule drops into the existing `hermes.yaml` — no new file, no import.
- Blackbox scrape jobs + modules live in `modules/services/blackbox-monitoring.nix`; the existing `http_2xx` module already returns success on a plain-HTTP 200.
- `darwin-hera` scrape job is in `modules/monitoring/services/remote-nodes.nix` (already enabled via `default.nix:68`).
- The `HostUnreachable` catch-all (`network.yaml:5`, `probe_success{job=~"blackbox_.*"} == 0`, `for: 2m`, **critical, ungated**) WILL match any new `blackbox_*` job and fire on hera reboots — this is the one thing that must be handled.

## 3. Design options

**Option A — New blackbox HTTP scrape target + dedicated gated alert (RECOMMENDED).**
Add a `blackbox_hera_mlx` scrape job (module `http_2xx`, target `http://hera.lan:8080/v1/models`) and a `MLXBackendDown` rule in `hermes.yaml` gated by `and on() up{job="darwin-hera"} == 1`. Reuses the existing exporter and module verbatim.
- *Pros:* tiny diff; cause-isolating; reuses proven infra; the conjunct cleanly separates "hera up + MLX dead" (page, actionable) from "hera down" (let DNSServerDown/LocalNetworkIssue/TargetDown own it). No secrets, no collector.
- *Cons:* must exclude the target from `HostUnreachable` to avoid a duplicate ungated critical; `/v1/models` proves the router is alive but not that a specific model loads (acceptable — that's the e2e probe's job).

**Option B — PromQL-only synthetic alert from existing signals (no new probe).**
Derive "MLX likely down" by ANDing `hermes_e2e_chat_ok == 0 and on() up{job="darwin-hera"} == 1 and ...`. No new scrape.
- *Pros:* zero new targets.
- *Cons:* **rejected.** It's still inference, not measurement — it can't tell MLX-down from LiteLLM-misroute or VM-down, which is the entire point of the gap. It also inherits the e2e probe's 5-min cadence and warmup confounds. We have a clean direct signal available; using a proxy is strictly worse.

**Option C — Authenticated deep probe (POST a tiny completion to hera:8080 directly).**
A textfile collector POSTs a 1-token completion to the hera backend and checks the body.
- *Pros:* proves a model actually loads/responds, not just that the router lives.
- *Cons:* **rejected as redundant.** The existing `hermes-e2e-chat-probe` already does exactly this through the real path (and is the right place for content validation). A direct deep probe duplicates it, costs hera model-time every interval, and likely needs an API key → secret handling for no new signal. The liveness layer (Option A) is the missing piece; the content layer already exists.

**Recommendation: Option A.** It is the cheapest change that actually closes the gap, layers cleanly under the existing e2e content probe (liveness vs. correctness), and needs zero secrets.

## 4. Recommended implementation

### 4.1 Scrape target — `modules/services/blackbox-monitoring.nix`

Add a new job to the `services.prometheus.scrapeConfigs` list (alongside `blackbox_litellm_fixup`, which is the closest precedent — a plain-HTTP local listener probed with `http_2xx`). Note `host_group` is intentionally **not** set so the ICMP `host_group`-based rules never match it.

```nix
# Direct liveness probe of the hera-side llama-swap / MLX model router
# (hera.lan:8080), the terminal upstream LiteLLM's `hera/*` models route to
# and thus the terminal dependency of all Hermes Discord chat. GET /v1/models
# returns HTTP 200 UNAUTHENTICATED (verified: owned_by=llama-swap, 30 models,
# ~2ms), so the strict http_2xx module suffices — no auth, no secrets. This is
# a LIVENESS probe of the router; per-model load correctness is covered by the
# hermes-e2e-chat-probe content check. NOTE this is the HERA instance, distinct
# from the vulcan-side llama-swap.vulcan.lan already in blackbox_https_local.
# The MLXBackendDown alert in hermes.yaml owns this target; it is deliberately
# EXCLUDED from the generic HostUnreachable rule (network.yaml) so a hera
# reboot does not double-fire an ungated critical. (coverage plan deferred:
# mlx-hera-probe)
{
  job_name = "blackbox_hera_mlx";
  metrics_path = "/probe";
  params = { module = [ "http_2xx" ]; };
  static_configs = [
    {
      targets = [ "http://hera.lan:8080/v1/models" ];
      labels = {
        service = "mlx-backend";
        probe = "hera-mlx";
      };
    }
  ];
  relabel_configs = [
    { source_labels = [ "__address__" ]; target_label = "__param_target"; }
    { source_labels = [ "__param_target" ]; target_label = "instance"; }
    { target_label = "__address__";
      replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}"; }
    { target_label = "probe_type"; replacement = "http_remote"; }
  ];
  scrape_interval = "30s";
  scrape_timeout = "10s";
}
```

Resulting series after relabel: `probe_success{job="blackbox_hera_mlx", instance="http://hera.lan:8080/v1/models", service="mlx-backend", probe="hera-mlx", probe_type="http_remote"}` plus the usual `probe_http_status_code`, `probe_duration_seconds`.

### 4.2 Suppress the generic catch-all double-fire — `modules/monitoring/alerts/network.yaml`

The `HostUnreachable` rule matches `blackbox_*` and is ungated critical. Add an instance exclusion so the new target is owned solely by the gated rule (mirrors the existing `instance!="TL-WPA8630.lan"` precedent for the latency rules):

```yaml
# was:  expr: probe_success{job=~"blackbox_.*"} == 0
expr: probe_success{job=~"blackbox_.*", job!="blackbox_hera_mlx"} == 0
```

(Equivalently exclude by `instance!~".*hera\\.lan:8080.*"`, but `job!=` is the cleaner, less brittle form.) This is the single behavioral edit that needs care.

### 4.3 The alert — append to `modules/monitoring/alerts/hermes.yaml` (`hermes_availability` group)

```yaml
# Direct liveness of the hera-side llama-swap/MLX model router — the terminal
# upstream every `hera/*` LiteLLM model routes to, and thus the terminal
# dependency of all Hermes chat. blackbox_hera_mlx GETs hera.lan:8080/v1/models
# (HTTP 200 unauth). When this is 0, the model backend itself is down — this is
# the CAUSE rule that isolates an MLX outage from the generic downstream
# HermesAskFailing / HermesE2eChatFailing symptoms.
#
# `and on() up{job="darwin-hera"} == 1` gates on hera being reachable at all:
#   - probe down + hera up   -> THIS fires: hera is alive but llama-swap is dead
#                               (the actionable case — restart llama-swap on hera).
#   - probe down + hera down -> THIS stays silent; DNSServerDown / LocalNetworkIssue
#                               / TargetDown(job=darwin-hera) own "hera unreachable".
# `on()` (no labels) because probe_success and up share no common labels — we
# want the scalar conjunction "hera is up" applied to the single probe series.
#
# for: 8m clears hera's observed reboot/network blips (longest contiguous
# darwin-hera gap in 7d was ~6.5min; avg_up_7d=0.9989). hera is effectively
# 24/7, so NO sleep-window suppression is needed.
- alert: MLXBackendDown
  expr: probe_success{job="blackbox_hera_mlx"} == 0 and on() up{job="darwin-hera"} == 1
  for: 8m
  labels:
    severity: warning
    category: availability
    service: mlx-backend
  annotations:
    summary: "hera MLX/llama-swap model router down (Hermes chat terminal dependency)"
    description: |
      The llama-swap model router on hera (http://hera.lan:8080/v1/models) has
      not answered HTTP 200 for 8 minutes WHILE hera itself is reachable
      (up{job="darwin-hera"}==1). This is the terminal upstream of every
      `hera/*` LiteLLM model, so Hermes Discord chat (and OpenClaw's hera-routed
      models) will fail until it recovers — expect HermesE2eChatFailing /
      HermesAskFailing / HermesFallbackChainTriggered to be firing alongside this
      as DOWNSTREAM symptoms; THIS rule names the root cause.

      Runbook (hera-side, manual — vulcan cannot ssh hera):
        1. On hera: confirm the llama-swap process / launchd job is alive and
           re-listening on :8080 (e.g. `curl -s localhost:8080/v1/models`).
        2. Restart llama-swap on hera; once `/v1/models` returns 200 this clears
           within one scrape interval.
        3. If hera itself is wedged (also see DNSServerDown/LocalNetworkIssue for
           hera.lan), recover hera first — this rule self-suppresses while hera
           is unreachable.
```

Optional staleness companion (only if you want to catch "the blackbox exporter stopped scraping this target" distinctly from `TargetDown`) — usually unnecessary since `up{job="blackbox_..."}` and the existing `BlackboxExporterDown` cover the exporter. Skip unless asked.

### 4.4 ports.txt

No new listening port on vulcan (the probe reuses blackbox :9115). Add a documentation line under the hera section noting the probed remote endpoint:
```
# (remote, hera) 8080 hera.lan llama-swap/MLX model router — probed by blackbox_hera_mlx (no vulcan listener)
```

### 4.5 Deploy choreography

1. Edit the three files above (`blackbox-monitoring.nix`, `network.yaml`, `hermes.yaml`) + ports.txt note.
2. `nixos-rebuild switch` — **restart cost is low and surgical**: Prometheus reloads rules + scrape config (no data loss), and `prometheus-blackbox-exporter.service` may restart (it has `Restart=always`, `startLimitIntervalSec=0`; a few-second blip in blackbox probing only). **No microVM restart** (these files are not in the microVM `restartTriggers`/`models.nix` set), so Hermes/OpenClaw are untouched — important given the "edits to models.nix cold-boot both VMs" gotcha.
3. Verify post-switch:
   - `curl -s 'localhost:9090/api/v1/query?query=probe_success{job="blackbox_hera_mlx"}'` → expect `1`.
   - `curl -s 'localhost:9090/api/v1/query?query=ALERTS{alertname="MLXBackendDown"}'` → expect empty (not firing).
   - `promtool check rules` clean (0 err rules — house standard).
4. **Rollback**: revert the three edits + `nixos-rebuild switch`. Stateless (no datastore, no secret, no collector files) → trivial.

## 5. Noise & failure-mode analysis

- **Double-firing on hera reboot (the main risk):** without §4.2 the ungated `HostUnreachable` (for:2m critical) would page on every hera blip and on real MLX death. The `job!="blackbox_hera_mlx"` exclusion plus the `and on() up{job="darwin-hera"}==1` gate together ensure: hera-down → only the hera-host rules fire (correct); hera-up + MLX-dead → only `MLXBackendDown` fires (correct, single page). Verify the exclusion landed by checking `ALERTS{alertname="HostUnreachable", instance=~".*hera.lan:8080.*"}` is always empty.
- **`for: 8m` chosen against the measured baseline:** longest contiguous `darwin-hera` outage in 7d was ~6.5min; 8m clears it with margin while still surfacing a genuine MLX outage well before the operator would otherwise notice via Discord. If 8m feels slow, 6m is defensible but risks catching a worst-case reboot.
- **`on()` correctness:** `probe_success{job="blackbox_hera_mlx"}` is a single series; `up{job="darwin-hera"}` is a single series; they share no labels, so `and on()` does the intended scalar conjunction. If a second hera probe target is ever added, switch `job="blackbox_hera_mlx"` filters stay single-series so `on()` remains safe.
- **llama-swap lazy-load semantics (scope honesty):** `/v1/models` returns 200 as long as the **router** is alive — it does NOT prove `Qwen3.6-27B-MLX-8bit` can actually load (confirmed: that exact id isn't even in the static `/v1/models` list; llama-swap swaps it in on demand). So `MLXBackendDown` is a **liveness** signal; a "router up but model won't load" failure is caught by the pre-existing `hermes-e2e-chat-probe` content check. This layering is deliberate and should be stated in the runbook so the operator doesn't think a green MLXBackendDown means chat is definitely working.
- **Silent-break risk:** if blackbox exporter dies, the target goes stale → `up{job="blackbox_hera_mlx"}` (the scrape-of-exporter) and the existing `BlackboxExporterDown`/`TargetDown` rules catch it; `MLXBackendDown` itself won't false-clear because a missing `probe_success` series makes the `== 0` term absent (no firing) — acceptable, the exporter-health rules own that.
- **Latency drift:** not alerted here (router liveness is binary); the e2e chat probe already tracks end-to-end latency. Don't add a `probe_duration_seconds` threshold on this job — a 200 from `/v1/models` is ~2ms and uninformative about model latency.

## 6. Security considerations

- **No secrets touched.** The probe is an unauthenticated GET of `/v1/models`; no API key, no token, no `EnvironmentFile`, no SOPS secret. This is the decisive reason it's cheaper than Option C.
- **No secret-bearing config read.** The hera api_base lives in `/etc/litellm/config.yaml` (`0600 litellm:litellm`, contains master/provider keys) — this spec deliberately does **not** read it; the endpoint (`hera.lan:8080`) was derived from non-secret port scanning + the public `/v1/models` response, never from the keyed config.
- **No new exposure surface.** blackbox stays bound to `lo:9115` (existing firewall rule); the probe egresses to hera over the LAN. No new listener on vulcan.
- **Metrics emitted are non-sensitive:** `probe_success` (0/1), `probe_http_status_code`, `probe_duration_seconds`, and standard labels (`instance` = the URL, `service`, `probe`). No model names, no payload, no PII. The `instance` label exposes only `hera.lan:8080` (already documented infra, same as the existing ICMP probe of hera.lan).
- **Topology note:** the alert description references `hera.lan` (already present in `blackbox-monitoring.nix` and `remote-nodes.nix`), so it discloses nothing new about network layout.

## 7. Effort & sequencing

- **Effort: S, ~2-3h** — ~30 min to write the three edits (all proven patterns), the rest is the `nixos-rebuild switch`, live verification, and a short soak to confirm `MLXBackendDown` stays quiet while green.
- **Prerequisites: none.** All infra exists: blackbox exporter (running), `http_2xx` module (proven against the target), `darwin-hera` scrape job (live, `up=1`), alerts auto-discovery (active). No new exporter, port, secret, or collector.
- **What it unblocks:** turns an MLX outage from "a cluster of generic downstream criticals 5+ min later" into "one root-cause-named warning that points straight at the hera-side restart." It also gives the self-heal daemons a clean signal to *not* restart the Hermes VM for a backend outage they can't fix (the VM restart just re-arms the warmup clock — a documented past failure mode), and it provides the precise label a future Hermes runbook/dashboard panel can key on.
- **Sequencing:** standalone; safe to land any time. Independent of the microVM `restartTriggers` set, so it will not cold-boot the VMs.

## 8. Decisions required from the operator

- **Severity of `MLXBackendDown`:** recommend **`warning`**, because (a) the user-visible symptom is already paged critical by `HermesE2eChatFailing`/`HermesAskFailing`, and (b) neither self-heal daemon can restart hera, so this is a cause-isolation/runbook signal, not a new urgent page. Confirm `warning` vs `critical`.
- **Flap detection (out of scope by default):** I left out a `MLXBackendDegraded` warning on `rate(probe_success[5m]) < 1 and > 0` to keep the change minimal. Say if you want llama-swap *flapping* (vs hard-down) surfaced too.


---


<a id="email-fts-staleness"></a>

# Email FTS (Xapian/flatcurve) index-staleness monitoring + formal retirement of DovecotHighConnectionCount

**Verdict:** IMPLEMENT · **Effort:** S/M — ~3-4h (one collector module mirroring dovecot-imapsieve-monitor.nix + 3 alert rules; single build/switch)

**Key live evidence:** FTS backend = flatcurve (Xapian glass): dovecot.nix:333-338 fts=flatcurve, fts_autoindex=yes, fts_enforced=body, fts_languages=en. mailLocation=maildir:/var/mail/%u (dovecot.nix:88; /var/mail -> /var/spool/mail). · Index location is per-mailbox: <maildir>/[.<folder>/]fts-flatcurve/current.<id>/{postlist,termlist}.glass (+ rotated index.<n>/). johnw INBOX current index = 30.5MB+21.7MB at Jun 10 09:42; a rotated index.3007 is 807MB+590MB. /var/lib/dovecot-fts (the tmpfiles-created dir) is EMPTY — flatcurve does NOT use it. · No FTS metric exists: dovecot exporter (:9166, job=dovecot, up=1) exposes only dovecot_user_* auth/IO stats — zero fts/index series. Confirmed gap. · BASELINE (the load-bearing number): clamped max( newest_mail_mtime - newest_index_mtime ) over all folders = 0 s for johnw (40 fts-flatcurve dirs), assembly (2), bia (1). Newest mail and newest index both Jun 10 10:10:36 — autoindex is keeping perfect pace. · Mail churn is real: increase(postfix_lmtp_delivery_delay_seconds_count[24h]) = 306; [7d] = 1477 (~211/day). Staleness would be user-visible. · doveadm introspection: `doveadm fts` = expand|lookup|optimize|rescan|tokenize (NO status subcommand); `doveadm index <mask>` triggers indexing. So mtime-diff is the only staleness signal available.

## 1. TL;DR

Dovecot full-text search runs on **flatcurve** (a Xapian "glass" backend) with `fts_autoindex = yes` and `fts_enforced = body` (`dovecot.nix:333-338`). The autoindexer is supposed to keep a per-mailbox Xapian index in step with delivered mail, but **nothing monitors whether it actually does**. If the `indexer-worker` wedges, a folder's index corrupts, or a glass write fails mid-rotation, the service stays green (`dovecot_up=1`, the IMAP probe passes) while search silently returns stale or empty results — a textbook "correctness" gap of the kind the coverage plan calls out as the weakest pillar.

**Recommendation:** a daily **root textfile collector** that, per mail user, computes the maximum-over-folders lag between the newest delivered-mail mtime and the newest flatcurve-index mtime, emitting `fts_index_lag_seconds{user}` plus a freshness/last-success triad, backed by a `> 48h` warning and `> 7d` critical alert. The collector is a near-clone of the existing `dovecot-imapsieve-monitor.nix`.

**Cost:** S/M, ~3-4h, one build/switch. The current baseline is a clean **0 s** lag across all 40+ folders for all three mail users, so the thresholds sit far above noise.

This chapter also formally **RETIRES** `DovecotHighConnectionCount` (already deleted from the rule set; no backing metric, single-user server) — documenting the intent as consciously closed so it doesn't recur as a dead-rule placeholder.

## 2. Current state & evidence

**FTS configuration** (`modules/services/dovecot.nix`):
- `fts = flatcurve`, `fts_autoindex = yes`, `fts_enforced = body`, `fts_languages = en`, tokenizers `generic email-address` (lines 332-337). Plugins enabled globally (`fts`, `fts_flatcurve`, lines 103-104).
- `mailLocation = "maildir:/var/mail/%u"` (line 88); `/var/mail` → `/var/spool/mail`. Despite some `mdbox_*` plugin keys present (lines 323-326), storage is **maildir** — those mdbox settings are inert.
- `indexer-worker` configured with `vsz_limit = 1024M` (line ~243), `process_limit = 1024`.
- `/var/lib/dovecot-fts` is created by tmpfiles (`dovecot.nix:456`) but is **empty** — flatcurve stores indexes inside the maildir, not there.

**Index layout (where the staleness signal lives):** per-mailbox under
`<maildir>/[.<folder>/]fts-flatcurve/`, containing a live `current.<id>/` Xapian glass DB (`postlist.glass` + `termlist.glass` + `iamglass` + `flintlock`) and rotated `index.<n>/` snapshots. INBOX's live index is ~30.5MB + ~21.7MB (Jun 10 09:42); one rotated snapshot is ~807MB + ~590MB. Folder counts with an index: **johnw 40, assembly 2, bia 1**.

**No metric exists.** The dovecot Prometheus exporter (`:9166`, `job="dovecot"`, `up=1`) exposes only `dovecot_user_*` auth/IO/cache counters — **zero** FTS/index series. There is no `doveadm fts status` subcommand (only `expand|lookup|optimize|rescan|tokenize`), so an mtime comparison is the only available staleness signal.

**Baseline measured live (the number the design rests on):** the clamped max of `(newest_mail_mtime − newest_index_mtime)` over every folder is **0 s** for johnw (40 folders), assembly, and bia. Newest mail and newest index were the same second (Jun 10 10:10:36). The autoindexer is healthy and current; index mtime is typically *ahead* of mail mtime (flatcurve rewrites the whole-mailbox glass DB on each pass), so negative lags clamp to 0.

**Mail churn justifies caring:** `increase(postfix_lmtp_delivery_delay_seconds_count[24h]) = 306`, `[7d] = 1477` (~211/day). At that volume a wedged index is genuinely user-visible.

**Permissions:** all three maildirs are `0700 <user>:users`. node-exporter runs as `node-exporter` and cannot read them; the collector must run as **root** (exactly like `dovecot-imapsieve-health-check`, which is `User=root`).

**DovecotHighConnectionCount:** `grep -rln 'DovecotHighConnectionCount'` over the repo hits only `docs/MONITORING_COVERAGE_PLAN.md` (the disposition table). It is already absent from every `.nix`/`.yaml` rule file — deleted in the dead-metric sweep. The exporter exposes no concurrent-connection gauge to revive it against.

## 3. Design options

**Option A — Daily root textfile collector: max-folder mtime lag (RECOMMENDED).**
A oneshot, modeled on `dovecot-imapsieve-monitor.nix`, runs as root once a day. For each mail user it finds the newest mail file across all `cur`/`new` dirs and the newest `*.glass` file across all `fts-flatcurve` dirs, takes the per-folder lag clamped at 0, and emits the per-user maximum as `fts_index_lag_seconds{user="johnw"}`. Pure filesystem metadata (`find -printf '%T@'`), no IMAP login, no `doveadm` call, no mail-content reads.
- *Pros:* dead simple, follows the established textfile idiom exactly, zero load on dovecot, secret-safe (only mtimes leave the box), reuses the proven template, baseline is a clean 0 s.
- *Cons:* mtime is a proxy, not a query result — a corrupted-but-recently-written index would show 0 lag. Acceptable: corruption is a different failure mode, and flatcurve has its own self-heal on `rescan`. A daily cadence means up to ~24h detection latency (fine for a 48h threshold).

**Option B — Active `doveadm fts lookup` canary probe.**
Periodically run `doveadm fts lookup -u johnw <known-term>` for a term known to exist in a recent message and assert a non-empty hit set.
- *Pros:* tests the actual search path end-to-end (closest to "is search working?").
- *Cons:* needs a stable known-good term per mailbox (brittle), runs a real FTS query against the 800MB+ index (I/O cost), and reading lookup output risks surfacing message metadata into the conversation/logs (secret-safety friction). Overkill for a single-user box where the autoindexer has never lagged.

**Option C — Do nothing / rely on user noticing search is broken.**
- *Cons:* this is exactly the silent-correctness failure the coverage plan exists to eliminate. Reject.

**Recommendation: Option A.** It matches house conventions, is secret-trivial, has a measured 0 s baseline, and costs almost nothing to run. Option B's end-to-end fidelity isn't worth its brittleness and I/O on a healthy single-user system; keep `doveadm fts rescan` as a *remediation* runbook (section 4), not a monitoring probe.

## 4. Recommended implementation

### File to create
`/etc/nixos/modules/services/dovecot-fts-monitor.nix` — clone the structure of `dovecot-imapsieve-monitor.nix` (root oneshot + timer + inline `services.prometheus.ruleFiles`, atomic tmp+mv).

### Import
Add to `hosts/vulcan/default.nix` next to the existing dovecot modules (after line 72):
```nix
    ../../modules/services/dovecot-fts-monitor.nix
```

### Collector sketch (root oneshot, daily)
Writes `/var/lib/prometheus-node-exporter-textfiles/fts_staleness.prom`:
```sh
set -euo pipefail
METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/fts_staleness.prom"
TMP="$METRICS_FILE.tmp"
USERS="johnw assembly bia"          # decision #2 — or derive from /var/spool/mail dirs
{
  echo "# HELP fts_index_lag_seconds Max over folders of (newest mail mtime - newest flatcurve index mtime), clamped >=0"
  echo "# TYPE fts_index_lag_seconds gauge"
  for u in $USERS; do
    root="/var/spool/mail/$u"
    [ -d "$root" ] || continue
    maxlag=0
    # iterate folders that actually have an index dir
    while IFS= read -r ftsdir; do
      d=$(dirname "$ftsdir")
      mail=$(find "$d/cur" "$d/new" -type f -printf '%T@\n' 2>/dev/null | cut -d. -f1 | sort -nr | head -1)
      idx=$(find "$ftsdir" -type f -name '*.glass' -printf '%T@\n' 2>/dev/null | cut -d. -f1 | sort -nr | head -1)
      [ -z "$mail" ] && continue
      [ -z "$idx" ] && idx=0
      lag=$((mail - idx)); [ "$lag" -lt 0 ] && lag=0
      [ "$lag" -gt "$maxlag" ] && maxlag=$lag
    done < <(find "$root" -type d -name fts-flatcurve 2>/dev/null)
    echo "fts_index_lag_seconds{user=\"$u\"} $maxlag"
  done
  echo "# HELP fts_staleness_last_run_timestamp_seconds Unix time the FTS staleness check last completed"
  echo "# TYPE fts_staleness_last_run_timestamp_seconds gauge"
  echo "fts_staleness_last_run_timestamp_seconds $(date +%s)"
  echo "# HELP fts_staleness_check_success Whether the FTS staleness check completed (1=ok)"
  echo "# TYPE fts_staleness_check_success gauge"
  echo "fts_staleness_check_success 1"
} > "$TMP"
mv "$TMP" "$METRICS_FILE"
chmod 644 "$METRICS_FILE"
```
`serviceConfig`: `Type=oneshot`, `User=root`, `Group=root`, `path = [ coreutils findutils ]`. (No `SuccessExitStatus` gymnastics needed — set `-euo pipefail` and let a real failure exit non-zero so the `_success`/timestamp goes stale rather than lying.)

### Timer
Daily, with boot delay and persistence (matches the daily index rebuild cadence — `index.3007` rotated at 03:00):
```nix
timerConfig = { OnCalendar = "*-*-* 04:30:00"; Persistent = true; RandomizedDelaySec = "10m"; };
```
04:30 sits after the nightly index rotation (~03:00) and after backups, so it measures a settled state.

### Alert rules (inline `services.prometheus.ruleFiles`, mirroring imapsieve)
Group `fts-staleness`, `interval: 5m`:
```yaml
- alert: FtsIndexStale
  expr: fts_index_lag_seconds > 172800          # 48h
  for: 30m
  labels: { severity: warning, component: mail }
  annotations:
    summary: "Dovecot FTS index stale for {{ $labels.user }}"
    description: "Newest mail is {{ $value | humanizeDuration }} ahead of the newest flatcurve index. Search results may be incomplete. Remediate: doveadm index -u {{ $labels.user }} '*'  (or  doveadm fts rescan -u {{ $labels.user }})."

- alert: FtsIndexSeverelyStale
  expr: fts_index_lag_seconds > 604800           # 7d
  for: 30m
  labels: { severity: critical, component: mail }
  annotations:
    summary: "Dovecot FTS index SEVERELY stale for {{ $labels.user }}"
    description: "FTS index is >7d behind delivered mail. The indexer-worker is likely wedged. Check: systemctl status dovecot2; journalctl -u dovecot2 | grep -i 'fts\\|index'."

- alert: FtsStalenessCheckStale
  expr: (time() - fts_staleness_last_run_timestamp_seconds) > 129600   # 36h
  for: 1h
  labels: { severity: warning, component: mail }
  annotations:
    summary: "FTS staleness collector not running"
    description: "fts_staleness check hasn't completed in {{ $value | humanizeDuration }}. Check dovecot-fts-staleness-check.timer."
```
**Threshold justification:** observed baseline is **0 s** on a system delivering ~211-306 msgs/day, so any value above a few hours already means autoindex stopped. 48h tolerates a weekend of indexer trouble before paging warning; 7d is unambiguous breakage. The `for: 30m` on the lag alerts is irrelevant given the daily scrape but harmless and keeps the rule from flapping if the collector ever runs twice.

### ports.txt / loki.nix
No new listening port (textfile collector → existing `job=node`), so **no `docs/ports.txt` edit**. No LogQL, so **no loki.nix L+ symlink**. Auto-discovery doesn't apply because we use inline `ruleFiles` (the imapsieve module's choice) — promtool still validates at build via `checkConfig`.

### Optional monthly remediation oneshot (decision #3, ship commented/off)
A separate monthly `doveadm fts rescan -A` (or per active user) as a *self-heal*, not a probe. It is I/O-heavy against the 800MB+ INBOX index, so gate it behind a comment and only enable if `FtsIndexStale` ever fires. Document the manual form (`doveadm index -u johnw '*'`) in the alert annotation regardless.

### Deploy choreography
1. Honor the build lock: wait if `/etc/nixos/.nixos-build` exists; create it; build `--cores 0`; switch; remove the lock. (Another session is actively editing — coordinate or wait.)
2. `dovecot-fts-monitor.nix` adds only a oneshot + timer + rules; the switch does **not** restart `dovecot2` (no `dovecot2` config change). Zero mail-service impact.
3. Validate: `systemctl start dovecot-fts-staleness-check.service`, then `cat /var/lib/prometheus-node-exporter-textfiles/fts_staleness.prom` (mtimes only — safe), confirm `fts_index_lag_seconds{user="johnw"} 0`. Query Prometheus `/api/v1/query?query=fts_index_lag_seconds` and `/api/v1/rules` → all three rules `health=ok`, none firing.
4. **Rollback:** revert the import line + delete the module; rebuild. The `.prom` file goes stale and the metric disappears; no residual state.

### DovecotHighConnectionCount retirement (formal closure)
**No code change** — it is already gone from the rules. The documented disposition: **RETIRE permanently.** Rationale (record in the module header comment and/or the coverage plan): the dovecot Prometheus exporter exposes no concurrent-connection gauge (`dovecot_user_*` auth/IO only); vulcan is a single-user mail server with `mail_max_userip_connections = 100` for the LAN (`dovecot.nix:319`), so a connection-count alert would protect against a load profile that cannot occur. Reviving it would require a custom exporter scraping `doveadm who`/`proc` for a metric of zero operational value here. Up/down is covered by `up{job="dovecot"}` and the IMAPS blackbox probe. Intent consciously closed.

## 5. Noise & failure-mode analysis

- **Chronic false-positive risk: low.** Baseline is 0 s, threshold is 48h; the gap is six orders of magnitude. A folder receiving its first-ever mail before the next autoindex pass shows transient lag bounded by the autoindex interval (sub-minute in practice) — far under 48h.
- **Folders with no new mail never go stale:** lag = `newest_mail − newest_index`; if both are old and equal-ish, lag ≈ 0. A dormant folder cannot trip the alert. Correct by construction.
- **Index-ahead-of-mail (negative lag) is normal** (flatcurve rewrites the whole glass DB each pass) and clamps to 0 — no spurious negative values.
- **Silent-break of the collector itself:** mitigated by `fts_staleness_last_run_timestamp_seconds` + `FtsStalenessCheckStale` (36h). If the oneshot dies, the freshness alert fires; the lag metric goes stale rather than reporting a stale-but-frozen 0.
- **mtime is a proxy:** a corrupted-but-recently-written index reads 0 lag. This is an accepted limitation — corruption is a distinct failure mode that flatcurve's own `rescan` heals; if you want corruption detection, that's Option B, deliberately deferred.
- **Glob/permission edge:** the collector runs as root and reads `0700` maildirs fine; if a user's maildir is missing it `continue`s. `set -euo pipefail` plus `2>/dev/null` on the `find`s keeps a missing `cur`/`new` from failing the run.
- **Cardinality:** 3 series (one per user) + 2 housekeeping series. Negligible.

## 6. Security considerations

- **Reads mail directories but emits only derived integers** (unix-epoch mtimes and their difference). **No filenames, no headers, no message bodies, no sender/recipient data** ever leave the box or enter the metric. The `.prom` output is mtimes only — safe to `cat` during validation.
- Runs as **root** solely because the maildirs are `0700`; it touches no secrets, no `/run/secrets`, no SOPS, no tokens. It is strictly less privileged in scope than the existing `dovecot-imapsieve-health-check` (which greps the full journal).
- `find -printf '%T@'` returns timestamps, never content — there is no path by which message text could be surfaced even accidentally.
- Output file is `chmod 644` (metric is non-sensitive: "index is N seconds behind"). No credential, PII, or topology exposure. Consistent with every other `.prom` in the textfiles dir.
- The optional `doveadm fts rescan` remediation, if ever enabled, also emits nothing to the conversation — it only rewrites on-disk indexes.

## 7. Effort & sequencing

- **Effort:** S/M, ~3-4h. ~80% is cloning `dovecot-imapsieve-monitor.nix` and tuning the loop; ~20% is build/switch/validate on the throttled aarch64 box (`--cores 0`).
- **Prerequisites:** none. Textfile collector dir, node-exporter `job=node`, and the dovecot service all already exist and were verified live. No new ports, no SOPS edits, no Loki wiring.
- **Sequencing:** standalone P2-tier correctness add; fits the coverage plan's pattern #2 ("last-success/freshness triad on every artifact-producing job"). Independent of all other deferred specs — can land in any later batch. Honor the `/etc/nixos/.nixos-build` lock since another session is editing.
- **Unblocks:** closes the last unmonitored correctness surface in the mail stack (delivery, LMTP delay, imapsieve, and now FTS freshness are all observable) and formally retires the dangling `DovecotHighConnectionCount` intent so it can't resurface as a dead-rule placeholder.

## 8. Decisions required from the operator

- **Thresholds:** ship 48h warning / 7d critical (recommended, generous vs the 0 s baseline) — or tighten the warning to 24h for faster notice of a wedged `indexer-worker`.
- **Scope:** monitor johnw + assembly + bia (recommended `-A`-style loop) vs johnw-only. All three index cleanly today; cost difference is one loop iteration.
- **Monthly `doveadm fts rescan` remediation:** wire it now (commented/off by default) as documented self-heal, or leave it purely as the runbook line in the alert annotation. Recommended: leave commented until `FtsIndexStale` ever fires.


---


<a id="b2-offsite-probe"></a>

# B2 Offsite Backup Probe — Collector-Run Freshness + Optional Credential-Free Reachability Canary

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** S — 0.5-1.5h (freshness rule ~30min; optional blackbox probe +45min)

**Key live evidence:** restic-metrics.service: Type=oneshot, Result=success, NRestarts=0; timer active, every 6h (OnUnitActiveSec=6h), last triggered 2026-06-10 07:37 PDT · All 9 B2 repos report restic_check_success=1 live (Audio, Backups, Databases, Home, Photos, Public, Video, doc, src) — Public coverage confirmed present (added census 2026-06-09) · Per-repo last-snapshot ages live: 4.7-8.0h (Video 4.7h … Audio 8.0h) — all well under the 30h ResticNoRecentSnapshot threshold · restic.prom last rewritten 8430s (~2.34h) ago via restic_last_check_timestamp_seconds; node_textfile_mtime_seconds confirms file age ~8342s — normal for 6h cadence · restic.prom is NOT referenced in ANY freshness rule: grep of restic.prom / restic_last_check_timestamp / restic_metrics across alerts/ returns empty; it is absent from BOTH TextfileCollectorStaleFast and TextfileCollectorStaleDaily allowlists (meta-monitoring.yaml lines 319/331) · Collector swallows per-repo failures: each restic call is `if SNAPSHOTS=$(... 2>/dev/null); then … else CHECK_SUCCESS=0 fi`, script ends `set -euo pipefail` but always reaches `mv` and exits 0 → SystemdServiceFailed (node_systemd_unit_state state=failed) never fires on a B2 outage; restic_check_success=0 carries the signal instead

## 1. TL;DR

B2 credential + reachability validation is **already exercised every 6 hours** by the existing `restic-metrics` collector (`modules/monitoring/services/restic-metrics.nix`), which performs a real authenticated B2 round-trip per repository (`restic -r s3:s3.us-west-001.backblazeb2.com/jwiegley-<bucket> snapshots --json` plus three `stats` calls). The outcome is exported as `restic_check_success{repository}` and is alerted on by `ResticCheckFailed`, with freshness/size covered by `ResticNoRecentSnapshot`, `ResticNoSnapshots`, and `ResticRepoSizeShrunk`. All 9 repos (including the recently-added `Public`) currently report `restic_check_success=1`.

The brief's premise — "what ADDITIONAL signal exists" — resolves to **one genuine gap and one cheap optional addition**:

1. **Genuine gap (IMPLEMENT):** the `restic.prom` textfile has **no collector-run freshness alert**. It is deliberately omitted from both `TextfileCollectorStale*` tiers and is mislabeled "weekly restic" in the meta-monitoring comment (it actually runs every 6 h). If the `restic-metrics` timer dies or the collector starts silently failing its `mv`, every restic metric **freezes at its last value** (`restic_check_success=1` forever), and every restic alert silently reads stale data. This is the real "offsite probe" gap.
2. **Cheap optional canary (IMPLEMENT_MODIFIED):** a credential-free HTTPS blackbox probe to the B2 S3 endpoint separates *network/TLS-path* health from *auth* health (a live unauthenticated GET returns `403` with valid TLS in 108 ms). It rides the existing blackbox plumbing and auto-inherits the `HostUnreachable` backstop.

The heavyweight standalone idea — a separate authenticated B2 reachability/credential probe — should be **RETIRED**: it duplicates what `restic-metrics` already does every 6 h. Cost: S, ~0.5–1.5 h.

## 2. Current state & evidence

**The collector is a real B2 round-trip, not a local read.** `restic-metrics.nix` loops over 9 repos and, for each, runs an authenticated `restic snapshots --json` against `s3:s3.us-west-001.backblazeb2.com/jwiegley-<bucket>` (with `Backups → Backups-Misc` mapping). Credentials come from `/run/secrets/aws-keys` (sourced) and `/run/secrets/restic-password` (`cat`ed into `RESTIC_PASSWORD`). A successful JSON parse sets `restic_check_success{repository}=1`; on any failure it stays `0`. So a credential rotation, B2 outage, or network partition is *already* visible per-repo.

**Live state (2026-06-10 ~10:13 PDT):**
- `restic-metrics.service`: `Type=oneshot`, `Result=success`, `NRestarts=0`; timer `active`, `OnUnitActiveSec=6h`, `OnBootSec=5min`, `Persistent=true`; last triggered 07:37 PDT.
- All 9 repos `restic_check_success=1`: Audio, Backups, Databases, Home, Photos, **Public**, Video, doc, src.
- Per-repo last-snapshot ages: 4.7 h (Video) … 8.0 h (Audio) — all well under the 30 h `ResticNoRecentSnapshot` threshold.
- `restic.prom` last rewritten **~8 430 s (≈2.34 h) ago** (`time() - max(restic_last_check_timestamp_seconds)`); `node_textfile_mtime_seconds` agrees (~8 342 s). Normal for a 6 h cadence.

**Existing alert coverage (already deployed):**
| Alert | File | Expr | Covers |
|---|---|---|---|
| `ResticCheckFailed` | `storage.yaml:225` | `restic_check_success{repository!=""} == 0` for 5m | **auth + reachability** per repo |
| `ResticNoRecentSnapshot` | `storage.yaml:241` | `(time()-restic_last_snapshot_timestamp_seconds) > 108000` for 10m | snapshot freshness (30 h) |
| `ResticNoSnapshots` | `storage.yaml:252` | `restic_snapshots_total == 0` for 5m | empty repo |
| `ResticRepoSizeShrunk` | `storage.yaml:282` | `>0 and < 0.6*avg_over_time(...[14d])` for 6h | bucket emptied / misdirected backup |
| `ResticIntegrityCheckFailed/Stale` | `local-backup.yaml:63/82` | weekly `restic check` ExecStopPost metrics | bit-rot / corruption |

**The gap, precisely.** Grepping `restic.prom` / `restic_last_check_timestamp` / `restic_metrics` across `alerts/` returns **empty**. `restic.prom` is in neither `TextfileCollectorStaleFast` (allowlist: asymmetric_routing, nodered_safety, container_health, zfs_pool_health, nagios_status) nor `TextfileCollectorStaleDaily` (container_store_size, system_age, pg_dump, technitium_backup, nodered_backup) — see `meta-monitoring.yaml:324/331`. The exclusion comment justifies this as "weekly restic," but the collector runs **every 6 h**, so the file legitimately should never be >~7 h stale. **Nothing currently notices if the collector stops running.**

**Why `SystemdServiceFailed` does NOT backstop this.** The collector wraps each restic call in `if SNAPSHOTS=$(… 2>/dev/null); then … else CHECK_SUCCESS=0 fi` and always reaches the final `mv`/`exit 0`. So a total B2 outage produces `restic_check_success=0` (caught by `ResticCheckFailed`) but the unit exits **success** — `node_systemd_unit_state{name="restic-metrics.service",state="failed"}` never goes to 1. And a *timer death* produces neither a failed unit nor a `=0` metric — just frozen `=1`. That is the silent failure mode.

**B2 endpoint behavior (live, unauthenticated, harmless GETs):** `https://s3.us-west-001.backblazeb2.com/` → **403** (AccessDenied; TLS valid `ssl_verify=0`; 108 ms); `https://api.backblazeb2.com/` → **301** (63 ms). A 403/valid-TLS response is exactly the credential-free "the server is alive and the TLS path works" signal we'd want, distinct from restic's auth-bearing calls.

**B2 app-key expiry.** Backblaze B2 application keys **do not expire by default** — they persist until revoked unless a `validDurationInSeconds` was set at creation. Unless the user set a TTL, there is no expiry to track and no gap here (see Decisions).

## 3. Design options

**Option A — Freshness rule only (RECOMMENDED, minimal).** Add one `ResticMetricsStale` warning rule keyed on `restic_last_check_timestamp_seconds`, closing the silent-freeze gap. Zero new services, zero new credentials, zero attack surface. Cost: ~30 min.
- *Pro:* fixes the only real gap; pure alert YAML (auto-discovered); no rebuild of any service.
- *Con:* does not distinguish network-path failure from auth failure (but `restic_check_success=0` already tells you *a* failure happened, and the journal tells you which).

**Option B — Freshness rule + credential-free B2 S3 blackbox probe (RECOMMENDED+, still cheap).** A on top of a new `blackbox_b2` scrape job hitting `https://s3.us-west-001.backblazeb2.com/` with a permissive http module (`valid_status_codes: [200, 301, 403]`, TLS validated against the public CA bundle). This rides existing blackbox infra and auto-inherits `HostUnreachable`. Cost: A + ~45 min.
- *Pro:* `probe_success{job="blackbox_b2"}` gives you an *independent* network+TLS-path signal. When B2 is genuinely unreachable, **both** the probe and `ResticCheckFailed` fire → confirmed network/outage. When the probe is green but `ResticCheckFailed` fires → it's **credentials or a repo problem**, not the network. That disambiguation is the only thing restic-metrics can't give you today.
- *Con:* one more blackbox target + external dependency on Backblaze returning a stable status code. 403 is stable for unauthenticated S3, but a B2 frontend change could shift it (mitigated by the permissive status list + the fact that a flap only adds a warning, never silences restic coverage).

**Option C — Standalone authenticated B2 reachability/credential canary (RETIRE).** A dedicated oneshot that re-auths to B2 (e.g. `restic cat config` per repo, or a `b2 authorize-account`) purely to validate creds. This is **redundant**: the 6 h `restic snapshots` call already is an authenticated round-trip per repo and already drives `restic_check_success`. Adding a second auth path means a second place to handle secrets, a second timer to monitor, and no new signal. **Do not build this.** It is exactly the "heavyweight version" the brief flagged.

**Recommendation: Option B.** A is non-negotiable (it's the real gap). The B2 S3 probe in B is genuinely cheap, secret-free, and adds the one signal restic-metrics structurally cannot — network-vs-auth disambiguation — for ~45 min on plumbing that already exists. If the operator wants the absolute minimum, ship A alone and skip the probe.

## 4. Recommended implementation

### 4.1 Part A — `ResticMetricsStale` freshness rule (the real fix)

**File:** `modules/monitoring/alerts/storage.yaml` — append inside the existing `restic` rules block (after `ResticRepoSizeShrunk`, ~line 291). Auto-discovered; no Nix change.

```yaml
      # Collector-run freshness. restic-metrics.timer runs every 6h
      # (OnUnitActiveSec=6h, OnBootSec=5min, Persistent=true). If the timer dies
      # or the collector stops rewriting restic.prom, EVERY restic_* metric
      # freezes at its last value (restic_check_success stays 1 forever) and all
      # the restic.* alerts above silently read stale data. SystemdServiceFailed
      # does NOT catch this: the collector swallows per-repo errors and exits 0,
      # and a dead timer produces no failed unit at all. node_textfile_mtime would
      # also work, but restic.prom is intentionally excluded from the generic
      # TextfileCollectorStale tiers (meta-monitoring.yaml) — this is its dedicated
      # freshness guard. Threshold 8h = 6h cadence + ~2h grace (a single missed
      # 6h run is normal-ish under Persistent catch-up; two missed runs is wrong).
      # max() collapses the 9 per-repo series to one timestamp (they all write in
      # the same collector pass). Baseline verified live 2026-06-10: file age ~2.3h.
      - alert: ResticMetricsStale
        expr: (time() - max(restic_last_check_timestamp_seconds)) > 28800
        for: 10m
        labels:
          severity: warning
          category: storage
          service: restic
        annotations:
          summary: "Restic B2 metrics collector is stale"
          description: "restic-metrics has not refreshed restic.prom in over 8 hours (last collector pass {{ $value | humanizeDuration }} ago; expected every 6h). All restic_check_success / snapshot-freshness / repo-size alerts are now reading FROZEN values — a B2 outage or credential failure would not be detected. Check `systemctl status restic-metrics.timer` and `journalctl -u restic-metrics`."
```

Threshold justification: cadence 6 h; `Persistent=true` catches up a missed boot-window run; one slow run (the collector can take many minutes against 9 repos, `TimeoutSec=30m`) can push the file age toward 6.5 h legitimately. 8 h gives a clean ~1.3 h margin over the worst legitimate case while still catching a fully dead timer within one cadence. `for: 10m` matches the house pattern for daily/slow freshness rules and avoids a single delayed scrape flapping.

### 4.2 Part B — credential-free B2 S3 reachability probe (optional, recommended)

No new module file. Add a scrape job to the existing `blackbox-monitoring.nix`. Reuse the existing **`https_2xx` module** (TLS validated against the public CA bundle — B2's cert is public, so do NOT use `https_2xx_local` which pins step-ca) but, because a bare GET returns 403, add **one new permissive module** so the probe doesn't read 403 as failure.

**File:** `modules/services/blackbox-monitoring.nix`

(1) New blackbox module, alongside `https_2xx` (~line 76):
```yaml
      # Credential-free reachability/TLS canary for the Backblaze B2 S3 endpoint.
      # An unauthenticated GET returns 403 (AccessDenied) with a VALID public cert
      # in ~110ms — that 403 is the healthy "server alive + TLS path good" signal.
      # This is deliberately NOT authenticated: restic-metrics already proves
      # credentials every 6h. This probe's ONLY job is to separate a B2/network
      # outage (probe red) from a credential/repo fault (probe green, restic red).
      https_b2_endpoint:
        prober: http
        timeout: 5s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: [200, 301, 403]
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: false
          fail_if_ssl: false
          tls_config:
            insecure_skip_verify: false
```

(2) New scrape job, mirroring `blackbox_https` (~line 563):
```nix
          {
            job_name = "blackbox_b2";
            metrics_path = "/probe";
            params.module = [ "https_b2_endpoint" ];
            static_configs = [{
              targets = [ "https://s3.us-west-001.backblazeb2.com/" ];
            }];
            relabel_configs = [
              { source_labels = [ "__address__" ]; target_label = "__param_target"; }
              { source_labels = [ "__param_target" ]; target_label = "instance"; }
              { target_label = "__address__";
                replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}"; }
              { target_label = "probe_type"; replacement = "https_b2"; }
            ];
            scrape_interval = "60s";
            scrape_timeout = "15s";
          }
```

**Alerting:** the generic `HostUnreachable: probe_success{job=~"blackbox_.*"} == 0` (for 2m, critical) in `network.yaml:5` **auto-covers** `blackbox_b2` — no new alert strictly required. Optionally downgrade B2's severity with a dedicated rule (B2 being briefly unreachable is not a same-night emergency since backups retry with `Persistent=true`), but the cleaner play is to leave the generic critical and let the *correlation* with `ResticCheckFailed` tell the operator whether it's network or auth. No new ports (rides existing :9115). No `ports.txt` change.

### 4.3 Deploy choreography

- **Part A only:** edit `storage.yaml`, then `sudo nixos-rebuild switch --flake '.#vulcan'`. Prometheus rule reload is hot (no scrape disruption). Verify: `curl -s 127.0.0.1:9090/api/v1/rules | grep ResticMetricsStale` and confirm 0 firing. Rollback: `git revert` the YAML edit + switch.
- **Part B:** the new scrape job means a Prometheus **config reload** (graceful, no data loss) and the blackbox module is read by the blackbox exporter on reload — both happen on `switch`. The blackbox exporter restart is trivial (stateless). Verify: `curl -s 'localhost:9115/probe?module=https_b2_endpoint&target=https://s3.us-west-001.backblazeb2.com/' | grep probe_success` returns `1`, and `probe_success{job="blackbox_b2"}` appears in Prometheus within ~1 min. Rollback: `git revert` + switch; the exporter drops the module cleanly.
- **Sequencing:** ship A and B in one commit; they are independent and non-conflicting. No service-data risk, no `tmpfiles`, no secrets touched.

## 5. Noise & failure-mode analysis

- **`ResticMetricsStale` false-fire on a long collector run.** The collector can take minutes across 9 repos (TimeoutSec=30m). At the 8 h threshold with `for: 10m`, even a worst-case slow run (file age ~6.5 h) stays well below threshold. A single missed boot-window run under `Persistent` is also tolerated. Two consecutive missed 6 h runs (a real dead timer) is the only thing that fires — exactly correct. **Low noise risk.**
- **`max()` masking a single dead repo.** Using `max(restic_last_check_timestamp_seconds)` means all 9 repos share one freshness number — intentional, because they're written in one collector pass. A per-repo `restic_check_success=0` (single repo failing while others succeed) is already covered by `ResticCheckFailed`; this rule only guards the *collector itself*. Correct separation of concerns.
- **B2 probe status-code drift.** The 403 is stable for unauthenticated S3, but Backblaze could change its frontend (e.g. return 400 or a redirect). Mitigated by the permissive `[200, 301, 403]` list. If B2 ever returns a code outside that set, the probe flaps to `probe_success=0` and fires `HostUnreachable` — a *false* critical. Mitigation if observed: widen the list or add `403` only. This is a warning-level annoyance at worst, and it never silences restic coverage (which is independent). **Acceptable; monitor for the first few days.**
- **Probe gives a misleading green.** A credential-free 403 confirms only network + TLS, NOT that *your* buckets are writable or that credentials are valid. This is by design — the probe's value is precisely as the network-vs-auth discriminator paired with `ResticCheckFailed`. Documented in the module comment so no one mistakes it for end-to-end backup health.
- **Silent break of the freshness rule itself.** If `restic_last_check_timestamp_seconds` were ever renamed/removed, `ResticMetricsStale` becomes a dead rule (always-absent → never fires). Low risk (the metric is stable and in-tree), but the `max()` form means `absent()` is deliberately NOT used (a fresh deploy with the collector never-run would otherwise alarm). Same convention as `ResticIntegrityCheckStale`.

## 6. Security considerations

- **No new secret handling.** Part A reads only a derived Unix timestamp (`restic_last_check_timestamp_seconds`) already present in Prometheus — no credential path touched.
- **Part B is explicitly credential-free.** The blackbox probe sends an *unauthenticated* GET; it never carries `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `RESTIC_PASSWORD`. The response (403 AccessDenied) contains no secret and is not logged in full — blackbox only records `probe_success`, `probe_http_status_code`, `probe_duration_seconds`, and TLS expiry. This satisfies the brief's "a collector reading a token file must emit only derived metrics" constraint by simply never reading any token.
- **No change to `/run/secrets`, `aws-keys`, or `restic-password` ownership/permissions.** The existing collector's `source /run/secrets/aws-keys` / `cat /run/secrets/restic-password` plumbing is untouched and was already correct (root-owned, root-run oneshot).
- **No private topology, no PII.** B2 region endpoint (`s3.us-west-001.backblazeb2.com`) and bucket-name *prefix* (`jwiegley-*`) are already in plaintext in `backups.nix` and the collector script; the probe target adds nothing new. No internal IPs.
- **TLS validation against the PUBLIC bundle.** The B2 probe uses the system CA bundle (B2's cert is public), NOT the step-ca root — using `https_2xx_local` here would falsely fail. A genuine TLS/cert problem on the B2 path correctly trips `probe_success=0`.

## 7. Effort & sequencing

- **Effort:** S. Part A ≈ 30 min (one YAML rule + verify). Part B ≈ +45 min (one blackbox module + one scrape job + live `/probe` verification). Total 0.5–1.5 h including a build/switch and post-deploy verification.
- **Prerequisites:** none. Blackbox exporter (:9115), the `restic-metrics` collector, and the `HostUnreachable` backstop all already exist and are healthy. No SOPS edits, no new ports.
- **Unblocks / relationship to other deferred items:** independent of the rest of the worklist. Complements the existing backup last-success triads (`local-backup`, `technitium`, `node-red`) by giving the *offsite* (B2) path the same collector-freshness guarantee those daily backups already enjoy. Closes the "B2 has no freshness-of-monitoring guard" hole noted implicitly when `Public` was added on 2026-06-09.
- **What to RETIRE:** Option C (a standalone authenticated B2 credential/reachability canary). Document in the coverage plan that authenticated B2 reachability + credential validity is covered by `restic-metrics` (6 h) → `ResticCheckFailed`, so no separate authenticated probe is warranted.

## 8. Decisions required from the operator

- **Scope:** ship Part A alone (closes the real gap, zero new surface) or A+B (adds the credential-free network-vs-auth discriminator)? Recommendation: **A+B** — B is ~45 min on existing plumbing and is the only thing that adds a signal restic-metrics structurally cannot.
- **B2 app-key TTL:** confirm the B2 application key was created **without** `validDurationInSeconds` (the default → never expires). If a TTL *was* set, request a small expiry-timestamp collector spec (out of scope here); if not, formally treat key-expiry tracking as a **non-gap** and RETIRE it.
- **B2 probe severity:** keep the generic critical `HostUnreachable` for `blackbox_b2`, or add a dedicated warning-level rule (B2 retries with `Persistent=true`, so a brief outage is not a same-night emergency)? Recommendation: **keep generic critical** and rely on correlation with `ResticCheckFailed` for diagnosis.


---


<a id="discord-ws-parity"></a>

# Discord WS Liveness Signal Parity (OpenClaw ↔ Hermes)

**Verdict:** IMPLEMENT_MODIFIED · **Effort:** S — 2-3h (debounce + noise hardening of existing canary; no upstream patch). The "true heartbeat-ACK port" alternative would be L (8-12h, brittle) and is NOT recommended.

**Key live evidence:** OpenClaw gateway is upstream Node.js/TS: ExecStart=${openclawPkg}/bin/openclaw gateway run ... ; openclawPkg = inputs.llm-agents.packages.${system}.openclaw (openclaw-microvm.nix:65). No Python/discord.py process exists — the Hermes sitecustomize KeepAliveHandler.ack() monkey-patch (hermes-vm.nix:281-305) has no target. · Hermes heartbeat signal is rock-solid over 7d: hermes_discord_heartbeat_present changes=0, avg=1.0; hermes_discord_heartbeat_age_seconds max=41.4s, p99=40.7s across 40,293 samples — exactly the discord.py ~41s ACK cadence. · OpenClaw log-derived signal is noisy over 7d: openclaw_discord_ws_connected changes=68, avg=0.9966, min=0 (it DOES drop to 0). The ALERTS series OpenClawDiscordWsDown shows 33 firing-state transitions / 34 samples in 7d. · OpenClaw has NO periodic positive heartbeat log line: of 329 total [heartbeat] lines (span 2026-03-16 → now), 329/329 are '[heartbeat] started' (subsystem startup), not per-ACK stamps. Positive WS events (WebSocket connection opened / logged in / client initialized) are edge-only: openclaw_discord_ws_last_ready_age_seconds is currently 65,346s (~18h) while the WS is actually UP — proving a Hermes-style staleness threshold on the existing positive-event signal would chronically false-fire. · OpenClawDiscordWsDown routes to restart_microvm in the self-heal daemon (daemon.py:135), gated by for:3m + 600s VM-uptime warmup (openclaw.yaml:127-149) + a probe_clear() re-read of openclaw_discord_ws_connected==1 (daemon.py:284-286). So each false positive risks a full VM restart, currently caught only by these three guards.

## 1. TL;DR

The coverage census flagged a "signal-parity" gap between the two Discord-bearing agents: **Hermes** detects a dead gateway with a true per-ACK heartbeat stamp (`hermes_discord_heartbeat_age_seconds`, written by an in-VM `discord.py` monkey-patch on every `KeepAliveHandler.ack()`), while **OpenClaw** infers connectivity by log-scraping the *relative order* of positive vs negative WebSocket events (`openclaw_discord_ws_connected`). The brief asks to port the Hermes heartbeat-ACK approach to OpenClaw.

Investigation shows the Hermes signal is genuinely superior (7d: **0 state changes, avg present=1.0, age p99 40.7s** — the textbook every-41s discord.py cadence) and the OpenClaw signal is genuinely noisy (7d: **68 metric flips, 33 alert firings, drops to 0**), and that noise is *expensive* because `OpenClawDiscordWsDown` drives `restart_microvm`. **But the port as specified is impossible**: OpenClaw is an upstream **Node.js/TypeScript** package from `inputs.llm-agents` — there is no `discord.py` to patch, and its gateway log emits **no periodic positive heartbeat-ACK line** (the only `[heartbeat]` lines are 329× `[heartbeat] started` startup banners). 

**Recommendation: RETIRE the "parity" framing** (the two runtimes cannot share a mechanism) and instead **harden the existing log-derived signal in place** — debounce the alert and tighten the noisy edge-cases — a Small (~2-3h) change with no upstream patching and no VM-restart cost. A true heartbeat-ACK port would require patching upstream OpenClaw TS source (Large, brittle across the frequent version bumps) and is explicitly *not* recommended.

## 2. Current state & evidence

**Hermes (the "good" signal — Python/discord.py):**
- `hermes-vm.nix:253-306` injects a `sitecustomize.py` shim that wraps `discord.gateway.KeepAliveHandler.ack()` to atomically stamp `time.time()` into `/var/lib/hermes/.hermes/logs/discord_ws_heartbeat` on every gateway HEARTBEAT_ACK.
- `hermes-health-check.nix:256-273` reads that stamp's age and emits `hermes_discord_heartbeat_age_seconds` (+ `_present`), taking `min()` with a gateway.log fallback.
- Alert `HermesDiscordZombieSuspected` (`hermes.yaml:107`): `hermes_discord_last_event_age_seconds > 600` for 10m.
- **Live 7d behavior (measured):** `hermes_discord_heartbeat_present` changes=**0**, avg=**1.0**; `hermes_discord_heartbeat_age_seconds` max=**41.4s**, p99=**40.7s** over **40,293** samples. This is a flat, traffic-independent liveness line that only climbs when ACKs *actually* stop. It is the case the brief correctly identifies as the one that catches a "zombie WS that is connected but deaf."

**OpenClaw (the "noisy" signal — Node.js/TS):**
- `openclaw-canary.nix:97-127, 254-282` parses `gateway-vm.log`/`.err.log` tails for positive events (`client initialized…`, `logged in to discord as`, `WebSocket connection opened`) vs negative events (`websocket closed`, `gateway error`, `reconnect scheduled (close|zombie)`, `was not ready`, `channel exited`, `health-monitor restart`). `openclaw_discord_ws_connected = 1` iff the freshest positive event is newer than the freshest negative event, OR the last negative is older than a 60s reconnect-grace window.
- Alert `OpenClawDiscordWsDown` (`openclaw.yaml:127-149`): `== 0 and ignoring(__name__)(time()-vm_active_enter)>600` for 3m → **routes to `restart_microvm`** (`daemon.py:135`), with a `probe_clear()` re-read guard (`daemon.py:284-286`).
- **Live 7d behavior (measured):** `openclaw_discord_ws_connected` changes=**68**, avg=**0.9966**, min=**0**. The `OpenClawDiscordWsDown` ALERTS series shows **33** firing-state transitions / 34 samples in 7d. The signal works (up 99.66% of the time) but flaps at every reconnect.

**Why the Hermes mechanism cannot be ported (the killing evidence):**
1. **No discord.py.** `openclaw gateway run` is `${openclawPkg}/bin/openclaw` where `openclawPkg = inputs.llm-agents.packages.${system}.openclaw` (`openclaw-microvm.nix:65`), a Node.js binary (`NODE_ENV=production`, `nodejs_22` in PATH, `MemoryDenyWriteExecute=false` for V8 JIT). There is no Python interpreter in the gateway process and thus no `KeepAliveHandler.ack` to wrap via `sitecustomize.py`. The Hermes shim has *no target* here.
2. **No periodic positive heartbeat log line.** Of **329** `[heartbeat]` lines in the live gateway log (span 2026-03-16 → 2026-06-10), **329/329** are `[heartbeat] started` — subsystem-startup announcements, one per (re)connect, *not* per-ACK stamps. There is no every-41s positive event to scrape.
3. **The existing positive-event signal is edge-only, not periodic.** `openclaw_discord_ws_last_ready_age_seconds` is currently **65,346s (~18h)** while the WS is demonstrably UP (`openclaw_discord_ws_connected == 1`). A Hermes-style "`age > 600` ⇒ down" threshold applied to OpenClaw's positive-event age would false-fire continuously, because OpenClaw only logs a positive event on a *new* connection, never on a sustained-healthy one.

Net: the brief's hypothesis ("port heartbeat-ACK, preserve `_ws_connected` for continuity, add `_last_heartbeat_ack_seconds`") rests on a per-ACK source signal that **does not exist** on the OpenClaw side and cannot be created without upstream code changes.

## 3. Design options

**Option A — Port heartbeat-ACK by patching upstream OpenClaw TS (the brief's literal ask). NOT RECOMMENDED.**
OpenClaw uses (almost certainly) a Node Discord library; its gateway keep-alive handler would have to be patched in-process to write a heartbeat stamp. Mechanism would be an `overrideAttrs`/`postFixup` source patch (the only patch surface, `openclaw-microvm.nix:65-78`) injecting a wrapper, plus a new canary metric. Trade-offs: (a) brittle — OpenClaw version-bumps land roughly weekly (`openclaw doctor`/auto-update machinery in `openclaw-vm.nix:788-815`), so a source patch is a permanent maintenance tax and a rebuild-break risk; (b) high effort to even locate the right keep-alive call in a third-party TS bundle; (c) violates the repo's strong preference for leaving `inputs.llm-agents` unpatched. Effort **L (8-12h)**, ongoing breakage. **Reject.**

**Option B — Harden the existing log-derived signal in place + formally retire "parity". RECOMMENDED.**
Accept that the two runtimes are structurally different and that *equivalent reliability*, not *equivalent mechanism*, is the real goal. Keep `openclaw_discord_ws_connected`, add a **debounce** so a single noisy sample cannot trigger a VM restart, and (optionally) add an independent **positive-event-staleness zombie gauge** baselined against the real healthy gap. No upstream patch, no new in-VM agent. Effort **S (2-3h)**. **Recommend.** This directly addresses the *consequence* the parity gap was a proxy for — false `restart_microvm` triggers — which is the only thing that actually costs anything.

**Option C — Do nothing; close the census item as "won't fix / not portable".**
Defensible: the signal is up 99.66% and the alert is already triple-guarded (`for:3m` + 600s warmup + `probe_clear()` re-read), and there is no *evidence in this investigation* that a false restart actually fired (the 33 alert transitions are mostly the normal reconnect flapping that the guards absorb). Trade-off: leaves a known-noisy signal feeding a destructive action, so the next OpenClaw reconnect-storm could still cause an unnecessary restart. Effort **0**. Acceptable fallback if the operator declines B, but B is cheap enough to prefer.

## 4. Recommended implementation (Option B)

### B1 — Debounce the destructive alert (the load-bearing fix)

Edit `/etc/nixos/modules/monitoring/alerts/openclaw.yaml`, alert `OpenClawDiscordWsDown` (currently lines 127-149). Two changes:

- Raise `for: 3m` → `for: 5m`.
- Require the metric to be 0 for the *entire* recent window, not just instantaneously, so a single flap sample cannot satisfy the rule:

```yaml
      - alert: OpenClawDiscordWsDown
        expr: |
          max_over_time(openclaw_discord_ws_connected[5m]) == 0
          and ignoring(__name__) (time() - openclaw_microvm_active_enter_timestamp_seconds) > 600
        for: 5m
```

Rationale / baseline: `max_over_time(...[5m]) == 0` means "no healthy sample in the last 5 minutes" — given the canary runs every 60s (`openclaw-canary.nix:386-395`), that is ≥5 consecutive 0 samples. Combined with `for: 5m` that is ~10 minutes of *sustained* disconnect before a restart, which matches OpenClaw's own observation that a genuine stuck client re-emits negative events every ~15s (`openclaw-canary.nix:124-127`) while a healthy reconnect resolves in <60s. The existing 60s reconnect-grace inside the canary already folds short blips to `1`; `max_over_time` is the belt-and-suspenders against the residual 68-flips-in-7d noise. This change alone removes the false-restart risk that the parity gap was really about — no new metric, no exporter change.

### B2 — Document the divergence at both sources (retire the parity goal in code comments)

- In `openclaw-canary.nix`, near the `DISCORD_READY_RE`/`DISCORD_CLOSED_RE` block (lines 87-128), add a short comment: *"NOTE: this is intentionally NOT the Hermes heartbeat-ACK mechanism. OpenClaw's gateway is upstream Node/TS (inputs.llm-agents) with no discord.py to patch and emits no periodic positive heartbeat line — only edge events. Reliability parity is achieved via the `max_over_time` debounce in OpenClawDiscordWsDown, not a shared signal. See census item discord-ws-parity."*
- Mirror a one-line pointer in `hermes-vm.nix` near the shim (line 276) so a future reader doesn't re-open this as an inconsistency.

No metric-name churn: `openclaw_discord_ws_connected` is preserved exactly (the brief's continuity requirement is satisfied trivially — we are not removing it).

### B3 — OPTIONAL independent zombie gauge (only if operator approves & after baselining)

The one semantic capability Hermes has that OpenClaw lacks is catching a "connected-but-deaf" WS that emits *neither* a close event nor a fresh positive event. OpenClaw's negative-event set already covers the explicit `reconnect scheduled (...zombie)` and `health-monitor restart (reason: disconnected)` lines (`openclaw-canary.nix:113,120`), so much of this is covered. To close the residual gap *without* upstream code:

1. **Baseline first (read-only, do this before writing any threshold).** Measure the real distribution of the gap between consecutive positive events on a healthy WS. Because positive events are edge-only, the "healthy" gap can be hours (we observed ~18h live), so any staleness threshold must be derived from the *95th/99th percentile of observed inter-positive-event gaps over ≥30d*, NOT the Hermes 600s. Without this baseline the gauge is guaranteed to false-fire — this is exactly the baseline-check-before-threshold discipline from the coverage plan.
2. If and only if the baseline yields a stable ceiling, emit a new gauge in `openclaw-canary.nix`'s `write_metrics()`: `openclaw_discord_ws_zombie_suspected` = 1 when `openclaw_discord_ws_connected == 1` AND `discord_ws_last_ready_age > <baselined ceiling>` AND no negative event in the window. Add a **warning-severity** alert (NOT self-heal-eligible — do not wire to `restart_microvm`) so a suspected zombie pages a human rather than auto-restarting on a soft signal.

I recommend deferring B3 pending the baseline; B1 is the high-value piece. No new ports, no `loki.nix` symlinks, no `default.nix` import (the canary module is already imported and the alert file is auto-discovered).

### Deploy choreography

- B1+B2 are pure alert-YAML + comment edits → `sudo nixos-rebuild switch --flake '.#vulcan'`. Prometheus rule-group reload is automatic on switch; **no service restart, no VM restart**. Verify post-switch: `curl -sG http://127.0.0.1:9090/api/v1/rules | grep OpenClawDiscordWsDown` shows the new `for: 5m` and `max_over_time` expr, and `promtool` (run by `nix flake check`) confirms 0 err rules.
- Rollback: revert the YAML hunk and re-switch; instantaneous, no state.
- B3 (if approved) adds two metrics to the canary textfile and one alert; the canary timer picks it up on next 60s tick — no restart needed, the textfile is atomically replaced (`openclaw-canary.nix:219`).

## 5. Noise & failure-mode analysis

- **Current chronic noise (the problem being fixed):** 68 metric flips and 33 alert-state transitions in 7d. The `for:3m` + `probe_clear()` re-read currently absorb most of these, but a reconnect-storm (several closes inside a 3m window) could satisfy the rule and trigger `restart_microvm`. B1's `max_over_time(...[5m])==0 and for:5m` raises the bar to ~10m sustained-down, which the data shows only happens on a real outage (avg=0.9966 ⇒ real down-windows are rare and long, not the brief flaps).
- **B1 over-suppression risk:** raising to ~10m sustained could delay a genuine restart by ~7m vs today. Acceptable: `OpenClawHttpHealthDown` (for:1m) and `OpenClawMicroVMDown` (for:2m) catch hard outages faster on independent signals, and `OpenClawGatewayReadyStale` (1800s) catches wedged boots — the Discord-specific alert was never the primary outage detector.
- **B3 silent-break risk:** the headline failure mode of any staleness gauge on an edge-only signal is a *false* zombie alert when the bot is simply healthy-and-quiet (the exact bug Hermes's 2026-05-28 heartbeat migration fixed for *its* idle case). Mitigation is the mandatory ≥30d baseline before picking the ceiling, and routing B3 to warning/human, never to self-heal.
- **Canary itself breaking:** unchanged — already covered by `OpenClawCanaryStale` and `OpenClawCanaryMetricAbsent` (`openclaw.yaml:52,112`).

## 6. Security considerations

- All edits are alert-YAML and code comments — no secrets touched.
- The investigation read the gateway log only via **count-only** `grep -c` and **structural-token** extraction (bracketed tags, the single verb after `[heartbeat]`, HH:MM timestamps); **no message bodies were printed** — Discord message content, user IDs, and bot tokens never surfaced. Any future canary change (B3) inherits the existing module's secret-safety: it emits only derived numbers (ages, 0/1 gauges, epoch timestamps), never log content, and runs as the `openclaw` user under `ProtectSystem=strict` with the log dir mounted `ReadOnlyPaths` (`openclaw-canary.nix:362-383`).
- Explicitly rejecting Option A also avoids touching the OpenClaw package derivation, which is the safest posture (no risk of leaking the gateway auth token through a patched code path).

## 7. Effort & sequencing

- **B1 (debounce):** S, ~30-45min including switch + rule-reload verification. **This is the whole recommendation in practice.**
- **B2 (comments / retire parity in-code):** S, ~15min, rides B1's switch.
- **B3 (optional zombie gauge):** M, but front-loaded by a ≥30d read-only baselining period before any threshold is chosen — do not implement on a guess. ~2-3h of code once the baseline exists.
- **Prerequisites:** none for B1/B2. B3 needs the 30d gap-distribution measurement.
- **Unblocks:** closes the `discord-ws-parity` census item; removes the last soft signal feeding `restart_microvm`; documents the runtime divergence so it is not re-flagged.

## 8. Decisions required from the operator

- Accept that mechanism-parity is unachievable (Hermes=Python/discord.py vs OpenClaw=upstream Node/TS) and that the goal should be **retired**, replaced by "make the OpenClaw log signal quiet and trustworthy in place." Confirm you do **not** want upstream OpenClaw TS patched (Option A).
- Confirm the debounce thresholds: recommended `for: 5m` + `max_over_time(...[5m])==0` (≈10m sustained-down before a restart). Accept 5m, or keep 3m.
- Optionally approve the independent `openclaw_discord_ws_zombie_suspected` gauge (B3) — but only as warning/human-routed, and only after a ≥30d baseline of the healthy positive-event gap. Approve / defer.


---
