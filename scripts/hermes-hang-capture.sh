# hermes-hang-capture — in-VM watchdog that detects an unresponsive Hermes
# api_server (a starved or frozen asyncio event loop) and captures per-thread
# scheduler + kernel-stack state of the gateway for post-mortem analysis.
#
# Background: HermesApiServerDown fires when http://10.99.1.2:8080/v1/capabilities
# stops answering. The 2026-05-30 investigation found the gateway can go
# *silent* for minutes (no error, no traceback) under concurrent load — the
# signature of a CPU-starved event loop (the VM runs on a single vCPU; a
# 4-vCPU bump was tried 2026-05-31 and then REVERTED once it was shown not to
# change the warmup — see the vCPU rationale block in hermes-vm.nix, which
# names this watchdog as the evidence source for revisiting that decision).
# self-heal recovers it by restarting the whole
# microVM, which SIGKILLs the frozen process and destroys the evidence. This
# watchdog captures that evidence the moment the freeze is detected, BEFORE any
# restart, so a residual freeze can be root-caused from its actual thread state.
#
# Tooling note: py-spy (the usual choice) does NOT compile on aarch64 in this
# nixpkgs (remoteprocess libunwind error; meta.broken = isAarch64). So instead
# of Python frames we capture kernel-level per-thread state from /proc, which is
# enough to tell the two failure modes apart on a residual freeze:
#   • CPU starvation  → threads in State R (runnable) but not progressing,
#                       loadavg >> nproc, wchan "0"/running.
#   • blocking / lock → a thread in State D or parked in futex_wait etc.,
#                       /proc/<tid>/syscall pinned on the blocking call.
# (If Python-level frames are later wanted, register faulthandler on SIGUSR1 in
# hermesPyShim and have this script signal the gateway — left out here to avoid
# touching the gateway's startup path.)
#
# Runs as root inside the microVM so it can read /proc/<pid>/task/*/stack
# (privileged). Output goes to the host-shared state dir so dumps survive the
# VM restart self-heal performs.
#
# Liveness model: ANY HTTP response (even 401 Unauthorized) proves the event
# loop is alive and accepting connections, so it counts as healthy. Only a
# timeout / connection refusal — curl reports http_code 000 — counts as a miss.
# That is exactly the signature of a frozen loop, and means we never need the
# API_SERVER_KEY here.
#
# Tunables come from the systemd unit's Environment= (defaults below).
#
# Not under `set -e`: a long-running watchdog must never let a single transient
# command failure kill the loop (systemd would restart it and reset the miss
# counter). Every command is guarded explicitly instead.

PROBE_URL="${HANG_PROBE_URL:-http://127.0.0.1:8080/v1/capabilities}"
INTERVAL="${HANG_PROBE_INTERVAL:-20}"
THRESHOLD="${HANG_FAIL_THRESHOLD:-3}"
DIAG_DIR="${HANG_DIAG_DIR:-/var/lib/hermes/.hermes/diag}"
AGENT_LOG="${HANG_AGENT_LOG:-/var/lib/hermes/.hermes/logs/agent.log}"
UNIT="${HANG_UNIT:-hermes-agent.service}"
MAX_KEEP="${HANG_MAX_KEEP:-40}"

log() {
  logger -t hermes-hang-capture -- "$*" 2>/dev/null
  printf '%s hermes-hang-capture: %s\n' "$(date -u +%H:%M:%SZ)" "$*"
}

mkdir -p "$DIAG_DIR" 2>/dev/null
chown hermes:hermes "$DIAG_DIR" 2>/dev/null
chmod 0750 "$DIAG_DIR" 2>/dev/null

