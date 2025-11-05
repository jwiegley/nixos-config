{ config, lib, pkgs, ... }:

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
    after = [ "network.target" "podman.service" ];
    # No wantedBy - service only runs via timer

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "container-health-exporter" ''
        #!/usr/bin/env bash
        set -euo pipefail

        METRICS_FILE="/var/lib/prometheus/node-exporter/container_health.prom"
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

        # Get all containers managed by quadlet (have PODMAN_SYSTEMD_UNIT label)
        ${pkgs.podman}/bin/podman ps -a \
          --filter "label=PODMAN_SYSTEMD_UNIT" \
          --format "{{.Names}}\t{{.Status}}\t{{.State}}" | while IFS=$'\t' read -r name status state; do

          # Determine running status
          if [[ "$state" == "running" ]]; then
            running=1
          else
            running=0
          fi

          # Get health status from container inspect
          health_status=$(${pkgs.podman}/bin/podman inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || echo "none")

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
          service_name=$(${pkgs.podman}/bin/podman inspect "$name" --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' 2>/dev/null || echo "unknown")
          if [[ "$service_name" != "unknown" ]]; then
            restart_count=$(systemctl show "$service_name" --property=NRestarts --value 2>/dev/null || echo "0")
          else
            restart_count=0
          fi

          # Write metrics
          cat >> "$METRICS_TMP" <<EOF
container_health_status{name="$name"} $health
container_running{name="$name"} $running
container_restart_count{name="$name"} $restart_count
EOF
        done

        # Atomically replace metrics file
        mv "$METRICS_TMP" "$METRICS_FILE"
        chmod 644 "$METRICS_FILE"
      '';

      # Run as root to access podman socket
      User = "root";
      Group = "root";
    };
  };

  # Timer to run exporter every 30 seconds
  systemd.timers.container-health-exporter = {
    description = "Container Health Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };

  # Ensure node_exporter can read the metrics file
  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus/node-exporter 0755 root root -"
  ];

  # Add alerting rules for container health
  services.prometheus.rules = [
    ''
      groups:
        - name: container_health
          interval: 30s
          rules:
            - alert: ContainerUnhealthy
              expr: container_health_status{name!=""} == 1
              for: 2m
              labels:
                severity: warning
              annotations:
                summary: "Container {{ $labels.name }} is unhealthy"
                description: "Container {{ $labels.name }} has failed health checks for 2 minutes"

            - alert: ContainerDown
              expr: container_running{name!=""} == 0
              for: 1m
              labels:
                severity: critical
              annotations:
                summary: "Container {{ $labels.name }} is not running"
                description: "Container {{ $labels.name }} has been stopped for 1 minute"

            - alert: ContainerRestarting
              expr: rate(container_restart_count[5m]) > 0.1
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Container {{ $labels.name }} is restarting frequently"
                description: "Container {{ $labels.name }} has restarted {{ $value }} times in the last 5 minutes"

            - alert: ContainerHealthCheckFailing
              expr: container_health_status{name!=""} == 2
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Container {{ $labels.name }} health check stuck in starting state"
                description: "Container {{ $labels.name }} has been in 'starting' health state for 5 minutes"
    ''
  ];
}
