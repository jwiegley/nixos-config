# Reboot Resilience — Consolidated Record & Recovery Runbook

**What this is:** the single authoritative account of every change that makes
vulcan survive a cold reboot cleanly, why each was needed, and how to recover if
any of it regresses. Written 2026-06-10 after the first fully-clean cold-boot
validation (21 PASS / 0 WARN / 0 FAIL). If you ever see a problem after a
reboot, **start here**.

**First action after any reboot (or any suspected boot problem):**

```bash
sudo bash /etc/nixos/scripts/post-reboot-validation.sh
```

That script (22 checks) is the executable form of this document. It exits 0 when
healthy. Each numbered check below corresponds to a check in the script and
tells you what to do if it FAILs.

**Companion docs (read for depth):**
- `docs/BOOT_SWITCH_ROBUSTNESS_AUDIT.md` — the original 13-dimension audit that
  found most of these issues (2026-06-08/09).
- `docs/COLD_REBOOT_CHECKLIST.md` — the pre/post-reboot operator checklist.
- Memory: `project_vulcan_wait_online_rca`, `project_boot_switch_robustness_audit`,
  `project_alert_dead_metric_remediation`, `project_tank_uas_enclosure_failure`.

> **Commit references** are given by their **subject line** (stable — find with
> `git log --grep='<phrase>'`) plus the hash *as of 2026-06-10*. Hashes may shift
> if history is rebased; the subject line is the durable key.

---

## 1. The validated end-state (2026-06-10 cold boot)

| Metric | Value |
|---|---|
| Validation result | 21 PASS / 0 WARN / 0 FAIL / 1 INFO |
| `systemctl --failed` | 0 |
| Time to `multi-user.target` | 3 min 24 s |
| NetworkManager-wait-online runtime | 5 s (was: full 60 s timeout) |
| Prometheus rules / errors | 536 / 0 |
| Prometheus targets down | 0 / 145 |
| Asymmetric routing rules at boot | 2/2 (prio 50, 51), gauge=1 |
| Nagios services *(stack removed 2026-08-19 — historical row, nothing replaces it)* | 826 (incl. 480 Prometheus-rule mirrors) |

The 15-minute figure from `systemd-analyze time` is **not** boot latency — it is
background oneshots (`restic-metrics` ~9.5 min of real B2 network round-trips,
`technitium-dns-server` ~2.5 min) that run *after* `multi-user.target` and gate
nothing. Confirmed via `systemd-analyze critical-chain` (multi-user @ 3 min 24 s).

---

## 2. The fixes, by subsystem

Each entry: **symptom → root cause → fix (file · commit subject) → verify/recover.**

### 2.1 `network-online.target` never settled — 180 s burned every boot

- **Symptom:** boot hung ~120 s on `systemd-networkd-wait-online` + ~60 s on
  `NetworkManager-wait-online`; both ultimately failed.
- **Root cause (two independent bugs, 11-agent RCA 2026-06-02):**
  1. networkd-wait-online `--any` counts only networkd-*managed* links. On vulcan
     the real uplinks (`end0`, `wlp1s0f0`) are **NetworkManager-owned and
     networkd-unmanaged**; the only links networkd can see are the microVM
     bridges/taps, which gain carrier only *after* their VMs boot — and the VMs
     are ordered *behind* `network-online.target`. Self-referential deadlock →
     full 120 s timeout.
  2. The NM-wait-online override used `nm-online -x`, which means "exit if NM is
     not running/connecting" — it fast-failed at boot (rc=1 in ~62 ms while NM
     was still `connecting`), releasing `network-online.target` before the
     network was actually up, and logging a failure every boot.
- **Fix:**
  - `systemd.network.wait-online.enable = false;` — masks the networkd half
    (`modules/core/networking.nix` · *"disable systemd-networkd-wait-online"* ·
    `deef5be`). NM is the sole correct owner of `network-online.target` here.
  - Revert NM-wait-online to upstream `nm-online -s -q -t 60` (`-s` = wait for
    NM **startup-complete**; returns in ~5 s at boot, ~13 ms on switch)
    (`modules/core/networking.nix` · *"fix NetworkManager-wait-online (-x -> -s
    -q)"* · `f6a20cb`).
- **Verify (checks 2 & 3):** `NetworkManager-wait-online` active/exited, runtime
  ≤ 65 s; `systemd-networkd-wait-online` LoadState=masked.
