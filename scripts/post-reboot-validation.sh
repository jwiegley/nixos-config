#!/usr/bin/env bash
#
# post-reboot-validation.sh — cold-reboot validation harness for vulcan
#
# READ-ONLY. Run this AFTER a cold reboot to confirm the boot-robustness fixes
# deployed over 2026-06-08..10 actually held on a real cold boot (most were only
# switch-time verified). See docs/COLD_REBOOT_CHECKLIST.md for the check→fix map.
#
# Each numbered check prints PASS / FAIL / WARN + a one-line detail. A summary
# count is printed at the end; exit 0 only if there are zero FAILs.
#
# SAFETY: this script prints only unit/service/job names, counts, and booleans —
# never secrets, tokens, WiFi SSIDs, LAN device hostnames, or IP addresses. It
# reads no forbidden paths (no /run/secrets, no NetworkManager profiles, no
# .storage). `dig`/`ip rule` output is reduced to a yes/no or a count.
#
# Intentionally NOT `set -e`: every check must run so the operator gets a full
# report, not a halt on the first failure.
set -uo pipefail

# ---------------------------------------------------------------------------
# Output plumbing
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_WARN=$'\033[33m'
  C_INFO=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_PASS=""; C_FAIL=""; C_WARN=""; C_INFO=""; C_DIM=""; C_RST=""
fi

n_pass=0; n_fail=0; n_warn=0; n_info=0
fail_names=(); warn_names=()
check_no=0

# current check label (set by `check`)
_cur=""

check() { check_no=$((check_no + 1)); _cur="$1"; }

pass() { printf "%2d. %sPASS%s  %-46s %s\n" "$check_no" "$C_PASS" "$C_RST" "$_cur" "${1:-}"; n_pass=$((n_pass + 1)); }
warn() { printf "%2d. %sWARN%s  %-46s %s\n" "$check_no" "$C_WARN" "$C_RST" "$_cur" "${1:-}"; n_warn=$((n_warn + 1)); warn_names+=("$check_no:$_cur"); }
fail() { printf "%2d. %sFAIL%s  %-46s %s\n" "$check_no" "$C_FAIL" "$C_RST" "$_cur" "${1:-}"; n_fail=$((n_fail + 1)); fail_names+=("$check_no:$_cur"); }
info() { printf "%2d. %sINFO%s  %-46s %s\n" "$check_no" "$C_INFO" "$C_RST" "$_cur" "${1:-}"; n_info=$((n_info + 1)); }

note() { printf "      %s%s%s\n" "$C_DIM" "$1" "$C_RST"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Seconds since boot (integer).
uptime_s() { awk '{print int($1)}' /proc/uptime; }

UPTIME=$(uptime_s)
BOOT_WINDOW=900   # 15 min — within this, slow-start services WARN instead of FAIL
LONG_RUN=86400    # 24 h — beyond this, boot-proximity checks become advisory INFO

# Within the early boot window? (slow starters get a pass on WARN)
in_boot_window() { [ "$UPTIME" -lt "$BOOT_WINDOW" ]; }
# Long-running system? boot-proximity timing checks are advisory only.
is_long_run() { [ "$UPTIME" -ge "$LONG_RUN" ]; }

# systemctl show single property value
sc() { systemctl show "$2" -p "$1" --value 2>/dev/null; }

active_state() { sc ActiveState "$1"; }
sub_state() { sc SubState "$1"; }
load_state() { sc LoadState "$1"; }
result_of() { sc Result "$1"; }

# Convert a systemd timestamp property (ExecMainStartTimestamp etc.) to epoch
# seconds, or empty on failure. Uses the *Monotonic variants where possible for
# robust deltas.
mono_us() { systemctl show "$2" -p "$1" --value 2>/dev/null; }

NODE_EXPORTER_URL="http://127.0.0.1:9100/metrics"
PROM_URL="http://127.0.0.1:9090"
LOKI_URL="http://127.0.0.1:3100"
TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
printf "%s========================================================%s\n" "$C_INFO" "$C_RST"
printf "%s vulcan cold-reboot validation  —  %s%s\n" "$C_INFO" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$C_RST"
printf "%s========================================================%s\n" "$C_INFO" "$C_RST"
printf "Uptime: %s  (%dh %dm)\n" "$UPTIME" "$((UPTIME / 3600))" "$(((UPTIME % 3600) / 60))"
if is_long_run; then
  printf "%sNOTE: uptime > 24h — boot-proximity timing checks (NM-wait-online%s\n" "$C_DIM" "$C_RST"
  printf "%s      delta, restic-not-at-boot) are ADVISORY only, not gates.%s\n" "$C_DIM" "$C_RST"
elif ! in_boot_window; then
  printf "%sNOTE: past the 15-min boot window — slow starters held to FAIL.%s\n" "$C_DIM" "$C_RST"
else
  printf "%sNOTE: within 15-min boot window — slow starters WARN, not FAIL.%s\n" "$C_DIM" "$C_RST"
fi
echo

# ===========================================================================
# (a) systemctl --failed is empty
# ===========================================================================
check "systemctl --failed empty"
failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)
failed_count=$(printf "%s\n" "$failed_units" | grep -c . || true)
if [ "$failed_count" -eq 0 ]; then
  pass "no failed units"
