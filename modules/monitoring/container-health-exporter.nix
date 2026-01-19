{
  config,
  lib,
  pkgs,
  ...
}:

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
                  done
                }

                # Collect metrics from root podman
                collect_container_metrics "${pkgs.podman}/bin/podman" "root"

                # Collect metrics from rootless podman users
                # Add users who run rootless podman containers here
                ROOTLESS_USERS="open-webui"

                for user in $ROOTLESS_USERS; do
                  if id "$user" &>/dev/null; then
                    collect_container_metrics "${pkgs.sudo}/bin/sudo -u $user ${pkgs.podman}/bin/podman" "$user"
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

  # Container health alerting rules
  # Alert rules are defined in /etc/nixos/modules/monitoring/alerts/container-health.yaml
  # and loaded by prometheus-server.nix
}
