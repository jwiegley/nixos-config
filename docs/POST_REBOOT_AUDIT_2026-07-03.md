# Post-Reboot Health Audit — 2026-07-03

74-agent workflow audit (run `wf_3c9ffea1-d08`) after the 11:37 reboot: 24h of
journals across all 435 system units + 17 user managers, kernel, both microVMs,
all firing alerts, every nginx vhost probed, deep-dives on the two observed
console stack-trace storms, and adversarial verification of all 45 warn/crit
findings. 467 sources came back clean.

## Verdict

**The system is fully back up and healthy.** `is-system-running=running`,
0 failed units, all pools healthy, 21/21 post-reboot validation checks,
145/145 Prometheus targets up, both microVMs green, every vhost serving.
Remaining alert noise is (a) self-clearing backup-age gauges, (b) two
physically-dead LAN devices, (c) the known Schwab token expiry.

## The actual timeline (corrected — there were TWO outages)

| When (2026-07-03) | Event |
|---|---|
| 05:00 | Utility power outage; UPS on battery (upsmon logged it) |
| 05:23:51 | **Designed NUT low-battery poweroff** (charge 48% < 50% threshold). Not a crash. Host down ~5.5h |
| 10:58:29 | Power restored; **boot -1** — the *troubled* boot |
| 10:58–11:36 | Error storm: 184k err-lines in 38 min (see root causes below); openclaw health never recovered; self-heal restarted the VM 3× futilely (host-side fault) |
| 11:36:16 | Orderly `systemd-reboot` (the user-initiated "hard reboot" went through cleanly) |
| 11:37:36 | **boot 0** — came up healthy end to end |

## Root causes of the console stack-trace storms (both on boot -1, both gone)

### speedtest-tracker — pg_hba reject loop (~372k journal lines)
The lingering rootless user manager launched the quadlet **14 s after kernel
start**, before NetworkManager had assigned the LAN IPv4. Podman therefore
picked the first non-loopback host address — the **microVM bridge IP
10.99.0.1** — as `host.containers.internal` and froze it into the container's
/etc/hosts. Laravel connected to PostgreSQL as 10.99.0.1, which matches no
pg_hba rule (10.99.0.0/30 is scoped to org/openclaw) and fell through to the
reject catch-all: 3,772 rejects, an ~85-line traceback every 1.3 s for 36
minutes. systemd never intervened because the container process never exited.
**The same race also hit memory_vault (74 rejects), shlink (20), openproject
(12), litellm (5) — the fix must be host-wide.**

Durable fix (not yet applied): pin
`host_containers_internal_ip = "192.168.3.16"` via
`virtualisation.containers.containersConf.settings.containers`, or gate
rootless quadlets behind a wait-for-LAN-IPv4 ExecStartPre.

### litellm — upstream hera backends down (~47k lines)
Not a vulcan fault: hera.lan:8000/8443 (Qwen backends) refused connections
during the outage window; litellm logs ~263 lines of chained traceback per
failed request (~178 requests). Ended 12:05; container healthy since.
Optional: router `allowed_fails`/cooldown to quiet future hera outages.

## Fixed during the audit (verified)

1. **drafts-mcp.service restarted** — boot-time DNS race had killed its ssh
   child (`hera.lan` unresolvable at 11:38:25); ssh child confirmed alive,
   DraftsMcpBridgeDown + DraftsMcpAskFailing alerts cleared.
2. **syncthing write access to /tank/Public restored** — ACL mask had been
   clobbered to r-x; `setfacl -m m::rwx`, write-verified. (Recurring
   mask-clobberer suspected in copyparty startup — see backlog.)
3. **11 frozen Nagios SSL CRITs force-rechecked** — 24h-interval checks had
   frozen pre-reboot state (the known deploy-race/freeze class).
4. **openspeedtest user manager (user@944) restarted** — cleared
   cgroup-delegation failed-scope backlog; probe clean after.
5. **Stale `claude-mem-worker` johnw user unit removed** (plugin uninstalled
   2026-06-15; was failing every boot).

## Needs the user (cannot be done from vulcan)

- **TL-WPA8630 powerline extender**: dead since the 05:00 outage, never
  rejoined — power-cycle it (it also carries b-hyve-sprinkler.lan).