else
  fail "$failed_count failed unit(s): $(printf '%s ' $failed_units)"
fi

# ===========================================================================
# (b) NetworkManager-wait-online — active(exited), success, runtime sane (<=65s)
#     Fix: commit da1946b — upstream `nm-online -s -q -t 60` (old `-x` burned 60s)
# ===========================================================================
check "NetworkManager-wait-online sane"
nmw_active=$(active_state NetworkManager-wait-online)
nmw_sub=$(sub_state NetworkManager-wait-online)
nmw_result=$(result_of NetworkManager-wait-online)
if [ "$nmw_active" != "active" ] || [ "$nmw_result" != "success" ]; then
  fail "state=$nmw_active/$nmw_sub result=$nmw_result (expected active/exited success)"
else
  # Compute runtime from the monotonic timestamps (us since boot).
  start_us=$(mono_us ExecMainStartTimestampMonotonic NetworkManager-wait-online)
  exit_us=$(mono_us ExecMainExitTimestampMonotonic NetworkManager-wait-online)
  if [ -z "$start_us" ] || [ -z "$exit_us" ] || [ "$start_us" = "0" ] || [ "$exit_us" = "0" ] || [ "$exit_us" -lt "$start_us" ]; then
    # Fall back to ActiveEnter - InactiveExit wall delta is unreliable; just report.
    if is_long_run; then
      info "active/exited success; runtime timestamps unavailable (advisory)"
    else
      warn "active/exited success but runtime delta unavailable from monotonic timestamps"
    fi
  else
    delta_s=$(( (exit_us - start_us) / 1000000 ))
    if [ "$delta_s" -le 65 ]; then
      pass "active/exited success, runtime ${delta_s}s (<=65s)"
    else
      fail "active/exited success but runtime ${delta_s}s > 65s (old -x 60s-burn pattern?)"
    fi
  fi
fi

# ===========================================================================
# (c) systemd-networkd-wait-online MASKED
#     Fix: commit f3706d2 — systemd.network.wait-online.enable = false
# ===========================================================================
check "networkd-wait-online masked"
nwd_load=$(load_state systemd-networkd-wait-online)
if [ "$nwd_load" = "masked" ]; then
  pass "LoadState=masked"
else
  fail "LoadState=$nwd_load (expected masked — f3706d2 should mask it)"
fi

