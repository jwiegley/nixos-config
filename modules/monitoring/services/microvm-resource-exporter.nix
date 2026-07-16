{
  config,
  lib,
  pkgs,
  ...
}:

let
  # ============================================================================
  # microVM resource exporter (Option A — docs/MONITORING_DEFERRED_SPECS.md
  # "microVM Guest Visibility").
  # ============================================================================
  #
  # The two AI microVMs (openclaw on 10.99.0.2, hermes on 10.99.1.2) expose ZERO
  # in-guest system metrics to Prometheus: there is no node_exporter inside
  # either guest, and node-exporter's host-side systemd collector was verified
  # live to NOT export per-unit MemoryCurrent / CPUUsageNSec for the microvm@*
  # units (node_systemd_unit_memory_current_bytes{name=~"microvm@.*"} → 0
  # results). The genuinely-blind signal is guest MEMORY PRESSURE: both guests
  # run a tmpfs root with ZERO swap, so a runaway allocation OOM-kills the VM
  # with no host warning today.
  #
  # This collector closes that gap WITHOUT a VM restart (Option A). It reads the
  # cgroup accounting that systemd already maintains (MemoryAccounting=yes,
  # confirmed live) for each microvm@<vm> unit and emits per-VM gauges to the
  # node-exporter textfile collector (job=node) — the same idiom as
  # system-age-exporter.nix / asymmetric-routing-exporter.nix.
  #
  # SECURITY: every emitted series is an integer (byte count, nanosecond
  # counter, task count, or 0/1). The collector field-targets
  # `systemctl show -p MemoryCurrent,CPUUsageNSec,TasksCurrent,ActiveState`
  # (NEVER -p Environment), and `du -sb` walks the state-share dirs for SIZE
  # only — never lists, reads, or echoes their contents. No secret surface.
  #
  # DEFERRED (per worklist decision): the in-guest ssh probe (df/free over the
  # debug key — needs the §8 key decision) and Option B (full guest
  # node_exporter — needs a VM cold-boot / ~10-min agent warmup each). Guest-OOM
  # detection ships as a host-side kernel-journal Loki rule instead
  # (modules/monitoring/loki-rules/microvm-oom.yaml).
  #
  # Static facts (verified live 2026-06-10):
  #   openclaw  microvm.mem = 4096 MiB, microvm.vcpu = 4  (openclaw-microvm.nix:28-29)
  #   hermes    microvm.mem = 3072 MiB, microvm.vcpu = 1  (hermes-vm.nix:349,351)
  # The cgroup MemoryMax is `infinity` for both (no cgroup ceiling); the REAL
  # ceiling is the QEMU memory allocation (microvm.mem), so that is what the
  # *_ceiling_bytes gauge encodes.

  # Per-VM static parameters: memory ceiling (MiB → bytes), vCPU count (used by
  # the CPU-saturation alert), and the host-side persistent state-share dir.
  vms = {
    openclaw = {
      ceilingMiB = 4096;
      vcpu = 4;
      stateShare = "/var/lib/openclaw";
    };
    hermes = {
      ceilingMiB = 3072;
      vcpu = 1;
      stateShare = "/var/lib/hermes";
    };
  };

  # ---- Fast collector: cgroup gauges (cheap; 60s cadence) -------------------
  microvm-resource-exporter = pkgs.writeShellApplication {
    name = "microvm-resource-exporter";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      gnused
    ];
    text = ''
      TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"
      TMP="$TEXTFILE_DIR/microvm_resources.prom.$$"
      OUT="$TEXTFILE_DIR/microvm_resources.prom"

      mkdir -p "$TEXTFILE_DIR"

      {
        echo "# HELP microvm_memory_current_bytes Current memory (cgroup MemoryCurrent) of the microVM unit"
        echo "# TYPE microvm_memory_current_bytes gauge"
        echo "# HELP microvm_memory_ceiling_bytes QEMU memory allocation (microvm.mem) — the real ceiling; cgroup MemoryMax is infinity"
        echo "# TYPE microvm_memory_ceiling_bytes gauge"
        echo "# HELP microvm_cpu_usage_seconds_total Cumulative CPU time of the microVM unit (cgroup CPUUsageNSec / 1e9)"
        echo "# TYPE microvm_cpu_usage_seconds_total counter"
        echo "# HELP microvm_vcpu_count Number of vCPUs configured for the microVM (microvm.vcpu)"
        echo "# TYPE microvm_vcpu_count gauge"
        echo "# HELP microvm_tasks_current Current task count (cgroup TasksCurrent) of the microVM unit"
        echo "# TYPE microvm_tasks_current gauge"
        echo "# HELP microvm_unit_active 1 if the microvm@<vm> unit ActiveState=active, else 0"
        echo "# TYPE microvm_unit_active gauge"
        echo "# HELP microvm_memory_pressure_some_avg300 cgroup memory PSI 'some' avg300 (% of 5m the cgroup stalled on memory). Real-pressure signal; ~0 when memory_current is merely reclaimable page cache."
        echo "# TYPE microvm_memory_pressure_some_avg300 gauge"
        echo "# HELP microvm_memory_pressure_full_avg300 cgroup memory PSI 'full' avg300 (% of 5m ALL tasks stalled on memory)."
        echo "# TYPE microvm_memory_pressure_full_avg300 gauge"

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (vm: p: ''
            ceil=$(( ${toString p.ceilingMiB} * 1048576 ))

            # Field-targeted show — NEVER -p Environment. Read only the four
            # numeric/state keys below into the shell namespace; nothing is
            # eval'd, so a hostile value cannot inject.
            mc=0; cpu_ns=0; tasks=0; active=0
            while IFS='=' read -r k v; do
              case "$k" in
                MemoryCurrent) mc="$v" ;;
                CPUUsageNSec)  cpu_ns="$v" ;;
                TasksCurrent)  tasks="$v" ;;
                ActiveState)   [ "$v" = "active" ] && active=1 ;;
              esac
            done < <(systemctl show "microvm@${vm}" \
                       -p MemoryCurrent,CPUUsageNSec,TasksCurrent,ActiveState 2>/dev/null)

            # `[not set]` / empty (accounting off or unit gone) → 0 so ratios read
            # 0 (under threshold) rather than divide-by-zero; combined with
            # microvm_unit_active you can still distinguish "VM down" from
            # "accounting off". Non-numeric guard keeps the textfile parseable.
            case "$mc"     in (*[!0-9]*|"") mc=0 ;; esac
            case "$cpu_ns" in (*[!0-9]*|"") cpu_ns=0 ;; esac
            case "$tasks"  in (*[!0-9]*|"") tasks=0 ;; esac

            echo "microvm_memory_current_bytes{vm=\"${vm}\"} $mc"
            echo "microvm_memory_ceiling_bytes{vm=\"${vm}\"} $ceil"
            echo "microvm_cpu_usage_seconds_total{vm=\"${vm}\"} $(( cpu_ns / 1000000000 ))"
            echo "microvm_vcpu_count{vm=\"${vm}\"} ${toString p.vcpu}"
            echo "microvm_tasks_current{vm=\"${vm}\"} $tasks"
            echo "microvm_unit_active{vm=\"${vm}\"} $active"

            # cgroup memory PSI — the REAL pressure signal. Unlike MemoryCurrent
            # (which counts reclaimable page cache and so spikes during nightly
            # backups that read the VM's virtiofs share), PSI stays ~0 while
            # memory is merely cache; it only climbs when the cgroup genuinely
            # stalls reclaiming/refaulting needed pages — the true OOM precursor.
            # /sys is readable under ProtectSystem=strict (ProtectControlGroups
            # is not set); read-only access, no accounting side effects.
            cg=$(systemctl show "microvm@${vm}" -p ControlGroup --value 2>/dev/null)
            psi_some=0; psi_full=0
            pf="/sys/fs/cgroup$cg/memory.pressure"
            if [ -n "$cg" ] && [ -r "$pf" ]; then
              psi_some=$(sed -n 's/^some .*avg300=\([0-9.]*\).*/\1/p' "$pf")
              psi_full=$(sed -n 's/^full .*avg300=\([0-9.]*\).*/\1/p' "$pf")
            fi
            case "$psi_some" in (*[!0-9.]*|"") psi_some=0 ;; esac
            case "$psi_full" in (*[!0-9.]*|"") psi_full=0 ;; esac
            echo "microvm_memory_pressure_some_avg300{vm=\"${vm}\"} $psi_some"
            echo "microvm_memory_pressure_full_avg300{vm=\"${vm}\"} $psi_full"
          '') vms
        )}

        echo "# HELP microvm_resource_exporter_last_run_timestamp_seconds Unix time of the last cgroup-gauge run (staleness anchor)"
        echo "# TYPE microvm_resource_exporter_last_run_timestamp_seconds gauge"
        echo "microvm_resource_exporter_last_run_timestamp_seconds $(date +%s)"
      } > "$TMP"

      # Atomic publish so the node-exporter collector never reads a partial file.
      mv "$TMP" "$OUT"
      chmod 644 "$OUT"
    '';
  };

  # ---- Slow collector: state-share size (hourly; walks the 14.5G openclaw
  # share — too heavy for the 60s cadence, per the spec noise analysis §5) -----
  microvm-state-share-exporter = pkgs.writeShellApplication {
    name = "microvm-state-share-exporter";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"
      TMP="$TEXTFILE_DIR/microvm_state_share.prom.$$"
      OUT="$TEXTFILE_DIR/microvm_state_share.prom"

      mkdir -p "$TEXTFILE_DIR"

      {
        echo "# HELP microvm_state_share_bytes Size of the microVM's host-side persistent virtiofs state share (du -sb; SIZE only)"
        echo "# TYPE microvm_state_share_bytes gauge"
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (vm: p: ''
            # du -sb walks for SIZE only — never lists/reads file contents.
            sz=$(du -sb "${p.stateShare}" 2>/dev/null | cut -f1)
            case "$sz" in (*[!0-9]*|"") sz=0 ;; esac
            echo "microvm_state_share_bytes{vm=\"${vm}\"} $sz"
          '') vms
        )}
        echo "# HELP microvm_state_share_exporter_last_run_timestamp_seconds Unix time of the last state-share du run (staleness anchor)"
        echo "# TYPE microvm_state_share_exporter_last_run_timestamp_seconds gauge"
        echo "microvm_state_share_exporter_last_run_timestamp_seconds $(date +%s)"
      } > "$TMP"

      mv "$TMP" "$OUT"
      chmod 644 "$OUT"
    '';
  };

  # Hardening shared by both oneshots (mirrors system-age-exporter.nix). Root is
  # required to `systemctl show` foreign-user units and `du` the 0700
  # openclaw-owned share; NOT DynamicUser for the same reason.
  hardenedService = exec: {
    Type = "oneshot";
    ExecStart = exec;
    User = "root";
    Group = "root";
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
  };
in
{
  # ---- Fast cgroup-gauge timer: 60s ----------------------------------------
  systemd.timers."microvm-resource-exporter" = {
    description = "microVM resource exporter timer (cgroup mem/CPU/tasks gauges)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "60s";
      Unit = "microvm-resource-exporter.service";
    };
  };

  systemd.services."microvm-resource-exporter" = {
    description = "microVM resource exporter (cgroup MemoryCurrent/CPUUsageNSec/TasksCurrent → textfile gauges)";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = hardenedService "${lib.getExe microvm-resource-exporter}";
  };

  # ---- Slow state-share du timer: hourly (the 14.5G openclaw share is too
  # heavy to walk every minute — split per spec §5 noise analysis) -----------
  systemd.timers."microvm-state-share-exporter" = {
    description = "microVM state-share size exporter timer (hourly du of the virtiofs shares)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1h";
      Persistent = true;
      Unit = "microvm-state-share-exporter.service";
    };
  };

  systemd.services."microvm-state-share-exporter" = {
    description = "microVM state-share size exporter (du -sb of /var/lib/{openclaw,hermes})";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = hardenedService "${lib.getExe microvm-state-share-exporter}";
  };
}
