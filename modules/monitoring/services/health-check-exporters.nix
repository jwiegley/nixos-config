{ config, lib, pkgs, ... }:

let
  # Directory for textfile collector metrics
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  # Get list of all backup names
  backupNames = builtins.attrNames config.services.restic.backups;

  # Critical services to monitor
  criticalServices = [
    "postgresql"
    "nginx"
    "step-ca"
    "prometheus"
    "dovecot"
    "postfix"
  ];

  # Script to generate backup status metrics
  backupStatusExporter = pkgs.writeShellScript "backup-status-exporter" ''
    set -euo pipefail

    OUTPUT_FILE="${textfileDir}/backup_status.prom"
    TEMP_FILE="$OUTPUT_FILE.$$"

    # Write metrics header
    cat > "$TEMP_FILE" <<'HEADER'
# HELP backup_service_active Whether the backup service is currently active (1 = active, 0 = inactive)
# TYPE backup_service_active gauge
# HELP backup_service_failed Whether the backup service is in failed state (1 = failed, 0 = not failed)
# TYPE backup_service_failed gauge
# HELP backup_timer_active Whether the backup timer is active (1 = active, 0 = inactive)
# TYPE backup_timer_active gauge
# HELP backup_last_run_timestamp_seconds Timestamp of the last backup run
# TYPE backup_last_run_timestamp_seconds gauge
# HELP backup_last_run_success Whether the last backup run was successful (1 = success, 0 = failure)
# TYPE backup_last_run_success gauge
HEADER

    # Check each backup service
    for service in ${lib.concatStringsSep " " (map (n: "restic-backups-${n}") backupNames)}; do
      BACKUP_NAME="''${service#restic-backups-}"

      # Check service state
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$service"; then
        SERVICE_ACTIVE=1
      else
        SERVICE_ACTIVE=0
      fi

      # Check if service is failed
      if ${pkgs.systemd}/bin/systemctl is-failed --quiet "$service"; then
        SERVICE_FAILED=1
      else
        SERVICE_FAILED=0
      fi

      # Check timer state
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$service.timer"; then
        TIMER_ACTIVE=1
      else
        TIMER_ACTIVE=0
      fi

      # Get last run timestamp
      LAST_RUN_TS=$(${pkgs.systemd}/bin/systemctl show -p ExecMainExitTimestampMonotonic --value "$service" || echo "0")
      if [ "$LAST_RUN_TS" = "0" ] || [ -z "$LAST_RUN_TS" ]; then
        LAST_RUN_EPOCH=0
      else
        # Convert monotonic to epoch (approximate)
        CURRENT_EPOCH=$(date +%s)
        CURRENT_MONOTONIC=$(${pkgs.coreutils}/bin/cat /proc/uptime | ${pkgs.gawk}/bin/awk '{print int($1 * 1000000)}')
        LAST_RUN_EPOCH=$(( CURRENT_EPOCH - (CURRENT_MONOTONIC - LAST_RUN_TS) / 1000000 ))
      fi

      # Get result of last run
      RESULT=$(${pkgs.systemd}/bin/systemctl show -p Result --value "$service" || echo "unknown")
      if [ "$RESULT" = "success" ]; then
        LAST_RUN_SUCCESS=1
      else
        LAST_RUN_SUCCESS=0
      fi

      # Write metrics
      cat >> "$TEMP_FILE" <<EOF