# ===========================================================================
# (d) Asymmetric routing landed at boot: exactly 2 rules at prio 50 & 51,
#     asymmetric-routing.service success, textfile gauge == 1.
#     networkd no longer flushes them (ManageForeignRoutingPolicyRules=false,
#     commit 5dcb038). The oneshot is the sole authoritative writer.
# ===========================================================================
check "asymmetric routing rules at boot"
# Count rules at priorities 50 and 51 (names/IPs not printed).
rule50=$(ip rule list 2>/dev/null | grep -cE '^50:' || true)
rule51=$(ip rule list 2>/dev/null | grep -cE '^51:' || true)
ar_result=$(result_of asymmetric-routing)
ar_active=$(active_state asymmetric-routing)
gauge_val=""
if [ -f "$TEXTFILE_DIR/asymmetric_routing.prom" ]; then
  gauge_val=$(grep -E '^asymmetric_routing_rules_present ' "$TEXTFILE_DIR/asymmetric_routing.prom" 2>/dev/null | awk '{print $2}')
fi
ar_ok=1
ar_detail="rules: prio50=$rule50 prio51=$rule51; svc=$ar_active/$ar_result; gauge=${gauge_val:-missing}"
[ "$rule50" -eq 1 ] && [ "$rule51" -eq 1 ] || ar_ok=0
[ "$ar_active" = "active" ] && [ "$ar_result" = "success" ] || ar_ok=0
[ "${gauge_val:-0}" = "1" ] || ar_ok=0
if [ "$ar_ok" -eq 1 ]; then
  pass "$ar_detail"
  note "networkd ManageForeignRoutingPolicyRules=false (5dcb038): no longer flushed on switch"
else
  fail "$ar_detail"
  note "oneshot is sole writer; ManageForeignRoutingPolicyRules=false (5dcb038)"
fi

# ===========================================================================
# (e) cloudflared-tunnel-data — active, NOT in give-up, NRestarts small, no
#     StartLimit hit. Fix: 2c15db1 (After=technitium + StartLimitIntervalSec=0).
# ===========================================================================
check "cloudflared tunnel healthy"
cf_active=$(active_state cloudflared-tunnel-data)
cf_sub=$(sub_state cloudflared-tunnel-data)
cf_result=$(result_of cloudflared-tunnel-data)
cf_nrestarts=$(sc NRestarts cloudflared-tunnel-data); cf_nrestarts=${cf_nrestarts:-0}
cf_limitint=$(sc StartLimitIntervalUSec cloudflared-tunnel-data)
if [ "$cf_active" != "active" ]; then
  if [ "$cf_result" = "start-limit-hit" ]; then
    fail "INACTIVE, Result=start-limit-hit — gave up permanently (the pre-2c15db1 failure mode)"
  elif in_boot_window; then
    warn "state=$cf_active/$cf_sub result=$cf_result (still within boot window)"
  else
    fail "state=$cf_active/$cf_sub result=$cf_result"
  fi
elif [ "$cf_result" = "start-limit-hit" ]; then
  fail "active now but Result=start-limit-hit (hit the burst cap at boot)"
elif [ "$cf_nrestarts" -ge 10 ]; then
  warn "active but NRestarts=$cf_nrestarts (>=10 — crash-looping early?)"
else
  pass "active/$cf_sub, NRestarts=$cf_nrestarts, StartLimitInterval=${cf_limitint}us"
fi

# ===========================================================================
# (f) Technitium DNS active AND a live dig resolves vulcan.lan @127.0.0.1.
#     Fix: 2c15db1 (ExecStartPost probe + nss-lookup.target gate).
# ===========================================================================
check "Technitium DNS resolves"
td_active=$(active_state technitium-dns-server)
dig_lines=0
if have dig; then
  dig_lines=$(dig +short +time=2 +tries=1 vulcan.lan @127.0.0.1 2>/dev/null | grep -c . || true)
fi
if [ "$td_active" != "active" ]; then
  if in_boot_window; then warn "service $td_active (boot window)"; else fail "service $td_active"; fi
elif ! have dig; then
  warn "service active but 'dig' unavailable to probe :53"
