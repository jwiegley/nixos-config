# Boot Slowness RCA — vulcan, 2026-06-24

**Boot:** index 0, started 2026-06-24 15:54:18 PDT (14 days after the prior boot).
**Author:** boot RCA agent. **Method:** `systemd-analyze time|blame|critical-chain`, `journalctl -b 0 -o short-monotonic`, `systemctl cat/show`, adversarial verifier pass. All offsets are userspace-monotonic seconds from kernel handoff unless noted.

---

## 1. Executive summary

**This boot was NOT a regression.** It reproduced vulcan's chronic boot profile, last validated clean on 06-10 (`post-reboot-validation.sh` 21/21 PASS). The "unusually slow" perception is best explained by the 14-day gap since the previous reboot making a familiar-but-rarely-seen pattern feel unfamiliar. A direct numeric comparison to the 06-10 boot is impossible — that boot's startup data has rotated out of the 1.9 G journal (oldest surviving PID-1 entry is 06-21). The comparison rests on the deployed memory record and on steady-state corroboration (the prior-boot warm Technitium restart still took ~103 s).

The complaint splits cleanly into **one real functional problem** and **one cosmetic illusion**, plus two genuinely-fixable churn sources:

- **REAL — DNS dead for ~125 s.** Technitium DNS did not answer on `127.0.0.1:53` until +149.4 s. It is a **native systemd service** (`Type=simple`, `DynamicUser=yes`, `ExecStart` of the `technitium-dns-server` binary), **NOT a podman container** — the shared-context "root podman container" note is stale and was disproven by `systemctl show`. Its ~125 s of silent in-app init (loading ~503 MB of blocklists + indexing a 2.3 GB / ~5,500-file hourly statistics dataset on local NVMe) gates `nss-lookup.target`, correctly holding `cloudflared` and `home-assistant` and explaining the "DNS down for several minutes" complaint.
- **REAL — ordering gap.** `fetchmail-good` orders only `After=network-online.target` (not `After=nss-lookup.target`), so it started ~120 s before DNS was usable and restart-looped 23× on `Name or service not known` until DNS came up, firing `ServiceRestartLooping`. (Verifier narrowed this to `fetchmail-good` only — see §3.)
- **COSMETIC — ~15 min "starting" state.** `multi-user.target` was reached at **2 min 56 s** — the system was usable then. `is-system-running` stayed `starting` until +879 s only because `restic-metrics.service` (timer `OnBootSec=5min`, no downstream consumers) ran ~9.5 min as a long pole in the still-open boot transaction. It blocked nothing functional.

**Top three confirmed root causes:** (1) Technitium ~125 s in-app init; (2) `fetchmail-good` racing a dead resolver due to the `network-online`-vs-`nss-lookup` ordering gap; (3) `restic-metrics` `OnBootSec=5min` holding the cosmetic `starting` state.

Storage was healthy this boot: the `usb-storage.quirks=1e91:a4a7:u` UAS mitigation held, tank imported cleanly (~+20 s), zero `uas_eh_abort`/`err -108`, zero storage-attributed service failures. Both deployed network fixes held: `NetworkManager-wait-online` ran 5.4 s; `systemd-networkd-wait-online` confirmed masked. `systemctl --failed` is currently EMPTY — every failing/looping unit self-healed.

---

## 2. Boot timeline (userspace-monotonic offsets)

