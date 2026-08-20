# Finalized Decisions — vulcan remediation plan

**Date:** 2026-07-28 · Companion to `REMEDIATION_PLAN.md` (supersedes its §8 and §9).
All 18 open decisions and all 10 scope-creep items resolved with the operator.

---

## Part 1 — The 18 decisions

| # | Decision | Resolution | Notes / plan impact |
|---|---|---|---|
| D1 | Discord bot token in history | **CLOSED — not the operator's app.** Verified absent from their Discord account. | Nothing to rotate. The fixture redaction (`182ae2cb`) is the complete fix. Discord's public API could not adjudicate this — `/applications/{id}/rpc` returns "Unknown Application" even for MEE6 and Dyno, so that endpoint is gated and proved nothing. |
| D2 | Restore the Gitea→GitHub mirror | **Rewrite history with `git filter-repo`.** Reaffirmed after cost review. | Operator confirms the repo is solely theirs with one clone on Hera, which they will force-pull. Force-push to **both** Gitea and GitHub authorized. Cost accepted: **675 of 1,975 commits** rewritten, **146 commit-SHA references** dangling (55 in tracked docs/`modules/`/`CLAUDE.md`, 91 in the memory dir). Cheaper options (GitHub unblock-secret URLs, orphan branch) were offered and declined. |
| D3 | Schwab OAuth (expired 34d) | **Retire the Schwab source entirely; rely on alpha_vantage.** | Removes the ~weekly manual re-auth chore permanently. **Dissolves scope-creep A-94** — deleting the source deletes the lying gauge, so the upstream app defect stops mattering. Also removes the need for the A-U1 token-expiry alert. |
| D4 | UPS battery (3.96 yr, never tested) | **Run one self-test, then decide on replacement.** | Operator chose this over replace-first. **Sequencing refinement:** land NUT monitoring *before* the test so the battery transfer is instrumented and yields a runtime curve rather than pass/fail. **Reclassification:** `services.prometheus.exporters.nut.enable` is a first-class NixOS option, so UPS monitoring is **fixableNow, not scope-creep** as the plan assumed. |
| D5 | LiteLLM 55 GB spend-log bloat | **DONE.** Prompt bodies scrubbed, all rows kept. | See Part 3. Committed `72ffe46a`. Pre-scrub table retained until 2026-07-29 per operator caution, then drop. |
| D6 | Technitium DNS ratio rules | **Fix the 7 broken expressions AND retune to measured 7-day maxima.** | Thresholds: server_failure >0.05, refused >0.10, nx_domain >0.50, cache-hit floor 0.40. Prevents 2 rules firing immediately on normal home-LAN traffic. |
| D7 | 739 GiB legacy PG snapshots | **No action — let the 12-monthly ladder expire them.** | Declined both the plan's advice (destroy two) and the stronger privacy argument (these four hold Feb–May 2026 prompt bodies). Nothing irreversible. Pool at 70%, and D5 removed the growth driver, so there is no capacity pressure. |
| D8 | Off-site B2 for 3 excluded sets | **All three.** TechnitiumDNS (158 MiB) + Machines (307 GB) now; PostgreSQL after the next dump confirms the shrink. | D5 changed the economics: PG set projected ~40 GB → **~8 GB**, so the plan's "33 GB nightly" objection is void. **Machines must be a separate MANUAL daytime upload**, not the 03:30 timer — stacking B2 bandwidth + compression CPU + USB read load is the one action here that could take the pool offline. Watch `journalctl -k` for `uas_eh_abort` / `err -108` and abort if seen. Pre-silence `ResticRepoSizeShrunk` for `repository="Backups"` 14d. |
| D9 | 163 unavailable HA entities | **Fix mail_and_packages AND delete the debris.** | The halves are coupled: 37 known-dead twins are what hide a real 26-entity outage, and a threshold set against today's 163 would encode them as normal. Prerequisite for M-91. |
| D10 | restic bit-rot detection | **`--read-data-subset=2%` weekly — but only after the per-repo loop isolation fix lands.** | With `RuntimeMaxSec=4h` and a 06:30 de-herd. Ordering is load-bearing: today `set -euo pipefail` aborts the whole check on the first failing repo, and adding read-data first raises metrics-collector collision odds from ~2% to 17–50% every Monday. |
| D11 | Stale flake inputs | **Defer both** until the nixpkgs-unstable pin is re-floated (~2026-08-10). | Batches nixos-apple-silicon (222d) + home-manager (66.7d) with the pin re-float. Accepts running 222-day-old kernel/GPU/firmware/m1n1 support meanwhile. Validate with `scripts/post-reboot-validation.sh`. |
| D12 | 17 abandoned logind sessions | **Periodic guarded sweep, log-only for the first cycle.** | Log-only proves the age guard never selects an in-progress builder — `nix-daemon --stdio` is the daemon side of a LIVE connection and a `closing` session can still be serving a build. Explicitly NOT `killUserProcesses`. |
| D13 | info-severity paging policy | **Promote 4, digest the other 17.** | Keeps HostUnexpectedReboot + ContainerCVEScanFailed + ContainerCVEDBStale as notifications: a scanner that stops scanning is a coverage failure (the vacuous-check class), and on this host only the operator reboots. |
| D14 | stray `litellm.public` DB | **Drop it now.** | Empty, zero tables, zero references in `/etc/nixos`. It is mirrored nightly forever and would skew the completeness check's baseline. |
| D15 | `notebook.vulcan.lan` broken TLS | **Drop the `serverAlias`.** | Resolved by exploration, not asked: the name appears only as the alias itself (`jupyterlab.nix:320`) plus one blackbox comment. Nothing references it. Removing a name that cannot work beats adding machinery to keep it working. |
| D16 | NVMe + SMART self-tests | **Both, as ONE collector.** Add `nvme0n1` to smartctl_exporter and enable smartd self-tests. | Critical caveat: the exporter emits **no `self_test` series at all**, so a failed self-test would reach only smartd's unmonitored mail. smartd's notification must be wired into the alerting plane or the self-tests are decorative. |
| D17 | 82 retained generations | **Leave as-is.** | Disk is not scarce (482 GB free) and rollback depth is worth more — especially with a 222-day platform bump deferred to ~August. |
| D18 | Discord round-trip canaries | **Enable both directions.** | Plan's premise was **wrong**: it advised deletion because "no probe was ever declared" and "requires a new Discord bot token". Both probes are fully scaffolded at `hosts/vulcan/default.nix:235` with `enable = false`, and both token sources already point at existing SOPS secrets. **Only a shared channel ID is missing.** |

