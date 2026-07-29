{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Directory for textfile collector metrics
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  # Get list of all backup names
  backupNames = builtins.attrNames config.services.restic.backups;

  # Critical services to monitor
  criticalServices = [
    # Infrastructure
    "postgresql"
    "nginx"
    "step-ca"
    "dovecot"
    "postfix"
    "radicale"

    # Monitoring Stack
    "prometheus"
    "alertmanager"
    "grafana"
    "loki"
    "victoriametrics"

    # Critical Application Services
    "home-assistant"
    "node-red"
    "jupyterlab"
    "technitium-dns-server"

    # Critical Dependencies
    "redis-litellm"
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

          # Get last run timestamp (real timestamp, not monotonic). Fall back
          # through several systemd properties so a backup caught mid-run never
          # reports epoch 0 -- a spurious 0 makes (time() - 0) > 36h and
          # false-trips BackupNotRunRecently:
          #   1. ExecMainExitTimestamp  - last completed run (normal idle case)
          #   2. ExecMainStartTimestamp - main process started (running, past
          #                               ExecStartPre)
          #   3. InactiveExitTimestamp  - unit began activating; the ONLY one of
          #                               the three set during ExecStartPre,
          #                               which for restic can last minutes (B2
          #                               repo prep). Without this rung a timer
          #                               tick landing in ExecStartPre wrote 0
          #                               and paged (Home: 03:50 activate, main
          #                               at 03:54:43 -> ~4m43s pre-start window
          #                               that coincides with the :50 tick).
          # All three are "n/a" only for a unit that has genuinely never started,
          # which correctly yields 0 so a never-run backup still alerts.
          LAST_RUN_TS=""
          for prop in ExecMainExitTimestamp ExecMainStartTimestamp InactiveExitTimestamp; do
            CANDIDATE=$(${pkgs.systemd}/bin/systemctl show -p "$prop" --value "$service" || echo "")
            if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "n/a" ]; then
              LAST_RUN_TS="$CANDIDATE"
              break
            fi
          done
          if [ -n "$LAST_RUN_TS" ]; then
            # Convert systemd timestamp to epoch seconds
            LAST_RUN_EPOCH=$(${pkgs.coreutils}/bin/date -d "$LAST_RUN_TS" +%s 2>/dev/null || echo "0")
          else
            # Service has never run
            LAST_RUN_EPOCH=0
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
    # Backup status exporter - runs every 15 minutes (see the timer below)
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
        # Every 15 minutes. Correctness no longer depends on dodging the backup
        # windows: backupStatusExporter resolves "last run" through an
        # ExecMainExit -> ExecMainStart -> InactiveExitTimestamp fallback chain,
        # so a tick landing mid-run reports the activation time, not 0. The :05
        # offset is kept only as harmless belt-and-suspenders -- staggered restic
        # backups (e.g. Home 03:50, Databases 02:50) otherwise collide with the
        # :50 tick during their multi-minute ExecStartPre (B2 repo prep).
        OnCalendar = "*:5/15"; # Every 15 minutes, offset by 5
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
      static_configs = [
        {
          targets = [ "127.0.0.1:9221" ];
        }
      ];
      scrape_interval = "10s"; # Check every 10 seconds for quick detection
      scrape_timeout = "5s";
    }
  ];

  # REMOVED 2026-07-28: this module used to add health-checks.yaml to
  # services.prometheus.ruleFiles explicitly. That file is ALREADY picked up by the
  # directory glob in monitoring/services/alerting.nix, so it was being loaded TWICE and
  # every rule in it evaluated twice -- directly observable in the live rules API, where
  # health_check_alerts' BackupServiceFailed and BackupNotRunRecently each appeared as two
  # separate entries. health-checks.yaml contains TWO groups -- health_check_alerts (12
  # rules) and certificate_alerts (7) -- so 19 rules were being evaluated twice, which is
  # the entire 534->510 delta apart from the 3 deleted backup rules and the 2 absorbed by
  # the mbsync consolidation.
  # NOTE, corrected: this did NOT affect the `certificates` group, which lives in
  # certificates.yaml and was never double-loaded -- only groups inside the one file listed
  # here were shadowed. And it did NOT double NOTIFICATION volume: both copies wrote into
  # the SAME series (10 distinct label sets, not 20), so identical Alertmanager
  # fingerprints deduplicated to one notification. The waste was evaluation, not paging.
  #
  # The glob in alerting.nix is now the single inclusion path for everything under
  # monitoring/alerts/. Do NOT re-add individual files here; add them to that directory
  # instead. The scrapeConfigs above are unaffected and remain live -- only the redundant
  # ruleFiles entry was removed.
}