elif [ "$dig_lines" -ge 1 ]; then
  pass "service active; vulcan.lan resolved (answer present)"
else
  if in_boot_window; then
    warn "service active but vulcan.lan did NOT resolve yet (boot window)"
  else
    fail "service active but vulcan.lan did NOT resolve via 127.0.0.1:53"
  fi
fi

# ===========================================================================
# (g) ZFS: tank pool exists, healthy, key mounts present.
# ===========================================================================
check "ZFS tank pool healthy"
if ! have zpool; then
  warn "zpool unavailable"
else
  if zpool list -H tank >/dev/null 2>&1; then
    zx=$(zpool status -x 2>/dev/null)
    if printf "%s" "$zx" | grep -qiE 'all pools are healthy|pool .tank. is healthy'; then
      pass "tank present; zpool status -x: healthy"
    else
      # status -x lists only problem pools; if tank named, it has an issue.
      if printf "%s" "$zx" | grep -q 'tank'; then
        fail "tank present but NOT healthy (zpool status -x flags it)"
      else
        pass "tank present; zpool status -x: healthy"
      fi
    fi
  else
    fail "tank pool not listed by zpool"
  fi
fi

check "ZFS key mounts present"
mount_fail=0; mount_detail=""
for m in /tank /tank/Photos/Immich /tank/Backups /tank/Backups/PostgreSQL; do
  if mountpoint -q "$m" 2>/dev/null; then
    mount_detail+="$(basename "$m"):ok "
  else
    mount_detail+="$(basename "$m"):MISSING "
    mount_fail=1
  fi
done
if [ "$mount_fail" -eq 0 ]; then
  pass "$mount_detail"
elif in_boot_window; then
  warn "$mount_detail (boot window — tank may import late)"
else
  fail "$mount_detail"
fi

# ===========================================================================
# (h) immich-server active (ConditionPathIsMountPoint=/tank/Photos/Immich).
#     Distinguish condition-skipped vs crashed.  Fix: 2c15db1.
# ===========================================================================
check "immich-server active"
im_active=$(active_state immich-server)
im_sub=$(sub_state immich-server)
im_cond=$(sc ConditionResult immich-server)
im_result=$(result_of immich-server)
if [ "$im_active" = "active" ]; then
  pass "active/$im_sub (ConditionResult=$im_cond)"
elif [ "$im_cond" = "no" ]; then
  if in_boot_window; then
    warn "inactive: ConditionPathIsMountPoint NOT met (tank late? boot window)"
  else
    fail "inactive: ConditionPathIsMountPoint=/tank/Photos/Immich not met (tank not mounted)"
  fi
else
  if in_boot_window; then
    warn "inactive/$im_sub result=$im_result — condition met, may be warming"
  else
    fail "inactive/$im_sub result=$im_result — condition met but service down (crashed)"
  fi
fi

# ===========================================================================
# (i) No stale restic locks: no restic-* in failed; restic-check.timer exists
#     and did NOT trigger at boot (weekly-only now — 2c15db1/213d0ea).
# ===========================================================================
check "no failed restic units"
restic_failed=$(systemctl list-units 'restic-*' --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)
rf_count=$(printf "%s\n" "$restic_failed" | grep -c . || true)
if [ "$rf_count" -eq 0 ]; then
  pass "no restic-* units in failed state"
else
  fail "$rf_count failed restic unit(s): $(printf '%s ' $restic_failed)"
fi

check "restic-check.timer not boot-triggered"
rct_load=$(load_state restic-check.timer)
if [ "$rct_load" != "loaded" ]; then
  fail "restic-check.timer LoadState=$rct_load (expected loaded)"
