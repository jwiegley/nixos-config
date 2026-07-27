# Boot / Switch Service-Robustness Audit — vulcan

> **Status (2026-07-27): historical. Every residual finding below has since been fixed.**
> The audit's "nothing was applied" / "apply nothing" framing was true on 2026-06-08 only.
> Verified in the tree today: #1/#2 DNS race — `modules/services/dns.nix:19-28`
> (`before`/`wantedBy = nss-lookup.target` + an `ExecStartPost` readiness probe) and
> `modules/services/cloudflare-tunnels.nix:66,99` (`after = technitium-dns-server.service`,
> `StartLimitIntervalSec = 0`); #3 immich — `ConditionPathIsMountPoint` +
> `wantedBy = tank-Photos-Immich.mount` at `modules/services/immich.nix:82,89,98,101,155`;
> #4/#8 restic boot herd — `restic-check` is timer-only, with the reasoning kept at
> `modules/storage/backups.nix:252,279-283,338`; #5/#6 OpenClaw self-heal —
> the `>600` VM-uptime gate is live at `modules/monitoring/alerts/openclaw.yaml:150,183,224`;
> #7 `pg_isready` — replaced by a bounded retry loop at
> `modules/lib/mkQuadletService.nix:288-293`; and both out-of-scope defects in item 7 of
> "Recommended Next Actions" are closed (`SystemdServiceFailed` now uses
> `node_systemd_unit_state`, `modules/monitoring/alerts/systemd.yaml:7`; the
> asymmetric-routing rules are exported as a gauge, `asymmetric_routing.prom`).
> A clean cold reboot validated the result on 2026-06-10. **The consolidated,
> maintained document is now [REBOOT_RESILIENCE.md](REBOOT_RESILIENCE.md)** —
> read that for current behaviour; this file is kept for the reasoning and the evidence.
>
> Note also that `backups.nix` has moved to `modules/storage/backups.nix` and the
> self-heal `daemon.py` referenced below is `scripts/openclaw-self-heal/daemon.py`;
> line numbers cited throughout are as-of 2026-06-08 and will not all still match.

_Generated 2026-06-08 by a multi-agent read-only audit (13 dimensions, 58 agents; 10 findings confirmed after adversarially refuting 29). Findings are recommendations only — nothing was applied._

# Vulcan Service Robustness Audit — Reboot & Large `nixos-rebuild switch`

**Scope:** Read-only audit of production NixOS host `vulcan` (aarch64/Asahi). Question: *Have we fully and completely resolved all issues with service robustness/stability after a reboot or a large `nixos-rebuild switch`?*