- **Recover if regressed:** if boot hangs on a wait-online unit, check
  `systemctl status systemd-networkd-wait-online` is `masked` and the NM unit's
  `ExecStart` is `nm-online -s -q -t 60` (`systemctl cat NetworkManager-wait-online`).
  The leading empty `ExecStart=` in the override is required (replace, not append).
  Only `cloudflared-tunnel-data` hard-`Requires=` the target; everything else is
  a soft `Wants=`, so a wait-online failure degrades gracefully.

### 2.2 Asymmetric source-policy routing rules vanished

- **Symptom:** `AsymmetricRoutingRulesMissing` fired; cross-subnet replies
  (clients on 192.168.3.x reaching 192.168.1.2) left via the wrong interface
  with the wrong source IP. Happened both at boot (rules never landed) and after
  every `nixos-rebuild switch` (rules landed then got flushed).
- **Root cause (two separate bugs):**
  1. **At boot:** the `asymmetric-routing` oneshot greenwashed failures with
     `|| true`, reporting `active (exited)` with no rules in the kernel. Also, NM
     `ipv4.routing-rule1/2` keys were declared but **NM never materializes them**
     (verified: only `proto unspec` oneshot rules were ever live, never NM's
     `proto static`).
  2. **On switch:** systemd-networkd reconfigures the VM bridges on every switch,
     and with the systemd defaults `ManageForeignRoutingPolicyRules=yes` /
     `ManageForeignRoutes=yes` it **deletes every rule/route it did not create** —
     including the oneshot's prio 50/51 rules and the `end0_return`-table routes.