backup_service_active{backup="$BACKUP_NAME"} $SERVICE_ACTIVE
backup_service_failed{backup="$BACKUP_NAME"} $SERVICE_FAILED
backup_timer_active{backup="$BACKUP_NAME"} $TIMER_ACTIVE
backup_last_run_timestamp_seconds{backup="$BACKUP_NAME"} $LAST_RUN_EPOCH
backup_last_run_success{backup="$BACKUP_NAME"} $LAST_RUN_SUCCESS
EOF
    done

    # Atomically replace the metrics file
    ${pkgs.coreutils}/bin/mv "$TEMP_FILE" "$OUTPUT_FILE"
    ${pkgs.coreutils}/bin/chmod 644 "$OUTPUT_FILE"
  '';

  # Simple HTTP exporter for critical services health
  criticalServicesExporter = pkgs.writeShellScript "critical-services-exporter" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    # HTTP response function
    http_response() {
      local code="$1"
      local content_type="$2"
      local body="$3"

      echo -ne "HTTP/1.1 $code\r\n"
      echo -ne "Content-Type: $content_type\r\n"
      echo -ne "Content-Length: ''${#body}\r\n"
      echo -ne "Connection: close\r\n"
      echo -ne "\r\n"
      echo -ne "$body"
    }

    # Generate metrics
    generate_metrics() {
      cat <<'HEADER'
# HELP critical_service_active Whether the critical service is active (1 = active, 0 = inactive)
# TYPE critical_service_active gauge
# HELP critical_service_failed Whether the critical service is in failed state (1 = failed, 0 = not failed)
# TYPE critical_service_failed gauge
# HELP critical_service_load_state Service load state (1 = loaded, 0 = not loaded)
# TYPE critical_service_load_state gauge
HEADER

      for service in ${lib.concatStringsSep " " criticalServices}; do
        # Check if service is active
        if ${pkgs.systemd}/bin/systemctl is-active --quiet "$service" 2>/dev/null; then
          ACTIVE=1
        else
          ACTIVE=0
        fi

        # Check if service is failed
        if ${pkgs.systemd}/bin/systemctl is-failed --quiet "$service" 2>/dev/null; then
          FAILED=1
        else
          FAILED=0
        fi

        # Check load state
        LOAD_STATE=$(${pkgs.systemd}/bin/systemctl show -p LoadState --value "$service" 2>/dev/null || echo "not-found")
        if [ "$LOAD_STATE" = "loaded" ]; then
          LOADED=1
        else
          LOADED=0
        fi

        cat <<EOF
critical_service_active{service="$service"} $ACTIVE
critical_service_failed{service="$service"} $FAILED
critical_service_load_state{service="$service"} $LOADED
EOF
      done
    }

    # Handle single HTTP request (socat fork spawns new instance per connection)
    # Read HTTP request (use read instead of head to avoid buffering issues)
    IFS= read -r REQUEST

    # Consume headers until we hit blank line
    while IFS= read -r line; do
      line=$(echo "$line" | tr -d '\r')
      [ -z "$line" ] && break
    done

    # Check if it's a GET request for /metrics
    if echo "$REQUEST" | grep -q "^GET /metrics"; then
      METRICS=$(generate_metrics)
      http_response "200 OK" "text/plain; version=0.0.4" "$METRICS"
    elif echo "$REQUEST" | grep -q "^GET /health"; then
      http_response "200 OK" "text/plain" "OK"
    else
      http_response "404 Not Found" "text/plain" "Not Found"
    fi
  '';
in
{
  # Systemd services for textfile exporters
  systemd.services = {
    # Backup status exporter - runs daily
    backup-status-exporter = {
      description = "Generate backup status metrics for Prometheus";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = backupStatusExporter;
        User = "root";
      };
    };

    # Critical services health exporter - HTTP server on port 9221
    critical-services-exporter = {
      description = "Critical services health exporter for Prometheus";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:9221,bind=127.0.0.1,reuseaddr,fork EXEC:${criticalServicesExporter}";
        Restart = "always";
        RestartSec = 5;
        User = "root";
      };
    };
  };

  # Timers for textfile exporters
  systemd.timers = {
    backup-status-exporter = {
      description = "Timer for backup status metrics exporter";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        OnBootSec = "10min";
        Persistent = true;
      };
    };
  };

  # Open firewall for critical services exporter (localhost only)
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 9221 ];

  # Prometheus scrape configuration for critical services exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "critical-services-health";
      static_configs = [{
        targets = [ "localhost:9221" ];
      }];
      scrape_interval = "10s";  # Check every 10 seconds for quick detection
      scrape_timeout = "5s";
    }
  ];

  # Add health check alert rules
  services.prometheus.ruleFiles = [
    ../../monitoring/alerts/health-checks.yaml
  ];
}
