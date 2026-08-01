{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Rootless quadlet users with a persistent podman store. DERIVED, not
  # hand-listed: a user has a per-user podman graphroot iff its Home Manager home
  # lives under /var/lib/containers/. Same structural predicate as
  # modules/users/home-manager/rootless-podman-image-prune.nix:38, which installs
  # the podman-image-prune.{timer,service} this exporter then reports on — so the
  # producer of those units and the reader of them can never drift apart.
  #
  # Verified 2026-07-29 by `nix eval` and against live TSDB
  # (count by (user) (last_over_time(container_image_prune_failed[30d])) = these
  # 14 users): exactly the 14 names formerly hardcoded in the ROOTLESS_USERS
  # string below. Excluded structurally, and correctly:
  #   - technitium-dns-exporter: runs as a ROOT podman container (already covered
  #     by the root sweep), no rootless store, no HM user. config.users.users
  #     WOULD include it (15 names) — hence home-manager.users, not users.users.
  #   - zimit: transient on-demand containers per archive job (no persistent
  #     PODMAN_SYSTEMD_UNIT container to track).
  #   - johnw: human account (/home/johnw).
  # A full rootless sweep measures ~1.7s wall (ps+inspect+stats per container),
  # comfortably inside the 2-min cadence.
  rootlessUsers = lib.filter (
    u: lib.hasPrefix "/var/lib/containers/" config.home-manager.users.${u}.home.homeDirectory
  ) (lib.attrNames config.home-manager.users);
in
{
  # Container Health Exporter for Prometheus
  # Monitors Podman container health status and exposes metrics for alerting
  #
  # Metrics exposed:
  # - container_health_status{name="<container>"} = 0 (healthy) | 1 (unhealthy) | 2 (starting)
  # - container_running{name="<container>"} = 0 (stopped) | 1 (running)
  # - container_restart_count{name="<container>"} = number of restarts

  # Create a script that checks container health and outputs Prometheus metrics
  systemd.services.container-health-exporter = {
    description = "Container Health Exporter for Prometheus";
    after = [
      "network.target"
      "podman.service"
    ];
    # No wantedBy - service only runs via timer

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "container-health-exporter" ''
                set -euo pipefail

                METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/container_health.prom"
                METRICS_TMP="$METRICS_FILE.tmp"

                # Ensure directory exists
                mkdir -p "$(dirname "$METRICS_FILE")"

                # Start building metrics file
                cat > "$METRICS_TMP" <<'EOF'
        # HELP container_health_status Container health status (0=healthy, 1=unhealthy, 2=starting, 3=none)
        # TYPE container_health_status gauge
        # HELP container_running Container running status (0=stopped, 1=running)
        # TYPE container_running gauge
        # HELP container_restart_count Container restart count
        # TYPE container_restart_count counter
        # HELP container_memory_usage_bytes Container resident memory usage in bytes
        # TYPE container_memory_usage_bytes gauge
        # HELP container_cpu_percent Container CPU utilization percent (podman stats CPUPerc, 100=one full core)
        # TYPE container_cpu_percent gauge
        # HELP container_image_prune_last_trigger_seconds Unix time the user's rootless podman-image-prune timer last triggered
        # TYPE container_image_prune_last_trigger_seconds gauge
        # HELP container_image_prune_failed Whether the user's last rootless podman-image-prune run failed (1=failed, 0=ok)
        # TYPE container_image_prune_failed gauge
        EOF

                # Function to collect metrics for a podman instance
                collect_container_metrics() {
                  local podman_cmd="$1"
                  local user="$2"

                  # Get all containers managed by quadlet (have PODMAN_SYSTEMD_UNIT label)
                  $podman_cmd ps -a \
                    --filter "label=PODMAN_SYSTEMD_UNIT" \
                    --format "{{.Names}}\t{{.Status}}\t{{.State}}" 2>/dev/null | while IFS=$'\t' read -r name status state; do

                    # Skip empty lines
                    [[ -z "$name" ]] && continue

                    # Determine running status
                    if [[ "$state" == "running" ]]; then
                      running=1
                    else
                      running=0
                    fi

                    # Get health status from container inspect
                    health_status=$($podman_cmd inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || echo "none")

                    case "$health_status" in
                      "healthy")
                        health=0
                        ;;
                      "unhealthy")
                        health=1
                        ;;
                      "starting")
                        health=2
                        ;;
                      *)
                        health=3  # No health check configured
                        ;;
                    esac

                    # Get restart count from systemd
                    service_name=$($podman_cmd inspect "$name" --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' 2>/dev/null || echo "unknown")
                    if [[ "$service_name" != "unknown" && -n "$service_name" ]]; then
                      if [[ "$user" == "root" ]]; then
                        restart_count=$(systemctl show "$service_name" --property=NRestarts --value 2>/dev/null || echo "0")
                      else
                        # For rootless containers, query user's systemd
                        restart_count=$(systemctl --user -M "$user@" show "$service_name" --property=NRestarts --value 2>/dev/null || echo "0")
                      fi
                    else
                      restart_count=0
                    fi

                    # Use container name for matching (open-webui alert expects container="open-webui")
                    cat >> "$METRICS_TMP" <<EOF
        container_health_status{name="$name",container="$name",user="$user"} $health
        container_running{name="$name",container="$name",user="$user"} $running
        container_restart_count{name="$name",container="$name",user="$user"} $restart_count
        EOF

                    # Resident memory + CPU (best-effort; emitted only when stats parse
                    # cleanly). ONE podman stats call returns both fields tab-separated so
                    # we never double the (expensive) per-container stats invocation.
                    #   MemUsage looks like "105.4MB / 66.84GB" — take the usage field, strip
                    #     the B/iB suffix, convert via numfmt. No memory LIMIT is emitted
                    #     (most containers run unlimited, so the limit field is just host RAM).
                    #   CPUPerc looks like "0.31%" — strip the trailing '%'. 100 == one full
                    #     core (podman normalizes per-CPU like docker), so a 4-vCPU container
                    #     can legitimately read up to ~400.
                    # Tab built via printf to avoid a doubled single-quote (the Nix
                    # indented-string terminator) adjacent to the Go-template braces
                    # in the --format argument.
                    tab=$(${pkgs.coreutils}/bin/printf '\t')
                    stats_line=$($podman_cmd stats --no-stream --format "{{.MemUsage}}''${tab}{{.CPUPerc}}" "$name" 2>/dev/null) || stats_line=""
                    if [[ -n "$stats_line" ]]; then
                      mem_raw="''${stats_line%%"''${tab}"*}"
                      cpu_raw="''${stats_line##*"''${tab}"}"
                      mem_raw="$(echo "$mem_raw" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
                      if [[ -n "$mem_raw" && "$mem_raw" != "--" ]]; then
                        mem_clean="''${mem_raw%B}"; mem_clean="''${mem_clean%i}"
                        mem_bytes=$(${pkgs.coreutils}/bin/numfmt --from=iec "$mem_clean" 2>/dev/null) || mem_bytes=""
                        if [[ -n "$mem_bytes" ]]; then
                          echo "container_memory_usage_bytes{name=\"$name\",container=\"$name\",user=\"$user\"} $mem_bytes" >> "$METRICS_TMP"
                        fi
                      fi
                      cpu_clean="''${cpu_raw%\%}"
                      if [[ -n "$cpu_clean" && "$cpu_clean" != "--" && "$cpu_clean" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                        echo "container_cpu_percent{name=\"$name\",container=\"$name\",user=\"$user\"} $cpu_clean" >> "$METRICS_TMP"
                      fi
                    fi
                  done
                }

                # Collect metrics from root podman
                collect_container_metrics "${pkgs.podman}/bin/podman" "root"

                # Collect metrics from rootless podman users. This list is derived
                # from home-manager.users at eval time — see the rootlessUsers
                # let-binding at the top of this file for the predicate and the
                # rationale for each structural exclusion.
                ROOTLESS_USERS="${lib.concatStringsSep " " rootlessUsers}"

                for user in $ROOTLESS_USERS; do
                  if id "$user" &>/dev/null; then
                    collect_container_metrics "${pkgs.sudo}/bin/sudo -u $user ${pkgs.podman}/bin/podman" "$user"

                    # Rootless weekly image-prune health (HM user unit
                    # podman-image-prune.{timer,service} from
                    # rootless-podman-image-prune.nix). Only emit for users that
                    # actually have the timer installed — list-unit-files prints a
                    # row iff the unit exists, so an empty result means skip (a
                    # rootless user with no prune unit shouldn't carry the series).
                    if systemctl --user -M "$user@" list-unit-files podman-image-prune.timer --no-legend 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q 'podman-image-prune.timer'; then
                      # LastTriggerUSec is a human-formatted timestamp on this
                      # systemd ("Mon 2026-06-08 00:52:11 PDT"); date -d parses it
                      # to epoch. A never-triggered timer reports "n/a"/"0"/empty,
                      # which date -d rejects -> we omit the series (alert treats
                      # absent as stale, which is correct: it has never run).
                      last_trigger_raw=$(systemctl --user -M "$user@" show podman-image-prune.timer --property=LastTriggerUSec --value 2>/dev/null || echo "")
                      last_trigger_epoch=$(${pkgs.coreutils}/bin/date -d "$last_trigger_raw" +%s 2>/dev/null || echo "")
                      if [[ -n "$last_trigger_epoch" ]]; then
                        echo "container_image_prune_last_trigger_seconds{user=\"$user\"} $last_trigger_epoch" >> "$METRICS_TMP"
                      fi

                      # Result=success -> 0; anything else (failed/timeout/exit-code)
                      # -> 1. Default to 0 when the property can't be read so a
                      # transient query miss doesn't fire ContainerPruneFailed.
                      prune_result=$(systemctl --user -M "$user@" show podman-image-prune.service --property=Result --value 2>/dev/null || echo "success")
                      if [[ "$prune_result" == "success" || -z "$prune_result" ]]; then
                        prune_failed=0
                      else
                        prune_failed=1
                      fi
                      echo "container_image_prune_failed{user=\"$user\"} $prune_failed" >> "$METRICS_TMP"
                    fi
                  fi
                done

                # Atomically replace metrics file
                mv "$METRICS_TMP" "$METRICS_FILE"
                chmod 644 "$METRICS_FILE"
      '';

      # Run as root to access podman socket and sudo to other users
      User = "root";
      Group = "root";
    };
  };

  # Timer to run exporter every 2 minutes
  # Reduced from 30s to 120s to decrease systemd-logind session creation
  # Each run creates a session per rootless user (~3 log lines each)
  # At 30s: ~12,960 lines/day; At 120s: ~3,240 lines/day
  systemd.timers.container-health-exporter = {
    description = "Container Health Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "120s"; # 2 minutes - balances monitoring vs log volume
      AccuracySec = "5s";
    };
  };

  # Ensure node_exporter can read the metrics file
  # Note: The directory /var/lib/prometheus-node-exporter-textfiles is
  # created by the prometheus node_exporter service configuration

  # ---------------------------------------------------------------------------
  # Per-user container store size exporter
  # ---------------------------------------------------------------------------
  # Emits container_store_size_bytes{user="<user>"} for each podman store under
  # /var/lib/containers/. This is the early-warning signal for dangling-image
  # bloat (the 2026 48G dangling-image incident: moving-tag pulls leave <none> copies that
  # the weekly per-user `podman image prune -af` is meant to keep down).
  #
  # `du -sb` is the only accurate measure but is expensive (~11s over all stores
  # as of 2026-06-10), so this runs on its OWN daily timer rather than piggybacking
  # on the 2-minute health-exporter cadence. It writes a SEPARATE textfile so the
  # two collectors never clobber each other's atomic temp file.
  systemd.services.container-store-size-exporter = {
    description = "Container Store Size Exporter for Prometheus";
    after = [ "local-fs.target" ];
    # No wantedBy - service only runs via timer

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "container-store-size-exporter" ''
        set -euo pipefail

        METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/container_store_size.prom"
        METRICS_TMP="$METRICS_FILE.tmp"

        mkdir -p "$(dirname "$METRICS_FILE")"

        {
          echo "# HELP container_store_size_bytes Disk usage of a podman store under /var/lib/containers (bytes, du -sb)"
          echo "# TYPE container_store_size_bytes gauge"
        } > "$METRICS_TMP"

        # One entry per top-level dir under /var/lib/containers. The root graphroot
        # is the directory literally named "storage"; relabel it user="root" so the
        # series matches the convention used by container_running{user="root"}.
        #
        # DELIBERATELY a runtime glob, NOT the derived `rootlessUsers` list above.
        # This collector measures disk reality, not declared intent, and the whole
        # point is to see stores that NO LONGER have an owner: the 2026-06-01
        # cleanup found ~18G of orphaned images in legacy container-db / mindsdb /
        # container-misc stores whose HM users had already been removed and whose
        # UIDs had been recycled. Deriving this loop from home-manager.users would
        # make exactly those orphans invisible — i.e. it would blind the exporter
        # to its primary failure mode. It also legitimately sees "storage" (root)
        # and technitium-dns-exporter, neither of which is an HM user.
        for dir in /var/lib/containers/*/; do
          [[ -d "$dir" ]] || continue
          name="$(${pkgs.coreutils}/bin/basename "$dir")"
          # Skip the shared image-pull cache (not attributable to a single user).
          [[ "$name" == "cache" ]] && continue
          user="$name"
          [[ "$name" == "storage" ]] && user="root"
          size="$(${pkgs.coreutils}/bin/du -sb "$dir" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)" || size=""
          [[ -n "$size" ]] || continue
          echo "container_store_size_bytes{user=\"$user\"} $size" >> "$METRICS_TMP"
        done

        mv "$METRICS_TMP" "$METRICS_FILE"
        chmod 644 "$METRICS_FILE"
      '';

      # Needs root to traverse the 0700 per-user store directories.
      User = "root";
      Group = "root";
    };
  };

  # Daily timer for the store-size exporter (du is too heavy for the 2-min cadence)
  systemd.timers.container-store-size-exporter = {
    description = "Container Store Size Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "10m";
      AccuracySec = "1m";
    };
  };

  # Container health alerting rules
  # Alert rules are defined in /etc/nixos/modules/monitoring/alerts/container-health.yaml
  # and loaded by prometheus-server.nix
}