## Part 2 — The 10 scope-creep items

### Pursuing (4)

| # | Item | Decision |
|---|---|---|
| A-91 | HA `climate.upstairs` setpoints silently never applied (~11 failures/day, `nest/climate.py:317`) | **Investigate + attempt the VTherm fix, and add HA service-call error detection either way.** Prior art: the 2026-05-28 office-flow fix addressed the same Nest mode confusion. Likely fix is VTherm sending only `temperature` for a single-setpoint device. Timeboxed. |
| A-92 | matter-server: 5 nodes in subscribe/timeout/resubscribe churn (~5,394 CHIP errors/13h) | **Drop the mesh convergence; add a churn-rate alert.** Mesh debugging is unbounded and may end in new hardware. But 5,000+ errors/13h while systemd reports perfect health is the active-but-broken pattern with zero signal. |
| M-91 | HA entity-availability monitoring (no metric exists anywhere) | **Build the exporter** — REST poll → textfile gauge, unavailable-entity counts labelled by integration. This is the detector that would have caught mail_and_packages dark for 17 days with a "loaded" config entry. Unblocked by D9. |
| M-92 | Per-cgroup memory-throttle alerting (PostgreSQL at 99.8% of MemoryHigh, 3.68M throttle events) | **Both** — raise the limits (removes the self-inflicted condition) and build the cgroup textfile exporter (catches future recurrence). |

### Dropped (6)