# Per-thread scheduler + kernel-stack dump for one pid, read from /proc.
dump_threads() {
  pid="$1"
  taskdir="/proc/$pid/task"
  if [ ! -d "$taskdir" ]; then
    echo "(no $taskdir — process gone?)"
    return
  fi
  for t in "$taskdir"/*; do
    [ -d "$t" ] || continue
    tid=$(basename "$t")
    comm=$(cat "$t/comm" 2>/dev/null)
    state=$(grep -m1 '^State:' "$t/status" 2>/dev/null | cut -f2-)
    wch=$(cat "$t/wchan" 2>/dev/null)
    sysc=$(cat "$t/syscall" 2>/dev/null)
    echo "--- tid $tid [$comm] state='${state}' wchan='${wch}' syscall='${sysc}'"
    cat "$t/stack" 2>/dev/null || echo "    (kernel stack unavailable)"
  done
}

capture() {
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  out="$DIAG_DIR/hang-$ts.txt"
  pid=$(systemctl show "$UNIT" -p MainPID --value 2>/dev/null)
  log "api_server unresponsive ${THRESHOLD}x — capturing diagnostic to $out (gateway pid=${pid:-?})"
  {
    echo "=== hermes gateway hang capture $ts ==="
    echo "unit=$UNIT MainPID=${pid:-?} probe=$PROBE_URL interval=${INTERVAL}s threshold=$THRESHOLD"
    echo "kernel: $(uname -a 2>/dev/null)"
    echo "uptime:$(uptime 2>/dev/null)"
    echo "loadavg: $(cat /proc/loadavg 2>/dev/null)"
    echo "nproc: $(nproc 2>/dev/null)  <-- compare against loadavg: load >> nproc means CPU starvation"
    echo
    echo "=== free -m ==="
    free -m 2>/dev/null
    echo
    echo "=== top (1 batch, sorted by cpu) ==="
    top -b -n1 2>/dev/null | head -n 20
    echo
    echo "=== ss tcp (listeners + :8080) ==="
    ss -tanp 2>/dev/null | grep -E 'State|:8080'
    if [ -n "${pid:-}" ] && [ "${pid:-0}" -gt 0 ] 2>/dev/null; then
      echo
      echo "=== /proc/$pid/status (sched/mem) ==="
      grep -E 'State|Threads|VmRSS|voluntary_ctxt|nonvoluntary' "/proc/$pid/status" 2>/dev/null
      echo
      echo "=== ps -L thread summary (stat: R=run S=sleep D=uninterruptible) ==="
      ps -L -o tid,stat,wchan:28,pcpu,cputime,comm -p "$pid" 2>/dev/null
      echo
      echo "=== per-thread kernel state + stacks (/proc/$pid/task/*) ==="
      dump_threads "$pid"
    else
      echo "(gateway MainPID unavailable — process not running?)"
    fi
    echo
    echo "=== in-VM journal: $UNIT last 40 ==="
    journalctl -u "$UNIT" -n 40 --no-pager 2>/dev/null
    echo
    echo "=== agent.log tail 60 (the app already redacts secrets in its logs) ==="
    tail -n 60 "$AGENT_LOG" 2>/dev/null
  } >"$out" 2>&1
  chown hermes:hermes "$out" 2>/dev/null
  chmod 0640 "$out" 2>/dev/null
  log "capture complete: $out"
  # Retention: keep only the newest $MAX_KEEP hang-*.txt files.
  ls -1t "$DIAG_DIR"/hang-*.txt 2>/dev/null | tail -n "+$((MAX_KEEP + 1))" | while read -r old; do
    rm -f -- "$old" 2>/dev/null
  done
}

log "started: probing $PROBE_URL every ${INTERVAL}s; capture after ${THRESHOLD} consecutive misses"
fails=0
armed=1   # 1 = will capture on next breach; 0 = already captured this episode
while true; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$PROBE_URL" 2>/dev/null)
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    if [ "$fails" -ge "$THRESHOLD" ] && [ "$armed" -eq 0 ]; then
      log "api_server responsive again (HTTP $code) — re-arming"
    fi
    fails=0
    armed=1
  else
    fails=$((fails + 1))
    log "no response (${fails}/${THRESHOLD})"
    if [ "$fails" -ge "$THRESHOLD" ] && [ "$armed" -eq 1 ]; then
      capture
      armed=0
    fi
  fi
  sleep "$INTERVAL"
done