else
  last_us=$(mono_us LastTriggerUSecMonotonic restic-check.timer)
  # last_us is monotonic us since boot; >0 and small (<600s) means it ran AT boot.
  if [ -z "$last_us" ] || [ "$last_us" = "0" ]; then
    pass "timer present; no trigger this boot (weekly-only)"
  else
    last_s=$((last_us / 1000000))
    if [ "$last_s" -lt 600 ]; then
      if is_long_run; then
        info "timer last triggered ${last_s}s into THIS boot — but uptime>24h, likely a real weekly run since boot (advisory)"
      else
        fail "timer triggered ${last_s}s after boot (<10min) — boot-herd not removed?"
      fi
    else
      pass "timer present; last trigger ${last_s}s into boot (not a boot herd)"
    fi
  fi
fi

# ===========================================================================
# (j) microVMs active + uptime gauges present.
# ===========================================================================
check "microvm@openclaw / @hermes active"
oc_active=$(active_state microvm@openclaw)
he_active=$(active_state microvm@hermes)
vm_detail="openclaw=$oc_active hermes=$he_active"
if [ "$oc_active" = "active" ] && [ "$he_active" = "active" ]; then
  pass "$vm_detail"
elif in_boot_window; then
  warn "$vm_detail (microVMs warm ~10min; within boot window)"
else
  fail "$vm_detail"
fi

check "microVM uptime gauges present"
gauge_src=""
oc_gauge=""; he_gauge=""
if [ -f "$TEXTFILE_DIR/openclaw_self_heal.prom" ] || [ -f "$TEXTFILE_DIR/openclaw_canary.prom" ]; then :; fi
# Prefer textfiles, fall back to scraping node-exporter.
oc_gauge=$(grep -rhE '^openclaw_microvm_active_enter_timestamp_seconds ' "$TEXTFILE_DIR"/*.prom 2>/dev/null | head -1)
he_gauge=$(grep -rhE '^hermes_vm_uptime_seconds ' "$TEXTFILE_DIR"/*.prom 2>/dev/null | head -1)
if [ -n "$oc_gauge" ] || [ -n "$he_gauge" ]; then
  gauge_src="textfiles"
elif have curl; then
  body=$(curl -s --max-time 5 "$NODE_EXPORTER_URL" 2>/dev/null || true)
  oc_gauge=$(printf "%s\n" "$body" | grep -E '^openclaw_microvm_active_enter_timestamp_seconds ' | head -1)
  he_gauge=$(printf "%s\n" "$body" | grep -E '^hermes_vm_uptime_seconds ' | head -1)
  gauge_src="node-exporter:9100"
fi
present=""
[ -n "$oc_gauge" ] && present+="openclaw "
[ -n "$he_gauge" ] && present+="hermes "
if [ -n "$oc_gauge" ] && [ -n "$he_gauge" ]; then
  pass "both gauges present (via ${gauge_src:-?})"
elif [ -n "$present" ]; then
  if in_boot_window; then warn "only: ${present}(${gauge_src:-?}; warming)"; else warn "only: ${present}(${gauge_src:-?})"; fi
else
  if in_boot_window; then warn "no microVM uptime gauges yet (boot window)"; else fail "no microVM uptime gauges found"; fi
fi

# ===========================================================================
# (k) Monitoring stack active; Prometheus rules 0 err; Loki >=10 groups;
#     Watchdog firing.
# ===========================================================================
check "monitoring stack services active"
mon_bad=""
for s in prometheus alertmanager victoriametrics loki promtail grafana; do
  st=$(active_state "$s")
  [ "$st" = "active" ] || mon_bad+="$s($st) "
done
if [ -z "$mon_bad" ]; then
  pass "prometheus alertmanager victoriametrics loki promtail grafana all active"
elif in_boot_window; then
  warn "not active yet: $mon_bad(boot window)"
else
  fail "not active: $mon_bad"
fi

check "Prometheus rules: 0 health=err"
if have curl && have python3; then
  rules_out=$(curl -s --max-time 8 "$PROM_URL/api/v1/rules" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR parse"); sys.exit(0)
gs = d.get("data", {}).get("groups", [])
rules = [r for g in gs for r in g.get("rules", [])]
err = [r for r in rules if r.get("health") == "err"]
print(f"OK total={len(rules)} err={len(err)}")
' 2>/dev/null)
  if printf "%s" "$rules_out" | grep -q '^OK '; then
    total=$(printf "%s" "$rules_out" | sed -E 's/.*total=([0-9]+).*/\1/')
    errc=$(printf "%s" "$rules_out" | sed -E 's/.*err=([0-9]+).*/\1/')
    if [ "$errc" -eq 0 ]; then
      pass "total=$total rules, err=0"
    else
      fail "total=$total rules, err=$errc (rules failing to evaluate)"
    fi
  else
    if in_boot_window; then warn "could not query Prometheus rules API (boot window)"; else fail "could not query Prometheus rules API"; fi
  fi
else
  warn "curl/python3 unavailable to query rules API"
fi

check "Loki ruler >=10 rule groups"
if have curl && have python3; then
  loki_n=$(curl -s --max-time 8 "$LOKI_URL/prometheus/api/v1/rules" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get("data", {}).get("groups", [])))