| # | Item | Why dropped |
|---|---|---|
| A-93 | Reconstruct the 2026-07-23 multi-service incident | **Forensically closed.** copyparty's journal holds 1 line across a 22.6h outage; openclaw's unit journal is empty across a 47-restart storm; openclaw-self-heal has emitted zero lines in its entire life. Forward instrumentation is in the plan. |
| M-93 | Identify the 24.7h wildcard listener | **Unattributable.** port-drift-exporter records a count with no port or process label. Labels added going forward; the past event is unrecoverable. |
| M-94 | Identify the 21.75h Nagios divergence [Nagios removed 2026-08-19] | **Unrecoverable** — the reconciler keeps no divergence detail. **Structural note worth retaining:** the mirror cannot detect the dead-rule class at all (Nagios evaluates the same broken expression, gets no data, lands OK/UNKNOWN, and the script skips UNKNOWN by design), so a green mirror must never be read as "no dead rules". |
| A-94 | Fix the lying `stock_trader_data_source_up` gauge | **Dissolved by D3.** Retiring the source removes the metric. |
| A-95 | copyparty nspawn unit/journal visibility | **Covered externally instead.** Chronic-availability monitoring sees it from outside at 86.5%/7d — which is how the 22.6h outage would have surfaced. An nspawn-aware collector is not worth it. |
| Y-91 | 6 quadlets reporting `UnitFileState=bad` | **Cosmetic + upstream.** No link actually dangles (`find -xtype l` is empty), all 6 run with `Result=success`, and nothing on this host consumes `UnitFileState`. Fix belongs in quadlet-nix. |

## Part 3 — Already executed on 2026-07-28

1. **Discord-token fixtures removed** (`182ae2cb`) — both token-shaped literals replaced with runtime-assembled fixtures; 131 tests pass incl. all 7 redaction tests; repo-wide rescan returns 0 matches; pushed, so the public Gitea HEAD no longer serves it.
2. **Push-mirror detection shipped** (`ed235bbc`) — `gitea-push-mirror-exporter` reads Gitea's recorded per-mirror **outcome** (not the trigger) hourly; 12 mirrors found, `failed_count=1`, the single failing series is `repo="nixos-config"`. `GiteaPushMirrorFailing` + 3 self-monitoring rules, all `health=ok`. **Supersedes plan item M-01** (a Loki rule over nginx 500s), which could not see mirrors that fail without an HTTP error. Measured gotcha recorded in-code: Gitea's `last_update` is the last **attempt**, not the last success — nixos-config reported it fresh while 3 months stale — so a freshness rule there would have been another dead rule.
3. **LiteLLM prompt-body scrub + settings** (`72ffe46a`) — `response` and `proxy_server_request` emptied across all **220,021 rows** (both retained, nothing deleted); live table **57 GB → 701 MB**; `store_prompts_in_spend_logs = false`; retention interval `7d → 6h` because the sweep is uptime-gated and the container restarts nightly, so the 90d policy had never once run. Method: `CREATE TABLE (LIKE … INCLUDING ALL)` + INSERT + rename, chosen over CTAS (drops PK/indexes/defaults) and in-place UPDATE (220k dead TOAST tuples, then VACUUM FULL at ~2× space). One transaction with a row-count assertion; 33.7s because replacing the columns with literals means the 55 GB is never detoasted.
4. **B2 config for `/etc/nixos` reverted** at operator request — the mirror is the intended off-site path. System store path verified byte-identical to the pre-change generation. Snapshot `6b47e352` still contains one copy and ages out under 7-daily retention.

## Part 4 — Actions owed by the operator

1. **Discord channel ID** for the two canary probes (D18) — creates a shared channel, paste the snowflake into both probe definitions, flip `enable = true`.
2. **Hera force-pull** after the D2 history rewrite.
3. **UPS self-test** timing (D4) — after NUT monitoring lands, then decide on the battery.
4. **Confirm the pre-scrub table drop** (2026-07-29) once litellm has run a full day.

## Part 5 — Net effect on the plan

- **Moving in from scope-creep:** A-91 (fix + detection), A-92 (alert only), M-91 (exporter), M-92 (both halves).
- **Reclassified as fixableNow:** UPS/NUT monitoring — `services.prometheus.exporters.nut.enable` exists.
- **Removed:** D7 (no action), A-93/M-93/M-94/A-95/Y-91 dropped, A-94 dissolved, M-01 superseded, Schwab token-alert work removed by retirement, D11's two bumps deferred.
- **Superseded plan text:** §8 (decisions) and §9 (out of scope) are replaced by this document.