- **August lock (garage door)**: offline since the outage — battery/WiFi.
- **Schwab token**: genuinely expired → `StockTraderQuotesUnavailable`.
  Run the hera browser-OAuth re-bootstrap runbook (project_stock_trader).

## Self-clearing (no action)

- `BackupNotRunRecently` (18 gauges): backups were skipped during the 5.5h
  downtime window; all timers fire tonight 02:10–05:30 and the alerts clear.
- `PostgreSQLSlowStatements`: skewed by one-shot maintenance statements from
  the boot backup churn (rule hardening in backlog).
- `Watchdog`: by design.

## Hardening backlog — IMPLEMENTED 2026-07-03 (10 commits, switched, verified)

1. **Host-wide `host_containers_internal_ip = "10.88.0.1"`** (quadlet.nix).
   NOT the originally-suggested LAN IP: vulcan is multi-homed (end0 + WiFi,
   either can lack carrier at boot); the podman0 bridge IP is config-static,
   PostgreSQL binds it, pg_hba admits 10.88.0.0/16. Verified: recreated
   container bakes `10.88.0.1 host.containers.internal`, 0 pg errors.
2. **drafts-mcp `After=nss-lookup.target`** (boot DNS race).
3. **`RuntimeMaxSec` → `TimeoutStartSec`** in 8 oneshot probe units.
4. **/tank/Public ACL clobberer FOUND + fixed**: it was the tmpfiles rule
   `d /var/www/home.newartisans.com 0755 root root` (bind mount of
   /tank/Public!) re-chmodding on every boot/resetup — not the container.
   Mode fields now `-`; stale /tank/Public/{johnw,nasimw} rules removed
   (both copyparty-container.nix and secure-nginx.nix).
5. nginx explicit default :443 (`rejectSSL`) — bogus SNI now gets handshake
   rejection instead of the Alertmanager UI; real vhosts unaffected.
6. PostgreSQLSlowStatements gated on `calls > 1`.
7. smartctl exporter: nvme0n1 dropped (Apple ANS rejects --log=error page;
   device was silently discarded → SmartDeviceMissing fired constantly),
   threshold `< 4`; `smartctl_devices` now reads 4.
8. wyoming-openai `stopSignal = "SIGINT"`.
9. mkMbsync per-account health thresholds; assembly 26h/50h (was CRITICAL
   ~20h of every day on the 1h/4h defaults; now OK).
10. gitea-runner exponential backoff 10s→300s, StartLimitIntervalSec=0,
    ordered after gitea + nss-lookup (was churning ~30 restarts/min in
    outages).
11. HA metric-restorer tolerates carrier-less NIC (SuccessExitStatus "0 2").
12. cockpit placeholder units: DefaultDependencies=false (shutdown noise).
13. rclone: 3 download-forbidden SharedWithMe files excluded (nightly 403s).
14. litellm `allowed_fails: 3` / `cooldown_time: 30` — found ALREADY present
    in the stateful /etc/litellm/config.yaml; no change needed.

### Still deferred (with reasons)

- budget-board-client `SuccessExitStatus`: actual stop exit code not in the
  journal; capture `systemctl show budget-board-client -p ExecMainStatus`
  after its next stop, then set.
- Boot-NVMe SMART coverage via textfile gauge (`smartctl -H` works).
- Blackbox TCP probes for hera.lan:8000/:8443 (litellm upstreams).
- openclaw-self-heal backoff cap after N futile VM restarts (daemon code).
- immich 2.5.2 corePlugin packaging gap (upstream nixpkgs).
- Node-RED "HA Integration Health" debug-node journal spam (flow edit).
- copyparty.vulcan.lan orphan cert: wire a host vhost or retire the cert.
- FLAGGED for owner decision: /var/lib/copyparty-passwords/* are chmod 644
  (world-readable password files; the in-file comment claims the container
  bind-mount requires it — worth revisiting with idmapped mounts or a group).

Chronic baseline noted (not reboot-related): etterminal SIGABRTs 1–3×/day;
avahi/resolved dual-mDNS warning at boot; budget-board missing libgssapi.

Full verified findings: session tool-results (45 verdicts, 109 raw findings).