- **Fix:**
  - Make the oneshot **fail-loud** (drop `|| true`, verify each rule landed, exit
    1 otherwise) (`modules/core/networking.nix` · audit finding F · `31512a2`).
  - `systemd.network.config.networkConfig.ManageForeignRoutingPolicyRules = false;`
    + `ManageForeignRoutes = false;` so networkd leaves the oneshot/NM/podman
    rules alone while still managing its own bridges (`modules/core/networking.nix`
    · *"stop networkd flushing the asymmetric-routing rules on switch"* ·
    `3e1dce5`). **Proven** by surviving a `networkctl reconfigure vm-openclaw`.
  - The oneshot is the **single authoritative writer**, re-run by the NM
    dispatcher on every `end0` up/dhcp event.
  - **Phase B (2026-06-10, after cold-boot confirmation):** removed the dead NM
    `routing-rule1/2` keys entirely (`modules/core/networking.nix` · *"remove dead
    NM routing-rule keys (Phase B)"* · `c9c1c5c`).
- **Verify (check 4):** `ip rule show | grep -cE '^(50|51):'` == 2;
  `asymmetric-routing.service` active/success; gauge
  `asymmetric_routing_rules_present` == 1.
- **Recover if regressed:** `sudo systemctl restart asymmetric-routing.service`
  re-lands the rules immediately. If they vanish again *on a switch*, confirm
  `grep ManageForeign /etc/systemd/networkd.conf` shows both `=false`. If they're
  missing *at boot*, read `journalctl -u asymmetric-routing` — a fail-loud exit 1
  will name the prefix that didn't land.

### 2.3 cloudflared gave up permanently (~9.5 min into boot)

- **Symptom:** `cloudflared-tunnel-data` hit its systemd start-limit and stopped
  retrying — the public tunnel stayed down until manual intervention.
- **Root cause:** it started before DNS was ready, failed fast a few times, and
  tripped `StartLimitBurst`. With a finite limit, systemd stopped restarting it.
- **Fix:** `After=technitium-dns-server.service` (don't start before DNS) +
  `StartLimitIntervalSec=0` (retry forever — it self-reconnects)
  (`modules/services/cloudflare-tunnels.nix` · audit fix · `30e5d5c`).
- **Verify (check 5):** `cloudflared-tunnel-data` active/running, `NRestarts`
  small, `StartLimitIntervalUSec=0`.
- **Recover:** `sudo systemctl restart cloudflared-tunnel-data`; check it isn't
  ordered before a now-broken DNS unit.

### 2.4 Technitium DNS was a false "ready" gate

- **Symptom:** units depending on local DNS started before Technitium could
  actually resolve, causing cascading early-boot failures (incl. 2.3).
- **Fix:** `ExecStartPost` dig-probe so the unit isn't "started" until it
  actually answers, plus `Before=`/`WantedBy=nss-lookup.target`
  (`modules/services/dns.nix` · `30e5d5c`).
- **Verify (check 6):** service active **and** `dig +short vulcan.lan @127.0.0.1`
  returns an answer.
- **Recover:** `systemctl status technitium-dns-server`; if the ExecStartPost
  probe is failing, DNS isn't actually serving — check its own logs.

### 2.5 ZFS `tank` late-mount races (immich crash-loop, tank-bind races)

- **Symptom:** `tank` (the OWC USB enclosure pool) imports late; services that
  need `/tank/...` crash-looped permanently or bind-mounted over empty dirs.
- **Root cause:** services started before `zfs-mount.service` completed; immich
  in particular crash-looped instead of waiting.
- **Fix:**
  - immich: `ConditionPathIsMountPoint=/tank/Photos/Immich` +
    `wantedBy = tank-Photos-Immich.mount` — it waits for the mount instead of
    crash-looping (`30e5d5c`).
  - tank binds: order after `zfs-mount.service` + a `tank-binds-ensure` oneshot
    boot safety-net (*"bindTank: order tank binds after zfs-mount.service"*
    `d707818`, *"tank-binds-ensure oneshot"* `b919cd0`).
  - **Hardware mitigation:** the enclosure is forced off UAS
    (`usb-storage.quirks=...:u`) to stop the bridge hangs that make the pool go
    MISSING under heavy I/O (*"force OWC tank enclosure off UAS"* `6dbda35`).
    See memory `project_tank_uas_enclosure_failure` for the full hang signature
    and the physical power-cycle recovery runbook.
- **Verify (checks 7-9):** `zpool status -x` healthy; key mounts present;
  immich-server active with `ConditionResult=yes`.
- **Recover:** if `tank` is MISSING (not just unmounted), it's almost always the
  USB bridge hanging — **physically power-cycle the enclosure**, then
  `sudo zpool import tank`. Do NOT assume disk failure (SMART is clean; it's the
  enclosure). Full runbook in `project_tank_uas_enclosure_failure`.

### 2.6 restic backups herded + boot-triggered + stale locks

- **Symptom:** all restic jobs fired at 02:00 (thundering herd); `restic-check`
  ran at boot competing with the import; stale locks left exit-11 failures every
  reboot.
- **Fix:** stagger jobs off 02:00 (*"stagger restic jobs off the 02:00 thundering
  herd"* `a4ca50f`); `restic-check` is weekly-timer-only, de-herded from
  `tank.mount`; `forget --retry-lock=5m` so a stale lock self-heals instead of
  needing manual `restic unlock` (`30e5d5c` / `31512a2`).
- **Verify (checks 10-11):** no `restic-*` units failed; `restic-check.timer` not
  triggered this boot.
- **Recover:** a one-off stale lock → `restic unlock` on the named repo; but the
  `--retry-lock` should make this unnecessary now.

### 2.7 Dead alert rules (couldn't fire) + monitoring blind spots

- **Symptom:** 123 Prometheus alert rules across 35 files could never fire
  (verified vs live TSDB) — silent monitoring failure.
- **Root cause:** the dominant defect (48 rules) used `systemd_unit_state` instead
  of `node_systemd_unit_state`, plus a `type=` label confusion and unescaped
  regex dots.
- **Fix:** fleet-wide repair (*"repair 80 dead alert rules"* `27a71ea`, *"recover
  dead alerts"* `d4b1ac4`, + the coverage-plan sweeps `dc9056f`/`4a1c1ec`/`66991d8`).
  See memory `project_alert_dead_metric_remediation`.
- **Verify (checks 15-18):** 0 rules with `health=err`; ≥10 Loki ruler groups;
  Watchdog firing (= pipeline alive); ≤3 targets down.
- **Belt-and-suspenders:** `systemd.services.prometheus-rule-audit`
  (`modules/monitoring/services/prometheus-rule-audit.nix`, source
  `scripts/prometheus-rule-audit.py`, hourly timer) re-derives the dead-rule
  check directly: for every alerting rule it extracts the metric names the expr
  selects and asserts each has ≥1 series in the TSDB, then flags stale
  evaluation, `health=err`, and groups whose evaluation exceeds their interval.
  Results land as textfile metrics (`prometheus_rule_audit.prom`). Until
  2026-07-31 this job was done as a side effect of a second, independent
  scheduler — a Nagios mirror that re-evaluated every rule in
  `modules/monitoring/{alerts,loki-rules,vm-alerts}/` and reconciled the two
  stacks; that is what caught this class in the first place. The mirror went on
  2026-07-31 and the rest of Nagios on 2026-08-19; the audit job replaces the
  mirror's headline capability without standing up a second scheduler. Coverage is now total
  rather than exclusion-filtered, but it is a periodic audit, not a live
  cross-check: a rule that goes dead is caught on the next run, not instantly.

### 2.8 OpenClaw self-heal restart storms at boot

- **Symptom:** the self-heal daemon restarted the agent microVMs during their
  normal (slow) boot warm-up, fighting the boot instead of helping.
- **Fix:** VM-uptime warm-up gate (`> 600 s` boot window) on the HTTP/WS health
  alerts + bounded resolved-incident retention (*"bound resolved-incident
  retention + boot-window alert gates"* `7c89c68`).
- **Verify (checks 12-13):** both microVMs active; uptime gauges present. Expect
  Hermes API warm-up noise for ~10-15 min post-boot — that's normal, not a fault
  (memory `project_hermes_apiserver_down_rootcause`).

---

## 3. The validation harness

`scripts/post-reboot-validation.sh` — 22 read-only checks, PASS/WARN/FAIL/INFO +
a summary; exit 0 iff no FAILs. **Boot-window aware:** within 15 min of boot,
slow starters (microVMs, Loki ruler, targets) WARN instead of FAIL; past 24 h
uptime, boot-proximity timing checks (the NM-wait-online runtime delta, "restic
not boot-triggered") downgrade to advisory INFO. Emits only unit/job/metric names
and counts — never secrets or LAN topology.

Run it after every reboot. If anything FAILs, find the matching subsystem in §2.

---

## 4. Pre-reboot ritual (also in COLD_REBOOT_CHECKLIST.md)

```bash
cd /etc/nixos
git status --short                       # must be clean (commit/stash WIP)
readlink /run/current-system | tee /var/tmp/pre-reboot-generation.txt
# optional baseline for after:
{ echo "failed=$(systemctl --failed --no-legend | wc -l)"; \
  echo "rules50_51=$(ip rule show | grep -cE '^(50|51):')"; } \
  | tee /var/tmp/pre-reboot-baseline.txt
```

Then reboot. On return: `sudo bash scripts/post-reboot-validation.sh`.

**Rollback:** every fix is a NixOS generation. If a reboot is worse than before,
`sudo nixos-rebuild switch --rollback` (or pick the prior generation in the boot
menu) restores the last-good state; `/var/tmp/pre-reboot-generation.txt` records
which store path that was.

---

## 5. If a NEW boot problem appears (continue-the-work playbook)

1. Run the validation script; note which check FAILs and read its §2 entry.
2. If it's a **new** failure mode not covered here:
   - `systemd-analyze critical-chain` — is the slow/failed unit actually on the
     critical path, or just `blame` noise (like restic-metrics)?
   - `journalctl -b -u <unit>` for the failing unit; `systemctl --failed`.
   - For network ordering: was it started before `network-online.target` /
     `nss-lookup.target` / `zfs-mount.service` / a `*.mount` it depends on?
   - For "rules/routes vanished on switch": suspect networkd foreign-management
     again (§2.2) — anything added outside networkd that networkd might flush.
3. Apply the fix as a NixOS module change, `nixos-rebuild build` first, then add a
   corresponding check to `scripts/post-reboot-validation.sh` so the new failure
   mode is caught next time.
4. Record it: append the symptom/cause/fix to §2 here, and update the relevant
   memory file.

---

## 6. Commit ledger (subjects are the durable keys)

Boot/switch resilience, roughly chronological (hashes as of 2026-06-10):

- `deef5be` networking: disable systemd-networkd-wait-online; add temp NM boot probe
- `f6a20cb` networking: fix NetworkManager-wait-online (-x -> -s -q); drop boot probe
- `30e5d5c` boot robustness: fix cold-reboot DNS race, immich late-mount, restic herd
- `31512a2` boot/switch robustness: audit findings A, B, D, E, F
- `7c89c68` openclaw-self-heal: bound resolved-incident retention + boot-window alert gates
- `d707818` / `b1b69ca` / `b919cd0` bindTank ordering + tank-binds-ensure safety-net
- `6dbda35` zfs: force OWC tank enclosure off UAS to stop bridge hangs
- `a4ca50f` backups: stagger restic jobs off the 02:00 thundering herd
- `3e1dce5` networking: stop networkd flushing the asymmetric-routing rules on switch
- `198e1c9` docs+scripts: cold-reboot validation harness
- `c9c1c5c` networking: remove dead NM routing-rule keys (Phase B, cold-boot confirmed)

Full audit context: `docs/BOOT_SWITCH_ROBUSTNESS_AUDIT.md`.
