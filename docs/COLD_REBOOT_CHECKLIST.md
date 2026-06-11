# Cold-Reboot Validation Checklist — vulcan

A batch of boot/switch-robustness fixes was deployed 2026-06-08..10. **Almost all
were verified only at `nixos-rebuild switch` time — the generation that carries them
has never cold-booted.** This checklist exists to validate them on the **next clean
cold reboot** (the operator reboots; nothing here reboots or asks you to).

Background and the full reasoning live in
[`BOOT_SWITCH_ROBUSTNESS_AUDIT.md`](./BOOT_SWITCH_ROBUSTNESS_AUDIT.md).

---

## (a) Why this reboot matters — check → originating fix

The validator `scripts/post-reboot-validation.sh` runs the checks below. Each maps to
a fix whose *cold-boot* behavior is still unproven:

| Check | What it asserts | Originating fix (commit) |
|---|---|---|
| 1 | `systemctl --failed` empty | (baseline — all fixes) |
| 2 | `NetworkManager-wait-online` active(exited), `Result=success`, runtime **≤ 65s** | **da1946b** — reverted override to upstream `nm-online -s -q -t 60`. The old `-x` either fast-failed (releasing `network-online.target` early) or burned the full 60s timeout. This is the single check the audit explicitly called out as *unproven on cold boot* (Residual #6, Next-Action 6). |
| 3 | `systemd-networkd-wait-online` is **masked** | **f3706d2** — `systemd.network.wait-online.enable = false`. Kills the self-referential 120s-timeout deadlock (networkd could only count microVM bridges, which gain carrier behind `network-online.target`). |
| 4 | `ip rule` has exactly prio 50 + 51, `asymmetric-routing.service` success, gauge `asymmetric_routing_rules_present == 1` | The oneshot is now **fail-loud** (no `\|\| true`; verifies the rules landed). **5dcb038** told networkd `ManageForeignRoutingPolicyRules=false` / `ManageForeignRoutes=false` so a switch no longer flushes the prio 50/51 rules + `end0_return` routes. The audit's out-of-scope finding 7(a) was "rules absent post-boot" — this check proves they land **at boot**, not just after an `end0` dispatcher event. |
| 5 | `cloudflared-tunnel-data` active, not `start-limit-hit`, `NRestarts` small | **2c15db1** — added `After=technitium-dns-server.service` + `StartLimitIntervalSec=0`. Pre-fix, cloudflared hit its burst cap ~8s before Technitium answered `:53` and gave up **permanently** (~9.5 min dead public tunnel on the audit boot; would be indefinite with no human present). |
| 6 | Technitium active **and** a live `dig vulcan.lan @127.0.0.1` resolves | **2c15db1** — `ExecStartPost` `:53` readiness probe + `Before`/`WantedBy=nss-lookup.target`. Converts the previously *false* `After=nss-lookup.target` DNS gate into a truthful one. |
| 7 | `tank` pool listed + `zpool status -x` healthy; key mounts present | (ZFS soft-fail import — confirmed solid; sanity gate so checks 8–11 aren't misread). |
| 8 | `immich-server` active (or condition-skip vs crash distinguished) | **2c15db1** — added `ConditionPathIsMountPoint=/tank/Photos/Immich` so a late tank mount makes it **skip** instead of crash-looping into a permanent give-up. |
| 9 | No failed `restic-*` units; `restic-check.timer` did **not** trigger at boot | **2c15db1 / 213d0ea (finding A)** — de-herded restic-check + 8 backups from `tank.mount` (weekly-timer-only now) and added `forget --retry-lock`. Pre-fix: guaranteed exit-11 + page on every reboot (boot-herd live-lock; `restic unlock` could not clear a *live* lock). |
| 10 | microVMs `openclaw` + `hermes` active; uptime gauges present | **347f3da** — OpenClaw self-heal got a VM-uptime warmup gate so a cold boot no longer triggers a wasteful mid-cold-start VM restart (Residual #5/#6). |
| 11 | Monitoring stack active; Prometheus rules `health=err == 0`; Loki ruler ≥ 10 groups; **Watchdog firing** | **213d0ea (findings D/E/F)** + the broader dead-metric / coverage sweeps. `health=err == 0` proves no rule references a non-existent metric (the `systemd_unit_state` → `node_systemd_unit_state` class of bug). Watchdog **firing is good** — its *absence* means the alert pipeline died. |
| 12 | Prometheus targets: ≤ 3 down | Coverage sweep added many exporters/probes; a clean boot should bring them all up. |
| 13 | PostgreSQL active; `shared_preload_libraries` includes `pg_stat_statements` | Validates the PG config persisted across the restart. |
| 14 | node-red / nagios / home-assistant active | (baseline app health.) |
| 15 | All 9 monitoring exporter timers active | **213d0ea / Phase 3–4 coverage** — confirms the timer fleet armed at boot. |
| 16 | Boot timing (`systemd-analyze time` + `blame`) | Informational only — not a gate. |

> The check numbers above are the *logical groups* from the script's design (a–p in the
> spec); the live script prints 22 numbered lines because a few groups (ZFS pool vs
> mounts, monitoring services vs rules vs Loki vs Watchdog vs targets) are split into
> separate PASS/FAIL lines for clarity.

---

## (b) Pre-reboot steps (minimal)

1. **Working tree clean.** Confirm there is no uncommitted WIP that a reboot-then-debug
   cycle could lose:
   ```bash
   git -C /etc/nixos status        # expect: "nothing to commit, working tree clean"
   ```
   Commit or stash anything outstanding first.

2. **Record the running kernel / generation** so you can confirm the reboot actually
   landed the intended generation (and to compare if something regresses):
   ```bash
   readlink /run/current-system
   ```
   Note the printed `…-nixos-system-vulcan-<version>` path.

That is all. Do **not** kick off a `zpool scrub`, extra backups, or any other heavy
pre-reboot work — keep the pre-state quiet so the post-boot timing is representative.

---

## (c) Run the validator after boot

After the machine comes back up, run (read-only; safe; prints no secrets):

```bash
sudo bash /etc/nixos/scripts/post-reboot-validation.sh
```

**Expected output:** a numbered list of `PASS` lines, a final summary, and exit 0.

```
 SUMMARY: PASS=21  WARN=0  FAIL=0  INFO=1  (of 22 checks)
```

- **Exit 0** ⇒ no FAILs. The harness only fails the exit code on a real FAIL.
- **WARN** is expected only inside the **first ~15 min** of boot for slow starters
  (microVMs warm ~10 min; Loki ruler / targets may still be loading). Re-run after
  ~15 min and the WARNs should clear to PASS.
- On a long-running system (uptime > 24h) the boot-proximity timing checks
  (NM-wait-online runtime delta, restic-not-at-boot) print as **advisory INFO**, since
  monotonic boot timestamps no longer reflect a fresh boot.
- A **FAIL** means a fix did not hold on cold boot — read the one-line detail; the
  check→fix table above points at the responsible commit and file.

The first **genuine cold-boot** run is the one that matters: it is the first time
checks 2 (NM-wait-online `-s -q` timing), 4 (oneshot lands rules at boot), 5
(cloudflared survives the DNS race), and 6 (Technitium gate is real) are tested under
the conditions they were written for.

---

## (d) Follow-up after a clean cold reboot

**If — and only if — check 4 PASSes on a real cold boot** (prio 50 + 51 present,
`asymmetric-routing.service` success, gauge == 1), the dead NetworkManager
`ensureProfiles` routing-rule keys can be deleted. They are documented as kept *only*
until a cold reboot proves the fail-loud oneshot lands the rules at boot
(see `modules/core/networking.nix` comment block, lines ~112–119, and
`BOOT_SWITCH_ROBUSTNESS_AUDIT.md` "asymmetric-routing, Phase B").

In `modules/core/networking.nix`, inside the `end0-wired` profile's `ipv4 = { … }`
block, **delete these two lines** (NetworkManager never materializes them into the
kernel — verified 2026-06-09; the only live prio 50/51 rules are `proto unspec`, added
by the oneshot, never `proto static` as NM would tag its own):

```nix
        # Force all traffic from 192.168.1.2 destined for 192.168.x.x back via
        # the wired gateway (192.168.1.1) so asymmetric replies use correct source IP
        "routing-rule1" = "priority 50 from 192.168.1.2/32 to 192.168.0.0/16 table 200";
        # Same fix for container network range (10.x.x.x)
        "routing-rule2" = "priority 51 from 192.168.1.2/32 to 10.0.0.0/8 table 200";
```

(i.e. remove the `routing-rule1` / `routing-rule2` keys and their preceding comments;
keep `method`, `route-metric`, and the rest of the profile intact.) Then update the
comment block above the profile so it no longer says the keys are "kept FOR NOW", and
`nixos-rebuild switch`. The oneshot + the NM dispatcher (`re-apply-asymmetric-routing`)
remain the sole authoritative writers — removing the dead keys is purely tidying.

---

## (e) Known-acceptable post-boot alerts

These are **expected** and not a sign of a failed boot:

- **Watchdog** — always firing **by design**. Its presence proves the
  Alertmanager → notification pipeline is alive; its *absence* is the failure
  (check 11/17 asserts it is firing).
- **HermesApiServerDown** — Hermes can take **~10–15 min** of microVM warmup before its
  API server answers (cold-start of the model server). Benign within that window; the
  self-heal daemon is uptime-gated (`hermes_vm_uptime_seconds > 600`) and will not
  counter-productively restart it mid-init. If it persists well past ~15 min, treat as
  real.
- **OpenClawHttpHealthDown / DiscordWsDown** — similarly warmup-gated
  (`> 600s` active-enter clause, commit 347f3da); transient during the first ~10 min.
- **rclone per-remote**, **StockTraderSchwabDataSourceDown** — independently noisy
  (expired Google OAuth on disabled remotes; Schwab off-hours / 7-day token cycle).
  Not boot-related; out of scope for this checklist.

If any *other* alert is firing after the system has been up 15+ min, run the validator,
note which check FAILs, and use the check→fix table to localize the regression.