**Live state at audit:** `systemctl --failed` empty; `is-system-running` = `running`; booted 13:32:05, a switch landed 13:43:40 (so this boot's evidence mixes a cold boot with a mid-boot switch — accounted for throughout).

---

## Verdict

**No — not fully resolved. Mostly stable in steady state, but a clean cold reboot still has real, reproducible gaps.**

The recent fixes hardened **link/carrier** readiness (networkd-wait-online masking, NM-wait-online flag change). But the cold-boot fragility has **migrated to two places those fixes don't touch**:

1. **Local DNS readiness.** The system resolver is Technitium on `127.0.0.1:53` (resolved has `DNSStubListener=no`). Technitium is `Type=simple` and answers `:53` only ~117s into boot, yet nothing orders it `Before=nss-lookup.target`. So `After=nss-lookup.target` is a *false* DNS-ready gate. cloudflared trusts it, crash-loops on `connection refused`, hits `StartLimitBurst=10` (~108s) about **8s before** Technitium is ready, and then **gives up permanently**. This boot the public `data.newartisans.com` tunnel was dead ~9.5 min and recovered only by coincidence (the unrelated 13:43 switch restarted it). On a clean cold reboot with no human present it stays down indefinitely.

2. **Late/absent ZFS mount handling.** `immich-server` has no `ConditionPathIsMountPoint` guard (unlike `aria2`), and `RequiresMountsFor` is a no-op against the runtime ZFS mount unit. When tank is imported late, immich crash-loops, exhausts its StartLimit, and stays down with no auto-recovery.

Add the recurring **restic exit-11 at every reboot** (a boot herd, not a stale lock — the operator's manual `restic unlock` does *not* prevent recurrence), and the **OpenClaw self-heal gating asymmetry** (one wasteful self-recovering VM restart per cold boot / model-changing switch), and the honest answer is *mostly resolved, with a clear ranked tail of work.*

None of the residual issues cause data loss. The worst (cloudflared, immich) leave a service permanently down until manual intervention.

---

## What's Solid (including the recent fixes)

| Area | Status | Note |
|---|---|---|
| **systemd-networkd-wait-online deadlock** | RESOLVED | Masked (networking.nix:154); the self-referential cycle (only networkd-managed links were microVM bridges/taps gated behind network-online.target) is now structurally impossible. networkd half of the RCA verified live. |
| **NM-wait-online flag change** | PARTIAL — see residual | Live ExecStart is `nm-online -s -q -t 60` (networking.nix:175), but the only successful run observed (13:43:48) was during the mid-boot switch with NM already connected. This generation has **never cold-booted**; `-s` may fast-fail like the old `-x`. The premature `network-online.target` is a secondary correctness issue, not the cloudflared outage cause. |
| **hermes-agent aarch64 pin** | RESOLVED (workaround) | Pinned to pre-refactor rev c47b9d12 (flake.nix, commit e313bca); microvm@hermes active, NRestarts=0. Unpin when upstream makes npmDepsHash arch-independent. |
| **restic stale-lock (reboot-interrupted)** | NOT the recurring failure | The documented stale-lock that `restic unlock` fixes is distinct from the **boot-herd live-lock** that recurs every reboot (see residual). |
| **No boot-time ordering cycle** | CONFIRMED | network-online.target has no microvm/dnat/tap/bridge edges; VMs are After=network.target; dnat is Before=microvm@* / soft-Wants network-online.target. systemd-analyze verify clean. |
| **ZFS tank import (soft-fail)** | CONFIRMED | Stock 60×1s poolReady retry; fails soft (tank.mount RequiredBy/WantedBy empty, binds carry nofail, tank-binds-ensure mountpoint-q-guarded). UAS-disable quirk live. *USB enclosure remains a SPOF with manual-only recovery — inherent.* |
| **Bind-mount ordering** | CONFIRMED | ea0c800 + 177866a live; the poisonous auto-generated tank-<dataset>.mount Requires is gone; prior 5afc85a boot failure fixed. |
| **tmpfiles destructive directives** | CLEAN | Zero D/R/r against persistent data; all D-class lines target transient paths. 2025-11 data-loss vectors do not recur. |
| **switch-restart semantics** | CONFIRMED | zimit/local-backup/mbsync correctly restartIfChanged=false; a switch won't kill the 30-day crawl or backups. |
| **Kernel/initrd in 13:43 switch** | CONFIRMED | Byte-identical booted-vs-current; only /etc delta was the NM-wait-online change + temp probe removal (da1946b). nm-boot-state-capture cleanly gone. |
| **Hermes self-heal at boot** | CONFIRMED CORRECT | Zero actions taken; ApiServerDown gated on `hermes_vm_uptime_seconds>600`; E2eChatFailing correctly not in ACTION_MAP. This is the safe pattern OpenClaw lacks. |

---

## Residual Risks (ranked)

| # | Issue | Sev | Trigger | Mechanism (proof) | Concrete fix (file refs) |
|---|---|---|---|---|---|
| 1 | **cloudflared dies permanently on cold reboot (DNS ~8s late)** | medium | reboot | `network-online.target` RequiredBy = cloudflared only. cloudflared After=nss-lookup.target,network-online.target; RestartSec=10, burst=10, interval=300 → cap trips ~108s. Technitium (Type=simple, **not** Before=nss-lookup.target) logs "started successfully" at 13:34:20; cloudflared hit StartLimit 13:34:12, then NO restart until the 13:43:48 switch. ~9.5min dead window would be permanent on a pure reboot. | (A) dns.nix: ExecStartPost probe blocking on `:53`, `before`/`wantedBy=nss-lookup.target`. (B) cloudflare-tunnels.nix:66,70-71: `after=technitium-dns-server.service` + StartLimitIntervalSec=0 or RestartSec~30/interval>=900. |
| 2 | **nss-lookup.target false DNS-readiness** | medium | reboot | nss-lookup orders only After=nscd+resolved (up in 1st sec). DNSStubListener=no (networking.nix:75) + nameservers=[127.0.0.1] (networking.nix:24) → Technitium answers :53, but is unordered vs the target. Structural amplifier behind #1; latent trap for any future After=nss-lookup consumer. | Same as #1(A): order technitium Before=nss-lookup.target + real readiness probe in dns.nix. Verify `systemctl show nss-lookup.target -p After` lists technitium. |
| 3 | **immich-server crash-loops & gives up on late tank mount** | medium | reboot | immich.nix:74-92 has only after=[zfs.target, tank-Photos-Immich.mount] + RequiresMountsFor (no-op: the .mount is a runtime unit from /proc/self/mountinfo, FragmentPath empty, RequiredBy empty). No ConditionPathIsMountPoint (vs aria2.nix:85). On boot -4: immich-server Started 02:19:10 → exit1 (`.immich` ENOENT) → restart 1..30 → "Start request repeated too quickly" 02:22:30 → nothing until manual `reset-failed`+`start` 11:01:27. aria2 cleanly SKIPPED. | immich.nix: add `unitConfig.ConditionPathIsMountPoint` to immich-server (74-82), immich-machine-learning (84-92), immich-fix-permissions (138-141). For TRUE auto-recovery also add a systemd.paths watcher or zfs-mount-driven pull (Condition alone only makes it SKIP, not re-trigger). |
| 4 | **restic exit-11 every cold boot (boot herd live-lock)** | medium | both | tank.mount pulls 9 restic-backups-* (backups.nix:237) + restic-check.service (:259) + restic-check.timer Persistent=yes (:277) simultaneously. restic-check holds exclusive locks (resticOperations.nix:30,32,34 --retry-lock=1h). Backup units' `forget --prune` + pre-start `cat config` carry NO retry-lock (extraBackupArgs reaches only the backup subcommand, backups.nix:44) → "waiting up to 0s" → exit 11. Reproduced boots 0/-1/-2/-3. Manual `restic unlock` can't clear a LIVE lock. | backups.nix: remove `wantedBy=[tank.mount]` from restic-check.service (:259) and from restic-check.timer (:277-278); optionally also from per-service (:237). Persistent=yes still catches up. Secondary: thread --retry-lock onto forget/unlock (custom ExecStart). |
| 5 | **models.nix/VM-closure change cold-boots BOTH microVMs on switch** | medium | both | restartTriggers=[toJSON models] (openclaw-microvm.nix:760, hermes-microvm.nix:402-404); restartIfChanged=true+stopIfChanged=true → hard ExecStop(microvm-shutdown)+ExecStart(microvm-run) re-arming ~8-10min warmup. Trigger leads with the VM toplevel store path → fires on ANY guest-closure change. Downstream harm (ungated self-heal alert during warmup) ALSO fires on plain reboot. | (1) Add OpenClaw uptime gate (see #6). (2) Optionally narrow restartTrigger to the VM-consumed model subset. Don't change restart-on-real-model-change (correct by design). |
| 6 | **OpenClaw self-heal restarts VM mid-cold-start (no uptime gate)** | low | both | daemon.py:96-97 maps OpenClawHttpHealthDown (openclaw.yaml:150, for:1m) + DiscordWsDown (:130, for:3m) → restart_microvm; deterministic n==1, vm_ts used only for dedup (daemon.py:306). Only GatewayReadyStale gates (>1800, :74-75). Hermes fixed this (hermes.yaml:49, `hermes_vm_uptime_seconds>600`). This boot: restart_microvm at 13:34:54 vs VM active 13:32:27. Single redundant ~8s restart, self-recovered (NRestarts=0). | openclaw.yaml:149-150/129-130: add `and ignoring(__name__) (time()-openclaw_microvm_active_enter_timestamp_seconds)>600`. Gauge already exported (openclaw-canary.nix:205-207). Keep for:1m/3m. |
| 7 | **pg_isready ExecStartPre no-op at cold boot** | low | reboot | mkQuadletService.nix:280-282 + litellm.nix:99 use `pg_isready -t N` (per-attempt connect timeout, not retry); returns exit2 in 0.002s on a refused loopback port. Cross-namespace After=postgresql.service drops for user units. Boot 0: 8 quadlets probed 13:32:24.5, PG ready 13:32:27.5 → each exactly 1 first-failure, recovered ~10s via Restart=always. | Replace ExecStartPre with a bounded retry loop (TimeoutStartSec=900 headroom). Secondary: common.nix StartLimitBurst 5→10. Masked today; latent give-up risk on a slow-PG cold boot. |
| 8 | **forget/unlock steps lack --retry-lock (residual race)** | low | both | Same root as #4; benign in isolation but any lingering lock makes forget fail exit-11 instantly. | Subsumed by #4's herd removal; optional --retry-lock on forget/unlock for defense-in-depth. Cannot cause data loss. |

---

## Recommended Next Actions (ordered)

1. **Fix the DNS cold-boot race (covers #1 and #2 together).** In `modules/services/dns.nix`, make Technitium readiness real and ordered: `ExecStartPost` that blocks until `127.0.0.1:53` answers, plus `before=[\"nss-lookup.target\"]` + `wantedBy=[\"nss-lookup.target\"]`. This converts `After=nss-lookup.target` into a truthful gate for cloudflared and every future consumer. Pair with widening cloudflared's restart budget (`cloudflare-tunnels.nix:66,70-71`) so it can't permanently give up.
2. **Break the restic boot herd (#4, also resolves #8).** Remove `wantedBy=[\"tank.mount\"]` from `restic-check.service` (backups.nix:259) and the timer (:277-278). Lowest-risk change that eliminates the guaranteed exit-11 + page on every reboot. Persistent=yes still catches up missed runs.
3. **Guard immich against late tank mounts (#3).** Add `ConditionPathIsMountPoint` to the two immich services + fix-permissions (immich.nix:74-92, 138-141), mirroring aria2. For true auto-recovery, additionally add a `systemd.paths` watcher or have zfs-mount pull immich.
4. **Add the OpenClaw VM-uptime gate (#5, #6).** Amend `openclaw.yaml:149-150` and `:129-130` with the `>600` active-enter clause (zero exporter work). Closes the only path that restarts a healthy-but-warming VM and bounds the model-change blast radius.
5. **Replace pg_isready single-shot with a retry loop (#7)** in `mkQuadletService.nix:280-282` + `litellm.nix:99`; bump `common.nix` StartLimitBurst as cheap insurance.
6. **Validate empirically on the next clean cold reboot:** capture `journalctl -u NetworkManager-wait-online -b -o short-precise` + `systemctl show NetworkManager-wait-online -p ExecStart` to settle whether the new `-s -q -t 60` generation fast-fails like the old `-x` (currently unproven — this generation has never cold-booted).
7. **Track the two out-of-scope defects surfaced during refutation:** (a) asymmetric-routing's priority 50/51 `ip rule`s are absent ~7h post-boot (live asymmetric misrouting to WiFi); (b) the `SystemdServiceFailed` alert references a non-existent metric (`systemd_unit_state` vs `node_systemd_unit_state`) and can never fire — silently disabling generic service-failure paging fleet-wide.

**Apply nothing from this audit — these are recommendations for the operator.**
(Superseded: the operator applied all of them between 2026-06-08 and 2026-06-10 —
see the status note at the top of this file.)