| t (s) | event |
|------:|-------|
| 0 | Kernel hands off to userspace (after firmware 1 m 2 s [Asahi/m1n1, outside systemd] + loader 7.3 s + kernel 4.4 s ≈ 74 s pre-userspace). |
| 5.7–12.2 | `systemd-udev-settle` (deprecated, pulled in **only** by `zfs-import-tank`) runs ~6.5 s, blocking import start. |
| 12.2–19.8 | `zfs-import-tank` imports the tank mirror over USB (~7.6 s). |
| ~21–23 | `tank.mount` active (+21.2 s); `zfs-mount` done +23.1 s; `local-fs.target` +23.1 s; all 57 datasets mounted; UAS disabled, 0 abort errors. |
| 24.4 | `technitium-dns-server` process starts; **DNS not yet answering**. ~140 `Starting…` lines fan out at +23–24 s (redis ×10, prometheus, victoriametrics, postgres, dovecot, postfix, microVMs hermes/openclaw, exporters). |
| 25.3 / 29.7 | `NetworkManager-wait-online` finished (5.4 s, healthy); `network-online.target` reached. `networkd-wait-online` masked. **DNS-down window BEGINS.** |
| ~30.3 | `fetchmail-good` starts (`After=network-online.target` only) and fails name resolution (exit 11); begins 5 s-interval restart loop. |
| 32.4 | `asymmetric-routing` oneshot lands policy rules (one transient `signal` retry at +26 s, then success). |
| 52.7 | `postgresql-mailarchiver-optimize` finishes (~22 s; idempotent `CREATE INDEX`, fully masked by HA's later start). |
| 101.5 | `kiwix-url-map-generator` first run finishes (~70 s; ran fully concurrent, masked by HA's later start). |
| 149.4 | Technitium logs `started successfully` after ~125 s of silent .NET init. |
| 149.7 | `ExecStartPost` dig-probe succeeds; `nss-lookup.target` reached — **DNS first usable system-wide. DNS-down window ENDS (~125 s wide).** `cloudflared` and `home-assistant` released from the gate. |
| 150.2 | `home-assistant.service` active; `home-assistant-metric-restorer` starts and executes a hardcoded `sleep 30`. |
| 151.4 | `fetchmail-good` stabilizes active/running after 23 restarts (`NRestarts` frozen at 23). |
| 180.2 | `home-assistant-metric-restorer` finishes (sleep elapses) → **`multi-user.target` reached (2 min 55.9 s). SYSTEM FUNCTIONALLY USABLE.** |
| 300.5 | `restic-metrics.service` fires (`OnBootSec=5min`) and serially probes 9 restic/B2 repos over the USB tank. No downstream consumers. |
| 874.2 | `restic-metrics` finishes (~9.5 min; ~10 m 33 s CPU, 1.8 G peak RAM, 1.5 G read). |
| 879.0 | PID 1 emits `Startup finished` (userspace 14 m 34 s, total 15 m 48 s); `is-system-running` → `running`. The ~15 min `starting` was **cosmetic**. |

---

## 3. Root causes

### Confirmed (verifier `holds=true`)

**RC1 — Technitium ~125 s in-application init gates DNS (the real DNS-down cause).**
Process up +24.4 s, `started successfully` +149.4 s, with the entire interval silent (one interleaved log line; the success banner emits all at once). Verified native systemd service: `Type=simple`, `DynamicUser=yes`, `ExecStart=…/technitium-dns-server $STATE_DIRECTORY`, `Before=nss-lookup.target`, `ExecStartPost=…/technitium-wait-ready` (a real `dig @127.0.0.1 vulcan.lan A` poll loop, 1 s interval, ~200 s cap). `nss-lookup.target` reached +149.7 s; `cloudflared-tunnel-data` and `home-assistant` both started at that exact instant — genuine gating, not coincidence. State lives on `/dev/nvme0n1p5` (ext4 NVMe), not the USB tank; zero kernel I/O errors in the window → CPU/app-bound. Chronic: a warm restart still took ~103 s. **Impact: delays DNS; on the critical chain.**

**RC2 — Ordering gap: `fetchmail-good` races a dead resolver.**
`fetchmail-good` orders `After=network-online.target` (NOT `nss-lookup.target`), `Restart=always`, `RestartUSec=5s`. It started ~120 s before DNS was usable and failed `Name or service not known` (exit 11) 23× from +30.3 s to +146.4 s, stabilizing +151.4 s — ~2 s after DNS came up. The deployed Technitium `nss-lookup` gate is correct but only protects units that *explicitly* order after it; this boot only `cloudflared-tunnel-data` and `home-assistant` do. **Independent of and additive to RC1.** **Impact: causes the user-visible service-failure/`ServiceRestartLooping` churn.**

**RC3 — `restic-metrics` holds the cosmetic `starting` state.**
`restic-metrics.timer`: `OnBootSec=5min`, `OnUnitActiveSec=6h`, `Persistent=true`. Service: `Type=oneshot`, `WantedBy=`/`RequiredBy=` EMPTY → not in the boot dependency graph; `critical-chain` confirms it is NOT in the `multi-user.target` chain (reached +175.9 s). It ran +300.5 s → +874.2 s serially probing 9 repos over the slow USB tank. **It does not delay `multi-user.target` or time-to-usable** — the ~15 min `starting` is purely cosmetic. The earlier "restic de-herded to weekly-timer-only" fix applied to the distinct **restic-CHECK** unit, not restic-METRICS. **Impact: holds `starting`; drives boot-window USB-tank I/O contention and the `BackupNotRunRecently`/`ServiceStuckActivating` churn that keys off `starting`.**

**RC4 (partial) — HA metric-restorer hardcoded `sleep 30` (the one real fixed delay on the multi-user tail).**
`home-assistant-metric-restorer` runs a literal `sleep 30` (`After=home-assistant.service`, `WantedBy`+`Before=multi-user.target`). HA active +150.2 s → restorer finishes +180.247 s = `multi-user.target` `ActiveEnter` (same instant). Removing the blind sleep saves ~30 s of pure fixed delay.

**RC6 — `systemd-udev-settle` adds ~6.5 s to the ZFS import path.**
Deprecated, pulled in **only** by `zfs-import-tank` (`WantedBy=zfs-import-tank.service`, sole consumer). `critical-chain` confirms it blocks import start. Journal carries the deprecation warning naming `zfs-import-tank`. Minor, removable, entirely before `basic.target`; storage caused zero service failures and is NOT a contributor to the DNS/service-failure complaints.

### Refuted / corrected (do NOT chase these)

- **"Technitium is a root podman container."** FALSE. `systemctl show` proves a native `DynamicUser` systemd service. The podman piece is the separate `technitium-dns-exporter` (metrics only). Do not "fix" container cold-start or image pre-loading for the resolver.
- **RC2 over-scoped to 4 units.** REFUTED for three of them. `gitea-runner-org-builder` had `Restart=no`, `NRestarts=0`, `After=` empty, and **zero** "no such host" failures this boot — the claimed "5× / lookup gitea.vulcan.lan" is not in boot 0. `matter-server` (`NRestarts=0`) failed on mDNS/CHIP discovery timeouts (CHIP 0x32), not name resolution — `nss-lookup` gating would not help it. `rspamd` orders `After=network.target` (not `network-online.target`), `NRestarts=0`, only 2 transient self-recovered DNS misses. **Apply the ordering fix to `fetchmail-good`; audit the rest, don't presume the set.**
- **"kiwix and postgresql-mailarchiver-optimize inflate the 2 min 56 s multi-user figure."** REFUTED for this boot. kiwix's first run (+31.5 → +101.5 s) and mailarchiver-optimize (+30.7 → +52.7 s) both finished long before HA even started (+149.7 s) and were fully masked — they added ~0 s to time-to-multi-user. They are worth de-gating for hygiene/robustness, **not** for the multi-user number. The bulk of the 2 min 56 s is HA not starting until +149.7 s (gated by its `After=` postgresql/network-online/nss-lookup) — i.e. RC1/RC2 territory.
- **"Thundering herd inflated Technitium 103 → 125 s; CPU/IO priority claws back ~20 s."** REFUTED. During Technitium's init window only ~1–2 of 10 cores were busy (kiwix run #1 ≈ 1 core); the big CPU hogs (`restic-metrics`, kiwix runs 2–7) all started at +300 s, *after* Technitium finished. Zero I/O pressure (no UAS/hung_task/PSI). The prior boot had a comparable herd yet Technitium took only 103 s. The 21 s delta is unattributed, plausibly data-dependent zone/blocklist/cache-load variance. **Setting `CPUWeight`/`IOWeight`/`Nice` targets a bottleneck that did not exist in that window — deprioritize it.**
- **"kiwix was I/O-starved to ~21 min by a restic read storm."** REFUTED. kiwix fired **7 separate times** this boot; each run is CPU-bound (CPU ≈ wall). `restic-metrics` read only ~1.5 G over 574 s (~2.6 MB/s) — not a "read storm." The "21.6 min" conflates 7 timer firings with one stalled run.
- **"restic-metrics is literally the last job; `Startup finished` waits ~5 s on it."** Mechanism corrected (root cause unaffected). The genuinely last job was `container-health-exporter.service` (finished +879.004 s; `Startup finished` +879.020 s, 16 ms later). While restic ran, short periodic timer oneshots (`container-health-exporter` every 120 s, `nut-low-battery-poweroff` every 30 s, 60 s textfile exporters) kept getting swept into the still-open transaction. **Consequence for the fix: removing restic's `OnBootSec` collapses the long window but leaves a few-second tail from these other periodic oneshots — `Startup finished` will NOT snap exactly to multi-user time.**

---

## 4. Prioritized fix plan

### P0 — close the ordering gap (kills the failure/alert storm)
- **Change:** Add `After=nss-lookup.target` (and `Wants=nss-lookup.target`) to `fetchmail-good`. Then audit every other `After=network-online.target`-only unit that actually performs name resolution and apply the same; prefer a small shared NixOS overlay so future units are DNS-correct by construction. Do **not** blindly add it to gitea-runner/matter/rspamd — verifier showed they did not fail on DNS this boot.
- **file_hint:** `/etc/nixos/modules/services/*fetchmail*.nix`; optionally a new `/etc/nixos/modules/dns-readiness-ordering.nix`. Mirror the existing `nss-lookup` gating on home-assistant.
- **Risk:** low. **Expected effect:** eliminates the 23-restart loop and the `ServiceRestartLooping`/`CriticalServiceDown` churn; no effect on DNS-ready time itself.
- **Verify (cold reboot):** `systemctl show fetchmail-good -p After` lists `nss-lookup.target`; `systemctl show fetchmail-good -p NRestarts` = 0 (was 23); `journalctl -b 0 -u fetchmail-good | grep -c "Name or service not known"` = 0; `post-reboot-validation.sh` stays 21/21.

### P0 — take `restic-metrics` off boot timing (collapses cosmetic 15 min → ~3 min)
- **Change:** In `restic-metrics.timer`, drop `OnBootSec=5min` (rely on `OnUnitActiveSec=6h` / add an `OnCalendar`) **or** raise `OnBootSec` to ~30 min; add `RandomizedDelaySec`. No downstream consumers → nothing functional changes, only when the first sample is taken.
- **file_hint:** `/etc/nixos/modules/monitoring/services/restic-metrics.nix`.
- **Risk:** low. **Expected effect:** `is-system-running` reaches `running` shortly after `multi-user.target`; removes the `BackupNotRunRecently`/`ServiceStuckActivating` churn that keys off `starting`; reduces early-boot USB-tank I/O contention. Caveat: a few-second tail from `container-health-exporter`/`nut-low-battery-poweroff`/textfile exporters remains.
- **Verify (cold reboot):** `systemd-analyze time` userspace drops from ~14 m 34 s toward ~3–5 min; `is-system-running` reaches `running` within minutes of `multi-user.target` (compare PID-1 `Startup finished` vs multi-user timestamp in `journalctl -b 0`).

### P1 — shrink Technitium startup (shrinks the ~125 s DNS-down window for ALL consumers)
- **Change:** Lower Technitium stats retention (Max Stats Days) from ~223/365 to 30–90 days and consider disabling/shortening per-query logging — the 2.3 GB stats + 503 MB blocklists are what the silent init reads; cutting ~3–7× should cut init roughly proportionally. Optionally add a bounded maintenance timer that prunes **only** `*.stat` under `stats/` (never `zones/` or `*.config`). Investigate whether Technitium 14.x can serve `:53` while stats/blocklists load asynchronously.
- **file_hint:** Technitium state at `/var/lib/private/technitium-dns-server` (`dns.config`/`log.config`), via the Technitium web console or declarative options in `/etc/nixos/modules/services/dns.nix` (retention not currently set there).
- **Risk:** low (loses only old dashboard history; DNS function unaffected). **Expected effect:** init from ~125 s toward ~20–40 s; smaller DNS-down window.
- **Verify (cold reboot):** `journalctl -b 0 -u technitium-dns-server` delta between `Starting` and `started successfully` materially smaller; `systemd-analyze critical-chain nss-lookup.target` well under 149 s; `du -sh` of `stats/` confirms reduced retention.
- **Note:** Keep the `ExecStartPost` dig-probe as-is — it is correct and not the bottleneck. Do NOT shorten it; that would let `nss-lookup.target` activate before `:53` actually answers and re-introduce the cloudflared crash-loop the gate prevents.

### P1 — replace HA metric-restorer's hardcoded `sleep 30`
- **Change:** Replace `sleep 30` with a bounded readiness poll (curl/`ss` against HA's port, capped ~30 s) **or** drop its `WantedBy=multi-user.target` so it no longer gates the target. It is the literal +180.2 s gating edge.
- **file_hint:** `/etc/nixos/modules/services/home-assistant-metric-trick.nix` (the metric-restorer ExecStart script).
- **Risk:** low. **Expected effect:** removes up to ~30 s from time-to-multi-user; the route-metric restore still applies.
- **Verify (cold reboot):** `journalctl -b 0 -u home-assistant-metric-restorer` finishes well before +180 s; `systemd-analyze critical-chain multi-user.target` no longer shows it as the +180 s gate.

### P2 — boot hygiene (no measurable time-to-usable win this boot, but robustness)
- **Change:** Remove `Before=multi-user.target` from `kiwix-url-map-generator` (let it run async after nginx, which already seeds an empty map); guard `postgresql-mailarchiver-optimize` `CREATE INDEX` with `IF NOT EXISTS` so it is a sub-second no-op after first boot; raise `zfs-pool-health-metrics` `OnUnitActiveSec` from 2 min toward 5–15 min with `RandomizedDelaySec` to stop ~8 re-fires per boot.
- **file_hint:** `/etc/nixos/modules/services/zimit.nix`; `/etc/nixos/modules/services/databases.nix`; `/etc/nixos/modules/monitoring/services/zfs-pool-health-exporter.nix`.
- **Risk:** medium. **Expected effect:** cuts boot-window I/O contention and `activating/restarting` churn from frequent timer re-fires. **Do not** expect this to move the 2 min 56 s number — these units were masked this boot.

### P2 — drop the deprecated `systemd-udev-settle` from `zfs-import-tank`
- **Change:** Override `zfs-import-tank` to not pull in `systemd-udev-settle` (disks are addressed by `wwn-*` by-id, so settle is unnecessary), removing ~6.5 s.
- **file_hint:** a `systemd.services."zfs-import-tank"` override in `/etc/nixos` (the unit is auto-generated by the nixpkgs zfs module).
- **Risk:** medium — the USB enclosure is slow to enumerate (~6–11 s) and import could race ahead of disk attach. **MUST be cold-boot validated.**
- **Verify (cold reboot):** `systemd-analyze blame | grep udev-settle` gone/near-zero; `zfs-import-tank` starts ~6 s earlier; **CRITICAL** — `zpool status tank` ONLINE with all 4 disks and `post-reboot-validation.sh` stays 21/21.

### Explicitly NOT recommended
- Do not set `CPUWeight`/`IOWeight`/`Nice` on Technitium to "claw back ~20 s" — refuted (no contention in its window).
- Do not treat Technitium as a podman container or pre-load an image — refuted.
- Do not keep the `usb-storage.quirks=1e91:a4a7:u` change out of `boot.kernelParams` — it held and prevented the UAS hang. Leave it.

---

## 5. Functional impact vs cosmetic `starting` state

| Symptom | Classification | Mechanism |
|---|---|---|
| DNS unresolvable for ~125 s | **REAL functional** | Technitium ~125 s in-app init gates `nss-lookup.target` (RC1). |
| `fetchmail-good` 23 restarts, `ServiceRestartLooping` | **REAL functional** (self-healed) | Started before DNS ready due to ordering gap (RC2); stabilized +151 s. |
| `is-system-running` "starting" ~15 min | **COSMETIC** | `restic-metrics` long pole holds the boot transaction open (RC3); `multi-user.target` reached at 2 min 56 s — system usable then. |
| `BackupNotRunRecently` ×9, `ServiceStuckActivating` ×3 | **COSMETIC churn** | Monitoring keys off the prolonged `starting`/late textfile writes; resolves when restic-metrics is de-herded. |
| `gitea-runner-org-builder`, `matter-server`, `rspamd` errors | Transient, self-healed | NOT DNS-ordering failures this boot (see §3 refutations); matter = mDNS/CHIP, rspamd = 2 transient misses. |
| Storage (UAS tank) | Healthy, no impact | Quirk mitigation held; clean import; 0 abort errors; 0 storage-attributed service failures. |

---

## 6. Open questions to confirm on next (cold) reboot

1. **Does the 06-10 baseline still hold?** Capture `systemd-analyze time` and `systemd-analyze critical-chain nss-lookup.target multi-user.target` to establish a fresh, in-journal baseline (the 06-10 transaction has rotated out).
2. **Is the 21 s Technitium init variance reproducible?** With P1 stats-retention trimming, does init land near the ~20–40 s target, and is the boot-to-boot spread stable?
3. **After P0/P1, does `Startup finished` track `multi-user.target`?** Confirm the residual tail is only the short periodic oneshots (`container-health-exporter`, `nut-low-battery-poweroff`, textfile exporters), not a new long pole.
4. **Audit completeness for the ordering fix:** enumerate units that both `After=network-online.target` only AND perform name resolution; confirm none other than `fetchmail-good` actually fails at boot before adding gates broadly.
5. **udev-settle removal safety:** on the very first cold boot after the change, does the USB enclosure enumerate all 4 disks before import? Watch for any import race.