except Exception:
    print(-1)
' 2>/dev/null)
  loki_n=${loki_n:--1}
  if [ "$loki_n" -ge 10 ]; then
    pass "$loki_n groups"
  elif [ "$loki_n" -ge 0 ]; then
    if in_boot_window; then warn "$loki_n groups (<10; loki ruler may still be loading)"; else fail "$loki_n groups (<10 expected)"; fi
  else
    if in_boot_window; then warn "Loki ruler API not answering (boot window)"; else fail "Loki ruler API not answering"; fi
  fi
else
  warn "curl/python3 unavailable to query Loki ruler"
fi

check "Watchdog alert firing (pipeline alive)"
if have curl && have python3; then
  wd=$(curl -s --max-time 8 "$PROM_URL/api/v1/alerts" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    al = d.get("data", {}).get("alerts", [])
    print("YES" if any(a.get("labels",{}).get("alertname")=="Watchdog" and a.get("state")=="firing" for a in al) else "NO")
except Exception:
    print("ERR")
' 2>/dev/null)
  case "$wd" in
    YES) pass "Watchdog firing — alert pipeline is alive" ;;
    NO)  if in_boot_window; then warn "Watchdog NOT firing yet (boot window)"; else fail "Watchdog NOT firing — alert pipeline may be DEAD"; fi ;;
    *)   if in_boot_window; then warn "could not query alerts API (boot window)"; else fail "could not query alerts API"; fi ;;
  esac
else
  warn "curl/python3 unavailable to query alerts"
fi

# ===========================================================================
# (l) Prometheus targets: count up==0; FAIL if > 3. Print down job names only.
# ===========================================================================
check "Prometheus targets up"
if have curl && have python3; then
  tg=$(curl -s --max-time 8 "$PROM_URL/api/v1/targets" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR"); sys.exit(0)
ats = d.get("data", {}).get("activeTargets", [])
down = sorted(set(t.get("labels",{}).get("job","?") for t in ats if t.get("health") != "up"))
print("OK total=%d down=%d jobs=%s" % (len(ats), len(down), ",".join(down)))
' 2>/dev/null)
  if printf "%s" "$tg" | grep -q '^OK '; then
    tot=$(printf "%s" "$tg" | sed -E 's/.*total=([0-9]+).*/\1/')
    dn=$(printf "%s" "$tg" | sed -E 's/.*down=([0-9]+).*/\1/')
    jobs=$(printf "%s" "$tg" | sed -E 's/.*jobs=//')
    if [ "$dn" -le 3 ]; then
      if [ "$dn" -eq 0 ]; then pass "$tot targets, 0 down"; else warn "$tot targets, $dn down (<=3 tolerated): ${jobs}"; fi
    else
      fail "$tot targets, $dn down (>3): ${jobs}"
    fi
  else
    if in_boot_window; then warn "could not query targets API (boot window)"; else fail "could not query targets API"; fi
  fi
else
  warn "curl/python3 unavailable to query targets"
fi

# ===========================================================================
# (m) PostgreSQL active; shared_preload_libraries contains pg_stat_statements.
# ===========================================================================
check "PostgreSQL + pg_stat_statements"
pg_active=$(active_state postgresql)
if [ "$pg_active" != "active" ]; then
  if in_boot_window; then warn "postgresql $pg_active (boot window)"; else fail "postgresql $pg_active"; fi
else
  spl=$(sudo -u postgres psql -tAc "SHOW shared_preload_libraries;" 2>/dev/null | tr ',' '\n' | grep -c 'pg_stat_statements' || true)
  if [ "$spl" -ge 1 ]; then
    pass "active; shared_preload_libraries includes pg_stat_statements"
  else
    fail "active but pg_stat_statements NOT in shared_preload_libraries (config didn't persist?)"
  fi
fi

# ===========================================================================
# (n) node-red, nagios, home-assistant active.
# ===========================================================================
check "node-red / nagios / home-assistant active"
app_bad=""
for s in node-red nagios home-assistant; do
  st=$(active_state "$s")
  [ "$st" = "active" ] || app_bad+="$s($st) "
done
if [ -z "$app_bad" ]; then
  pass "node-red nagios home-assistant all active"
elif in_boot_window; then
  warn "not active yet: $app_bad(boot window)"
else
  fail "not active: $app_bad"
fi

# ===========================================================================
# (o) Monitoring exporter timers all active.
# ===========================================================================
check "monitoring exporter timers active"
timers=(
  container-cve-exporter
  port-drift-exporter
  config-drift-exporter
  container-image-staleness-exporter
  microvm-resource-exporter
  dovecot-fts-staleness-check
  asymmetric-routing-exporter
  restic-metrics
  nagios-status-exporter
)
timer_bad=""
for t in "${timers[@]}"; do
  st=$(active_state "$t.timer")
  [ "$st" = "active" ] || timer_bad+="$t.timer($st) "
done
if [ -z "$timer_bad" ]; then
  pass "all ${#timers[@]} exporter timers active"
elif in_boot_window; then
  warn "not active yet: $timer_bad(boot window)"
else
  fail "not active: $timer_bad"
fi

# ===========================================================================
# (p) Boot timing — informational only.
# ===========================================================================
check "boot timing (informational)"
if have systemd-analyze; then
  bt=$(systemd-analyze time 2>/dev/null | head -1)
  info "${bt:-unavailable}"
  if ! is_long_run; then
    note "systemd-analyze blame (top 15):"
    systemd-analyze blame 2>/dev/null | head -15 | sed 's/^/        /'
  else
    note "uptime > 24h — blame reflects this boot; printed for the record:"
    systemd-analyze blame 2>/dev/null | head -15 | sed 's/^/        /'
  fi
else
  warn "systemd-analyze unavailable"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
printf "%s========================================================%s\n" "$C_INFO" "$C_RST"
printf " SUMMARY: %sPASS=%d%s  %sWARN=%d%s  %sFAIL=%d%s  INFO=%d  (of %d checks)\n" \
  "$C_PASS" "$n_pass" "$C_RST" "$C_WARN" "$n_warn" "$C_RST" "$C_FAIL" "$n_fail" "$C_RST" "$n_info" "$check_no"
printf "%s========================================================%s\n" "$C_INFO" "$C_RST"
if [ "${#warn_names[@]}" -gt 0 ]; then
  printf "%sWARNed:%s %s\n" "$C_WARN" "$C_RST" "$(printf '[%s] ' "${warn_names[@]}")"
fi
if [ "${#fail_names[@]}" -gt 0 ]; then
  printf "%sFAILed:%s %s\n" "$C_FAIL" "$C_RST" "$(printf '[%s] ' "${fail_names[@]}")"
fi

if [ "$n_fail" -gt 0 ]; then
  exit 1
fi
exit 0
